import SwiftUI
import UIKit

struct TrackpadTouch: Equatable {
    let id: Int
    let location: CGPoint
}

struct PressableButtonStyle: ButtonStyle {
    var reduceMotion = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.2, dampingFraction: 0.8), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed else { return }
                TrackpadHaptics.light.impactOccurred(intensity: 0.5)
                TrackpadHaptics.light.prepare()
            }
    }
}

struct TrackpadView: UIViewRepresentable {
    var enabled: Bool
    var sensitivity: Double
    var send: (ControlMessage) -> Void
    var move: (Double, Double, TimeInterval) -> Void
    var onTouch: ([TrackpadTouch], Bool) -> Void

    func makeUIView(context: Context) -> TouchSurface {
        let view = TouchSurface()
        view.configure(enabled: enabled, sensitivity: sensitivity, send: send, move: move, onTouch: onTouch)
        return view
    }

    func updateUIView(_ view: TouchSurface, context: Context) {
        view.configure(enabled: enabled, sensitivity: sensitivity, send: send, move: move, onTouch: onTouch)
    }
}

final class TouchSurface: UIView, UIGestureRecognizerDelegate {
    private var send: (ControlMessage) -> Void = { _ in }
    private var move: (Double, Double, TimeInterval) -> Void = { _, _, _ in }
    private var onTouch: (([TrackpadTouch], Bool) -> Void)?
    private var sensitivity = 1.4
    private var dragging = false
    /// The long press fired but the finger has not moved yet: moving starts a drag, lifting is a
    /// right-click. Nothing has gone to the Mac until one of those happens.
    private var holdPending = false
    /// The last left tap, so quick repeats count up to a double or triple click. Each tap goes out
    /// at once instead of waiting to see whether another follows.
    private var lastTap: (time: TimeInterval, count: Int)?
    private static let multiTapInterval: TimeInterval = 0.4
    private var wasEnabled = true
    private let oneFinger = PointerPanGestureRecognizer()
    private var lastPointer: CGPoint?
    private let twoFingers = UIPanGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private let observer = TouchObserverGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true
        oneFinger.maximumNumberOfTouches = 1
        oneFinger.addTarget(self, action: #selector(movePointer(_:)))
        twoFingers.minimumNumberOfTouches = 2
        twoFingers.maximumNumberOfTouches = 2
        twoFingers.addTarget(self, action: #selector(scroll(_:)))
        hold.minimumPressDuration = 0.35
        hold.addTarget(self, action: #selector(drag(_:)))
        // No double-tap recognizer: it would hold every single tap back until it failed.
        let single = UITapGestureRecognizer(target: self, action: #selector(leftClick))
        let right = UITapGestureRecognizer(target: self, action: #selector(rightClick))
        right.numberOfTouchesRequired = 2
        single.require(toFail: hold)
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delaysTouchesEnded = false
        observer.onChange = { [weak self] points in
            guard let self else { return }
            self.onTouch?(points, self.showsDragMode)
        }
        for gesture in [oneFinger, twoFingers, hold, single, right, observer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
        isAccessibilityElement = true
        accessibilityLabel = "Mac 触控板"
        accessibilityHint = "单指滑动移动鼠标，轻点单击，连点双击，双指轻点或长按松开为右键，双指滚动，长按后移动可拖拽"
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "左键单击", target: self, selector: #selector(accessibleClick)),
            UIAccessibilityCustomAction(name: "右键单击", target: self, selector: #selector(accessibleRightClick))
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(enabled: Bool, sensitivity: Double, send: @escaping (ControlMessage) -> Void,
                   move: @escaping (Double, Double, TimeInterval) -> Void, onTouch: @escaping ([TrackpadTouch], Bool) -> Void) {
        let previouslyEnabled = wasEnabled
        if previouslyEnabled && !enabled && dragging {
            self.send(.drag(active: false))
            dragging = false
        }
        if !enabled {
            holdPending = false
            lastTap = nil
        }
        self.send = send
        self.move = move
        self.onTouch = onTouch
        self.sensitivity = sensitivity
        isUserInteractionEnabled = enabled
        wasEnabled = enabled
        if previouslyEnabled && !enabled {
            DispatchQueue.main.async { [weak self] in self?.observer.clear() }
        }
    }

    @objc private func movePointer(_ gesture: UIPanGestureRecognizer) {
        // Measure from the finger's touch-down point rather than `translation`: the pan's
        // ~10pt start threshold would otherwise be dropped, making small moves feel dead.
        switch gesture.state {
        case .began, .changed:
            let speed = hypot(gesture.velocity(in: self).x, gesture.velocity(in: self).y)
            // Slow strokes stay precise (≈1×); fast flicks reach up to 3.5× to cross the screen.
            let gain = sensitivity * (1 + min(speed / 600, 2.5))
            // Every touch sample, including the ones UIKit coalesced into this frame, goes out
            // with its own timestamp so the Mac can replay the stroke at the finger's pace.
            var samples = oneFinger.takeSamples()
            if samples.isEmpty { samples = [(gesture.location(in: self), ProcessInfo.processInfo.systemUptime)] }
            for sample in samples {
                let origin = lastPointer ?? sample.location
                lastPointer = sample.location
                let dx = (sample.location.x - origin.x) * gain
                let dy = (sample.location.y - origin.y) * gain
                guard dx != 0 || dy != 0 else { continue }
                // The pointer left the tapped spot, so the next tap starts a new click run.
                lastTap = nil
                if holdPending { beginDrag() }
                move(ControlMessage.clampDelta(dx), ControlMessage.clampDelta(dy), sample.time)
            }
        default:
            _ = oneFinger.takeSamples()
            lastPointer = nil
        }
    }

    @objc private func scroll(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            lastTap = nil
            holdPending = false
            if dragging {
                send(.drag(active: false))
                dragging = false
            }
            notifyTouchState()
        }
        if gesture.state == .changed {
            let delta = gesture.translation(in: self)
            send(.scroll(dx: ControlMessage.clampDelta(delta.x * 1.5), dy: ControlMessage.clampDelta(delta.y * 1.5)))
        }
        gesture.setTranslation(.zero, in: self)
    }

    @objc private func drag(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            holdPending = true
            lastTap = nil
            TrackpadHaptics.hold.impactOccurred()
            notifyTouchState()
        case .ended, .cancelled, .failed:
            if dragging {
                dragging = false
                send(.drag(active: false))
            } else if holdPending, gesture.state == .ended {
                rightClick()
            }
            holdPending = false
            notifyTouchState()
        default:
            break
        }
    }

    /// Presses the button only once the held finger moves, so a hold released in place can be a
    /// right-click instead.
    private func beginDrag() {
        holdPending = false
        dragging = true
        send(.drag(active: true))
        notifyTouchState()
    }

    @objc private func leftClick() {
        let now = ProcessInfo.processInfo.systemUptime
        let count = lastTap.map { now - $0.time < Self.multiTapInterval ? min($0.count + 1, 3) : 1 } ?? 1
        lastTap = (now, count)
        send(.click(button: .left, count: count))
    }

    @objc private func rightClick() {
        lastTap = nil
        send(.click(button: .right, count: 1))
    }

    @objc private func accessibleClick() -> Bool {
        lastTap = nil
        send(.click(button: .left, count: 1))
        return true
    }

    @objc private func accessibleRightClick() -> Bool { rightClick(); return true }

    /// The touch glow takes the drag color from the moment the hold fires.
    private var showsDragMode: Bool { dragging || holdPending }

    private func notifyTouchState() {
        onTouch?(observer.latest, showsDragMode)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === oneFinger, oneFinger.state == .possible { lastPointer = touch.location(in: self) }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === observer || other === observer { return true }
        return (gestureRecognizer === oneFinger && other === hold) || (gestureRecognizer === hold && other === oneFinger)
    }
}

/// A pan that keeps every touch sample since the last action, including the in-between ones UIKit
/// coalesces into one frame (touch sampling outruns the display on ProMotion iPhones).
final class PointerPanGestureRecognizer: UIPanGestureRecognizer {
    typealias Sample = (location: CGPoint, time: TimeInterval)
    private var samples: [Sample] = []

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            for sample in event.coalescedTouches(for: touch) ?? [touch] {
                samples.append((sample.location(in: view), sample.timestamp))
            }
        }
        super.touchesMoved(touches, with: event)
    }

    func takeSamples() -> [Sample] {
        defer { samples.removeAll(keepingCapacity: true) }
        return samples
    }

    override func reset() {
        samples.removeAll()
        super.reset()
    }
}

final class TouchObserverGestureRecognizer: UIGestureRecognizer {
    var onChange: (([TrackpadTouch]) -> Void)?
    private var active: [ObjectIdentifier: (touch: UITouch, slot: Int)] = [:]
    private var nextSlot = 0
    private(set) var latest: [TrackpadTouch] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            active[ObjectIdentifier(touch)] = (touch: touch, slot: nextSlot)
            nextSlot += 1
        }
        if state == .possible { state = .began } else { state = .changed }
        report()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if state == .began { state = .changed }
        report()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            active.removeValue(forKey: ObjectIdentifier(touch))
        }
        report()
        if active.isEmpty {
            state = .ended
            nextSlot = 0
        } else {
            state = .changed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        active.removeAll()
        report()
        state = .cancelled
        nextSlot = 0
    }

    override func reset() {
        active.removeAll()
        latest = []
        nextSlot = 0
        super.reset()
    }

    func clear() {
        active.removeAll()
        latest = []
        onChange?(latest)
    }

    private func report() {
        guard let view else {
            latest = []
            onChange?(latest)
            return
        }
        latest = active.values
            .sorted { $0.slot < $1.slot }
            .map { TrackpadTouch(id: $0.slot, location: $0.touch.location(in: view)) }
        onChange?(latest)
    }
}

struct TouchpadCanvas: View {
    var sensitivity: Double
    var send: (ControlMessage) -> Void
    var move: (Double, Double, TimeInterval) -> Void
    var isConnected: Bool
    var inputAllowed: Bool
    var cornerRadius: CGFloat
    var onConnect: () -> Void

