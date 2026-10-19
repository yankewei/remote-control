import AppKit
import Network
import Observation
import ApplicationServices

@Observable
final class ConnectionServer {
    var status = "正在启动"
    var secret = ""
    var peerName: String?
    var permissionGranted = AXIsProcessTrusted()
    var running = false
    let input = InputController()
    private var listener: NWListener?
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
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
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
            } else if self.activeID == id {
                if case .text = message, self.input.pasting {
                    channel.send(.failure("上一段文字仍在粘贴，请稍后再发送"))
                    return
                }
                self.input.handle(message)
                if case let .text(requestID, _) = message, AXIsProcessTrusted() {
                    channel.send(.textAccepted(id: requestID))
                }
            } else { channel.close("请先完成握手") }
        }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            self.channels.removeValue(forKey: id)
            if self.activeID == id {
                self.input.releaseDrag()
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
        for channel in Array(channels.values) { channel.close() }
        channels.removeAll()
        input.releaseDrag()
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
