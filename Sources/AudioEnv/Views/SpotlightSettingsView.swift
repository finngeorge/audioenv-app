import SwiftUI
import Carbon.HIToolbox

/// Settings view for configuring the global Spotlight search panel.
struct SpotlightSettingsView: View {
    @EnvironmentObject var hotkeyManager: HotkeyManager

    @State private var isRecordingHotkey = false
    @State private var showOnLogin = UserDefaults.standard.bool(forKey: "spotlightShowOnLogin")
    @State private var dismissOnFocusLoss = UserDefaults.standard.object(forKey: "spotlightDismissOnFocusLoss") as? Bool ?? true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Spotlight Settings")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure the global search panel")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Hotkey
                VStack(alignment: .leading, spacing: 12) {
                    Text("Global Shortcut")
                        .font(.headline)

                    HStack {
                        Text("Trigger Shortcut")
                            .foregroundColor(.secondary)

                        Spacer()

                        Button {
                            isRecordingHotkey.toggle()
                            if isRecordingHotkey {
                                hotkeyManager.unregister()
                            }
                        } label: {
                            if isRecordingHotkey {
                                Text("Press a key combo...")
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(.orange)
                                    .frame(minWidth: 160)
                            } else {
                                Text(hotkeyManager.currentBinding.displayString)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    .frame(minWidth: 160)
                            }
                        }
                        .buttonStyle(.bordered)
                        .onKeyPress(phases: .down) { press in
                            guard isRecordingHotkey else { return .ignored }

                            let carbonMods = carbonModifiers(from: press.modifiers)
                            // Require at least one modifier
                            guard carbonMods != 0 else { return .ignored }

                            let keyCode = keyCodeFromKeyEquivalent(press.key)
                            guard keyCode != UInt32.max else { return .ignored }

                            let binding = HotkeyManager.HotkeyBinding(
                                keyCode: keyCode,
                                modifiers: carbonMods
                            )
                            hotkeyManager.updateBinding(binding)
                            isRecordingHotkey = false
                            return .handled
                        }

                        Button("Reset") {
                            hotkeyManager.updateBinding(.defaultBinding)
                            isRecordingHotkey = false
                        }
                        .buttonStyle(.borderless)
                        .foregroundColor(.secondary)
                    }

                    Text("The shortcut works globally, even when another app has focus.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Behavior
                VStack(alignment: .leading, spacing: 12) {
                    Text("Behavior")
                        .font(.headline)

                    Toggle("Dismiss when clicking outside", isOn: $dismissOnFocusLoss)
                        .onChange(of: dismissOnFocusLoss) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "spotlightDismissOnFocusLoss")
                        }

                    Text("When enabled, the spotlight panel closes if you click on another window or switch apps.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Commands reference
                VStack(alignment: .leading, spacing: 12) {
                    Text("Commands")
                        .font(.headline)

                    ForEach(SpotlightVerb.allCases, id: \.rawValue) { verb in
                        HStack(spacing: 10) {
                            Image(systemName: verb.icon)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(width: 20)

                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(verb.rawValue)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    ForEach(verb.aliases, id: \.self) { alias in
                                        Text(alias)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                Text(verb.hint)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Keyboard shortcuts reference
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keyboard Shortcuts")
                        .font(.headline)

                    shortcutRow(key: "Enter", description: "Execute default action")
                    shortcutRow(key: "Cmd + Enter", description: "Show in Finder")
                    shortcutRow(key: "Opt + Enter", description: "Open in DAW")
                    shortcutRow(key: "Shift + Enter", description: "Quick Look")
                    shortcutRow(key: "Arrow Keys", description: "Navigate results")
                    shortcutRow(key: "Backspace", description: "Clear command badge (when empty)")
                    shortcutRow(key: "Escape", description: "Close panel")
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Spotlight")
    }

    private func shortcutRow(key: String, description: String) -> some View {
        HStack {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    // MARK: - Key Code Mapping

    private func carbonModifiers(from swiftUI: SwiftUI.EventModifiers) -> UInt32 {
        var mods: UInt32 = 0
        if swiftUI.contains(.command) { mods |= UInt32(cmdKey) }
        if swiftUI.contains(.shift) { mods |= UInt32(shiftKey) }
        if swiftUI.contains(.option) { mods |= UInt32(optionKey) }
        if swiftUI.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    private func keyCodeFromKeyEquivalent(_ key: KeyEquivalent) -> UInt32 {
        switch key {
        case .space: return UInt32(kVK_Space)
        case .return: return UInt32(kVK_Return)
        case .tab: return UInt32(kVK_Tab)
        case .escape: return UInt32(kVK_Escape)
        default:
            // Map common letter keys
            let char = String(key.character).lowercased()
            let map: [String: Int] = [
                "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
                "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
                "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
                "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
                "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
                "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
                "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            ]
            if let code = map[char] { return UInt32(code) }
            return UInt32.max
        }
    }
}
