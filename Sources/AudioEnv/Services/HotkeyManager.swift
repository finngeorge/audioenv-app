import Carbon.HIToolbox
import Foundation
import os.log

/// Manages a global keyboard shortcut (default: Ctrl+Space) that works even when
/// the app is in the background. Uses Carbon RegisterEventHotKey which doesn't
/// require Accessibility permissions.
@MainActor
final class HotkeyManager: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Hotkey")

    @Published var currentBinding: HotkeyBinding {
        didSet { saveBinding() }
    }

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Called when the global hotkey is pressed
    var onHotkeyPressed: (() -> Void)?

    // MARK: - Binding Model

    struct HotkeyBinding: Codable, Equatable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// Ctrl+Space
        static let defaultBinding = HotkeyBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey)
        )

        var displayString: String {
            var parts: [String] = []
            if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
            if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
            if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
            if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }

            let keyName: String
            switch Int(keyCode) {
            case kVK_Space: keyName = "Space"
            case kVK_Return: keyName = "Return"
            case kVK_Tab: keyName = "Tab"
            case kVK_Escape: keyName = "Esc"
            case kVK_ANSI_A: keyName = "A"
            case kVK_ANSI_B: keyName = "B"
            case kVK_ANSI_C: keyName = "C"
            case kVK_ANSI_D: keyName = "D"
            case kVK_ANSI_E: keyName = "E"
            case kVK_ANSI_F: keyName = "F"
            case kVK_ANSI_G: keyName = "G"
            case kVK_ANSI_H: keyName = "H"
            case kVK_ANSI_I: keyName = "I"
            case kVK_ANSI_J: keyName = "J"
            case kVK_ANSI_K: keyName = "K"
            case kVK_ANSI_L: keyName = "L"
            case kVK_ANSI_M: keyName = "M"
            case kVK_ANSI_N: keyName = "N"
            case kVK_ANSI_O: keyName = "O"
            case kVK_ANSI_P: keyName = "P"
            case kVK_ANSI_Q: keyName = "Q"
            case kVK_ANSI_R: keyName = "R"
            case kVK_ANSI_S: keyName = "S"
            case kVK_ANSI_T: keyName = "T"
            case kVK_ANSI_U: keyName = "U"
            case kVK_ANSI_V: keyName = "V"
            case kVK_ANSI_W: keyName = "W"
            case kVK_ANSI_X: keyName = "X"
            case kVK_ANSI_Y: keyName = "Y"
            case kVK_ANSI_Z: keyName = "Z"
            default: keyName = "Key(\(keyCode))"
            }
            parts.append(keyName)
            return parts.joined()
        }
    }

    // MARK: - Init

    init() {
        self.currentBinding = Self.loadBinding() ?? .defaultBinding
    }

    // MARK: - Registration

    func register() {
        unregister()

        // Install the Carbon event handler for hotkey events
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Store self pointer for the C callback
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyEventHandler,
            1,
            &eventType,
            refcon,
            &eventHandlerRef
        )

        guard status == noErr else {
            logger.error("InstallEventHandler failed: \(status)")
            return
        }

        // Register the actual hotkey
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = OSType(0x41456E76) // 'AEnv'
        hotKeyID.id = 1

        let regStatus = RegisterEventHotKey(
            currentBinding.keyCode,
            currentBinding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if regStatus != noErr {
            logger.error("RegisterEventHotKey failed: \(regStatus)")
        } else {
            logger.info("Global hotkey registered: \(self.currentBinding.displayString)")
        }
    }

    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    /// Re-register with a new binding
    func updateBinding(_ binding: HotkeyBinding) {
        currentBinding = binding
        register()
    }

    // MARK: - Persistence

    private static let defaultsKey = "com.audioenv.spotlightHotkey"

    private static func loadBinding() -> HotkeyBinding? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    private func saveBinding() {
        if let data = try? JSONEncoder().encode(currentBinding) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    deinit {
        // Note: deinit can't be @MainActor but these Carbon calls are safe from any thread
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
    }
}

// MARK: - Carbon Event Handler (C function pointer)

/// Global C callback for Carbon hotkey events. Dispatches to MainActor via notification.
private func hotkeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    NotificationCenter.default.post(name: .spotlightHotkeyPressed, object: nil)
    return noErr
}
