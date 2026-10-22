import AppKit
import ApplicationServices
import QuartzCore

private func inputDisplayConfigurationChanged(_: CGDirectDisplayID, _: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let controller = Unmanaged<InputController>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { [weak controller] in controller?.refreshDisplays() }
}

/// CADisplayLink needs an Objective-C target; this one forwards to a closure without retaining
/// the controller.
private final class DisplayLinkTarget: NSObject {
    let fire: () -> Void
    init(_ fire: @escaping () -> Void) { self.fire = fire }
    @objc func step(_ link: CADisplayLink) { fire() }
}

final class InputController {
    var dragging = false
    var useClipboard = UserDefaults.standard.bool(forKey: "useClipboard") {
        didSet { UserDefaults.standard.set(useClipboard, forKey: "useClipboard") }
    }
    private(set) var pasting = false
    /// Cached by ConnectionServer's permission poll; querying it per motion datagram is an IPC call.
    var accessibilityAllowed = AXIsProcessTrusted()
    var onError: ((String) -> Void)?
    private var displayBounds: [CGRect] = []
    private static let clipboardRestoreDelay: TimeInterval = 0.8
    // Bluetooth motion is replayed on its original timeline by `playout`, sampled once per refresh
    // of the display under the cursor so each frame shows exactly one step.
    private var playout = MotionPlayout()
    private var displayLink: CADisplayLink?
    var playoutDelay: Double { playout.delay }
    // Posted events apply asynchronously, so reading the system cursor right after posting can
    // return a stale position and swallow motion. Track our own position while moving.
    private var cursor: CGPoint?
    private var lastMoveTime: TimeInterval = 0
    private var scroll = ScrollAccumulator()