    @State private var spots: [TrackpadSpot] = []
    @State private var ripples: [TouchRipple] = []
    @State private var dragging = false
    @State private var isTouching = false
    @State private var hasTouched = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mode: TouchMode {
        if dragging { return .drag }
        return spots.count > 1 ? .scroll : .move
    }

    var body: some View {
        ZStack {
            TouchpadBackground()
            IdleHint(isConnected: isConnected, inputAllowed: inputAllowed, isTouching: isTouching, hasTouched: hasTouched)
            TouchGlowLayer(spots: spots, mode: mode, isTouching: isTouching, reduceMotion: reduceMotion)
            ZStack {
                ForEach(ripples) { ripple in
                    TouchRippleMark(color: ripple.color, reduceMotion: reduceMotion)
                        .position(x: ripple.point.x, y: ripple.point.y)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            TrackpadView(
                enabled: isConnected && inputAllowed,
                sensitivity: sensitivity,
                send: send,
                move: move,
                onTouch: handleTouch
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !isConnected {
                GeometryReader { geometry in
                    ConnectButton(action: onConnect, reduceMotion: reduceMotion)
                        .position(x: geometry.size.width / 2, y: geometry.size.height * 0.66)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.30), radius: 26, y: 14)
    }

    private func handleTouch(_ points: [TrackpadTouch], _ isDragging: Bool) {
        let wasTouching = isTouching
        let oldIDs = wasTouching ? Set(spots.map(\.id)) : []
        let newSpots = points.map { TrackpadSpot(id: $0.id, point: $0.location) }
        let added = newSpots.filter { !oldIDs.contains($0.id) }

        if !added.isEmpty {
            let rippleColor = color(count: points.count, dragging: isDragging)
            for spot in added {
                let ripple = TouchRipple(point: spot.point, color: rippleColor)
                ripples.append(ripple)
                let id = ripple.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    ripples.removeAll { $0.id == id }
                }
            }
            hasTouched = true
        }

        dragging = isDragging

        if points.isEmpty {
            isTouching = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if !isTouching { spots = [] }
            }
        } else {
            spots = newSpots
            isTouching = true
        }
    }

    private func color(count: Int, dragging: Bool) -> Color {
        if dragging { return TouchMode.drag.color }
        return count > 1 ? TouchMode.scroll.color : TouchMode.move.color
    }
}

struct GlassSurface: View {
    let cornerRadius: CGFloat
    let reduceTransparency: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(Color(white: 0.12))
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.white.opacity(0.05)))
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
    }
}

