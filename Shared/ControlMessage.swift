import Foundation
import CoreGraphics
import CryptoKit

enum MouseButton: String, Codable { case left, right }
enum RemoteKey: String, Codable, CaseIterable {
    case enter, escape, delete, tab, space, copy, paste, spotlight
    case volumeUp, volumeDown, mute, playPause, brightnessUp, brightnessDown
    case missionControl, switchApp, fullScreen, closeWindow
}

enum WireProtocol {
    /// Both apps are normally updated together; the handshake rejects a mismatch with a clear message.
    static let version = 6
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
    /// Pointer motion over Wi-Fi, used until Bluetooth is confirmed or while its link is down;
    /// otherwise motion reaches the Mac as `MotionPacket`s over Bluetooth.
    case move(dx: Double, dy: Double)
    /// A single press; `count` is its place in a run of quick taps (2 = second tap of a double-click).
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
    /// Mac → iPhone: a per-session key for sealing Bluetooth motion datagrams.
    case motionOffer(key: Data)
    /// Mac → iPhone: the first authenticated Bluetooth datagram arrived; the pointer may move.
    case motionReady
    /// iPhone → Mac: the motion total sent so far, ahead of a click/drag/key on the TCP stream,
    /// so the action lands where the pointer ends up even if Bluetooth datagrams are late or lost.
    case motionSync(seq: UInt32, totals: MotionTotals)

    var isValid: Bool {
        switch self {
        case let .move(x, y), let .scroll(x, y):
            return x.isFinite && y.isFinite
                && abs(x) <= ProtocolConstants.maximumPointerDelta
                && abs(y) <= ProtocolConstants.maximumPointerDelta
        case let .motionOffer(key): return key.count == 32
        case let .motionSync(_, totals): return totals.isValid
        case let .click(_, count): return (1...3).contains(count)
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

// MARK: - Bluetooth motion channel
//
// Pointer motion over Wi-Fi arrives in bursts (power save, retransmits), so the cursor stutters.
// Motion and two-finger scrolling instead go over a direct Bluetooth LE link: each datagram carries the running total
// since the session started (a skipped datagram is healed by the next one) and the sender's
// clock, so the Mac can replay the stroke at its original pace after a small fixed delay.

enum MotionChannel {
    /// Starting playout delay, until enough samples show how much the link actually jitters.
    /// Late packets beyond the delay still apply, just without interpolation.
    static let playoutDelay: TimeInterval = 0.015
    /// The Mac advertises this service with its serverID as the local name, so the phone joins
    /// the Mac it is paired with.
    static let bluetoothService = "8E3F2C1A-5B7D-4E9A-9C61-2D4B7A1E6F30"
    static let bluetoothCharacteristic = "8E3F2C1B-5B7D-4E9A-9C61-2D4B7A1E6F30"
}

/// Running pointer and scroll totals since a motion session started; the difference of two is
/// the delta to apply. Scroll rides along with the pointer so it gets the same smooth playout.
struct MotionTotals: Codable, Equatable {
    var x = 0.0
    var y = 0.0
    var scrollX = 0.0
    var scrollY = 0.0

    static let zero = MotionTotals()

    var pointer: CGVector { CGVector(dx: x, dy: y) }
    var isValid: Bool { [x, y, scrollX, scrollY].allSatisfy { $0.isFinite && abs($0) < 1e12 } }

    static func - (lhs: MotionTotals, rhs: MotionTotals) -> MotionTotals {
        MotionTotals(x: lhs.x - rhs.x, y: lhs.y - rhs.y, scrollX: lhs.scrollX - rhs.scrollX, scrollY: lhs.scrollY - rhs.scrollY)
    }

    static func + (lhs: MotionTotals, rhs: MotionTotals) -> MotionTotals {
        MotionTotals(x: lhs.x + rhs.x, y: lhs.y + rhs.y, scrollX: lhs.scrollX + rhs.scrollX, scrollY: lhs.scrollY + rhs.scrollY)
    }

    static func * (lhs: MotionTotals, t: Double) -> MotionTotals {
        MotionTotals(x: lhs.x * t, y: lhs.y * t, scrollX: lhs.scrollX * t, scrollY: lhs.scrollY * t)
    }
}

struct MotionPacket: Equatable {
    enum Kind: UInt8 { case probe = 0, motion = 1 }

    var kind: Kind
    var seq: UInt32
    var timestamp: Double
    var totals: MotionTotals

    private static let plainSize = 1 + 4 + 8 * 5
    static let sealedSize = 12 + plainSize + 16

    func seal(with key: SymmetricKey) throws -> Data {
        var plain = Data(capacity: Self.plainSize)
        plain.append(kind.rawValue)
        Self.append(UInt64(seq), bytes: 4, to: &plain)
        for value in [timestamp, totals.x, totals.y, totals.scrollX, totals.scrollY] {
            Self.append(value.bitPattern, bytes: 8, to: &plain)
        }
        return try ChaChaPoly.seal(plain, using: key).combined
    }

    /// Returns nil for anything not sealed with `key`, so stray or forged datagrams are ignored.
    static func open(_ data: Data, with key: SymmetricKey) -> MotionPacket? {
        guard data.count == sealedSize,
              let box = try? ChaChaPoly.SealedBox(combined: data),
              let plain = try? ChaChaPoly.open(box, using: key),
              plain.count == plainSize,
              let kind = Kind(rawValue: plain[plain.startIndex]) else { return nil }
        let bytes = [UInt8](plain)
        func read(_ offset: Int, _ count: Int) -> UInt64 {
            bytes[offset..<offset + count].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func double(_ offset: Int) -> Double { Double(bitPattern: read(offset, 8)) }
        let packet = MotionPacket(kind: kind, seq: UInt32(read(1, 4)), timestamp: double(5),
                                  totals: MotionTotals(x: double(13), y: double(21), scrollX: double(29), scrollY: double(37)))
        guard packet.timestamp.isFinite, packet.totals.isValid else { return nil }
        return packet
    }

    private static func append(_ value: UInt64, bytes: Int, to data: inout Data) {
        for shift in stride(from: (bytes - 1) * 8, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift))) }
    }
}

/// Turns bursty, possibly reordered motion samples into a steady stream: each sample is scheduled
/// at `sender time + clock offset + delay` and the pointer is interpolated between samples.
struct MotionPlayout {
    private struct Sample { var time: Double; var totals: MotionTotals }

