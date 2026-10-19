import AppKit
import ApplicationServices

private func inputDisplayConfigurationChanged(_: CGDirectDisplayID, _: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let controller = Unmanaged<InputController>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async { [weak controller] in controller?.refreshDisplays() }
}

final class InputController {
    var dragging = false
    var useClipboard = UserDefaults.standard.bool(forKey: "useClipboard") {
        didSet { UserDefaults.standard.set(useClipboard, forKey: "useClipboard") }
    }
    private(set) var pasting = false
    var onError: ((String) -> Void)?
    private var displayBounds: [CGRect] = []
    private static let clipboardRestoreDelay: TimeInterval = 0.8

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

    func handle(_ message: ControlMessage) {
        guard AXIsProcessTrusted() else { onError?("请先在 Mac 系统设置中允许辅助功能访问"); return }
        let location = CGEvent(source: nil)?.location ?? .zero
        switch message {
        case let .move(dx, dy):
            let proposed = CGPoint(x: location.x + dx, y: location.y + dy)
            if displayBounds.isEmpty { refreshDisplays() }
            // Clamp to the nearest display, including displays above/left of the primary one.
            let candidates = displayBounds.map { bounds -> CGPoint in
                CGPoint(x: min(max(proposed.x, bounds.minX), bounds.maxX - 1),
                        y: min(max(proposed.y, bounds.minY), bounds.maxY - 1))
            }
            let point = candidates.min { hypot($0.x - proposed.x, $0.y - proposed.y) < hypot($1.x - proposed.x, $1.y - proposed.y) } ?? location
            CGEvent(mouseEventSource: nil, mouseType: dragging ? .leftMouseDragged : .mouseMoved,
                    mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        case let .click(button, count):
            releaseDrag()
            for index in 1...count {
                for type: CGEventType in button == .left ? [.leftMouseDown, .leftMouseUp] : [.rightMouseDown, .rightMouseUp] {
                    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
                                        mouseButton: button == .left ? .left : .right)
                    event?.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                    event?.post(tap: .cghidEventTap)
                }
            }
        case let .scroll(dx, dy):
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                    wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0)?.post(tap: .cghidEventTap)
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
            }
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
                event?.flags = flags
                event?.post(tap: .cghidEventTap)
            }
        default: break
        }
    }

    func releaseDrag() {
        guard dragging else { return }
        dragging = false
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: CGEvent(source: nil)?.location ?? .zero, mouseButton: .left)?.post(tap: .cghidEventTap)
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
