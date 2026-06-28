import XCTest
import OfftypeCore
@testable import Persistence

final class PersistenceTests: XCTestCase {

    private func makeStore() throws -> Store { try Store.inMemory() }

    // MARK: - Rules

    func testRuleRoundTripPreservesEveryField() throws {
        let store = try makeStore()
        let rule = Rule(
            alias: "cuba", canonical: "Kuba", phoneticKey: "KP",
            context: ["harness", "hetzner"], confidence: 0.875, enabled: true,
            hitCount: 3, createdAt: Date(timeIntervalSinceReferenceDate: 12345.678)
        )
        try store.rules.save(rule)
        let loaded = try store.rules.all()
        XCTAssertEqual(loaded, [rule])
    }

    func testSaveAllAndEnabledFilterAndRollback() throws {
        let store = try makeStore()
        let a = Rule(alias: "a", canonical: "A", createdAt: Date(timeIntervalSinceReferenceDate: 1))
        let b = Rule(alias: "b", canonical: "B", enabled: false, createdAt: Date(timeIntervalSinceReferenceDate: 2))
        try store.rules.saveAll([a, b])

        XCTAssertEqual(try store.rules.all().count, 2)
        XCTAssertEqual(try store.rules.enabled().map(\.alias), ["a"])

        // Rollback: disable a, re-enable b.
        try store.rules.setEnabled(false, id: a.id)
        try store.rules.setEnabled(true, id: b.id)
        XCTAssertEqual(try store.rules.enabled().map(\.alias), ["b"])
    }

    func testUpsertReplacesByID() throws {
        let store = try makeStore()
        var rule = Rule(alias: "cuba", canonical: "Kuba", confidence: 0.5)
        try store.rules.save(rule)
        rule.confidence = 0.9
        rule.hitCount = 7
        try store.rules.save(rule)
        let loaded = try store.rules.all()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.confidence, 0.9)
        XCTAssertEqual(loaded.first?.hitCount, 7)
    }

    func testDeleteAndDeleteAll() throws {
        let store = try makeStore()
        let a = Rule(alias: "a", canonical: "A")
        let b = Rule(alias: "b", canonical: "B")
        try store.rules.saveAll([a, b])
        try store.rules.delete(id: a.id)
        XCTAssertEqual(try store.rules.all().map(\.alias), ["b"])
        try store.rules.deleteAll()
        XCTAssertTrue(try store.rules.all().isEmpty)
    }

    func testRuleFTSSearchByAliasPrefix() throws {
        let store = try makeStore()
        try store.rules.saveAll([
            Rule(alias: "off type", canonical: "Offtype"),
            Rule(alias: "cuba", canonical: "Kuba"),
        ])
        XCTAssertEqual(try store.rules.search(alias: "off").map(\.canonical), ["Offtype"])
        XCTAssertEqual(try store.rules.search(alias: "cub").map(\.canonical), ["Kuba"])
        XCTAssertTrue(try store.rules.search(alias: "zzz").isEmpty)
    }

    // MARK: - Dictionary

    func testDictionaryRoundTripAndSearch() throws {
        let store = try makeStore()
        let entries = [
            DictionaryEntry(term: "Offtype", source: .correction, createdAt: Date(timeIntervalSinceReferenceDate: 1)),
            DictionaryEntry(term: "Kuba", source: .correction, createdAt: Date(timeIntervalSinceReferenceDate: 2)),
            DictionaryEntry(term: "GemmaQuant", source: .seed, createdAt: Date(timeIntervalSinceReferenceDate: 3)),
        ]
        try store.dictionary.saveAll(entries)
        XCTAssertEqual(try store.dictionary.all(), entries)
        XCTAssertEqual(try store.dictionary.search(term: "kub").map(\.term), ["Kuba"])
        XCTAssertEqual(try store.dictionary.search(term: "gemma").map(\.term), ["GemmaQuant"])
    }

    // MARK: - Corrections

    func testCorrectionRoundTrip() throws {
        let store = try makeStore()
        let correction = Correction(
            rawText: "off type", correctedText: "Offtype",
            appBundleID: "com.example.app", createdAt: Date(timeIntervalSinceReferenceDate: 99)
        )
        try store.corrections.save(correction)
        XCTAssertEqual(try store.corrections.all(), [correction])
    }

    func testCorrectionNilBundleID() throws {
        let store = try makeStore()
        let correction = Correction(rawText: "a", correctedText: "b")
        try store.corrections.save(correction)
        XCTAssertNil(try store.corrections.all().first?.appBundleID)
    }

    // MARK: - Stats

    func testStatsDefaultAndRoundTrip() throws {
        let store = try makeStore()
        XCTAssertEqual(try store.stats.load(), LearnedStats()) // default when empty

        var stats = LearnedStats()
        stats.rulesLearned = 4
        stats.wordsAdded = 3
        stats.llmCallsAvoided = 17
        stats.tokensSaved = 2310
        stats.localOnlyPercent = 0.84
        try store.stats.save(stats)
        XCTAssertEqual(try store.stats.load(), stats)
    }

    // MARK: - File-backed persistence (survives "relaunch")

    func testFileBackedStoreSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offtype-persist-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let rule = Rule(alias: "cuba", canonical: "Kuba", context: ["harness"], confidence: 0.9)
        do {
            let store = try Store(url: url)
            try store.rules.save(rule)
            var stats = LearnedStats(); stats.rulesLearned = 1
            try store.stats.save(stats)
        }
        // Reopen a fresh Store at the same path — data must still be there.
        let reopened = try Store(url: url)
        XCTAssertEqual(try reopened.rules.all(), [rule])
        XCTAssertEqual(try reopened.stats.load().rulesLearned, 1)
    }
}
