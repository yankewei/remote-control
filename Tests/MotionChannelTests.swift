import XCTest
import CoreGraphics
import CryptoKit
@testable import RemoteControlCore

final class MotionChannelTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    private func packet(_ seq: UInt32, at time: Double, x: Double, y: Double = 0, scrollY: Double = 0) -> MotionPacket {
        MotionPacket(kind: .motion, seq: seq, timestamp: time, totals: MotionTotals(x: x, y: y, scrollY: scrollY))
    }

    func testPacketRoundTripsAndRejectsWrongKey() throws {
        let original = MotionPacket(kind: .motion, seq: 42, timestamp: 1234.5678,
                                    totals: MotionTotals(x: -12.25, y: 99.5, scrollX: 3.75, scrollY: -480.5))
        let sealed = try original.seal(with: key)
        XCTAssertEqual(MotionPacket.open(sealed, with: key), original)
        XCTAssertEqual(sealed.count, MotionPacket.sealedSize)
        XCTAssertNil(MotionPacket.open(sealed, with: SymmetricKey(size: .bits256)))
        var tampered = sealed
        tampered[tampered.count - 1] ^= 1
        XCTAssertNil(MotionPacket.open(tampered, with: key))
    }

    func testBurstIsSpreadOverOriginalTimeline() {
        var playout = MotionPlayout()
        playout.delay = 0.05
        // An on-time packet establishes the clock offset (local = phone + 90 s).
        playout.receive(packet(1, at: 10, x: 0), at: 100)
        // Four more sent every 10 ms (the last at local 100.04), all delivered in one burst at
        // 100.045 — the first of them 35 ms late, still within the 50 ms delay.
        for index in 1...4 {
            playout.receive(packet(UInt32(index + 1), at: 10 + Double(index) * 0.01, x: Double(index) * 10), at: 100.045)
        }
        var total = 0.0
        var steps: [Double] = []
        var now = 100.045
        while now < 100.2 {
            now += 1.0 / 120
            let step = playout.advance(to: now).x
            if step != 0 { steps.append(step) }
            total += step
        }
        XCTAssertEqual(total, 40, accuracy: 1e-9)
        // Spread over several frames at the finger's pace (1 pt/ms) instead of one 40-point jump.
        XCTAssertGreaterThan(steps.count, 3)
        XCTAssertLessThanOrEqual(steps.max() ?? 0, 10 + 1e-9)
        XCTAssertTrue(playout.isIdle)
    }

    func testStaleAndDuplicatePacketsAreIgnored() {
        var playout = MotionPlayout()
        XCTAssertNotNil(playout.receive(packet(2, at: 1, x: 20), at: 5))
        XCTAssertNil(playout.receive(packet(1, at: 0.99, x: 10), at: 5))
        XCTAssertNil(playout.receive(packet(2, at: 1, x: 20), at: 5))
        XCTAssertEqual(playout.flush().x, 20)
    }

    func testLossIsHealedByRunningTotal() {
        var playout = MotionPlayout()
        playout.receive(packet(1, at: 1, x: 10), at: 5)
        // Packets 2–4 lost; 5 carries the full total.
        playout.receive(packet(5, at: 1.04, x: 50), at: 5.04)
        XCTAssertEqual(playout.flush().x, 50)
    }

    func testSyncJumpsToAuthoritativeTotalAndDropsOlderDatagrams() {
        var playout = MotionPlayout()
        playout.receive(packet(1, at: 1, x: 10), at: 5)
        XCTAssertEqual(playout.sync(seq: 3, totals: MotionTotals(x: 30, y: 4, scrollY: -6)), MotionTotals(x: 30, y: 4, scrollY: -6))
        // A late datagram from before the sync must not move the pointer back.
        XCTAssertNil(playout.receive(packet(2, at: 1.01, x: 20), at: 5.1))
        XCTAssertEqual(playout.advance(to: 6), .zero)
        XCTAssertNotNil(playout.receive(packet(4, at: 1.03, x: 35, y: 4, scrollY: -6), at: 5.1))
        XCTAssertEqual(playout.flush(), MotionTotals(x: 5))
    }

    func testPauseIsNotStretchedIntoSlowMotion() {
        var playout = MotionPlayout()
        playout.receive(packet(1, at: 1, x: 0), at: 5)
        _ = playout.advance(to: 6)
        // Two seconds later the finger moves 40 points in one touch frame.
        playout.receive(packet(2, at: 3, x: 40), at: 7)
        let playAt = 3 + 4 + MotionChannel.playoutDelay
        XCTAssertEqual(playout.advance(to: playAt - 0.03).x, 0)
        XCTAssertEqual(playout.advance(to: playAt).x, 40, accuracy: 1e-9)
    }

    func testScrollBurstIsSpreadLikePointerMotion() {
        var playout = MotionPlayout()
        playout.delay = 0.05
        playout.receive(packet(1, at: 10, x: 0), at: 100)
        // A two-finger scroll: the pointer stays put while the scroll total grows, and the
        // samples arrive in one burst.
        for index in 1...4 {
            playout.receive(packet(UInt32(index + 1), at: 10 + Double(index) * 0.01, x: 0, scrollY: Double(index) * -30), at: 100.045)
        }
        var pointer = 0.0
        var scrolled = 0.0
        var steps = 0
        var now = 100.045
        while now < 100.2 {
            now += 1.0 / 120
            let step = playout.advance(to: now)
            pointer += abs(step.x) + abs(step.y)
            scrolled += step.scrollY
            if step.scrollY != 0 { steps += 1 }
        }
        XCTAssertEqual(pointer, 0)
        XCTAssertEqual(scrolled, -120, accuracy: 1e-9)
        XCTAssertGreaterThan(steps, 3)
        XCTAssertTrue(playout.isIdle)
    }

    func testDelayShrinksOnSteadyLinkAtNextStroke() {
        var playout = MotionPlayout()
        // 60 samples every 5 ms, each delivered 2 ms after sending.
        for index in 0..<60 {
            let sent = 1 + Double(index) * 0.005
            playout.receive(packet(UInt32(index + 1), at: sent, x: Double(index)), at: sent + 4.002)
        }
        // Within the stroke the delay never drops.
        XCTAssertEqual(playout.delay, MotionChannel.playoutDelay)
        playout.receive(packet(61, at: 3, x: 61), at: 7.002)
        XCTAssertEqual(playout.delay, MotionPlayout.minimumDelay, accuracy: 1e-9)
    }

    func testDelayRisesGraduallyWithinStrokeOnJitter() {
        var playout = MotionPlayout()
        var delays: [Double] = []
        for index in 0..<120 {
            let sent = 1 + Double(index) * 0.005
            // Every other sample arrives 30 ms late.
            let lateness = index.isMultiple(of: 2) ? 0.0 : 0.03
            playout.receive(packet(UInt32(index + 1), at: sent, x: Double(index)), at: sent + 4 + lateness)
            delays.append(playout.delay)
        }
        XCTAssertEqual(playout.delay, 0.032, accuracy: 0.001)
        for (previous, next) in zip(delays, delays.dropFirst()) {
            XCTAssertLessThanOrEqual(next - previous, 0.002 + 1e-9)
        }
    }

    func testMotionMessagesValidate() throws {
        let offer = ControlMessage.motionOffer(key: Data(repeating: 1, count: 32))
        let sync = ControlMessage.motionSync(seq: 7, totals: MotionTotals(x: 1.5, y: -2, scrollX: 0.5, scrollY: 12))
        for message in [offer, sync, .motionReady] {
            var framer = MessageFramer()
            XCTAssertEqual(try framer.append(MessageFramer.encode(message)), [message])
        }
        XCTAssertFalse(ControlMessage.motionOffer(key: Data(count: 16)).isValid)
        XCTAssertFalse(ControlMessage.motionSync(seq: 1, totals: MotionTotals(x: .nan)).isValid)
        XCTAssertFalse(ControlMessage.motionSync(seq: 1, totals: MotionTotals(scrollY: .infinity)).isValid)
    }

    private func played(_ seqs: [UInt32], into stats: inout MotionStats) {
        for (index, seq) in seqs.enumerated() {
            stats.record(seq: seq, excessLatency: 0.001, playoutDelay: 0.01, at: Double(index) * 0.01)
        }
    }

    func testStatsLeaveOutSyncNumbers() {
        var stats = MotionStats()
        played(Array(1...6), into: &stats)
        stats.recordSync(seq: 7)
        played(Array(8...14), into: &stats)
        stats.recordSync(seq: 15)
        played([16], into: &stats)
        XCTAssertTrue(stats.summarize()?.contains("丢包 0.0% · 过期 0") == true)
    }

    func testStatsCountDatagramsLateForASyncAsStaleNotLost() {
        var stats = MotionStats()
        played(Array(1...5), into: &stats)
        stats.recordSync(seq: 7)
        // 6 was sealed before the sync but arrives after it; 5 is a resend.
        stats.recordStale(seq: 6)
        stats.recordStale(seq: 5)
        played(Array(8...13), into: &stats)
        XCTAssertTrue(stats.summarize()?.contains("丢包 0.0% · 过期 1") == true)
    }

    func testStatsStillReportRealLoss() {
        var stats = MotionStats()
        played(Array(1...10) + [12], into: &stats)
        XCTAssertTrue(stats.summarize()?.contains("丢包 8.3%") == true)
    }

    func testStatsKeepSyncsAcrossWindowsAndIgnoreOldRepeats() {
        var stats = MotionStats()
        played(Array(1...10), into: &stats)
        stats.recordSync(seq: 12)
        _ = stats.summarize()
        // 11 was in flight when the window closed; 10 is a resend from the last window.
        played([11] + Array(13...22), into: &stats)
        stats.recordStale(seq: 10)
        XCTAssertTrue(stats.summarize()?.contains("丢包 0.0% · 过期 0") == true)
    }
}
