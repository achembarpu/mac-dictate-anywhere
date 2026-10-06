import SwiftUI

/// Atom: section overline ("STARTUP", "AUDIO", …).
struct DSOverline: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Fonts.ui(12, .semibold))
            .tracking(0.4)
            .foregroundStyle(DS.Colors.textSecondary)
    }
}

/// Atom: 1pt hairline divider used inside cards.
struct DSDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.Colors.borderSoft)
            .frame(height: 1)
    }
}

/// Atom: inline hint line with a lightbulb icon.
struct DSHint: View {
    let text: String
    var icon: String = "lightbulb"

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Colors.accent)
            Text(text)
                .font(DS.Fonts.ui(12.5))
                .foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
