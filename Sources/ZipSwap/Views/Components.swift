import AppKit
import SwiftUI

/// ZipSwap's two-arrow mark.
struct SwapGlyph: View {
    var size: CGFloat = 16
    var color: Color = .black

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 16
            var top = Path()
            top.move(to: CGPoint(x: 3 * s, y: 5.5 * s)); top.addLine(to: CGPoint(x: 12.5 * s, y: 5.5 * s))
            top.move(to: CGPoint(x: 10 * s, y: 3 * s)); top.addLine(to: CGPoint(x: 12.5 * s, y: 5.5 * s)); top.addLine(to: CGPoint(x: 10 * s, y: 8 * s))
            var bottom = Path()
            bottom.move(to: CGPoint(x: 13 * s, y: 10.5 * s)); bottom.addLine(to: CGPoint(x: 3.5 * s, y: 10.5 * s))
            bottom.move(to: CGPoint(x: 6 * s, y: 8 * s)); bottom.addLine(to: CGPoint(x: 3.5 * s, y: 10.5 * s)); bottom.addLine(to: CGPoint(x: 6 * s, y: 13 * s))
            let style = StrokeStyle(lineWidth: 1.8 * s, lineCap: .round, lineJoin: .round)
            ctx.stroke(top, with: .color(color), style: style)
            ctx.stroke(bottom, with: .color(color), style: style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The app icon's mint tile, kept as the brand mark.
struct AppMark: View {
    var size: CGFloat = 24
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(Color(hex: 0x7CE0B5))
            .frame(width: size, height: size)
            .overlay(SwapGlyph(size: size * 0.62, color: Color(hex: 0x131417)))
    }
}

/// A provider's logo, tinted like text.
struct ProviderMark: View {
    let provider: Provider
    var size: CGFloat = 16
    var style: AnyShapeStyle = AnyShapeStyle(.secondary)

    var body: some View {
        Image(provider == .claude ? "ClaudeMark" : "CodexMark")
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            // The marks fill 80% of their artwork; scale so the drawn shape is `size`.
            .frame(width: size * 1.25, height: size * 1.25)
            .frame(width: size, height: size)
            .foregroundStyle(style)
            .accessibilityHidden(true)
    }
}

struct Avatar: View {
    let account: Account
    var size: CGFloat = 32

    var body: some View {
        let hue = Theme.hue(for: account.id)
        Circle()
            .fill(hue.opacity(0.16))
            .frame(width: size, height: size)
            .overlay(Text(account.initial).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(hue))
            .overlay(alignment: .bottomTrailing) {
                if account.isActive {
                    Circle().fill(account.activeIdentityVerified ? Theme.positive : Theme.amber).frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                }
            }
    }
}

/// A limit as a ring around its provider's mark, as on OpenUsage's Priority tab.
struct PriorityGauge: View {
    let fraction: Double
    let severity: Theme.Severity
    let provider: Provider

    private static let lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle().inset(by: Self.lineWidth / 2).stroke(Theme.track, lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Theme.severityColor(severity), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            ProviderMark(provider: provider, size: 15)
        }
        .frame(width: PanelMetrics.gaugeSide, height: PanelMetrics.gaugeSide)
        .accessibilityHidden(true)
    }
}

/// A limit's level as a rounded bar. Drawn as shapes so a copied picture matches the panel.
struct LevelBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fill: Double
    let severity: Theme.Severity
    var height: CGFloat = 6
    /// Where usage would be at an even pace, as a fraction of the bar.
    var pace: Double? = nil

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: height / 2, style: .continuous) }

    var body: some View {
        GeometryReader { proxy in
            shape.fill(Theme.track)
                .overlay(alignment: .leading) {
                    if fill > 0 {
                        shape.fill(Theme.severityColor(severity))
                            .frame(width: max(height, (proxy.size.width * min(fill, 1)).rounded()))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fill)
                    }
                }
                .overlay(alignment: .leading) {
                    if let pace, pace.isFinite {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Theme.text.opacity(0.55))
                            .frame(width: 2, height: height + 4)
                            .offset(x: min(max(0, proxy.size.width - 2), max(0, proxy.size.width * min(max(pace, 0), 1) - 1)))
                    }
                }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// The dashboard's usage bar, coloured by how much is used.
struct UsageBar: View {
    let pct: Double
    var height: CGFloat = 4
    var pace: Double? = nil

