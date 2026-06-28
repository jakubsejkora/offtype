import Foundation
import OfftypeCore
import LearningEngine
import Eval

/// Loads the FROZEN `demo/` fixtures for the live learning demo. Resolution order:
///   1. `OFFTYPE_DEMO_DIR` (explicit override)
///   2. the app bundle's `Resources/demo` (distributed builds — see build-app.sh)
///   3. the package's `demo/` derived from `#filePath` (dev / the demo machine)
enum DemoData {
    private struct SeedPair: Codable {
        let rawText: String
        let correctedText: String
    }

    static var demoDirectory: URL? {
        let fm = FileManager.default

        if let override = ProcessInfo.processInfo.environment["OFFTYPE_DEMO_DIR"] {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            if fm.fileExists(atPath: url.appendingPathComponent("manifest.json").path) { return url }
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("demo", isDirectory: true),
           fm.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
            return bundled
        }

        // Sources/OfftypeApp/DemoData.swift → package root → demo/
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("demo", isDirectory: true)
        if fm.fileExists(atPath: dev.appendingPathComponent("manifest.json").path) { return dev }

        return nil
    }

    private static func url(_ file: String) throws -> URL {
        guard let dir = demoDirectory else {
            throw OfftypeError.modelNotFound("demo data directory")
        }
        return dir.appendingPathComponent(file)
    }

    static func manifest() throws -> [ManifestEntry] {
        try Evaluator().loadManifest(at: try url("manifest.json"))
    }

    static func nearMiss() throws -> [ManifestEntry] {
        try Evaluator().loadManifest(at: try url("nearmiss.json"))
    }

    static func seedCorrections() throws -> [Correction] {
        let data = try Data(contentsOf: try url("seed.json"))
        let pairs = try JSONDecoder().decode([SeedPair].self, from: data)
        return pairs.enumerated().map { index, pair in
            Correction(rawText: pair.rawText, correctedText: pair.correctedText,
                       createdAt: Date(timeIntervalSinceReferenceDate: Double(index)))
        }
    }

    /// Rules + terms learned from the entire committed seed set.
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
