import AuthenticationServices
import Foundation
import Observation

/// Where the saved Withings sign-in lives. The Keychain in the app; memory in tests.
protocol WithingsTokenStore {
    func load() -> WithingsTokens?
    func save(_ tokens: WithingsTokens)
    func clear()
}

struct KeychainWithingsTokens: WithingsTokenStore {
    private static let service = "com.getsetecho.app.withings"
    private static let account = "tokens"

    func load() -> WithingsTokens? {
        Keychain.data(service: Self.service, account: Self.account).flatMap { try? JSONCoding.decoder.decode(WithingsTokens.self, from: $0) }
    }

    func save(_ tokens: WithingsTokens) {
        if let data = try? JSONCoding.encoder.encode(tokens) { Keychain.set(data, service: Self.service, account: Self.account) }
    }

    func clear() { Keychain.delete(service: Self.service, account: Self.account) }
}

/// A weight source read before Apple Health. nil means not connected: weight comes from Apple Health alone.
@MainActor
protocol DirectWeightSource: AnyObject, Sendable {
    func directWeighIns(from start: Date, to end: Date) async -> [WithingsWeighIn]?
}

/// Withings direct (HANDOFF.md §9, P6): the scale's weigh-ins from Withings' API through the
/// backend, so the Withings app never has to be opened. Tokens stay in the Keychain; the weigh-ins
/// are cached on the phone with the time of the last fetch.
@MainActor
@Observable
final class WithingsService: DirectWeightSource {
    static let shared = WithingsService()

    /// Withings' rule: never more than one fetch every 10 minutes.
    static let minimumInterval: TimeInterval = 10 * 60
    /// The first fetch reaches back this far; later ones ask only for what changed since the last.
    static let firstLookBack: TimeInterval = 60 * 86_400
    /// Refresh an access token this close to expiring rather than have Withings refuse it.
    static let refreshMargin: TimeInterval = 5 * 60
    static let refusedMessage = "Withings signed Setecho out. Connect again; until then weight comes through Apple Health."

    private(set) var isConnected: Bool
    /// Withings refused the saved sign-in (revoked, or unused past the refresh token's life).
    private(set) var needsReconnect = false
    private(set) var isConnecting = false
    private(set) var weighIns: [WithingsWeighIn] = []
    private(set) var lastFetch: Date?
    private(set) var error: String?

    var lastWeighIn: WithingsWeighIn? { weighIns.last }

    private let api: any WithingsAPI
    private let tokens: any WithingsTokenStore
    private let cacheURL: URL?
    private let now: () -> Date
    /// Where the next fetch's `lastUpdate` starts: Withings returns weigh-ins changed since then.
    private var cursor: Date?
    private var fetching: Task<Void, Never>?

    init(api: any WithingsAPI = APIClient(), tokens: any WithingsTokenStore = KeychainWithingsTokens(),
         cacheURL: URL? = Store.defaultRoot().appendingPathComponent("withings.json"), now: @escaping () -> Date = { .now }) {
        self.api = api
        self.tokens = tokens
        self.cacheURL = cacheURL
        self.now = now
        self.isConnected = tokens.load() != nil
        loadCache()
    }

    // MARK: Sign-in

