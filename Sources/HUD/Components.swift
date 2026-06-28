import SwiftUI

// MARK: - Flow layout
//
// Wraps chips onto as many rows as needed. Used by the proof strip so RAW and
// FINAL spans read as parallel, comparable rows.
public struct FlowLayout: Layout {
    public var spacing: CGFloat
    public var lineSpacing: CGFloat
    public init(spacing: CGFloat = 6, lineSpacing: CGFloat = 8) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widestLine: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                widestLine = max(widestLine, x - spacing)
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        widestLine = max(widestLine, x - spacing)
        let resolvedWidth = proposal.width ?? max(widestLine, 0)
        return CGSize(width: resolvedWidth, height: y + lineHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Pill

/// A compact capsule label. `filled` reads as the active/strong variant; the
/// outline variant is for quieter, secondary states.
public struct Pill: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color
    private let filled: Bool

    public init(_ text: String, systemImage: String? = nil, tint: Color = HUDPalette.inkDim, filled: Bool = false) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.filled = filled
    }

    public var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .bold))
            }
            Text(text).font(.hudMono(11, .semibold))
        }
        .foregroundStyle(filled ? Color.black.opacity(0.85) : tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background {
            Capsule(style: .continuous)
                .fill(filled ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)))
        }
        .overlay {
            Capsule(style: .continuous).strokeBorder(tint.opacity(filled ? 0 : 0.45), lineWidth: 1)
        }
        .fixedSize()
    }
}

// MARK: - Metric tile

/// One counter in the Learned panel. The number animates with a numeric-text
/// roll, and the whole tile flashes its tint when the value changes — so a climb
/// is impossible to miss from across the room.
public struct MetricTile: View {
    private let icon: String
    private let value: Double
    private let display: String
    private let label: String
    private let tint: Color

    @State private var flash = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(icon: String, value: Double, display: String, label: String, tint: Color = HUDPalette.local) {
        self.icon = icon
        self.value = value
        self.display = display
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tint)
                Eyebrow(label)
                Spacer(minLength: 0)
            }
            Text(display)
                .font(.hudNumber(26, .bold))
                .monospacedDigit()
                .foregroundStyle(HUDPalette.ink)
                .contentTransition(.numericText(value: value))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(HUDPalette.well)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(tint.opacity(flash ? 0.18 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(tint.opacity(flash ? 0.55 : 0.0), lineWidth: 1)
                }
        }
        .onChange(of: value) { _, _ in
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.18)) { flash = true }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                withAnimation(.easeIn(duration: 0.5)) { flash = false }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display)
    }
}

// MARK: - Ring gauge

/// The big "Local-Only %" dial. A track + a tinted progress arc + a centered
/// numeral; the arc length is the hero number, so the proof is the shape itself.
public struct RingGauge: View {
    private let value: Double          // 0...1
    private let tint: Color
    private let lineWidth: CGFloat
    private let caption: String

    public init(value: Double, tint: Color = HUDPalette.local, lineWidth: CGFloat = 12, caption: String = "") {
        self.value = max(0, min(1, value))
        self.tint = tint
        self.lineWidth = lineWidth
        self.caption = caption
    }

    public var body: some View {
        ZStack {
            Circle()
                .stroke(HUDPalette.well, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: value)
                .stroke(
                    AngularGradient(
                        colors: [tint.opacity(0.65), tint],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.5), radius: 6)
            VStack(spacing: 0) {
                Text(value.formatted(.percent.precision(.fractionLength(0))))
                    .font(.hudNumber(34, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(HUDPalette.ink)
                    .contentTransition(.numericText(value: value))
                if !caption.isEmpty {
                    Text(caption.uppercased())
                        .font(.hudLabel(9, .semibold))
                        .tracking(1.4)
                        .foregroundStyle(HUDPalette.inkDim)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption.isEmpty ? "Local only" : caption)
        .accessibilityValue(value.formatted(.percent.precision(.fractionLength(0))))
    }
}

// MARK: - Formatting helpers

public extension Double {
    /// Percent string at a fixed fraction length (e.g. 0.186 → "18.6%").
    func asPercent(_ fraction: Int = 0) -> String {
        formatted(.percent.precision(.fractionLength(fraction)))
    }
}
