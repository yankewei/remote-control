import Foundation

enum MouseButton: String, Codable { case left, right }
enum RemoteKey: String, Codable { case enter, escape, delete, tab, space, copy, paste, spotlight }

enum WireProtocol {
    /// Both apps are normally updated together; the handshake rejects a mismatch with a clear message.
    static let version = 2
}

enum ProtocolConstants {
    static let maximumTextBytes = 16_384
    static let maximumFrameBytes = 32_768
    static let maximumPointerDelta: Double = 2_000
    static let maximumNameBytes = 256
    static let maximumIdentifierBytes = 64
}

enum ControlMessage: Codable, Equatable {
    case hello(name: String, version: Int, deviceID: String)
    case welcome(name: String, version: Int, serverID: String, inputAllowed: Bool)
    case move(dx: Double, dy: Double)
    case click(button: MouseButton, count: Int)
    case scroll(dx: Double, dy: Double)
    case drag(active: Bool)
    case text(id: UUID, value: String)
    case textAccepted(id: UUID)
    case key(RemoteKey)
    case ping
    case pong
    case serverDisconnected
    case failure(String)

    var isValid: Bool {
        switch self {
        case let .move(x, y), let .scroll(x, y):
            return x.isFinite && y.isFinite
                && abs(x) <= ProtocolConstants.maximumPointerDelta
                && abs(y) <= ProtocolConstants.maximumPointerDelta
        case let .click(_, count): return (1...2).contains(count)
        case let .text(_, text): return !text.isEmpty && text.utf8.count <= ProtocolConstants.maximumTextBytes
        case let .hello(name, version, deviceID):
            return Self.isValidName(name) && version > 0 && Self.isValidIdentifier(deviceID)
        case let .welcome(name, version, serverID, _):
            return Self.isValidName(name) && version > 0 && Self.isValidIdentifier(serverID)
        case let .failure(reason): return reason.utf8.count <= 1_024
        default: return true
        }
    }

    static func clampDelta(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(ProtocolConstants.maximumPointerDelta, max(-ProtocolConstants.maximumPointerDelta, value))
    }

    private static func isValidName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= ProtocolConstants.maximumNameBytes
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= ProtocolConstants.maximumIdentifierBytes
    }
}

// TCP is a byte stream: a bounded length prefix handles both fragmented and coalesced packets.
struct MessageFramer {
    static let maximumSize = ProtocolConstants.maximumFrameBytes
    private var buffer = Data()

    static func encode(_ message: ControlMessage) throws -> Data {
        guard message.isValid else { throw ProtocolError.invalidMessage }
        let payload = try JSONEncoder().encode(message)
        guard payload.count <= maximumSize else { throw ProtocolError.oversizedFrame }
        var length = UInt32(payload.count).bigEndian
        var frame = withUnsafeBytes(of: &length) { Data($0) }
        frame.append(payload)
        return frame
    }

    mutating func append(_ data: Data) throws -> [ControlMessage] {
        buffer.append(data)
        var messages: [ControlMessage] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumSize else { throw ProtocolError.oversizedFrame }
            guard buffer.count >= length + 4 else { break }
            let payload = buffer.dropFirst(4).prefix(length)
            let message = try JSONDecoder().decode(ControlMessage.self, from: payload)
            guard message.isValid else { throw ProtocolError.invalidMessage }
            messages.append(message)
            buffer.removeFirst(length + 4)
        }
        return messages
    }
}

enum ProtocolError: Error, Equatable { case invalidMessage, oversizedFrame }
