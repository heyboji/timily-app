import SwiftUI

extension Color {
    init(projectHex: String) {
        let hex = projectHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let value = UInt64(hex, radix: 16) ?? 0

        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
