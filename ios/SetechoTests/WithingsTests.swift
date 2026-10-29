import Foundation
import Testing
@testable import Setecho

// Withings direct (HANDOFF.md §9, P6), offline: the backend is a fake, the Keychain is memory.

private let t0 = Date(timeIntervalSince1970: 1_793_000_000) // Oct 26 2026, 07:33 UTC

private final class MemoryTokens: WithingsTokenStore {
    var tokens: WithingsTokens?
    var saved: [WithingsTokens] = []
    init(_ tokens: WithingsTokens? = nil) { self.tokens = tokens }
    func load() -> WithingsTokens? { tokens }
    func save(_ tokens: WithingsTokens) { self.tokens = tokens; saved.append(tokens) }
    func clear() { tokens = nil }
}

private final class FakeWithings: WithingsAPI, @unchecked Sendable {
    var weights: [WithingsWeighIn] = []
    /// Access tokens Withings refuses on /weights.
    var refusedAccess: Set<String> = []
    var refuseRefresh = false
    var refreshCount = 0
    var weightCalls: [(token: String, since: Date)] = []
    var refreshedWith: [String] = []
    var exchangedCodes: [String] = []
    var authorizeStates: [String] = []

    func withingsAuthorizeURL(state: String) async throws -> URL {
        authorizeStates.append(state)
        return URL(string: "https://account.withings.com/oauth2_user/authorize2?state=\(state)")!
    }

    func withingsToken(code: String) async throws -> WithingsTokens {
        exchangedCodes.append(code)
        return WithingsTokens(accessToken: "access-0", refreshToken: "refresh-0", expiresAt: t0.addingTimeInterval(3 * 3600))
    }

    func withingsToken(refreshToken: String) async throws -> WithingsTokens {
        refreshedWith.append(refreshToken)
        if refuseRefresh { throw APIError(status: 401, message: "Withings refused the sign-in") }
        refreshCount += 1
        return WithingsTokens(accessToken: "access-\(refreshCount)", refreshToken: "refresh-\(refreshCount)",
                              expiresAt: t0.addingTimeInterval(3 * 3600))
    }

    func withingsWeights(accessToken: String, lastUpdate: Date) async throws -> [WithingsWeighIn] {
        weightCalls.append((accessToken, lastUpdate))
        if refusedAccess.contains(accessToken) { throw APIError(status: 401, message: "Withings refused the sign-in") }
        return weights
    }
}

private func valid(_ access: String = "access-0", refresh: String = "refresh-0", expires: Date = t0.addingTimeInterval(3 * 3600)) -> WithingsTokens {
    WithingsTokens(accessToken: access, refreshToken: refresh, expiresAt: expires)
}

@MainActor
private func service(_ api: FakeWithings, _ tokens: MemoryTokens, clock: @escaping () -> Date = { t0 }) -> WithingsService {
    WithingsService(api: api, tokens: tokens, cacheURL: nil, now: clock)
}

// MARK: Wire format

