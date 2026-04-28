import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotKeyRecorderView: View {
    var onSave: (HotKeyConfig) -> Void
    var onCancel: () -> Void
    @State private var displayText: String = "Press a key combination"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Hotkey")
                .font(.headline)
            Text(displayText)
                .foregroundColor(.secondary)
            HotKeyCaptureView { config in
                displayText = HotKeyFormatter.string(for: config)
                onSave(config)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
            }
        }
    }
}

struct HotKeyCaptureView: NSViewRepresentable {
    var onCapture: (HotKeyConfig) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {}
}

final class CaptureView: NSView {
    var onCapture: ((HotKeyConfig) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = CarbonModifierMapper.modifiers(from: event.modifierFlags)
        let config = HotKeyConfig(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        onCapture?(config)
    }
}

enum CarbonModifierMapper {
    static func modifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }
}
