import Foundation
import Network
import Security
import CryptoKit

// The random 128-bit pairing secret authenticates both peers. It never travels in Bonjour or plaintext.
enum Pairing {
    static let service = "_remotecontrol._tcp"
    static let port: NWEndpoint.Port = 19_847

    static func newSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func normalize(_ value: String) -> String {
        value.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }

    /// Bonjour instance names are limited to 63 bytes. The suffix keeps the stable server id intact.
    static func serviceInstanceName(host: String, identifier: String) -> String {
        let suffix = " [\(identifier)]"
        let limit = 63
        let suffixCount = suffix.utf8.count
        guard suffixCount < limit else { return String(suffix.prefix(limit)) }
        let budget = limit - suffixCount
        var kept = ""
        var count = 0
        for character in host {
            let next = count + character.utf8.count
            if next > budget { break }
            kept.append(character)
            count = next
        }
        return kept + suffix
    }

    static func parameters(secret: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let key = Data(SHA256.hash(data: Data(normalize(secret).utf8)))
        let identity = Data("remote-control-v1".utf8)
        key.withUnsafeBytes { keyBytes in
            identity.withUnsafeBytes { identityBytes in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                    DispatchData(bytes: keyBytes) as __DispatchData,
                    DispatchData(bytes: identityBytes) as __DispatchData)
            }
        }
        // Network.framework supports external PSKs only with TLS 1.2 (Apple TN3213).
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

enum CredentialStore {
    private static let service = "com.remotecontrol.pairing"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func delete(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}

struct ConnectionClose {
    var message: String
    var retry: Bool = true
    /// TLS rejected the pairing key. A dropped route is a different failure and may still retry.
    var authenticationFailed: Bool = false
    /// The peer sent malformed or incompatible data. Repeated failures should stop the retry loop.
    var protocolError: Bool = false
}

// All callbacks run on the main queue, keeping event order consistent with UI and input events.
final class SecureConnection {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onRecovered: (() -> Void)?
    var onWaiting: ((String) -> Void)?
    var onRejected: ((String) -> Void)?
    var onMessage: ((ControlMessage) -> Void)?
    var onClose: ((ConnectionClose) -> Void)?
    var isReady: Bool { ready }
    private var framer = MessageFramer()
    private var closed = false
    private var pendingSends = 0
    private var watchdog: Timer?
    private var connectTimeout: Timer?
    private var lastReceived = Date()
    private var ready = false
    private static let connectTimeoutInterval: TimeInterval = 10

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.lastReceived = Date()
                self.connectTimeout?.invalidate()
                self.connectTimeout = nil
                if self.ready {
                    self.onRecovered?()
                } else {
                    self.ready = true
                    self.onReady?()
                    self.receive()
                }
            case let .failed(error):
                if self.isAuthenticationFailure(error) {
                    self.close("配对码已失效，请重新输入", retry: false, authenticationFailed: true)
                } else {
                    self.close("连接失败，请检查配对码与局域网权限：\(error.localizedDescription)")
                }
            case let .waiting(error):
                // A wrong pairing key surfaces as .waiting with a TLS bad-MAC error.
                // Path waits stay open and can still become .ready.
                if self.isAuthenticationFailure(error) {
                    self.close("配对码已失效，请重新输入", retry: false, authenticationFailed: true)
                } else {
                    self.onWaiting?(self.waitingMessage(error))
                }
            case .cancelled: self.close("连接已断开")
            default: break
            }
        }
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.ready, !self.closed else { return }
            if Date().timeIntervalSince(self.lastReceived) > 12 { self.close("连接超时") }
            else { self.send(.ping) }
        }
        // NWConnection can stay in .waiting indefinitely when a Bonjour service disappears or an
        // address is unreachable. Without this deadline the UI would say "正在连接" forever and
        // the reconnect/backoff path would never run.
        connectTimeout = Timer.scheduledTimer(withTimeInterval: Self.connectTimeoutInterval, repeats: false) { [weak self] _ in
            guard let self, !self.ready, !self.closed else { return }
            self.close("连接超时，请检查网络后重试")
        }
        connection.start(queue: .main)
    }

    func send(_ message: ControlMessage) {
        guard !closed, ready else { return }
        if pendingSends >= 128 {
            switch message {
            case .move, .scroll, .ping:
                return
            default:
                guard pendingSends < 256 else {
                    onRejected?("网络拥堵，请稍后再试")
                    return
                }
            }
        }
        do {
            let data = try MessageFramer.encode(message)
            pendingSends += 1
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pendingSends -= 1
                if let error { self.close(error.localizedDescription) }
            })
        } catch let error as ProtocolError {
            onRejected?(error == .oversizedFrame ? "文字过长，请分段发送" : "指令格式无效")
        } catch {
            onRejected?("指令格式无效")
        }
    }

    private func isAuthenticationFailure(_ error: NWError) -> Bool {
        if case .tls = error { return true }
        return false
    }

    private func waitingMessage(_ error: NWError) -> String {
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
            return "本地网络被拒绝，请在系统设置中允许"
        }
        return "网络暂时不可用：\(error.localizedDescription)"
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, !data.isEmpty {
                    self.lastReceived = Date()
                    for message in try self.framer.append(data) {
                        if message == .ping { self.send(.pong) }
                        else if message != .pong { self.onMessage?(message) }
                    }
                }
                if complete || error != nil { self.close("连接已断开") }
                else { self.receive() }
            } catch { self.close("收到无效数据，已断开连接", protocolError: true) }
        }
    }

    func close(_ reason: String = "连接已断开", retry: Bool = true, authenticationFailed: Bool = false, protocolError: Bool = false) {
        guard !closed else { return }
        closed = true
        watchdog?.invalidate()
        watchdog = nil
        connectTimeout?.invalidate()
        connectTimeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(ConnectionClose(message: reason, retry: retry, authenticationFailed: authenticationFailed, protocolError: protocolError))
        onReady = nil
        onRecovered = nil
        onWaiting = nil
        onRejected = nil
        onMessage = nil
        onClose = nil
    }
}
