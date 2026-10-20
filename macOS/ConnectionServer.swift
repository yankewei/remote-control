import AppKit
import Network
import Observation
import ApplicationServices
import CryptoKit

/// Rolling 2-second view of Bluetooth motion delivery, to tell link jitter apart from other causes.
struct MotionStats {
    private var lateness: [Double] = []
    private var lateCount = 0
    private var delay = 0.0
    private var firstSeq: UInt32?
    private var lastSeq: UInt32?

    mutating func record(seq: UInt32, excessLatency: Double, playoutDelay: Double) {
        lateness.append(excessLatency)
        if excessLatency > playoutDelay { lateCount += 1 }
        delay = playoutDelay
        if firstSeq == nil { firstSeq = seq }
        lastSeq = seq
    }

    /// Returns nil while idle so the menu keeps the last meaningful reading.
    mutating func summarize() -> String? {
        defer { self = MotionStats() }
        guard lateness.count >= 10, let firstSeq, let lastSeq, lastSeq >= firstSeq else { return nil }
        let sorted = lateness.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
        let worst = (sorted.last ?? 0) * 1000
        let expected = Double(lastSeq - firstSeq + 1)
        let loss = max(0, 1 - Double(sorted.count) / expected) * 100
        let lateShare = Double(lateCount) / Double(sorted.count) * 100
        return String(format: "蓝牙 · 抖动 p95 %.0f ms · 最大 %.0f ms · 丢包 %.1f%% · 缓冲 %.0f ms · 超出 %.0f%%",
                      p95, worst, loss, delay * 1000, lateShare)
    }
}

@Observable
final class ConnectionServer {
    var status = "正在启动"
    var secret = ""
    var peerName: String?
    var permissionGranted = AXIsProcessTrusted() {
        didSet { input.accessibilityAllowed = permissionGranted }
    }
    var running = false
    /// Motion-channel health shown in the menu, e.g. "抖动 p95 8 ms · 丢包 0.3%".
    var motionStatus = ""
    /// Bluetooth off, not allowed or failing on the Mac; motion then falls back to Wi-Fi.
    var bluetoothProblem: String?
    let input = InputController()
    private var listener: NWListener?
    private let bluetooth = BluetoothMotionReceiver()
    private var motionKey: SymmetricKey?
    private var motionConfirmed = false
    private var motionStats = MotionStats()
    private var channels: [UUID: SecureConnection] = [:]
    private var activeID: UUID?
    private var peerDeviceID: String?
    private var permissionTimer: Timer?

    private var serverID: String {
        if let saved = UserDefaults.standard.string(forKey: "serverID") { return saved }
        let id = String(UUID().uuidString.prefix(8))
        UserDefaults.standard.set(id, forKey: "serverID")
        return id
    }

    private var serviceName: String {
        Pairing.serviceInstanceName(host: Host.current().localizedName ?? "Mac", identifier: serverID)
    }

