import SwiftUI
import os

@MainActor
class ColorTokens: ObservableObject {
    static let shared = ColorTokens()
    private let logger = Logger(subsystem: "com.audioenv.app", category: "ColorTokens")

    // Plugin format colors
    @Published var pluginAU = Color(red: 0.98, green: 0.85, blue: 0.93)
    @Published var pluginVST = Color(red: 0.60, green: 0.80, blue: 0.95)
    @Published var pluginVST3 = Color(red: 0.62, green: 0.86, blue: 0.74)
    @Published var pluginAAX = Color(red: 0.99, green: 0.95, blue: 0.85)

    // Bounce format colors
    @Published var bounceWAV = Color(red: 0.66, green: 0.85, blue: 0.92)
    @Published var bounceMP3 = Color(red: 0.94, green: 0.79, blue: 0.53)
    @Published var bounceAIFF = Color(red: 0.79, green: 0.70, blue: 0.90)
    @Published var bounceFLAC = Color(red: 0.66, green: 0.90, blue: 0.81)
    @Published var bounceM4A = Color(red: 0.91, green: 0.77, blue: 0.60)

    // Session format colors
    @Published var sessionAbleton = Color.gray
    @Published var sessionLogic = Color.blue
    @Published var sessionProTools = Color.purple

    // Bounce badge colors
    @Published var badgeBPM = Color(red: 0.94, green: 0.27, blue: 0.27)
    @Published var badgeKey = Color(red: 0.93, green: 0.29, blue: 0.60)
    @Published var badgeStage = Color(red: 0.06, green: 0.73, blue: 0.51)
    @Published var badgeVersion = Color(red: 0.96, green: 0.62, blue: 0.04)

    private init() {}

    func pluginFormatColor(_ format: PluginFormat) -> Color {
        switch format {
        case .audioUnit: return pluginAU
        case .vst: return pluginVST
        case .vst3: return pluginVST3
        case .aax: return pluginAAX
        }
    }

    func pluginFormatColorByName(_ format: String) -> Color {
        switch format.uppercased() {
        case "AU", "AUDIOUNIT": return pluginAU
        case "VST": return pluginVST
        case "VST3": return pluginVST3
        case "AAX": return pluginAAX
        default: return .gray
        }
    }

    func bounceFormatColor(_ format: String) -> Color {
        switch format.lowercased() {
        case "wav": return bounceWAV
        case "mp3": return bounceMP3
        case "aiff": return bounceAIFF
        case "flac": return bounceFLAC
        case "m4a": return bounceM4A
        default: return .secondary
        }
    }

    func sessionFormatColor(_ format: SessionFormat) -> Color {
        switch format {
        case .ableton: return sessionAbleton
        case .logic: return sessionLogic
        case .proTools: return sessionProTools
        }
    }

    func sessionFormatColorByName(_ format: String?) -> Color {
        switch format?.lowercased() {
        case "ableton live": return sessionAbleton
        case "logic pro": return sessionLogic
        case "pro tools": return sessionProTools
        default: return .secondary
        }
    }

    func bounceBadgeColor(_ badge: String) -> Color {
        switch badge.lowercased() {
        case "bpm": return badgeBPM
        case "key": return badgeKey
        case "stage": return badgeStage
        case "version": return badgeVersion
        default: return .secondary
        }
    }

    func fetch(baseURL: String) {
        guard let url = URL(string: "\(baseURL)/api/color-scheme") else { return }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                let response = try JSONDecoder().decode(ColorSchemeAPIResponse.self, from: data)
                let colors = response.colors

                await MainActor.run {
                    if let pf = colors.pluginFormats {
                        if let c = pf["AU"], let color = Color(hex: c) { self.pluginAU = color }
                        if let c = pf["VST"], let color = Color(hex: c) { self.pluginVST = color }
                        if let c = pf["VST3"], let color = Color(hex: c) { self.pluginVST3 = color }
                        if let c = pf["AAX"], let color = Color(hex: c) { self.pluginAAX = color }
                    }
                    if let bf = colors.bounceFormats {
                        if let c = bf["wav"], let color = Color(hex: c) { self.bounceWAV = color }
                        if let c = bf["mp3"], let color = Color(hex: c) { self.bounceMP3 = color }
                        if let c = bf["aiff"], let color = Color(hex: c) { self.bounceAIFF = color }
                        if let c = bf["flac"], let color = Color(hex: c) { self.bounceFLAC = color }
                        if let c = bf["m4a"], let color = Color(hex: c) { self.bounceM4A = color }
                    }
                    if let sf = colors.sessionFormats {
                        if let c = sf["Ableton Live"], let color = Color(hex: c) { self.sessionAbleton = color }
                        if let c = sf["Logic Pro"], let color = Color(hex: c) { self.sessionLogic = color }
                        if let c = sf["Pro Tools"], let color = Color(hex: c) { self.sessionProTools = color }
                    }
                    if let bb = colors.bounceBadges {
                        if let c = bb["bpm"], let color = Color(hex: c) { self.badgeBPM = color }
                        if let c = bb["key"], let color = Color(hex: c) { self.badgeKey = color }
                        if let c = bb["stage"], let color = Color(hex: c) { self.badgeStage = color }
                        if let c = bb["version"], let color = Color(hex: c) { self.badgeVersion = color }
                    }
                    self.logger.info("Color scheme loaded from API")
                }
            } catch {
                self.logger.warning("Failed to fetch color scheme: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Response models

    struct ColorSchemeAPIResponse: Codable {
        let colors: ColorSchemeColors
    }

    struct ColorSchemeColors: Codable {
        let pluginFormats: [String: String]?
        let bounceFormats: [String: String]?
        let sessionFormats: [String: String]?
        let bounceBadges: [String: String]?
    }
}

// MARK: - Color hex extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6,
              let int = UInt64(hex, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