    var delay = MotionChannel.playoutDelay
    /// Fit `delay` to the link: the recent p95 lateness plus a margin. It may rise a little within
    /// a stroke but only drops when a new stroke starts, where the change is invisible.
    var adaptive = true
    private var recentLateness: [Double] = []
    private var lastReceived = -Double.infinity
    private static let latenessWindow = 240
    private static let minimumSamples = 30
    private static let delayMargin = 0.002
    static let minimumDelay = 0.004
    /// A link that jitters more than this is not worth hiding: past it, waiting costs more than
    /// the occasional uninterpolated step a late sample makes.
    static let maximumDelay = 0.04
    /// Largest increase applied to a single sample within a stroke, so a rise reads as a
    /// barely slower stretch rather than a pause.
    private static let maximumRiseStep = 0.002
    private static let strokeGap = 0.15
    private var lastSeq: UInt32?
    private var samples: [Sample] = []
    private var offset: Double?
    private var offsetUpdated: Double = 0
    private var emitted = MotionTotals.zero
    /// A sample gap longer than this is a pause, not slow motion: the move it carries happened
    /// within roughly one touch frame before the sample, so it is not stretched across the pause.
    private static let maximumSpan = 0.02

    var isIdle: Bool {
        guard let last = samples.last else { return true }
        return last.totals == emitted
    }

    /// Queues a motion sample. Returns its lateness compared with the fastest one seen recently
    /// (for diagnostics), or nil if it was a probe, stale or a duplicate.
    @discardableResult
    mutating func receive(_ packet: MotionPacket, at now: Double) -> Double? {
        guard packet.kind == .motion else { return nil }
        if let lastSeq, packet.seq <= lastSeq { return nil }
        lastSeq = packet.seq
        // Track the minimum one-way offset; let it creep up slowly so clock drift cannot pin it.
        let observed = now - packet.timestamp
        let offset = self.offset.map { min(observed, $0 + 0.002 * max(0, now - offsetUpdated)) } ?? observed
        self.offset = offset
        offsetUpdated = now
        if adaptive { adapt(lateness: observed - offset, at: now) }
        var time = packet.timestamp + offset + delay
        if let last = samples.last { time = max(time, last.time) }
        samples.append(Sample(time: time, totals: packet.totals))
        return observed - offset
    }

    private mutating func adapt(lateness: Double, at now: Double) {
        recentLateness.append(lateness)
        if recentLateness.count > Self.latenessWindow { recentLateness.removeFirst() }
        let strokeStart = now - lastReceived > Self.strokeGap
        lastReceived = now
        guard recentLateness.count >= Self.minimumSamples else { return }
        let sorted = recentLateness.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let target = min(max(p95 + Self.delayMargin, Self.minimumDelay), Self.maximumDelay)
        if strokeStart { delay = target }
        else if target > delay { delay = min(target, delay + Self.maximumRiseStep) }
    }

    /// Moves the playout cursor to `now` and returns the pointer and scroll deltas to apply.
    mutating func advance(to now: Double) -> MotionTotals {
        // Keep exactly one sample at or before `now` as the interpolation base.
        while samples.count > 1, samples[1].time <= now { samples.removeFirst() }
        guard let base = samples.first, base.time <= now else { return .zero }
        var target = base.totals
        if samples.count > 1 {
            let next = samples[1]
            let start = max(base.time, next.time - Self.maximumSpan)
            if now > start {
                let t = (now - start) / (next.time - start)
                target = base.totals + (next.totals - base.totals) * t
            }
        }
        return emit(to: target)
    }