    init() {
        bluetooth.onDatagram = { [weak self] data in self?.handleMotionDatagram(data) }
        bluetooth.onProblem = { [weak self] problem in self?.bluetoothProblem = problem }
        input.onError = { [weak self] reason in
            self?.status = reason
            if let self, let id = self.activeID { self.channels[id]?.send(.failure(reason)) }
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            if let saved = CredentialStore.read("server") { secret = saved }
            else {
                secret = try Pairing.newSecret()
                try CredentialStore.save(secret, account: "server")
            }
            let listener = try NWListener(using: Pairing.parameters(secret: secret), on: Pairing.port)
            self.listener = listener
            listener.service = NWListener.Service(name: serviceName, type: Pairing.service)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.running = true; self.status = "等待 iPhone 连接 · 端口 19847"
                case let .failed(error): self.stop(); self.status = "无法启动：\(error.localizedDescription)"
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
            bluetooth.start(name: serverID)
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if let summary = self.motionStats.summarize() { self.motionStatus = summary }
                let allowed = AXIsProcessTrusted()
                if self.permissionGranted != allowed {
                    self.permissionGranted = allowed
                    if !allowed { self.input.releaseDrag() }
                    if let id = self.activeID {
                        self.channels[id]?.send(self.welcome())
                    }
                }
            }
        } catch { status = "启动失败：\(error.localizedDescription)" }
    }

    /// Anything not sealed with the session key is dropped; stale or duplicate datagrams are
    /// dropped by sequence number inside the playout buffer.
    private func handleMotionDatagram(_ data: Data) {
        guard let key = motionKey, let id = activeID, let packet = MotionPacket.open(data, with: key) else { return }
        if !motionConfirmed {
            motionConfirmed = true
            channels[id]?.send(.motionReady)
            motionStatus = "蓝牙已连接"
        }
        if let excess = input.receiveMotion(packet) {
            motionStats.record(seq: packet.seq, excessLatency: excess, playoutDelay: input.playoutDelay)
        }
    }

    /// Issues a fresh key for the phone that just completed the handshake.
    private func offerMotion(on channel: SecureConnection) {
        endMotion()
        let key = SymmetricKey(size: .bits256)
        motionKey = key
        motionStatus = "等待 iPhone 通过蓝牙连接"
        channel.send(.motionOffer(key: key.withUnsafeBytes { Data($0) }))
    }

    private func endMotion() {
        motionKey = nil
        motionConfirmed = false
        motionStats = MotionStats()
        motionStatus = ""
        input.resetMotion()
    }

    private func welcome() -> ControlMessage {
        .welcome(name: Host.current().localizedName ?? "Mac",
                 version: WireProtocol.version,
                 serverID: serverID,
                 inputAllowed: AXIsProcessTrusted())
    }

    private func accept(_ connection: NWConnection) {
        let readyCount = channels.values.filter(\.isReady).count
        let pendingCount = channels.count - readyCount
        // Unfinished handshakes must not consume the four control slots.
        if readyCount >= 4 || pendingCount >= 16 { connection.cancel(); return }
        let id = UUID()
        let channel = SecureConnection(connection)
        channels[id] = channel
        channel.onWaiting = { [weak self] message in
            guard let self, self.activeID == id else { return }
            self.status = message
        }
        channel.onRecovered = { [weak self] in
            guard let self, self.activeID == id, let name = self.peerName else { return }
            self.status = "已连接 · \(name)"
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            if case let .hello(name, version, deviceID) = message {
                guard version == WireProtocol.version else {
                    channel.send(.failure("Mac 与 iPhone 的协议版本不一致，请更新两端 App"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { channel.close() }
                    return
                }
                if let current = self.activeID, current != id {
                    // A stale TCP session from the same phone may be replaced. A different phone is
                    // rejected until the user explicitly disconnects the active one on the Mac.
                    if self.peerDeviceID == deviceID {
                        self.input.releaseDrag()
                        self.activeID = id
                        self.peerName = name
                        self.peerDeviceID = deviceID
                        self.status = "已连接 · \(name)"
                        self.channels[current]?.close()
                        channel.send(self.welcome())
                        self.offerMotion(on: channel)
                        return
                    }
                    channel.send(.failure("另一台 iPhone 正在控制，请在 Mac 菜单栏点击“断开当前设备”"))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { channel.close() }
                    return
                }
                self.activeID = id
                self.peerName = name
                self.peerDeviceID = deviceID
                self.status = "已连接 · \(name)"
                channel.send(self.welcome())
                self.offerMotion(on: channel)
            } else if self.activeID == id {
                if case .text = message, self.input.pasting {
                    channel.send(.failure("上一段文字仍在粘贴，请稍后再发送"))
                    return
                }
                self.input.handle(message)
                if case let .text(requestID, _) = message, self.permissionGranted {
                    channel.send(.textAccepted(id: requestID))
                }
            } else { channel.close("请先完成握手") }
        }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.channels.removeValue(forKey: id)
            if self.activeID == id {
                self.input.releaseDrag()
                self.endMotion()
                self.activeID = nil
                self.peerName = nil
                self.peerDeviceID = nil
                self.status = "等待 iPhone 连接 · 端口 19847"
            }
        }
        channel.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak channel] in
            guard let channel, !channel.isReady else { return }
            channel.close("握手超时")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak channel] in
            if self?.activeID != id { channel?.close("握手超时") }
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        bluetooth.stop()
        bluetoothProblem = nil
        for channel in Array(channels.values) { channel.close() }
        channels.removeAll()
        input.releaseDrag()
        endMotion()
        permissionTimer?.invalidate()
        permissionTimer = nil
        activeID = nil
        peerName = nil
        peerDeviceID = nil
        running = false
        status = "已暂停接收"
    }

    /// Disconnects only the phone currently in control; the listener and pairing key stay valid.
    /// The explicit message tells the phone not to auto-reconnect, otherwise it would take the
    /// slot back before another phone could connect.
    func disconnectActive() {
        guard let id = activeID, let channel = channels[id] else { return }
        channel.send(.serverDisconnected)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            channel.close("Mac 已断开当前设备")
        }
    }

    func revokePairing() {
        stop()
        do {
            let replacement = try Pairing.newSecret()
            try CredentialStore.save(replacement, account: "server")
            start()
        } catch { status = "更换配对码失败：\(error.localizedDescription)" }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        permissionGranted = AXIsProcessTrustedWithOptions(options)
        if !permissionGranted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
