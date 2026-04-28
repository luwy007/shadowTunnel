import Cocoa
import Carbon.HIToolbox

final class SelectionManager {
    func selectedText(allowClipboardFallback: Bool = true) -> String {
        if let text = selectedTextFromAX(), !text.isEmpty {
            return text
        }
        if allowClipboardFallback, let text = selectedTextFromClipboard(), !text.isEmpty {
            return text
        }
        return ""
    }

    private func selectedTextFromAX() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        let focusedStatus = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusedStatus == .success, let element = focusedElement else { return nil }

        var selectedTextValue: AnyObject?
        let selectedStatus = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedTextValue)
        if selectedStatus == .success, let text = selectedTextValue as? String {
            return text
        }

        return nil
    }

    private func selectedTextFromClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let originalChangeCount = pasteboard.changeCount
        let savedItems = pasteboard.pasteboardItems
        let savedString = pasteboard.string(forType: .string)

        sendCopyShortcut()
        let copiedText = waitForCopiedText(
            in: pasteboard,
            originalChangeCount: originalChangeCount,
            previousString: savedString
        )

        pasteboard.clearContents()
        if let items = savedItems, !items.isEmpty {
            pasteboard.writeObjects(items)
        } else if let savedString {
            pasteboard.setString(savedString, forType: .string)
        }

        return copiedText
    }

    private func waitForCopiedText(
        in pasteboard: NSPasteboard,
        originalChangeCount: Int,
        previousString: String?
    ) -> String? {
        let deadline = Date().addingTimeInterval(0.6)

        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))

            let candidate = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let candidate, !candidate.isEmpty else { continue }

            let didPasteboardChange = pasteboard.changeCount != originalChangeCount
            let differsFromPreviousString = candidate != (previousString ?? "")
            if didPasteboardChange || differsFromPreviousString {
                return candidate
            }
        }

        return nil
    }

    private func sendCopyShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
