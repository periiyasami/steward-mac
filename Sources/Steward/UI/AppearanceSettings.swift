import SwiftUI

/// Settings > Appearance: the accent color. Light and dark mode follow the Mac.
struct AppearanceSettings: View {
    @Bindable private var store = ThemeStore.shared

    var body: some View {
        Section {
            AccentPreview()
                .padding(.vertical, Space.xs)
            LabeledContent("Accent color") {
                VStack(alignment: .trailing, spacing: Space.xs) {
                    HStack(spacing: Space.sm) {
                        ForEach(Theme.all) { theme in
                            AccentSwatch(theme: theme, selected: store.themeID == theme.id) {
                                store.themeID = theme.id
                            }
                        }
                    }
                    Text(store.theme.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// A small picture of Steward in the chosen accent: the module bar, a stat
/// card, a Recommended badge, and the Review button. It redraws as people pick a color.
private struct AccentPreview: View {
    private let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.xs) {
                pill("Status", symbol: "gauge.with.dots.needle.67percent", selected: true)
                pill("Storage", symbol: "internaldrive", selected: false)
                pill("Apps", symbol: "square.grid.2x2", selected: false)
            }
            .padding(Space.xs)
            .background(.background.secondary, in: Capsule())
            HStack(alignment: .top, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Text("23%").font(.title3.weight(.semibold))
                    Capsule().fill(.quaternary).frame(height: 4)
                        .overlay(alignment: .leading) { Capsule().fill(Palette.accent).frame(width: 40, height: 4) }
                }
                .padding(Space.sm)
                .frame(width: 140, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("Recommended")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 2)
                        .background(Palette.accent.opacity(0.15), in: Capsule())
                    // Drawn, not real controls: the preview is a picture, and real
                    // controls turn gray when the window is not in front.
                    Text("Review…")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Palette.onAccent)
                        .padding(.horizontal, Space.md)
                        .frame(height: 24)
                        .background(Palette.accent, in: Capsule())
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.separator, lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the accent color")
    }

    private func pill(_ title: String, symbol: String, selected: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.callout.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? Palette.onAccent : .secondary)
            .padding(.horizontal, Space.md)
            .frame(height: 24)
            .background(selected ? Palette.accent : .clear, in: Capsule())
    }
}

/// One color dot, like the accent row in System Settings.
private struct AccentSwatch: View {
    let theme: Theme
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay {
                    if selected {
                        Circle().fill(theme.onAccent).frame(width: 6, height: 6) // grid: ok
                    }
                }
                .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(theme.name)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fill: AnyShapeStyle {
        if let tint = theme.tint {
            AnyShapeStyle(tint)
        } else {
            AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red],
                                          center: .center))
        }
    }
}
