import Foundation
import OfftypeCore
import LearningEngine
@testable import Eval

/// Loads the FROZEN `demo/` fixtures committed alongside the package, resolving the
/// path from this source file so tests are independent of the working directory.
enum DemoFixtures {
    static var demoDirectory: URL {
        URL(fileURLWithPath: #filePath)        // .../Tests/EvalTests/DemoFixtures.swift
            .deletingLastPathComponent()       // .../Tests/EvalTests
            .deletingLastPathComponent()       // .../Tests
            .deletingLastPathComponent()       // package root
            .appendingPathComponent("demo", isDirectory: true)
    }

    static func manifest() throws -> [ManifestEntry] {
        try Evaluator().loadManifest(at: demoDirectory.appendingPathComponent("manifest.json"))
    }

    static func nearMiss() throws -> [ManifestEntry] {
        try Evaluator().loadManifest(at: demoDirectory.appendingPathComponent("nearmiss.json"))
    }

    private struct SeedPair: Codable {
        let rawText: String
        let correctedText: String
    }

    /// The committed seed corrections, with deterministic ids/timestamps so learned
    /// rules are stable across runs.
    static func seedCorrections() throws -> [Correction] {
        let data = try Data(contentsOf: demoDirectory.appendingPathComponent("seed.json"))
        let pairs = try JSONDecoder().decode([SeedPair].self, from: data)
        return pairs.enumerated().map { index, pair in
            Correction(
                id: UUID(),
                rawText: pair.rawText,
                correctedText: pair.correctedText,
                createdAt: Date(timeIntervalSinceReferenceDate: Double(index))
            )
        }
    }

    /// Rules + terms learned from the entire seed set.
    static func learnedFromSeed() throws -> LearnOutcome {
        let engine = DiffEngine()
        var rules: [Rule] = []
        var terms: [DictionaryEntry] = []
        for correction in try seedCorrections() {
            let outcome = engine.learn(from: correction)
            rules.append(contentsOf: outcome.rules)
            terms.append(contentsOf: outcome.terms)
        }
        return LearnOutcome(rules: rules, terms: terms)
    }
}