private struct TrackpadSpot: Identifiable, Equatable {
    let id: Int
    let point: CGPoint
}

private enum TouchMode: Equatable {
    case move, scroll, drag

    var color: Color {
        switch self {
        case .move: return Color(red: 0.35, green: 0.78, blue: 1.00)
        case .scroll: return Color(red: 0.70, green: 0.52, blue: 1.00)
        case .drag: return Color(red: 1.00, green: 0.74, blue: 0.35)
        }
    }
}

private struct TouchRipple: Identifiable {
    let id = UUID()
    let point: CGPoint
    let color: Color
}

private struct TouchRippleMark: View {
    let color: Color
    let reduceMotion: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .strokeBorder(color.opacity(animate ? 0 : 0.75), lineWidth: 1.5)
            .frame(width: 48, height: 48)
            .scaleEffect(animate ? (reduceMotion ? 1.6 : 2.8) : 0.5)
            .blur(radius: 0.4)
            .onAppear {
                withAnimation(.easeOut(duration: reduceMotion ? 0.3 : 0.7)) {
                    animate = true
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct TouchGlowLayer: View {
    let spots: [TrackpadSpot]
    let mode: TouchMode
    let isTouching: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            ForEach(spots) { spot in
                halo(at: spot.point, color: mode.color)
                ring(at: spot.point, color: mode.color)
                core(at: spot.point, color: mode.color)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isTouching ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.22, dampingFraction: 0.8), value: isTouching)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: mode)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func halo(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(RadialGradient(colors: [color.opacity(0.50), color.opacity(0.16), .clear], center: .center, startRadius: 0, endRadius: 96))
            .frame(width: 190, height: 190)
            .blur(radius: 18)
            .blendMode(.screen)
            .position(x: point.x, y: point.y)
            .animation(reduceMotion ? nil : .interactiveSpring(response: 0.18, dampingFraction: 0.86), value: point)
    }

    private func ring(at point: CGPoint, color: Color) -> some View {
        Circle()
            .strokeBorder(color.opacity(0.9), lineWidth: 1.2)
            .frame(width: 36, height: 36)
            .shadow(color: color.opacity(0.8), radius: 10)
            .position(x: point.x, y: point.y)
    }

    private func core(at point: CGPoint, color: Color) -> some View {
        Circle()
            .fill(.white)
            .frame(width: 8, height: 8)
            .shadow(color: .white.opacity(0.95), radius: 5)
            .shadow(color: color, radius: 14)
            .position(x: point.x, y: point.y)
    }
}

private struct TouchpadBackground: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.035, green: 0.055, blue: 0.10),
                        Color(red: 0.06, green: 0.10, blue: 0.18),
                        Color(red: 0.03, green: 0.05, blue: 0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color(red: 0.18, green: 0.55, blue: 1.0).opacity(0.20))
                    .frame(width: geometry.size.width * 0.95, height: geometry.size.width * 0.95)
                    .blur(radius: 90)
                    .offset(x: -geometry.size.width * 0.32, y: -geometry.size.height * 0.28)
                    .blendMode(.screen)
                Circle()
                    .fill(Color(red: 0.45, green: 0.25, blue: 1.0).opacity(0.16))
                    .frame(width: geometry.size.width * 0.80, height: geometry.size.width * 0.80)
                    .blur(radius: 100)
                    .offset(x: geometry.size.width * 0.35, y: geometry.size.height * 0.28)
                    .blendMode(.screen)
                DotGrid()
                    .opacity(0.7)
                RadialGradient(
                    colors: [.clear, .black.opacity(0.35)],
                    center: .center,
                    startRadius: min(geometry.size.width, geometry.size.height) * 0.22,
                    endRadius: max(geometry.size.width, geometry.size.height) * 0.75
                )
                VStack {
                    LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: geometry.size.height * 0.32)
                    Spacer(minLength: 0)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: 11, to: size.width, by: 22) {
                for y in stride(from: 11, to: size.height, by: 22) {
                    let dot = Path(ellipseIn: CGRect(x: x, y: y, width: 1.1, height: 1.1))
                    context.fill(dot, with: .color(.white.opacity(0.075)))
                }
            }
        }
    }
}

