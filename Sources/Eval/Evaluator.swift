import Foundation
import LearningEngine
import OfftypeCore

// Scores the FROZEN held-out manifest through the *real* rule pipeline. Every
// number here is COMPUTED from the manifest — never hardcoded — so the before/after
// climb is un-fakeable. Deterministic and unit-tested.

/// One held-out item: the truth, the raw recognizer output that mis-hears the
/// jargon, and the proper nouns we score precisely.
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

/// Result of the anti-overfit challenge: did a learned rule fix its targets *without*
/// corrupting look-alike neighbors (e.g. the country "Cuba" must stay "Cuba")?
public struct AntiOverfitResult: Sendable, Equatable, Codable {
    /// Near-miss phrases left correct (not regressed) by the current rules.
    public var preserved: Int
    public var total: Int
    /// IDs of phrases a rule wrongly altered.
    public var regressions: [String]
    public var perPhrase: [EvalPhraseResult]

    public init(preserved: Int, total: Int, regressions: [String], perPhrase: [EvalPhraseResult]) {
        self.preserved = preserved
        self.total = total
        self.regressions = regressions
        self.perPhrase = perPhrase
    }

    /// True when no near-miss neighbor was corrupted.
    public var passed: Bool { regressions.isEmpty }
    public var preservationRate: Double { total == 0 ? 1 : Double(preserved) / Double(total) }
}

public enum EvalError: Error, Sendable, Equatable {
    case manifestUnreadable(String)
}

public struct Evaluator: Sendable {
    private let applier = RuleApplier()
    public init() {}

    /// Runs the manifest through `rules` (+ optional dictionary recasing) and reports
    /// corpus WER, proper-noun accuracy, and Local-Only %.
    ///
    /// - WER = total token edit-distance / total reference tokens (case-insensitive).
    /// - Proper-noun accuracy = fraction of listed proper nouns reproduced exactly
    ///   (case-sensitive) in the hypothesis.
    /// - Local-Only % = fraction of ground-truth tokens the local-only pipeline
    ///   (rules+dictionary, zero cloud) produces correctly — i.e. the spans that did
    ///   NOT need the cloud. It climbs as rules cover more of the user's vocabulary.
    public func run(manifest: [ManifestEntry], rules: [Rule], dictionary: [DictionaryEntry] = []) -> EvalResult {
        var totalEdits = 0
        var totalRefTokens = 0
        var pnCorrect = 0
        var pnTotal = 0
        var localMatched = 0
        var localTotal = 0
        var perPhrase: [EvalPhraseResult] = []

        for entry in manifest {
            let (hypothesis, _) = applier.apply(rules, dictionary: dictionary, to: entry.rawASR)
            let refTokens = OfftypeText.words(entry.groundTruth)
            let hypTokens = OfftypeText.words(hypothesis)
            let refLower = refTokens.map { $0.lowercased() }
            let hypLower = hypTokens.map { $0.lowercased() }

            let edits = OfftypeText.tokenEditDistance(refLower, hypLower)
            let wer = refTokens.isEmpty ? 0 : Double(edits) / Double(refTokens.count)
            totalEdits += edits
            totalRefTokens += refTokens.count

            let phraseCorrect = entry.properNouns.reduce(0) { count, noun in
                count + (OfftypeText.containsContiguous(hypTokens, OfftypeText.words(noun)) ? 1 : 0)
            }
            pnCorrect += phraseCorrect
            pnTotal += entry.properNouns.count

            localMatched += OfftypeText.lcsLength(hypLower, refLower)
            localTotal += refTokens.count

            perPhrase.append(EvalPhraseResult(
                id: entry.id,
                groundTruth: entry.groundTruth,
                hypothesis: hypothesis,
                wer: wer,
                properNounsCorrect: phraseCorrect,
                properNounsTotal: entry.properNouns.count
            ))
        }

        return EvalResult(
            wer: totalRefTokens == 0 ? 0 : Double(totalEdits) / Double(totalRefTokens),
            properNounAccuracy: pnTotal == 0 ? 1 : Double(pnCorrect) / Double(pnTotal),
            localOnlyPercent: localTotal == 0 ? 1 : Double(localMatched) / Double(localTotal),
            perPhrase: perPhrase
        )
    }

    /// The anti-overfit challenge: each near-miss phrase is already correct
    /// (`rawASR == groundTruth`); applying the rules must NOT change it. Any change is
    /// a regression — proof a rule over-generalized.
    public func runAntiOverfit(nearMiss: [ManifestEntry], rules: [Rule], dictionary: [DictionaryEntry] = []) -> AntiOverfitResult {
        var preserved = 0
        var regressions: [String] = []
        var perPhrase: [EvalPhraseResult] = []

        for entry in nearMiss {
            let (hypothesis, _) = applier.apply(rules, dictionary: dictionary, to: entry.rawASR)
            let refTokens = OfftypeText.words(entry.groundTruth)
            let hypTokens = OfftypeText.words(hypothesis)

            if hypTokens == refTokens {
                preserved += 1
            } else {
                regressions.append(entry.id)
            }

            let phraseCorrect = entry.properNouns.reduce(0) { count, noun in
                count + (OfftypeText.containsContiguous(hypTokens, OfftypeText.words(noun)) ? 1 : 0)
            }
            let edits = OfftypeText.tokenEditDistance(refTokens.map { $0.lowercased() }, hypTokens.map { $0.lowercased() })
            perPhrase.append(EvalPhraseResult(
                id: entry.id,
                groundTruth: entry.groundTruth,
                hypothesis: hypothesis,
                wer: refTokens.isEmpty ? 0 : Double(edits) / Double(refTokens.count),
                properNounsCorrect: phraseCorrect,
                properNounsTotal: entry.properNouns.count
            ))
        }

        return AntiOverfitResult(preserved: preserved, total: nearMiss.count, regressions: regressions, perPhrase: perPhrase)
    }

    /// Loads a committed manifest (or near-miss set — same shape) from disk.
    public func loadManifest(at url: URL) throws -> [ManifestEntry] {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([ManifestEntry].self, from: data)
        } catch {
            throw EvalError.manifestUnreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
