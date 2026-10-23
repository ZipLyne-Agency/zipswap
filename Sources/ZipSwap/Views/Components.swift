import SwiftUI

struct SwapGlyph: View {
    var size: CGFloat = 16
    var color: Color = Theme.bg

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

struct AppMark: View {
    var size: CGFloat = 24
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            .fill(Theme.mint)
            .frame(width: size, height: size)
            .overlay(SwapGlyph(size: size * 0.62, color: Theme.bg))
    }
}

struct Avatar: View {
    let account: Account
    var size: CGFloat = 32

    var body: some View {
        let hue = Theme.hue(for: account.id)
        Circle()
            .fill(hue.opacity(0.15))
            .frame(width: size, height: size)
            .overlay(Text(account.initial).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(hue))
            .overlay(alignment: .bottomTrailing) {
                if account.isActive {
                    Circle().fill(account.activeIdentityVerified ? Theme.mint : Theme.amber).frame(width: size * 0.28, height: size * 0.28)
                        .overlay(Circle().stroke(Theme.card, lineWidth: 2))
                }
            }
    }
}

struct Ring: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pct: Double
    var size: CGFloat = 44
    var line: CGFloat = 4.5
    var color: Color? = nil
    var label: String? = nil

    var body: some View {
        let tone = color ?? Theme.tone(pct)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: line)
            Circle()
                .trim(from: 0, to: UsageGeometry.fraction(pct))
                .stroke(tone, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .spring(duration: 0.6), value: pct)
            Text(label ?? Format.pct(pct))
                .font(.system(size: size * 0.27, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage")
        .accessibilityValue(label ?? Format.pct(pct))
    }
}

struct UsageBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pct: Double
    var height: CGFloat = 4
    var pace: Double? = nil

    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Theme.track)
                .overlay(alignment: .leading) {
                    Capsule().fill(Theme.tone(pct))
                        .frame(width: max(0, geo.size.width) * UsageGeometry.fraction(pct), height: height)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: pct)
                }
                .clipShape(Capsule())
                .overlay(alignment: .leading) {
                if let pace, pace.isFinite {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.text)
                        .frame(width: 2, height: height * 2)
                        .offset(x: min(max(0, geo.size.width - 2), max(0, geo.size.width * UsageGeometry.fraction(pace) - 1)))
                        .help("Even pace would be \(Format.pct(pace)) by now")
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage")
        .accessibilityValue(Format.pct(pct))
    }
}

struct Chip: View {
    let text: String
    var color: Color = Theme.mint

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// An account name you click to rename in place.
struct NameField: View {
    let account: Account
    var font: Font = .system(size: 15, weight: .semibold)
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
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.sunken))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.mint, lineWidth: 1))
                    .frame(maxWidth: 200)
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
                    HStack(spacing: 5) {
                        Text(account.title).font(font).foregroundStyle(Theme.text).lineLimit(1)
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.faint)
                            .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .help("Click to Rename")
            }
        }
    }

    private func commit() {
        guard editing else { return }
        editing = false
        AppModel.shared.rename(account, to: draft)
    }
}

struct IconButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let systemName: String
    let help: String
    var spinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hovering ? Theme.text : Theme.muted)
                .rotationEffect(.degrees(spinning && !reduceMotion ? 360 : 0))
                .animation(reduceMotion ? nil : spinning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SwitchButton: View {
    let account: Account
    @State private var hovering = false

    var body: some View {
        let model = AppModel.shared
        let busy = model.busy.contains(account.id) || model.coordinator.busy(account.provider)
        Button {
            model.activate(account)
        } label: {
            Group {
                if busy { ProgressView().controlSize(.mini) } else { Text("Switch") }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering && !account.isBlocked ? Theme.bg : Theme.text)
            .frame(width: 64, height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering && !account.isBlocked ? Theme.mint : Color(hex: 0x1F2126)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(hovering && !account.isBlocked ? Theme.mint : Color(hex: 0x2E3138)))
        }
        .buttonStyle(.plain)
        .disabled(busy || account.manualSwitchReason() != nil)
        .opacity(account.isBlocked ? 0.4 : 1)
        .onHover { hovering = $0 }
        .help(account.manualSwitchReason() ?? "Use \(account.title) for the default \(account.provider.title) CLI")
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
                Text(isOn ? Format.pct(value) : "off")
                    .font(Theme.mono(14, .semibold))
                    .foregroundStyle(isOn ? Theme.text : Theme.faint)
                    .contentTransition(.numericText())
            }
            Slider(value: $value, in: 50...99, step: 1)
                .tint(Theme.mint)
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
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.faint)
    }
}
