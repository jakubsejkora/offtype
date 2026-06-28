import Foundation
import LearningEngine
import OfftypeCore

// AGENT(Eval): load the FROZEN held-out manifest (demo/manifest.json, entries of
// {id, groundTruth, rawASR}), apply the current rules via RuleApplier, and compute
// WER + proper-noun accuracy + Local-Only %, returning EvalResult. Numbers must be
// COMPUTED from the manifest, never hardcoded. Add `runAntiOverfit(...)` over the
// near-miss set (similar names that must stay correct). Deterministic + unit-tested.

public struct ManifestEntry: Sendable, Equatable, Codable {
    public var id: String
    public var groundTruth: String
    public var rawASR: String
    public var properNouns: [String]
    public init(id: String, groundTruth: String, rawASR: String, properNouns: [String]) {
        self.id = id
        self.groundTruth = groundTruth
        self.rawASR = rawASR
        self.properNouns = properNouns
    }
}

public struct Evaluator: Sendable {
    public init() {}

    /// AGENT: implement WER (token edit-distance / ref length) + proper-noun
    /// accuracy + Local-Only %, applying `rules` to each entry's rawASR.
    public func run(manifest: [ManifestEntry], rules: [Rule], dictionary: [DictionaryEntry] = []) -> EvalResult {
        EvalResult(wer: 0, properNounAccuracy: 0, localOnlyPercent: 0, perPhrase: [])
    }

    /// AGENT: load the committed manifest JSON from `url`.
    public func loadManifest(at url: URL) throws -> [ManifestEntry] {
        try JSONDecoder().decode([ManifestEntry].self, from: Data(contentsOf: url))
    }
}
