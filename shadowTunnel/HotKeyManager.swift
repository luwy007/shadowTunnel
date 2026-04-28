import Cocoa
import Carbon.HIToolbox

struct HotKeyConfig: Codable {
    var keyCode: UInt32
    var modifiers: UInt32
}

final class HotKeyManager {
    var onTrigger: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private static let hotkeyDefaultsKey = "shadowTunnel.hotkey"

    init() {
        registerHotKey()
    }

    deinit {
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    private func registerHotKey() {
        let hotKeyId = EventHotKeyID(signature: OSType(0x5354544E), id: 1) // 'STTN'
        let config = Self.loadHotkeyConfig()

        RegisterEventHotKey(config.keyCode, config.modifiers, hotKeyId, GetEventDispatcherTarget(), 0, &hotKeyRef)

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { (_, eventRef, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.onTrigger?()
            return noErr
        }, 1, &eventSpec, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), &eventHandler)
    }

    func updateHotKey(config: HotKeyConfig) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        Self.saveHotkeyConfig(config)
        registerHotKey()
    }

    static func loadHotkeyConfig() -> HotKeyConfig {
        if let data = UserDefaults.standard.data(forKey: hotkeyDefaultsKey),
           let config = try? JSONDecoder().decode(HotKeyConfig.self, from: data) {
            return config
        }
        return HotKeyConfig(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(cmdKey | optionKey))
    }

    static func saveHotkeyConfig(_ config: HotKeyConfig) {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.setValue(data, forKey: hotkeyDefaultsKey)
        }
    }

    static func hotkeyString() -> String {
        let config = loadHotkeyConfig()
        return HotKeyFormatter.string(for: config)
    }
}

enum HotKeyFormatter {
    static func string(for config: HotKeyConfig) -> String {
        var parts: [String] = []
        if (config.modifiers & UInt32(cmdKey)) != 0 { parts.append("Cmd") }
        if (config.modifiers & UInt32(optionKey)) != 0 { parts.append("Option") }
        if (config.modifiers & UInt32(shiftKey)) != 0 { parts.append("Shift") }
        if (config.modifiers & UInt32(controlKey)) != 0 { parts.append("Control") }
        parts.append(keyName(config.keyCode))
        return parts.joined(separator: "+")
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        switch keyCode {
        case UInt32(kVK_ANSI_A): return "A"
        case UInt32(kVK_ANSI_B): return "B"
        case UInt32(kVK_ANSI_C): return "C"
        case UInt32(kVK_ANSI_D): return "D"
        case UInt32(kVK_ANSI_E): return "E"
        case UInt32(kVK_ANSI_F): return "F"
        case UInt32(kVK_ANSI_G): return "G"
        case UInt32(kVK_ANSI_H): return "H"
        case UInt32(kVK_ANSI_I): return "I"
        case UInt32(kVK_ANSI_J): return "J"
        case UInt32(kVK_ANSI_K): return "K"
        case UInt32(kVK_ANSI_L): return "L"
        case UInt32(kVK_ANSI_M): return "M"
        case UInt32(kVK_ANSI_N): return "N"
        case UInt32(kVK_ANSI_O): return "O"
        case UInt32(kVK_ANSI_P): return "P"
        case UInt32(kVK_ANSI_Q): return "Q"
        case UInt32(kVK_ANSI_R): return "R"
        case UInt32(kVK_ANSI_S): return "S"
        case UInt32(kVK_ANSI_T): return "T"
        case UInt32(kVK_ANSI_U): return "U"
        case UInt32(kVK_ANSI_V): return "V"
        case UInt32(kVK_ANSI_W): return "W"
        case UInt32(kVK_ANSI_X): return "X"
        case UInt32(kVK_ANSI_Y): return "Y"
        case UInt32(kVK_ANSI_Z): return "Z"
        case UInt32(kVK_Space): return "Space"
        default: return "KeyCode\(keyCode)"
        }
    }
}