    /// Applies everything received so far at once (before a click/drag/key).
    mutating func flush() -> MotionTotals {
        guard let last = samples.last else { return .zero }
        samples = [last]
        return emit(to: last.totals)
    }

    /// Jumps to an authoritative total from the ordered TCP stream; later-arriving older datagrams
    /// are then ignored by sequence number.
    mutating func sync(seq: UInt32, totals: MotionTotals) -> MotionTotals {
        if let lastSeq, seq < lastSeq { return flush() }
        lastSeq = seq
        samples = [Sample(time: -.infinity, totals: totals)]
        return emit(to: totals)
    }

    private mutating func emit(to target: MotionTotals) -> MotionTotals {
        let delta = target - emitted
        emitted = target
        return delta
    }
}

/// Rolling 2-second view of Bluetooth motion delivery, to tell link jitter apart from other causes.
struct MotionStats {
    private var lateness: [Double] = []
    private var lateCount = 0
    private var delay = 0.0
    /// Every sequence number that came over Bluetooth this window, played or too old to play.
    private var arrived: Set<UInt32> = []
    /// Arrived after a sync or a newer datagram had already moved past them: late, not lost.
    private var staleCount = 0
    /// Numbers taken by `motionSync`, which only travels over Wi-Fi, so they leave gaps that are
    /// not loss. The last window's are kept too, as a sync and the datagrams around it can fall
    /// into different windows.
    private var syncs: Set<UInt32> = []
    private var earlierSyncs: Set<UInt32> = []
    /// The highest number counted in earlier windows; anything at or below it is a repeat.
    private var counted: UInt32?
    private var lastArrival: TimeInterval?
    /// Time spent moving: gaps between datagrams, leaving out the pauses between strokes.
    private var movingTime: TimeInterval = 0
    private var movingGaps = 0

    mutating func record(seq: UInt32, excessLatency: Double, playoutDelay: Double, at arrival: TimeInterval) {
        lateness.append(excessLatency)
        if excessLatency > playoutDelay { lateCount += 1 }
        delay = playoutDelay
        arrived.insert(seq)
        if let lastArrival, arrival - lastArrival < 0.15 {
            movingTime += arrival - lastArrival
            movingGaps += 1
        }
        lastArrival = arrival
    }

    /// A motion datagram the playout buffer dropped as stale or a duplicate.
    mutating func recordStale(seq: UInt32) {
        if let counted, seq <= counted { return }
        if arrived.insert(seq).inserted { staleCount += 1 }
    }

    mutating func recordSync(seq: UInt32) {
        syncs.insert(seq)
    }

    /// Returns nil while idle so the menu keeps the last meaningful reading.
    mutating func summarize() -> String? {
        defer {
            var next = MotionStats()
            next.earlierSyncs = syncs
            next.counted = [counted, arrived.max()].compactMap { $0 }.max()
            self = next
        }
        guard lateness.count >= 10, let firstSeq = arrived.min(), let lastSeq = arrived.max() else { return nil }
        let sorted = lateness.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))] * 1000
        let worst = (sorted.last ?? 0) * 1000
        let synced = syncs.union(earlierSyncs).filter { (firstSeq...lastSeq).contains($0) }.count
        let expected = Double(lastSeq - firstSeq + 1) - Double(synced)
        let loss = max(0, 1 - Double(arrived.count) / max(expected, 1)) * 100
        let lateShare = Double(lateCount) / Double(sorted.count) * 100
        // How often the phone actually got a datagram out while moving; its pacing widens when
        // the link cannot keep up.
        let rate = Double(movingGaps) / max(movingTime, 0.001)
        return String(format: "蓝牙 · 缓冲 %.0f ms · 抖动 p95 %.0f ms · 最大 %.0f ms\n丢包 %.1f%% · 过期 %d · 超出 %.0f%% · %.0f 包/秒",
                      delay * 1000, p95, worst, loss, staleCount, lateShare, rate)
    }
}

/// Scroll events carry whole pixels; a slow scroll arrives as many sub-pixel deltas that would
/// each round to zero. Carry the fraction over to the next delta instead.
struct ScrollAccumulator {
    private var remainderX = 0.0
    private var remainderY = 0.0

    mutating func take(dx: Double, dy: Double) -> (dx: Int32, dy: Int32) {
        let x = remainderX + dx
        let y = remainderY + dy
        let wholeX = x.rounded(.towardZero)
        let wholeY = y.rounded(.towardZero)
        remainderX = x - wholeX
        remainderY = y - wholeY
        return (Int32(wholeX), Int32(wholeY))
    }
}
