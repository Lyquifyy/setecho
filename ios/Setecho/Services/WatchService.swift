import ConnectIQ
import Foundation
import Observation

/// The Garmin Venu 4 through Garmin's Connect IQ companion SDK (HANDOFF.md §7, Garmin watch).
/// Device selection goes through the Garmin Connect app and comes back through our URL scheme.
/// Messages are small dictionaries each way; times from the watch are its uptime in ms and are
/// converted to phone time from a ping/pong round trip, never from arrival time.
@MainActor
@Observable
final class WatchService: NSObject {
    static let shared = WatchService()

    /// The watch app's id: the same UUID as `id` in watch/manifest.xml (hex without dashes there).
    static let appUUID = UUID(uuidString: "F3A350D6-9CA3-4EB0-9079-5767C594B75B")!
    static let urlScheme = "setecho-ciq"
    static let protocolVersion = 1

    enum Status: Equatable {
        case notConnected
        case connecting
        case connected(name: String)
        case appMissing(name: String)
    }

    /// One message, either way, for the probe screen and the session debug JSON.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var at: Date
        var direction: String   // "in" or "out"
        var text: String
        /// Watch time → phone time delay, seconds, when the message carried a watch timestamp.
        var delay: Double?
    }

    private(set) var status: Status = .notConnected
    private(set) var log: [Entry] = []
    private(set) var lastMessageAt: Date?
    private(set) var lastError: String?
    /// Phone time (seconds since reference) minus watch uptime (seconds), from the last pong.
    private(set) var clockOffset: Double?
    private(set) var roundTripMs: Double?
    private(set) var isReady = false

    /// Set start/end, taps and pongs, decoded (HANDOFF.md §4, WatchEvent).
    var onEvent: ((WatchEvent) -> Void)?

    private var device: IQDevice?
    private var app: IQApp?
    private var pingSentAt: Date?

    /// Call once at launch. Safe to call again.
    func initialize() {
        guard !isReady else { return }
        ConnectIQ.sharedInstance().initialize(withUrlScheme: Self.urlScheme, uiOverrideDelegate: nil)
        isReady = true
        restoreDevice()
    }

    // MARK: Pairing

    /// Opens Garmin Connect to pick the watch; the answer arrives through `handle(url:)`.
    func connect() {
        initialize()
        status = .connecting
        ConnectIQ.sharedInstance().showDeviceSelection()
    }

    /// The return URL from Garmin Connect (RootView's onOpenURL).
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == Self.urlScheme else { return false }
        initialize()
        let devices = ConnectIQ.sharedInstance().parseDeviceSelectionResponse(from: url) as? [IQDevice] ?? []
        guard let first = devices.first else {
            status = .notConnected
            lastError = "Garmin Connect returned no watch."
            return true
        }
        UserDefaults.standard.set(first.uuid.uuidString, forKey: "watchDeviceUUID")
        UserDefaults.standard.set(Self.name(of: first), forKey: "watchDeviceName")
        use(device: first)
        return true
    }

    private func restoreDevice() {
        guard let string = UserDefaults.standard.string(forKey: "watchDeviceUUID"), let uuid = UUID(uuidString: string) else { return }
        let name = UserDefaults.standard.string(forKey: "watchDeviceName") ?? "Garmin"
        use(device: IQDevice(id: uuid, modelName: name, friendlyName: name))
    }

    nonisolated static func name(of device: IQDevice) -> String {
        let friendly = device.friendlyName ?? ""
        if !friendly.isEmpty { return friendly }
        let model = device.modelName ?? ""
        return model.isEmpty ? "Garmin" : model
    }

    private func use(device: IQDevice) {
        self.device = device
        let app = IQApp(uuid: Self.appUUID, store: Self.appUUID, device: device)
        self.app = app
        ConnectIQ.sharedInstance().register(forDeviceEvents: device, delegate: self)
        ConnectIQ.sharedInstance().register(forAppMessages: app, delegate: self)
        status = .connecting
        checkApp()
    }

    private func checkApp() {
        guard let app, let device else { return }
        let name = Self.name(of: device)
        ConnectIQ.sharedInstance().getAppStatus(app) { [weak self] appStatus in
            let installed = appStatus?.isInstalled ?? false
            Task { @MainActor in
                guard let self else { return }
                if installed {
                    self.status = .connected(name: name)
                    self.ping()
                } else {
                    self.status = .appMissing(name: name)
                }
            }
        }
    }

    func forget() {
        if let device { ConnectIQ.sharedInstance().unregister(forDeviceEvents: device, delegate: self) }
        if let app { ConnectIQ.sharedInstance().unregister(forAppMessages: app, delegate: self) }
        device = nil
        app = nil
        UserDefaults.standard.removeObject(forKey: "watchDeviceUUID")
        status = .notConnected
    }

    // MARK: Messages out

    func send(_ payload: [String: Any]) {
        guard let app else { return }
        let text = Self.describe(payload)
        log.insert(Entry(at: .now, direction: "out", text: text, delay: nil), at: 0)
        ConnectIQ.sharedInstance().sendMessage(payload, to: app, progress: nil) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if result != .success { self.lastError = "Send failed (\(result.rawValue))" }
            }
        }
    }

    func ping() {
        pingSentAt = .now
        send(["t": "ping", "at": Self.phoneMs(.now)])
    }

    func sendConfig(startStd: Double, endStd: Double) {
        send(["t": "config", "startStd": startStd, "endStd": endStd])
    }

    func sendTarget(exercise: String, load: String, reps: String, set: String) {
        send(["t": "target", "ex": exercise, "load": load, "reps": reps, "set": set])
    }

    func sendLogged(reps: Int, source: String) {
        send(["t": "logged", "reps": reps, "src": source])
    }

    func sendRest(endsAt: Date) {
        guard let watchMs = watchMs(for: endsAt) else { return }
        send(["t": "rest", "endsAt": watchMs])
    }

    func sendEnd() {
        send(["t": "end"])
    }

    /// "Test buzz": the watch vibrates on a logged message.
    func testBuzz() {
        sendLogged(reps: 8, source: "Test")
    }

    // MARK: Clock

    static func phoneMs(_ date: Date) -> Int64 { Int64(date.timeIntervalSinceReferenceDate * 1000) }

    /// Watch uptime ms → phone time, from the last pong.
    func phoneTime(forWatchMs ms: Int64) -> Date? {
        guard let clockOffset else { return nil }
        return Date(timeIntervalSinceReferenceDate: Double(ms) / 1000 + clockOffset)
    }

    func watchMs(for date: Date) -> Int64? {
        guard let clockOffset else { return nil }
        return Int64((date.timeIntervalSinceReferenceDate - clockOffset) * 1000)
    }

    // MARK: Messages in

    func received(_ payload: [String: Any]) {
        lastMessageAt = .now
        let text = Self.describe(payload)
        var delay: Double?
        if let event = WatchEvent.decode(payload) {
            switch event {
            case .pong(let watchMs, let echoMs):
                let sent = Date(timeIntervalSinceReferenceDate: Double(echoMs) / 1000)
                let rtt = Date.now.timeIntervalSince(sent)
                roundTripMs = rtt * 1000
                // The watch stamped its reply halfway through the round trip.
                clockOffset = sent.timeIntervalSinceReferenceDate + rtt / 2 - Double(watchMs) / 1000
                delay = rtt / 2
            case .setStart(let at):
                delay = phoneTime(forWatchMs: at).map { Date.now.timeIntervalSince($0) }
            case .setEnd(_, let at, _, _):
                delay = phoneTime(forWatchMs: at).map { Date.now.timeIntervalSince($0) }
            case .hello, .tap:
                break
            }
            onEvent?(event)
        }
        log.insert(Entry(at: .now, direction: "in", text: text, delay: delay), at: 0)
        if log.count > 200 { log.removeLast() }
    }

    static func describe(_ payload: [String: Any]) -> String {
        payload.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

/// Watch messages, decoded from the Connect IQ dictionary payloads (HANDOFF.md §4).
enum WatchEvent: Equatable {
    case hello(version: Int)
    case setStart(at: Int64)
    case setEnd(startAt: Int64, at: Int64, reps: Int?, confidence: Double?)
    case tap(WatchTap)
    case pong(watchMs: Int64, echoMs: Int64)

    static func decode(_ payload: [String: Any]) -> WatchEvent? {
        guard let t = payload["t"] as? String else { return nil }
        func int(_ key: String) -> Int64? {
            if let n = payload[key] as? NSNumber { return n.int64Value }
            if let s = payload[key] as? String { return Int64(s) }
            return nil
        }
        func double(_ key: String) -> Double? { (payload[key] as? NSNumber)?.doubleValue }
        switch t {
        case "hello": return .hello(version: Int(int("v") ?? 0))
        case "setStart": return int("at").map { .setStart(at: $0) }
        case "setEnd":
            guard let at = int("at") else { return nil }
            return .setEnd(startAt: int("startAt") ?? at, at: at, reps: int("reps").map(Int.init), confidence: double("conf"))
        case "tap":
            guard let a = payload["a"] as? String, let tap = WatchTap(rawValue: a) else { return nil }
            return .tap(tap)
        case "pong":
            guard let at = int("at"), let echo = int("echo") else { return nil }
            return .pong(watchMs: at, echoMs: echo)
        default: return nil
        }
    }
}

enum WatchTap: String {
    case done, undo, skipRest
}

// MARK: - Connect IQ delegates

extension WatchService: IQDeviceEventDelegate, IQAppMessageDelegate {
    nonisolated func deviceStatusChanged(_ device: IQDevice!, status: IQDeviceStatus) {
        let name = device.map(WatchService.name(of:)) ?? "Garmin"
        Task { @MainActor in
            switch status {
            case .connected:
                self.checkApp()
            case .notConnected, .bluetoothNotReady, .notFound, .invalidDevice:
                self.status = .notConnected
                self.lastError = "\(name): not connected"
            @unknown default:
                self.status = .notConnected
            }
        }
    }

    nonisolated func receivedMessage(_ message: Any!, from app: IQApp!) {
        // The SDK's dictionary is not Sendable; carry it across as JSON bytes.
        guard let message, JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        Task { @MainActor in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            self.received(object)
        }
    }
}