@Test func weighInsDecodeFromTheBackendsJSON() throws {
    let json = #"[{"at": "2026-10-26T07:33:20Z", "lb": 181.11}, {"at": "2026-10-27T07:33:20Z", "lb": 180.56}]"#
    let weighIns = try JSONCoding.decoder.decode([WithingsWeighIn].self, from: Data(json.utf8))
    #expect(weighIns == [WithingsWeighIn(at: t0, lb: 181.11), WithingsWeighIn(at: t0.addingTimeInterval(86_400), lb: 180.56)])
    let tokens = try JSONCoding.decoder.decode(WithingsTokens.self, from: Data(
        #"{"accessToken": "a", "refreshToken": "r", "expiresAt": "2026-10-26T10:33:20Z"}"#.utf8))
    #expect(tokens.expiresAt == t0.addingTimeInterval(3 * 3600))
}

// MARK: Sign-in

@Test func theCodeIsTakenOnlyWithTheStateThisPhoneSent() throws {
    let ok = URL(string: "setecho://withings?code=abc&state=s1")!
    #expect(try WithingsService.code(from: ok, state: "s1") == "abc")
    #expect(throws: WithingsService.SignInError.self) { try WithingsService.code(from: ok, state: "other") }
    let denied = URL(string: "setecho://withings?error=access_denied&state=s1")!
    #expect(throws: WithingsService.SignInError.self) { try WithingsService.code(from: denied, state: "s1") }
    let empty = URL(string: "setecho://withings?state=s1")!
    #expect(throws: WithingsService.SignInError.self) { try WithingsService.code(from: empty, state: "s1") }
}

@Test func statesAreRandomAndURLSafe() {
    let a = WithingsService.randomState(), b = WithingsService.randomState()
    #expect(a != b)
    #expect(a.count >= 32)
    #expect(a.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
}

@MainActor @Test func connectingExchangesTheCodeAtOnceAndFetches() async {
    let api = FakeWithings()
    api.weights = [WithingsWeighIn(at: t0, lb: 181.11)]
    let tokens = MemoryTokens()
    let withings = service(api, tokens)
    await withings.connect { url in
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: "setecho://withings?code=code-1&state=\(state)")!
    }
    #expect(api.exchangedCodes == ["code-1"])
    #expect(tokens.tokens == valid())
    #expect(withings.isConnected)
    #expect(withings.lastWeighIn?.lb == 181.11)
    #expect(api.weightCalls.first?.since == t0.addingTimeInterval(-WithingsService.firstLookBack))
}

@MainActor @Test func aMismatchedStateSavesNothing() async {
    let api = FakeWithings()
    let tokens = MemoryTokens()
    let withings = service(api, tokens)
    await withings.connect { _ in URL(string: "setecho://withings?code=code-1&state=forged")! }
    #expect(api.exchangedCodes.isEmpty)
    #expect(tokens.tokens == nil)
    #expect(!withings.isConnected)
    #expect(withings.error != nil)
}

// MARK: Refresh rotation

@MainActor @Test func anExpiringTokenIsRefreshedAndTheRotatedRefreshTokenSaved() async {
    let api = FakeWithings()
    let tokens = MemoryTokens(valid(expires: t0.addingTimeInterval(60)))   // a minute left
    var now = t0
    let withings = service(api, tokens, clock: { now })
    await withings.refreshIfDue()
    #expect(api.refreshedWith == ["refresh-0"])
    #expect(tokens.tokens?.refreshToken == "refresh-1")
    #expect(api.weightCalls.map { $0.token } == ["access-1"])

    // Next time it needs refreshing, it uses the new refresh token, never the old one.
    tokens.tokens?.expiresAt = now.addingTimeInterval(11 * 60)
    now = now.addingTimeInterval(11 * 60)
    await withings.refreshIfDue()
    #expect(api.refreshedWith == ["refresh-0", "refresh-1"])
    #expect(tokens.saved.map(\.refreshToken) == ["refresh-1", "refresh-2"])
}

@MainActor @Test func aRefusedAccessTokenRefreshesOnceAndAsksAgain() async {
    let api = FakeWithings()
    api.refusedAccess = ["access-0"]
    api.weights = [WithingsWeighIn(at: t0, lb: 180.56)]
    let tokens = MemoryTokens(valid())
    let withings = service(api, tokens)
    await withings.refreshIfDue()
    #expect(api.weightCalls.map { $0.token } == ["access-0", "access-1"])
    #expect(tokens.tokens?.refreshToken == "refresh-1")
    #expect(withings.isConnected)
    #expect(withings.weighIns.count == 1)
}

@MainActor @Test func fetchesAreAtMostEveryTenMinutes() async {
    let api = FakeWithings()
    var now = t0
    let withings = service(api, MemoryTokens(valid(expires: t0.addingTimeInterval(86_400))), clock: { now })
    await withings.refreshIfDue()
    now = now.addingTimeInterval(9 * 60)
    await withings.refreshIfDue()
    #expect(api.weightCalls.count == 1)
    now = now.addingTimeInterval(61)
    await withings.refreshIfDue()
    #expect(api.weightCalls.count == 2)
    // The second fetch asks only for what changed since the first (with a minute of slack).
    #expect(api.weightCalls[1].since == t0.addingTimeInterval(-60))
}

// MARK: Falling back to Apple Health

@MainActor @Test func noTokenMeansAppleHealthAlone() async {
    let api = FakeWithings()
    let withings = service(api, MemoryTokens())
    #expect(await withings.directWeighIns(from: t0, to: t0.addingTimeInterval(86_400)) == nil)
    #expect(api.weightCalls.isEmpty)
    let health = [HealthService.WeightSample(at: t0, lb: 181.2, source: "Withings", direct: false)]
    #expect(HealthService.mergeWeights(health: health, direct: nil) == health)
}

@MainActor @Test func aRefusedRefreshDisconnectsAndFallsBackToAppleHealth() async {
    let api = FakeWithings()
    api.refusedAccess = ["access-0"]
    api.refuseRefresh = true
    let tokens = MemoryTokens(valid())
    let withings = service(api, tokens)
    let direct = await withings.directWeighIns(from: t0.addingTimeInterval(-86_400), to: t0.addingTimeInterval(86_400))
    #expect(direct == nil)
    #expect(tokens.tokens == nil)
    #expect(!withings.isConnected)
    #expect(withings.needsReconnect)
    #expect(withings.error == WithingsService.refusedMessage)
}

@MainActor @Test func aNetworkFailureKeepsTheSignInAndTheCachedWeighIns() async {
    final class Offline: WithingsAPI, @unchecked Sendable {
        func withingsAuthorizeURL(state: String) async throws -> URL { throw URLError(.notConnectedToInternet) }
        func withingsToken(code: String) async throws -> WithingsTokens { throw URLError(.notConnectedToInternet) }
        func withingsToken(refreshToken: String) async throws -> WithingsTokens { throw URLError(.notConnectedToInternet) }
        func withingsWeights(accessToken: String, lastUpdate: Date) async throws -> [WithingsWeighIn] { throw URLError(.notConnectedToInternet) }
    }
    let tokens = MemoryTokens(valid())
    let withings = WithingsService(api: Offline(), tokens: tokens, cacheURL: nil, now: { t0 })
    await withings.refreshIfDue()
    #expect(withings.isConnected)
    #expect(tokens.tokens != nil)
    #expect(withings.error != nil)
}

// MARK: HealthService's weight source

@Test func directWeighInsWinAndADuplicateIsKeptOnce() {
    let day = 86_400.0
    let health: [HealthService.WeightSample] = [
        // Withings wrote Monday's weigh-in to Health too, a few seconds apart.
        .init(at: t0.addingTimeInterval(5), lb: 181.1, source: "Withings", direct: false),
        // Tuesday only reached Health (typed in by hand).
        .init(at: t0.addingTimeInterval(day), lb: 180.9, source: "Health", direct: false),
    ]
    let direct = [WithingsWeighIn(at: t0, lb: 181.11), WithingsWeighIn(at: t0.addingTimeInterval(2 * day), lb: 180.34)]
    let merged = HealthService.mergeWeights(health: health, direct: direct)
    #expect(merged.map(\.lb) == [181.11, 180.9, 180.34])
    #expect(merged.map(\.direct) == [true, false, true])
    #expect(merged.map(\.source) == ["Withings", "Health", "Withings"])
}

@Test func theLatestWeighInNamesItsRoute() {
    let day = 86_400.0
    func dayIndex(_ d: Date) -> Int? { Int(d.timeIntervalSince(t0) / day) }
    let direct = [
        HealthService.WeightSample(at: t0, lb: 181.11, source: "Withings", direct: true),
        HealthService.WeightSample(at: t0.addingTimeInterval(3600), lb: 182.0, source: "Withings", direct: true),  // later that day
        HealthService.WeightSample(at: t0.addingTimeInterval(day), lb: 180.56, source: "Withings", direct: true),
    ]
    let first = HealthService.firstPerDay(direct, day: dayIndex)
    #expect(first.byDay == [0: 181.11, 1: 180.56])   // the morning weigh-in, not the later one
    #expect(first.latestDirect)

    let lastFromHealth = direct + [HealthService.WeightSample(at: t0.addingTimeInterval(2 * day), lb: 180.3, source: "Health", direct: false)]
    #expect(!HealthService.firstPerDay(lastFromHealth, day: dayIndex).latestDirect)
}