    /// Sign in through `authenticate` (ASWebAuthenticationSession in the app), check `state`, and
    /// post the code at once: Withings lets it live 30 seconds.
    func connect(authenticate: (URL) async throws -> URL) async {
        isConnecting = true
        error = nil
        defer { isConnecting = false }
        let state = Self.randomState()
        do {
            let url = try await api.withingsAuthorizeURL(state: state)
            let callback = try await authenticate(url)
            let code = try Self.code(from: callback, state: state)
            let fresh = try await api.withingsToken(code: code)
            tokens.save(fresh)
            isConnected = true
            needsReconnect = false
            cursor = nil
            await refreshIfDue(force: true)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // He closed the sheet: nothing to say.
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Forget the sign-in and the cached weigh-ins. Weight comes through Apple Health again.
    func disconnect() {
        tokens.clear()
        isConnected = false
        weighIns = []
        cursor = nil
        lastFetch = nil
        error = nil
        saveCache()
    }

    struct SignInError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The code from `setecho://withings?code=…&state=…`, only when `state` is the one this phone sent.
    nonisolated static func code(from callback: URL, state: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == state else { throw SignInError(message: "The Withings sign-in didn't match. Try again.") }
        if value("error") != nil { throw SignInError(message: "Withings didn't allow access. Try again and choose Allow.") }
        guard let code = value("code"), !code.isEmpty else { throw SignInError(message: "Withings sent no sign-in code. Try again.") }
        return code
    }

    nonisolated static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<bytes.count).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: Fetching

    /// Fetch new weigh-ins unless the last fetch was under 10 minutes ago. Called when Setecho comes
    /// to the foreground and when the check-in is drafted; concurrent callers share one fetch.
    func refreshIfDue(force: Bool = false) async {
        guard isConnected else { return }
        if let fetching {
            await fetching.value
            return
        }
        if !force, let lastFetch, now().timeIntervalSince(lastFetch) < Self.minimumInterval { return }
        let task = Task { await fetch() }
        fetching = task
        await task.value
        fetching = nil
    }

    func directWeighIns(from start: Date, to end: Date) async -> [WithingsWeighIn]? {
        guard isConnected else { return nil }
        await refreshIfDue()
        guard isConnected else { return nil }   // refused while fetching: Apple Health alone
        return weighIns.filter { $0.at >= start && $0.at < end }
    }

    private func fetch() async {
        guard var current = tokens.load() else {
            isConnected = false
            return
        }
        let started = now()
        lastFetch = started   // a failed attempt counts too, so a bad hour never hammers Withings
        do {
            if current.expiresAt.timeIntervalSince(started) < Self.refreshMargin {
                current = try await refresh(current)
            }
            let since = cursor ?? started.addingTimeInterval(-Self.firstLookBack)
            let fresh: [WithingsWeighIn]
            do {
                fresh = try await api.withingsWeights(accessToken: current.accessToken, lastUpdate: since)
            } catch let e as APIError where e.status == 401 {
                // The access token went bad before its time: refresh once and ask again.
                current = try await refresh(current)
                fresh = try await api.withingsWeights(accessToken: current.accessToken, lastUpdate: since)
            }
            merge(fresh)
            cursor = started.addingTimeInterval(-60)
            error = nil
        } catch let e as APIError where e.status == 401 {
            disconnect()
            needsReconnect = true
            error = Self.refusedMessage
        } catch {
            self.error = error.localizedDescription
        }
        saveCache()
    }

    /// Withings rotates the refresh token: the old one stops working 8 hours later, so the new
    /// pair is saved before anything else happens.
    private func refresh(_ old: WithingsTokens) async throws -> WithingsTokens {
        let fresh = try await api.withingsToken(refreshToken: old.refreshToken)
        tokens.save(fresh)
        return fresh
    }

    private func merge(_ fresh: [WithingsWeighIn]) {
        var byTime = Dictionary(weighIns.map { ($0.at, $0) }, uniquingKeysWith: { _, new in new })
        for w in fresh { byTime[w.at] = w }
        let oldest = now().addingTimeInterval(-Self.firstLookBack * 2)
        weighIns = byTime.values.filter { $0.at >= oldest }.sorted { $0.at < $1.at }
    }

    // MARK: Cache

    private struct Cache: Codable {
        var weighIns: [WithingsWeighIn]
        var lastFetch: Date?
        var cursor: Date?
    }

    private func loadCache() {
        guard isConnected, let cacheURL, let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONCoding.decoder.decode(Cache.self, from: data) else { return }
        weighIns = cache.weighIns
        lastFetch = cache.lastFetch
        cursor = cache.cursor
    }

    private func saveCache() {
        guard let cacheURL else { return }
        let cache = Cache(weighIns: weighIns, lastFetch: lastFetch, cursor: cursor)
        guard let data = try? JSONCoding.encoder.encode(cache) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
