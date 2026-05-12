import SwiftUI

#if canImport(UIKit)
extension Color {
    /// Hex initializer matching the macOS view's `Color(hex:)` extension.
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex & 0xFF0000) >> 16) / 255.0
        let g = Double((hex & 0x00FF00) >> 8) / 255.0
        let b = Double(hex & 0x0000FF) / 255.0
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Provider-tinted accent colors for the iOS UI.
enum ProviderTint {
    static func color(for provider: QuotaProvider, colorScheme: ColorScheme) -> Color {
        switch provider {
        case .copilot:
            return colorScheme == .dark ? Color.white : Color.black
        case .codex:
            return Color.blue
        case .claude:
            return colorScheme == .dark ? Color(hex: 0xD4A0FF) : Color.purple
        case .gemini:
            return colorScheme == .dark ? Color(hex: 0xA5B4FC) : Color.indigo
        }
    }

    /// Health-coded accent based on remaining percent (0..100).
    static func healthAccent(remainingPercent: Int?, colorScheme: ColorScheme) -> Color {
        guard let pct = remainingPercent else { return .secondary }
        if pct <= 10 {
            return colorScheme == .dark ? Color(hex: 0xFF6961) : Color.red
        } else if pct <= 30 {
            return colorScheme == .dark ? Color(hex: 0xFFD60A) : Color.orange
        } else {
            return colorScheme == .dark ? Color(hex: 0x64D2FF) : Color.blue
        }
    }
}
#endif
