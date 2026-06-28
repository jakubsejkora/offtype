import SwiftUI

// MARK: - Offtype HUD design system
//
// One semantic palette carries the entire thesis: the color of the UI *is* the
// proof. Cyan = listening, emerald = local/free/instant (the win), amber =
// cloud/costs-tokens (the thing we wean off), coral = error, slate = idle.
// Type roles are content-justified: SF Rounded for identity + hero numbers,
// SF Mono for the RAW→FINAL diff (machine output), SF for utility eyebrows.

public enum HUDPalette {
    @inline(__always)
    static func rgb(_ r: Double, _ g: Double, _ b: Double, _ o: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: o)
    }

    public static let signal = rgb(40, 215, 229)   // cyan — listening
    public static let local  = rgb(43, 224, 139)   // emerald — local, free, instant
    public static let cloud  = rgb(255, 176, 32)   // amber — cloud, costs tokens
    public static let alert  = rgb(255, 92, 92)    // coral — error
    public static let idle   = rgb(126, 135, 148)  // slate — idle / dormant

    public static let ink    = rgb(233, 239, 246)  // near-white, primary text on glass
    public static let inkDim = rgb(150, 161, 176)  // secondary text
    public static let hairline = Color.white.opacity(0.10)
    public static let well   = Color.black.opacity(0.22) // recessed wells inside glass
}

// MARK: - Routing color

/// Which engine handled (or is handling) the work — drives the local-vs-cloud
/// color story everywhere in the HUD.
public enum HUDRoute: String, Sendable, Equatable, Codable {
    case local
    case cloud

    public var tint: Color { self == .local ? HUDPalette.local : HUDPalette.cloud }
    /// SF Symbol shown inside the orb during processing/result.
    public var glyph: String { self == .local ? "cpu" : "cloud.fill" }
    public var label: String { self == .local ? "On-device" : "Cloud" }
}

// MARK: - Typography

public extension Font {
    /// Hero + counter numerals: SF Rounded, the warm, legible-at-distance identity face.
    static func hudNumber(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// Eyebrows / labels: small, semibold rounded; usually tracked + uppercased.
    static func hudLabel(_ size: CGFloat = 10, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// The proof diff: monospaced, because it is literal recognizer output.
    static func hudMono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Shared building blocks

/// A small uppercase, tracked-out section label. Encodes structure without decoration.
public struct Eyebrow: View {
    private let text: String
    private let tint: Color
    public init(_ text: String, tint: Color = HUDPalette.inkDim) {
        self.text = text
        self.tint = tint
    }
    public var body: some View {
        Text(text.uppercased())
            .font(.hudLabel(10, .semibold))
            .tracking(1.6)
            .foregroundStyle(tint)
    }
}

/// The glass card used by every panel: vibrancy material, a faint inner top
/// highlight, and a hairline stroke so it reads on any desktop background.
public struct GlassCard<Content: View>: View {
    private let radius: CGFloat
    private let content: Content
    public init(radius: CGFloat = 20, @ViewBuilder content: () -> Content) {
        self.radius = radius
        self.content = content()
    }
    public var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.06), Color.clear],
                                    startPoint: .top, endPoint: .center
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(HUDPalette.hairline, lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
            }
    }
}

public extension View {
    /// Convenience: wrap any content in the standard Offtype glass card.
    func glassCard(radius: CGFloat = 20) -> some View {
        GlassCard(radius: radius) { self }
    }
}
