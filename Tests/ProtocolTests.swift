import XCTest
import Network
@testable import RemoteControlCore

final class ProtocolTests: XCTestCase {
    private var server: SecureConnection?
    func testEveryMessageSurvivesFragmentedAndCoalescedFrames() throws {
        let messages: [ControlMessage] = [.hello(name: "iPhone", version: WireProtocol.version, deviceID: "device-1"),
            .welcome(name: "Mac", version: WireProtocol.version, serverID: "A1B2C3D4", inputAllowed: true),
            .move(dx: -2.5, dy: 10), .click(button: .right, count: 2), .scroll(dx: 4, dy: -8),
            .drag(active: true), .drag(active: false), .text(id: UUID(), value: "中文，Hello 👨‍👩‍👧‍👦！"),
            .textAccepted(id: UUID()), .key(.paste), .ping, .pong, .serverDisconnected, .failure("未授权")]
        let bytes = try messages.reduce(into: Data()) { $0.append(try MessageFramer.encode($1)) }
        for size in [1, 2, 3, 4, 17, bytes.count] {
            var framer = MessageFramer()
            var decoded: [ControlMessage] = []
            var index = 0
            while index < bytes.count {
                decoded += try framer.append(bytes.subdata(in: index..<min(index + size, bytes.count)))
                index += size
            }
            XCTAssertEqual(decoded, messages)
        }
    }

    func testEveryRemoteKeyRoundTrips() throws {
        for key in RemoteKey.allCases {
            var framer = MessageFramer()
            XCTAssertEqual(try framer.append(MessageFramer.encode(.key(key))), [.key(key)])
        }
    }

    func testRejectsInvalidPayloads() throws {
        for prefix: [UInt8] in [[0, 0, 0, 0], [0, 0, 128, 1], [255, 255, 255, 255]] {
            var framer = MessageFramer()
            XCTAssertThrowsError(try framer.append(Data(prefix)))
        }
        for message: ControlMessage in [.move(dx: .infinity, dy: 0), .move(dx: 2001, dy: 0),
            .click(button: .left, count: 4), .text(id: UUID(), value: String(repeating: "中", count: 6000)),
            .hello(name: "", version: WireProtocol.version, deviceID: "device-1"),
            .hello(name: "iPhone", version: 0, deviceID: "device-1"),
            .welcome(name: "Mac", version: WireProtocol.version, serverID: "", inputAllowed: true)] {
            XCTAssertThrowsError(try MessageFramer.encode(message))
        }
        var framer = MessageFramer()
        XCTAssertThrowsError(try framer.append(Data([0, 0, 0, 1, 255])))
    }

    func testPairingSecretsHave128BitsAndNormalizeFormatting() throws {
        let first = try Pairing.newSecret()
        let second = try Pairing.newSecret()
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy(\.isHexDigit))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(Pairing.normalize(" aaBB-ccDD \n"), "AABBCCDD")
    }

    func testServiceInstanceNameFitsBonjourLimit() {
        let identifier = "A1B2C3D4"
        XCTAssertEqual(Pairing.serviceInstanceName(host: "Mac", identifier: identifier), "Mac [\(identifier)]")
        let host = String(repeating: "电脑", count: 40)
        let name = Pairing.serviceInstanceName(host: host, identifier: identifier)
        XCTAssertLessThanOrEqual(name.utf8.count, 63)
        XCTAssertTrue(name.hasSuffix(" [\(identifier)]"))
        XCTAssertEqual(name, Pairing.serviceInstanceName(host: host, identifier: identifier))
        XCTAssertEqual(name.utf8.count, 17 * 3 + " [\(identifier)]".utf8.count)
    }

    func testPointerDeltaAndEscapedTextStayInsideTheFrame() {
        XCTAssertEqual(ControlMessage.clampDelta(2001), 2000)
        XCTAssertEqual(ControlMessage.clampDelta(-2001), -2000)
        XCTAssertEqual(ControlMessage.clampDelta(.infinity), 0)
        XCTAssertEqual(ControlMessage.clampDelta(12.5), 12.5)
        let message = ControlMessage.text(id: UUID(), value: String(repeating: "\n", count: 16_384))
        XCTAssertTrue(message.isValid)
        XCTAssertThrowsError(try MessageFramer.encode(message)) { error in
            XCTAssertEqual(error as? ProtocolError, .oversizedFrame)
        }
    }

    @MainActor
    func testAuthenticatedTLSRoundTrip() async throws {
        let secret = try Pairing.newSecret()
        let listener = try NWListener(using: Pairing.parameters(secret: secret), on: .any)
        let listening = expectation(description: "listener ready")
        let delivered = expectation(description: "encrypted text acknowledged")
        let requestID = UUID()
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = SecureConnection(connection)
            self.server = peer
            peer.onMessage = { message in
                XCTAssertEqual(message, .text(id: requestID, value: "中文与 emoji 🧪"))
                peer.send(.textAccepted(id: requestID))
            }
            peer.start()
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let client = SecureConnection(NWConnection(host: "127.0.0.1", port: port, using: Pairing.parameters(secret: secret)))
        defer { client.close(); self.server?.close(); self.server = nil; listener.cancel() }
        client.onReady = { client.send(.text(id: requestID, value: "中文与 emoji 🧪")) }
        client.onMessage = { message in
            XCTAssertEqual(message, .textAccepted(id: requestID))
            delivered.fulfill()
        }
        client.start()
        await fulfillment(of: [delivered], timeout: 8)
    }

    @MainActor
    func testWrongPairingSecretCannotDeliverCommands() async throws {
        let listener = try NWListener(using: Pairing.parameters(secret: try Pairing.newSecret()), on: .any)
        let listening = expectation(description: "listener ready")
        let unauthorized = expectation(description: "unauthorized message")
        unauthorized.isInverted = true
        listener.stateUpdateHandler = { state in if case .ready = state { listening.fulfill() } }
        listener.newConnectionHandler = { connection in
            let peer = SecureConnection(connection)
            self.server = peer
            peer.onMessage = { _ in unauthorized.fulfill() }
            peer.start()
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)
        let client = SecureConnection(NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                                   using: Pairing.parameters(secret: try Pairing.newSecret())))
        defer { client.close(); self.server?.close(); self.server = nil; listener.cancel() }
        let rejected = expectation(description: "wrong key rejected by TLS")
        client.onReady = { XCTFail("Wrong pairing code authenticated"); client.send(.key(.enter)) }
        client.onClose = { end in
            XCTAssertTrue(end.authenticationFailed)
            XCTAssertFalse(end.retry)
            rejected.fulfill()
        }
        client.start()
        await fulfillment(of: [rejected, unauthorized], timeout: 2)
        client.onClose = nil
    }
}
