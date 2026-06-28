import SwiftUI
import OfftypeCore

// The un-fakeable proof: RAW recognizer output beside FINAL learned output.
// The RAW spans the model mis-heard stay visibly wrong; the FINAL spans are
// colored by who fixed them and carry their real accounting — green "rule ·
// 0 tokens · 0 ms" vs amber "cloud · N tokens · X ms". The arrow between them
// is the transformation. Built to read from across the room.
public struct DebugStripView: View {
    public var rawText: String
    public var finalText: String
    public var rewrite: RewriteResult?

    public init(rawText: String, finalText: String, rewrite: RewriteResult?) {
        self.rawText = rawText
        self.finalText = finalText
        self.rewrite = rewrite
    }

    private struct Span: Identifiable {
        let id: Int
        let raw: String
        let out: String
        let route: HUDRoute
        let changed: Bool
        let highlight: Bool   // worth calling out: a real correction, or a paid cloud span
        let badge: String
    }

    private var spans: [Span] {
        guard let rewrite, !rewrite.decisions.isEmpty else { return [] }
        return rewrite.decisions.enumerated().map { idx, d in
            let route: HUDRoute = d.source == .cloudLLM ? .cloud : .local
            let label = d.source == .dictionary ? "dict" : "rule"
            let changed = d.output != d.original
            let badge = route == .cloud
                ? "cloud · \(d.tokensUsed.formatted()) tokens · \(Int(d.latencyMS.rounded())) ms"
                : "\(label) · 0 tokens · 0 ms"
            // Cloud spans are always called out — paying tokens is the point, even
            // when the cloud failed to fix the word.
            return Span(id: idx, raw: d.original, out: d.output, route: route,
                        changed: changed, highlight: route == .cloud || changed, badge: badge)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Eyebrow("Proof · recognizer vs learned")

            if spans.isEmpty {
                emptyOrPlain
            } else {
                HStack(alignment: .top, spacing: 14) {
                    column(title: "Raw · on-device recognizer", tint: HUDPalette.idle) { rawFlow }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(HUDPalette.inkDim)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .padding(.top, 26)
                    column(title: "Final · after learned layer", tint: HUDPalette.local) { finalFlow }
                }
                aggregate
            }
        }
        .padding(18)
        .glassCard()
    }

    // MARK: Columns

    @ViewBuilder
    private func column<Content: View>(title: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title, tint: tint)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(HUDPalette.well)
                }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rawFlow: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(spans) { span in
                Text(span.raw)
                    .font(.hudMono(15, span.highlight ? .bold : .regular))
                    .foregroundStyle(span.highlight ? HUDPalette.cloud : HUDPalette.inkDim)
                    .padding(.horizontal, span.highlight ? 6 : 2)
                    .padding(.vertical, 2)
                    .background {
                        if span.highlight {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(HUDPalette.cloud.opacity(0.5), lineWidth: 1)
                        }
                    }
            }
        }
    }

    private var finalFlow: some View {
        FlowLayout(spacing: 6, lineSpacing: 8) {
            ForEach(spans) { span in
                if span.highlight {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(span.out)
                            .font(.hudMono(15, .bold))
                            .foregroundStyle(span.route.tint)
                        Text(span.badge)
                            .font(.hudLabel(8.5, .semibold))
                            .foregroundStyle(span.route.tint.opacity(0.95))
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(span.route.tint.opacity(0.14))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .strokeBorder(span.route.tint.opacity(0.45), lineWidth: 1)
                            }
                    }
                } else {
                    Text(span.out)
                        .font(.hudMono(15, .regular))
                        .foregroundStyle(HUDPalette.ink.opacity(0.85))
                        .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Aggregate

    private var aggregate: some View {
        let decisions = rewrite?.decisions ?? []
        let localCount = decisions.filter { $0.source != .cloudLLM }.count
        let cloudCount = decisions.count - localCount
        let tokens = decisions.reduce(0) { $0 + $1.tokensUsed }
        let ms = decisions.reduce(0) { $0 + $1.latencyMS }
        let localOnly = rewrite?.localOnlyFraction ?? 1
        return HStack(spacing: 8) {
            Pill("\(localCount) local · 0 tokens · 0 ms", systemImage: "bolt.fill",
                 tint: HUDPalette.local, filled: cloudCount == 0)
            if cloudCount > 0 {
                Pill("\(cloudCount) cloud · \(tokens.formatted()) tokens · \(Int(ms.rounded())) ms",
                     systemImage: "cloud.fill", tint: HUDPalette.cloud, filled: true)
            }
            Spacer(minLength: 0)
            Pill("Local-Only \(localOnly.asPercent())",
                 tint: cloudCount == 0 ? HUDPalette.local : HUDPalette.cloud)
        }
    }

    // MARK: Fallback

    @ViewBuilder
    private var emptyOrPlain: some View {
        if rawText.isEmpty && finalText.isEmpty {
            Text("Awaiting dictation…")
                .font(.hudMono(14))
                .foregroundStyle(HUDPalette.inkDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        } else {
            HStack(alignment: .top, spacing: 14) {
                column(title: "Raw", tint: HUDPalette.idle) {
                    Text(rawText).font(.hudMono(15)).foregroundStyle(HUDPalette.inkDim)
                }
                column(title: "Final", tint: HUDPalette.local) {
                    Text(finalText).font(.hudMono(15)).foregroundStyle(HUDPalette.ink)
                }
            }
        }
    }
}