    var body: some View {
        // Follows the panel's left/used switch so every bar fills the same way.
        let left = AppModel.shared.showsUsageLeft
        let shown = { (value: Double) in UsageGeometry.fraction(left ? 100 - value : value) }
        LevelBar(fill: shown(pct), severity: Theme.severity(pct), height: height, pace: pace.map(shown))
            .help(pace.map { "Even pace would be \(Format.pct($0)) used by now" } ?? "")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Usage")
            .accessibilityValue(UsageText.percent(used: pct) + (left ? " left" : " used"))
    }
}

/// Choices on a capsule track, with a thumb that slides to the chosen one.
struct CapsuleSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { segment($0.value, label: $0.label) }
        }
        .padding(2)
        .frame(height: height)
        .background(Theme.controlFill, in: Capsule())
    }

    private func segment(_ value: Value, label: String) -> some View {
        let isSelected = selection == value
        return Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.15)) { selection = value }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(Theme.segmentThumb)
                            .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                            .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
                            .matchedGeometryEffect(id: "thumb", in: thumb)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A small grey badge, like a plan name.
struct PlanBadge: View {
    let text: String
    var color: Color? = nil

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background((color ?? .primary).opacity(color == nil ? 0.08 : 0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A short confirmation that floats over the footer.
struct TransientPill: View {
    let systemImage: String
    let text: String
    var tint: Color = Theme.positive

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(tint)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

extension View {
    /// A static grey placeholder in finished geometry, for content that has not arrived yet.
    func skeleton() -> some View {
        foregroundStyle(Theme.skeleton).accessibilityHidden(true)
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.positive

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// An account name you click to rename in place.
struct NameField: View {
    let account: Account
    var font: Font = .system(size: 15, weight: .semibold)
    var color: Color = Theme.text
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        Group {
            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(font)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.controlFill))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1))
                    .frame(maxWidth: 160)
                    .focused($focused)
                    .onSubmit(commit)
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
            } else {
                Button {
                    draft = account.name
                    editing = true
                    DispatchQueue.main.async { focused = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(account.title).font(font).foregroundStyle(color).lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Rename")
            }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        AppModel.shared.rename(account, to: draft)
    }
}

/// A round icon button, as in OpenUsage's footer.
struct RoundIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Makes an account the default for its CLI.
struct SwitchButton: View {
    let account: Account
    var prominent = false
    var size: ControlSize = .small

    var body: some View {
        let model = AppModel.shared
        let busy = model.busy.contains(account.id) || model.coordinator.busy(account.provider)
        Group {
            if prominent {
                Button { model.activate(account) } label: { label(busy) }.buttonStyle(.borderedProminent)
            } else {
                Button { model.activate(account) } label: { label(busy) }.buttonStyle(.bordered)
            }
        }
        .controlSize(size)
        .disabled(busy || account.manualSwitchReason() != nil)
        .help(account.manualSwitchReason() ?? "Use \(account.title) for the default \(account.provider.title) CLI")
    }

    private func label(_ busy: Bool) -> some View {
        ZStack {
            Text("Switch").opacity(busy ? 0 : 1)
            if busy { ProgressView().controlSize(.mini) }
        }
    }
}

struct ToggleSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Toggle(label, isOn: $isOn)
        .toggleStyle(.switch)
        .controlSize(.small)
        .labelsHidden()
        .accessibilityLabel(label)
    }
}

struct Lever: View {
    let title: String
    @Binding var isOn: Bool
    @Binding var value: Double
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ToggleSwitch(isOn: $isOn, label: title)
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                Spacer()
                Text(isOn ? Format.pct(value) : "Off")
                    .font(Theme.mono(14, .semibold))
                    .foregroundStyle(isOn ? Theme.text : Theme.faint)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: 50...99, step: 1)
                .controlSize(.small)
                .disabled(!isOn)
                .accessibilityLabel("\(title) threshold")
            HStack {
                Text("50%").font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
                Spacer()
                if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(Theme.amber) }
                Spacer()
                Text("99%").font(Theme.mono(9.5)).foregroundStyle(Theme.faint)
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Copies a view to the clipboard as a PNG.
@MainActor
enum ShareImage {
    static let scale: CGFloat = 3

    static func png<Content: View>(_ view: Content) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        return rep.representation(using: .png, properties: [:])
    }

    @discardableResult
    static func copy<Content: View>(_ view: Content) -> Bool {
        guard let png = png(view) else { NSSound.beep(); return false }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(png, forType: .png) else { NSSound.beep(); return false }
        return true
    }
}
