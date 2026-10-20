import Foundation
import Network
import Observation
import UIKit
import CryptoKit

/// One Bluetooth motion session (see MotionPacket). Until the Mac confirms a datagram arrived
/// (`ready`), and whenever the link is down, moves go over the Wi-Fi connection instead and are
/// not added to the running total.
private struct MotionSession {
    let key: SymmetricKey
    var ready = false
    var seq: UInt32 = 0
    var syncedSeq: UInt32 = 0
    var x = 0.0
    var y = 0.0
    var probe: Timer?

    /// `timestamp` is when the motion happened (a touch sample's time), on the uptime clock.
    func seal(_ kind: MotionPacket.Kind, at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Data? {
        try? MotionPacket(kind: kind, seq: seq, timestamp: timestamp, x: x, y: y).seal(with: key)
    }
}

struct DiscoveredMac: Identifiable {
    let id: String
    let endpoint: NWEndpoint
    let serverID: String?
}

@Observable
final class MacConnection {
    var devices: [DiscoveredMac] = []
    var status = "正在寻找 Mac"
    var connectedName: String?
    var inputAllowed = false
    var draft = ""
    var sendingText = false
    var textStatus = ""
    var sensitivity = UserDefaults.standard.object(forKey: "pointerSensitivity") as? Double ?? 1.4 {
        didSet { UserDefaults.standard.set(sensitivity, forKey: "pointerSensitivity") }
    }
    private let deviceID: String = {
        if let saved = UserDefaults.standard.string(forKey: "deviceID") { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }()
    private var browser: NWBrowser?
    private var channel: SecureConnection?
    private var target: NWEndpoint?
    private var targetName: String?
    private var secret: String?
    private var reconnect: Timer?
    private var discoveryRetry: Timer?
    private var retryDelay: TimeInterval = 1
    private var active = true
    private var wantsConnection = true
    private var protocolFailures = 0
    private var pendingText: UUID?
    private var textTimeout: Timer?
    private var coalescedScroll: (dx: Double, dy: Double)?
    private var coalescedMove: (dx: Double, dy: Double)?
    private var flushScheduled = false
    private var motion: MotionSession?
    private let bluetooth = BluetoothMotionSender()
    /// Why the pointer cannot move right now (Bluetooth off, not allowed, still connecting), or nil.
    var bluetoothNotice: String?
    private var motionOverBluetooth: Bool { (motion?.ready ?? false) && bluetooth.isLinked }

    var isConnecting: Bool {
        connectedName == nil && target != nil && wantsConnection && (channel != nil || reconnect != nil)
    }
    var hasSavedConnection: Bool { savedCredential() != nil }

    func discover() {
        guard browser == nil else { return }
        discoveryRetry?.invalidate()
        discoveryRetry = nil
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Pairing.service, domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            guard case let .failed(error) = state else { return }
            browser.cancel()
            self.browser = nil
            self.status = "无法发现设备，请检查局域网权限：\(error.localizedDescription)"
            self.scheduleDiscoveryRestart()
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var chosen: [String: NWBrowser.Result] = [:]
            for result in results {
                guard case let .service(name, _, _, _) = result.endpoint else { continue }
                if let existing = chosen[name] {
                    chosen[name] = Self.preferInfrastructure(existing, over: result)
                } else {
                    chosen[name] = result
                }
            }
            self.devices = chosen.map {
                DiscoveredMac(id: $0.key, endpoint: $0.value.endpoint,
                              serverID: Self.serverID(fromServiceName: $0.key))
            }
            .sorted { $0.id < $1.id }
            self.autoConnectIfPossible()
        }
        browser.start(queue: .main)
        if channel == nil, wantsConnection, active,
           let host = UserDefaults.standard.string(forKey: "manualHost"),
           let saved = UserDefaults.standard.string(forKey: "lastMac"), saved == "IP: \(host)",
           let secret = CredentialStore.read(saved) {
            connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: Pairing.port), name: saved, secret: secret)
        }
    }

    private func scheduleDiscoveryRestart() {
        discoveryRetry?.invalidate()
        guard active else { return }
        discoveryRetry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            guard let self, self.active, self.browser == nil else { return }
            self.discover()
        }
    }

    private func autoConnectIfPossible() {
        guard channel == nil, reconnect == nil, wantsConnection, active else { return }
        if let serverID = UserDefaults.standard.string(forKey: "lastServerID"),
           let device = devices.first(where: { $0.serverID == serverID }),
           let secret = CredentialStore.read(device.id) ?? CredentialStore.read(Self.serverAccount(serverID)) {
            connect(endpoint: device.endpoint, name: device.id, secret: secret)
            return
        }
        if let saved = UserDefaults.standard.string(forKey: "lastMac"),
           let device = devices.first(where: { $0.id == saved }),
           let secret = CredentialStore.read(saved) {
            connect(endpoint: device.endpoint, name: saved, secret: secret)
        }
    }

    func pair(device: DiscoveredMac?, host: String, code: String) {
        let normalized = Pairing.normalize(code)
        guard normalized.count == 32, normalized.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            status = "请输入 Mac 上显示的 32 位配对码"; return
        }
        protocolFailures = 0
        if let device {
            UserDefaults.standard.removeObject(forKey: "manualHost")
            connect(endpoint: device.endpoint, name: device.id, secret: normalized)
        } else {
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { status = "请选择 Mac，或输入它的局域网 IP"; return }
            UserDefaults.standard.set(host, forKey: "manualHost")
            connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: Pairing.port),
                    name: "IP: \(host)", secret: normalized)
        }
    }

    /// Reconnects to the last Mac without asking for the 32-character pairing code again.
    func reconnectSaved() {
        guard let saved = savedCredential() else {
            status = "没有保存的配对，请输入配对码"; return
        }
        protocolFailures = 0
        if let device = devices.first(where: { $0.id == saved.name }) {
            connect(endpoint: device.endpoint, name: device.id, secret: saved.secret)
            return
        }
        if let serverID = UserDefaults.standard.string(forKey: "lastServerID"),
           let device = devices.first(where: { $0.serverID == serverID }) {
            connect(endpoint: device.endpoint, name: device.id, secret: saved.secret)
            return
        }
        if let host = UserDefaults.standard.string(forKey: "manualHost") {
            let secret = CredentialStore.read("IP: \(host)") ?? saved.secret
            connect(endpoint: .hostPort(host: NWEndpoint.Host(host), port: Pairing.port),
                    name: "IP: \(host)", secret: secret)
            return
        }
        status = "未找到已保存的 Mac，请确认它已打开并在同一网络"
    }

    func canConnectSaved(_ device: DiscoveredMac) -> Bool {
        CredentialStore.read(device.id) != nil
            || (device.serverID.map { CredentialStore.read(Self.serverAccount($0)) != nil } ?? false)
    }

    func connectSaved(_ device: DiscoveredMac) {
        protocolFailures = 0
        if let secret = CredentialStore.read(device.id) {
            connect(endpoint: device.endpoint, name: device.id, secret: secret)
        } else if let serverID = device.serverID, let secret = CredentialStore.read(Self.serverAccount(serverID)) {
            connect(endpoint: device.endpoint, name: device.id, secret: secret)
        } else {
            status = "请输入这台 Mac 的配对码"
        }
    }

    private func connect(endpoint: NWEndpoint, name: String, secret: String) {
        disconnect(clearIntent: false)
        wantsConnection = true
        target = endpoint
        targetName = name
        self.secret = secret
        status = "正在连接 \(name)"
        let channel = SecureConnection(NWConnection(to: endpoint, using: Pairing.parameters(secret: secret)))
        self.channel = channel
        channel.onReady = { [weak self, weak channel] in
            guard let self else { return }
            if self.connectedName == nil { self.status = "正在连接 \(name)" }
            channel?.send(.hello(name: UIDevice.current.name, version: WireProtocol.version, deviceID: self.deviceID))
        }
        channel.onRecovered = { [weak self] in
            guard let self, self.connectedName != nil else { return }
            self.status = self.inputAllowed ? "已连接 · 加密连接" : "已连接，请在 Mac 开启辅助功能权限"
        }
        channel.onWaiting = { [weak self] message in self?.status = message }
        channel.onRejected = { [weak self] reason in
            guard let self else { return }
            if self.sendingText {
                self.pendingText = nil
                self.sendingText = false
                self.textTimeout?.invalidate()
                self.textStatus = reason
            } else {
                self.status = reason
            }
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self else { return }
            switch message {
            case let .welcome(macName, version, serverID, allowed):
                guard version == WireProtocol.version else {
                    self.status = "Mac 与 iPhone 的协议版本不一致，请更新两端 App"
                    channel?.close(self.status, retry: false)
                    return
                }
                do {
                    try CredentialStore.save(secret, account: name)
                    try? CredentialStore.save(secret, account: Self.serverAccount(serverID))
                    UserDefaults.standard.set(name, forKey: "lastMac")
                    UserDefaults.standard.set(serverID, forKey: "lastServerID")
                    self.secret = secret
                    self.connectedName = macName
                    self.inputAllowed = allowed
                    self.retryDelay = 1
                    self.protocolFailures = 0
                    self.status = allowed ? "已连接 · 加密连接" : "已连接，请在 Mac 开启辅助功能权限"
                } catch { channel?.close("无法保存配对凭证，请重试", retry: false) }
            case let .motionOffer(key):
                self.startMotion(key: key)
            case .motionReady:
                self.motion?.ready = true
                self.motion?.probe?.invalidate()
            case let .textAccepted(id):
                guard self.pendingText == id else { return }
                self.pendingText = nil
                self.textTimeout?.invalidate()
                self.sendingText = false
                self.draft = ""
                self.textStatus = "Mac 已接收文字"
            case .serverDisconnected:
                self.wantsConnection = false
                self.status = "Mac 已断开当前设备，请手动连接"
                channel?.close(self.status, retry: false)
            case let .failure(reason):
                if self.sendingText {
                    self.pendingText = nil
                    self.sendingText = false
                    self.textTimeout?.invalidate()
                    self.textStatus = reason
                }
                if self.connectedName == nil {
                    self.status = reason
                    channel?.close(reason, retry: false)
                } else {
                    self.textStatus = reason
                }
            default: break
            }
        }
        channel.onClose = { [weak self] end in
            guard let self else { return }
            self.channel = nil
            self.connectedName = nil
            self.inputAllowed = false
            if self.sendingText { self.textStatus = "连接中断，文字可能未输入；请确认 Mac 后再发送" }
            self.sendingText = false
            self.pendingText = nil
            self.textTimeout?.invalidate()
            self.coalescedScroll = nil
            self.coalescedMove = nil
            self.stopMotion()
            self.status = end.message
            guard self.active, self.wantsConnection else { return }
            if end.protocolError {
                self.protocolFailures += 1
                if self.protocolFailures >= 3 {
                    self.wantsConnection = false
                    self.status = "两端协议不兼容或持续收到异常数据，请更新 App 后重试"
                    return
                }
            }
            if end.authenticationFailed {
                guard let saved = self.savedCredential(preferredName: name) else {
                    self.wantsConnection = false
                    self.status = "配对码已失效，请重新输入"
                    return
                }
                if saved.secret != secret {
                    self.status = "配对码不正确，正在恢复已保存的连接"
                    self.scheduleReconnect(name: saved.name, endpoint: endpoint, secret: saved.secret)
                } else {
                    self.wantsConnection = false
                    self.status = "配对码已失效，请重新输入"
                }
                return
            }
            guard end.retry, let saved = self.savedCredential(preferredName: name) else {
                if !end.retry { self.wantsConnection = false }
                return
            }
            self.scheduleReconnect(name: saved.name, endpoint: endpoint, secret: saved.secret)
        }
        channel.start()
    }

    private func scheduleReconnect(name: String, endpoint: NWEndpoint, secret: String) {
        guard active, wantsConnection else { return }
        if !status.contains("将自动重连") { status += " · 将自动重连" }
        reconnect?.invalidate()
        reconnect = Timer.scheduledTimer(withTimeInterval: retryDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.reconnect = nil
            guard self.active, self.wantsConnection else { return }
            var reconnectName = name
            var currentEndpoint = endpoint
            if let device = self.devices.first(where: { $0.id == name }) {
                currentEndpoint = device.endpoint
            } else if let serverID = UserDefaults.standard.string(forKey: "lastServerID"),
                      let device = self.devices.first(where: { $0.serverID == serverID }) {
                // The Mac may have a new Bonjour name/IP. Prefer the stable serverID over the
                // endpoint captured before the network changed.
                reconnectName = device.id
                currentEndpoint = device.endpoint
            }
            self.connect(endpoint: currentEndpoint, name: reconnectName, secret: secret)
        }
        retryDelay = min(retryDelay * 2, 10)
    }

    private func savedCredential(preferredName: String? = nil) -> (name: String, secret: String)? {
        if let name = preferredName, let secret = CredentialStore.read(name) {
            return (name, secret)
        }
        if let serverID = UserDefaults.standard.string(forKey: "lastServerID"),
           let secret = CredentialStore.read(Self.serverAccount(serverID)) {
            return (UserDefaults.standard.string(forKey: "lastMac") ?? serverID, secret)
        }
        if let name = UserDefaults.standard.string(forKey: "lastMac"), let secret = CredentialStore.read(name) {
            return (name, secret)
        }
        return nil
    }

    private static func serverAccount(_ serverID: String) -> String { "server:\(serverID)" }

    private static func serverID(fromServiceName name: String) -> String? {
        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else { return nil }
        let start = name.index(after: open)
        let end = name.index(before: name.endIndex)
        guard start < end else { return nil }
        let id = String(name[start..<end])
        guard id.count == 8, id.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        return id
    }

    private static func preferInfrastructure(_ current: NWBrowser.Result, over candidate: NWBrowser.Result) -> NWBrowser.Result {
        func infrastructure(_ result: NWBrowser.Result) -> Bool {
            result.interfaces.contains { $0.type == .wifi || $0.type == .wiredEthernet }
        }
        if infrastructure(candidate), !infrastructure(current) { return candidate }
        return current
    }

    /// One touch sample of pointer motion. Over Bluetooth it goes out at once as its own datagram
    /// stamped with the touch time, so the Mac replays the stroke at the finger's pace.
    func movePointer(dx: Double, dy: Double, at time: TimeInterval) {
        guard connectedName != nil, inputAllowed else { return }
        guard motionOverBluetooth else { send(.move(dx: dx, dy: dy)); return }
        motion?.x += dx
        motion?.y += dy
        motion?.seq &+= 1
        sendMotion(.motion, at: time)
    }

    func send(_ message: ControlMessage) {
        guard connectedName != nil, inputAllowed else { return }
        switch message {
        case let .move(dx, dy) where motionOverBluetooth:
            movePointer(dx: dx, dy: dy, at: ProcessInfo.processInfo.systemUptime)
        case let .move(dx, dy):
            // Bluetooth is off, not allowed or still connecting: Wi-Fi keeps the pointer usable.
            let current = coalescedMove ?? (0, 0)
            coalescedMove = (ControlMessage.clampDelta(current.dx + dx), ControlMessage.clampDelta(current.dy + dy))
            scheduleFlush()
        case let .scroll(dx, dy):
            let current = coalescedScroll ?? (0, 0)
            coalescedScroll = (ControlMessage.clampDelta(current.dx + dx), ControlMessage.clampDelta(current.dy + dy))
            scheduleFlush()
        default:
            flushCoalesced()
            syncMotion()
            channel?.send(message)
        }
    }

    /// Sends the Bluetooth total ahead of an action on the ordered stream, so it lands where the
    /// pointer ends up even if datagrams are late or lost.
    private func syncMotion() {
        guard let motion, motion.ready, motion.seq != motion.syncedSeq else { return }
        self.motion?.syncedSeq = motion.seq
        channel?.send(.motionSync(seq: motion.seq, x: motion.x, y: motion.y))
    }

    private func startMotion(key: Data) {
        stopMotion()
        // The welcome that precedes this offer stored the Mac's serverID, its Bluetooth name.
        guard let serverID = UserDefaults.standard.string(forKey: "lastServerID") else { return }
        motion = MotionSession(key: SymmetricKey(data: key))
        bluetooth.onNotice = { [weak self] notice in self?.bluetoothNotice = notice }
        bluetooth.start(serverID: serverID)
        // Probe until the Mac confirms; Bluetooth may need a few seconds, or the user may still
        // have to switch it on. Sending while disconnected is a no-op.
        motion?.probe = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, let motion = self.motion, !motion.ready else { timer.invalidate(); return }
            self.sendMotion(.probe)
        }
    }

    private func sendMotion(_ kind: MotionPacket.Kind, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let data = motion?.seal(kind, at: time) else { return }
        bluetooth.send(data)
    }

    private func stopMotion() {
        motion?.probe?.invalidate()
        motion = nil
        bluetooth.onNotice = nil
        bluetooth.stop()
        bluetoothNotice = nil
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushCoalesced() }
    }

    private func flushCoalesced() {
        flushScheduled = false
        guard connectedName != nil, inputAllowed else {
            coalescedScroll = nil
            coalescedMove = nil
            return
        }
        if let move = coalescedMove {
            coalescedMove = nil
            channel?.send(.move(dx: move.dx, dy: move.dy))
        }
        if let scroll = coalescedScroll {
            coalescedScroll = nil
            syncMotion()
            channel?.send(.scroll(dx: scroll.dx, dy: scroll.dy))
        }
    }

    func sendText() {
        guard !sendingText, connectedName != nil, inputAllowed, !draft.isEmpty else { return }
        guard draft.utf8.count <= ProtocolConstants.maximumTextBytes else {
            textStatus = "文字过长，请分段发送"; return
        }
        let id = UUID()
        guard (try? MessageFramer.encode(.text(id: id, value: draft))) != nil else {
            textStatus = "文字过长，请分段发送"
            return
        }
        pendingText = id
        sendingText = true
        textStatus = "正在发送"
        channel?.send(.text(id: id, value: draft))
        textTimeout = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, self.pendingText == id else { return }
            self.pendingText = nil
            self.sendingText = false
            self.textStatus = "未收到确认，请检查 Mac 是否已输入；不会自动重发"
        }
    }

    func disconnect(clearIntent: Bool = true) {
        if clearIntent { wantsConnection = false }
        reconnect?.invalidate()
        reconnect = nil
        channel?.onClose = nil
        channel?.send(.drag(active: false))
        channel?.close()
        channel = nil
        connectedName = nil
        inputAllowed = false
        pendingText = nil
        sendingText = false
        textTimeout?.invalidate()
        coalescedScroll = nil
        coalescedMove = nil
        stopMotion()
        status = "未连接"
    }

    func forget() {
        let name = targetName ?? UserDefaults.standard.string(forKey: "lastMac")
        let serverID = UserDefaults.standard.string(forKey: "lastServerID")
        disconnect()
        if let name { CredentialStore.delete(name) }
        if let serverID { CredentialStore.delete(Self.serverAccount(serverID)) }
        UserDefaults.standard.removeObject(forKey: "lastMac")
        UserDefaults.standard.removeObject(forKey: "lastServerID")
        UserDefaults.standard.removeObject(forKey: "manualHost")
        target = nil
        targetName = nil
        secret = nil
    }

    func setActive(_ value: Bool) {
        active = value
        if !value {
            disconnect(clearIntent: false)
            discoveryRetry?.invalidate()
            discoveryRetry = nil
            browser?.cancel()
            browser = nil
        } else {
            discover()
            if wantsConnection, channel == nil, let target, let targetName, let secret {
                connect(endpoint: target, name: targetName, secret: secret)
            }
        }
    }
}