private struct IdleHint: View {
    let isConnected: Bool
    let inputAllowed: Bool
    let isTouching: Bool
    let hasTouched: Bool

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(.white.opacity(0.10))
                    .frame(width: 6, height: 6)
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 1, height: 18)
                    .offset(y: -38)
                Rectangle()
                    .fill(.white.opacity(0.12))
                    .frame(width: 18, height: 1)
                    .offset(x: 38)
            }
            Text(isConnected ? (inputAllowed ? "你的手指，就是鼠标" : "等待 Mac 辅助功能权限") : "连接 Mac，开始操控")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            Text("单指移动 · 双指滚动 · 长按拖拽或右键")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
        }
        .opacity(isTouching ? 0.06 : (hasTouched ? 0.45 : 1))
        .animation(.easeOut(duration: 0.25), value: isTouching)
        .animation(.easeOut(duration: 0.35), value: hasTouched)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ConnectButton: View {
    let action: () -> Void
    let reduceMotion: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "link")
                Text("连接 Mac")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(red: 0.16, green: 0.45, blue: 1.0), Color(red: 0.10, green: 0.72, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Color(red: 0.16, green: 0.55, blue: 1.0).opacity(0.45), radius: 18, y: 6)
        }
        .buttonStyle(PressableButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("连接 Mac")
    }
}

// Taps and strokes on the touchpad stay silent, since a tap felt on the phone before the Mac
// cursor reacts makes network latency more noticeable. Buttons and the long press, a local mode
// change with nothing to wait for on the Mac, do get feedback.
private enum TrackpadHaptics {
    static let light = UIImpactFeedbackGenerator(style: .light)
    static let hold = UIImpactFeedbackGenerator(style: .medium)
}
