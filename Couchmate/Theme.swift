import SwiftUI

/// The Android TV app is the model: its sizes (dp/sp) are used here as they are, times this factor – an Apple TV
/// screen is 1920 points wide, the Android app's is about 1200 dp.
let uiScale: CGFloat = 1.6

extension Int {
    var dp: CGFloat { CGFloat(self) * uiScale }
}
extension Double {
    var dp: CGFloat { CGFloat(self) * uiScale }
}
extension CGFloat {
    var dp: CGFloat { self * uiScale }
}

/// A font size in the Android app's units.
func font(_ size: Double, _ weight: Font.Weight = .regular) -> Font { .system(size: CGFloat(size) * uiScale, weight: weight) }

/// Colours – dark and compact.
enum Palette {
    static let bg = Color(hex: 0xFF0A0C10)
    static let panel = Color(hex: 0xFF11141B)
    static let panelHi = Color(hex: 0xFF1A1F29)
    static let line = Color(hex: 0x14FFFFFF)
    static let accent = Color(hex: 0xFF3D7BFF)
    static let accentSoft = Color(hex: 0x403D7BFF)
    static let text = Color(hex: 0xFFF2F4F8)
    static let dim = Color(hex: 0xFFA3ABB9)
    static let faint = Color(hex: 0xFF616A7A)
    static let live = Color(hex: 0xFFE5484D)
    static let gold = Color(hex: 0xFFF5C451)
    static let green = Color(hex: 0xFF3DD68C)
    static let status = Color(hex: 0xFF9FB4FF)
    static let error = Color(hex: 0xFFFF8A80)
}

extension Color {
    /// 0xAARRGGBB, like the Android app.
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: Double((hex >> 24) & 0xFF) / 255)
    }

    /// "#RRGGBB", "#AARRGGBB" or "#RGB" from a plugin.
    init?(css: String) {
        var s = css.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard let v = UInt32(s, radix: 16) else { return nil }
        switch s.count {
        case 6: self.init(hex: 0xFF00_0000 | v)
        case 8: self.init(hex: v)
        default: return nil
        }
    }
}