    init() {
        refreshDisplays()
        CGDisplayRegisterReconfigurationCallback(inputDisplayConfigurationChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        CGDisplayRemoveReconfigurationCallback(inputDisplayConfigurationChanged, Unmanaged.passUnretained(self).toOpaque())
    }

    func refreshDisplays() {
        var displays = [CGDirectDisplayID](repeating: 0, count: 32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32, &displays, &count)
        displayBounds = displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Starts a fresh motion session: the phone's running totals restart from zero.
    func resetMotion() {
        flushMove()
        playout = MotionPlayout()
    }

    /// Returns the sample's lateness beyond the fastest recent one, or nil if it was stale.
    func receiveMotion(_ packet: MotionPacket, at arrival: TimeInterval) -> Double? {
        guard accessibilityAllowed, let lateness = playout.receive(packet, at: arrival) else { return nil }
        startSmoothing()
        return lateness
    }

    func handle(_ message: ControlMessage) {
        guard accessibilityAllowed else { onError?("请先在 Mac 系统设置中允许辅助功能访问"); return }
        if case let .motionSync(seq, totals) = message {
            stopSmoothing()
            apply(playout.sync(seq: seq, totals: totals))
            return
        }
        // Anything else (Wi-Fi move, click, drag, scroll, key) must land where the pointer will end up.
        flushMove()
        let location = currentLocation()
        switch message {
        case let .move(dx, dy):
            post(CGVector(dx: dx, dy: dy))
        case let .click(button, count):
            // One press per message; `count` is its place in a run of quick taps, so the second
            // tap of a double-click arrives as its own message with count 2.
            releaseDrag()
            for type: CGEventType in button == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
                                    mouseButton: button == .left ? .left : .right)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
            }
        case let .scroll(dx, dy):
            postScroll(dx: dx, dy: dy)
        case let .drag(active):
            guard active != dragging else { return }
            dragging = active
            CGEvent(mouseEventSource: nil, mouseType: active ? .leftMouseDown : .leftMouseUp,
                    mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        case let .text(_, text):
            if useClipboard { paste(text) }
            else {
                for chunk in TextChunker.chunks(text) {
                    for down in [true, false] {
                        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                        chunk.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                        event?.post(tap: .cghidEventTap)
                    }
                }
            }
        case let .key(key):
            press(key)
        default: break
        }
    }

    private func press(_ key: RemoteKey) {
        let code: CGKeyCode
        let flags: CGEventFlags
        switch key {
        case .enter: code = 36; flags = []
        case .escape: code = 53; flags = []
        case .delete: code = 51; flags = []
        case .tab: code = 48; flags = []
        case .space: code = 49; flags = []
        case .copy: code = 8; flags = .maskCommand
        case .paste: code = 9; flags = .maskCommand
        case .spotlight: code = 49; flags = .maskCommand
        case .switchApp: code = 48; flags = .maskCommand
        case .fullScreen: code = 3; flags = [.maskCommand, .maskControl]
        case .closeWindow: code = 13; flags = .maskCommand
        case .volumeUp: return postSystemKey(0)
        case .volumeDown: return postSystemKey(1)
        case .brightnessUp: return postSystemKey(2)
        case .brightnessDown: return postSystemKey(3)
        case .mute: return postSystemKey(7)
        case .playPause: return postSystemKey(16)
        case .missionControl:
            // Launching the app works even when the user has remapped or disabled the ⌃↑ shortcut.
            let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
                if error != nil { DispatchQueue.main.async { self?.onError?("无法打开调度中心") } }
            }
            return
        }
        // The app switcher (Dock) only reacts to ⌘Tab when Command itself goes down and up,
        // so press the modifier keys around the key instead of only flagging it.
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(55, .maskCommand), (59, .maskControl)].filter { flags.contains($0.1) }
        var held: CGEventFlags = []
        for (modifier, flag) in modifiers {
            held.insert(flag)
            postKey(modifier, down: true, flags: held)
        }
        postKey(code, down: true, flags: flags)
        postKey(code, down: false, flags: flags)
        for (modifier, flag) in modifiers.reversed() {
            held.remove(flag)
            postKey(modifier, down: false, flags: held)
        }
    }

    private func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    /// Media and brightness keys are NX_SYSDEFINED aux-control events, not virtual key codes;
    /// `type` is an NX_KEYTYPE_* value. Brightness only reaches displays macOS can dim itself.
    private func postSystemKey(_ type: Int) {
        for down in [true, false] {
            let data1 = (type << 16) | ((down ? 0xA : 0xB) << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00),
                               timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: data1, data2: -1)?
                .cgEvent?.post(tap: .cghidEventTap)
        }
    }

    private func startSmoothing() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget { [weak self] in self?.tick() }
        guard let link = screenUnderCursor()?.displayLink(target: target, selector: #selector(DisplayLinkTarget.step(_:))) else {
            tick()
            return
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
        tick()
    }

    /// The display link follows one screen's refresh; pick the one the pointer is on when a
    /// stroke starts.
    private func screenUnderCursor() -> NSScreen? {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(currentLocation(), 1, &display, &count) == .success, count > 0,
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
           }) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func tick() {
        apply(playout.advance(to: ProcessInfo.processInfo.systemUptime))
        if playout.isIdle { stopSmoothing() }
    }

    private func stopSmoothing() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func currentLocation() -> CGPoint {
        // After a pause the user or a physical mouse may have moved the cursor; resync.
        if let cursor, ProcessInfo.processInfo.systemUptime - lastMoveTime < 0.25 { return cursor }
        return CGEvent(source: nil)?.location ?? .zero
    }

    private func flushMove() {
        apply(playout.flush())
        stopSmoothing()
    }

    private func apply(_ delta: MotionTotals) {
        if delta.x != 0 || delta.y != 0 { post(delta.pointer) }
        if delta.scrollX != 0 || delta.scrollY != 0 { postScroll(dx: delta.scrollX, dy: delta.scrollY) }
    }

    private func postScroll(dx: Double, dy: Double) {
        let whole = scroll.take(dx: dx, dy: dy)
        guard whole != (0, 0) else { return }
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                wheel1: whole.dy, wheel2: whole.dx, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func post(_ delta: CGVector) {
        let base = currentLocation()
        lastMoveTime = ProcessInfo.processInfo.systemUptime
        let proposed = CGPoint(x: base.x + delta.dx, y: base.y + delta.dy)
        if displayBounds.isEmpty { refreshDisplays() }
        // Clamp to the nearest display, including displays above/left of the primary one.
        let candidates = displayBounds.map { bounds -> CGPoint in
            CGPoint(x: min(max(proposed.x, bounds.minX), bounds.maxX - 1),
                    y: min(max(proposed.y, bounds.minY), bounds.maxY - 1))
        }
        let point = candidates.min { hypot($0.x - proposed.x, $0.y - proposed.y) < hypot($1.x - proposed.x, $1.y - proposed.y) } ?? base
        cursor = point
        let event = CGEvent(mouseEventSource: nil, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: point, mouseButton: .left)
        // Apps that read relative motion (games, some canvases) need the delta fields too.
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - base.x).rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - base.y).rounded()))
        event?.post(tap: .cghidEventTap)
    }

    func releaseDrag() {
        flushMove()
        guard dragging else { return }
        dragging = false
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: currentLocation(), mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func paste(_ text: String) {
        pasting = true
        let clipboard = NSPasteboard.general
        // Snapshot each item as a copy. `data(forType:)` still forces promised data, so complex
        // clipboard payloads are not guaranteed to round-trip; the README documents this fallback.
        let saved = clipboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
        let changeCount = clipboard.changeCount
        handle(.key(.paste))
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardRestoreDelay) { [weak self] in
            defer { self?.pasting = false }
            // Restore only if another app or the user has not changed the clipboard meanwhile.
            guard clipboard.changeCount == changeCount else { return }
            clipboard.clearContents()
            clipboard.writeObjects(saved)
        }
    }
}
