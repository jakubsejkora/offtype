import Foundation
import GRDB
import OfftypeCore

// Repositories: a small, explicit CRUD surface mapping SQLite rows ↔ OfftypeCore
// Codable models. Each call serializes through the shared `DatabaseQueue`.

private let jsonEncoder = JSONEncoder()
private let jsonDecoder = JSONDecoder()

// MARK: - Rules

public struct RuleRepository: Sendable {
    let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func save(_ rule: Rule) throws {
        try dbQueue.write { db in try Self.upsert(rule, db) }
    }

    public func saveAll(_ rules: [Rule]) throws {
        try dbQueue.write { db in for rule in rules { try Self.upsert(rule, db) } }
    }

    /// All rules, oldest first (stable, deterministic order).
    public func all() throws -> [Rule] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM replacement_rule ORDER BY created_at, id").map(Self.decode)
        }
    }

    /// Only enabled rules — what the `RuleApplier`/`Router` should run.
    public func enabled() throws -> [Rule] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM replacement_rule WHERE enabled = 1 ORDER BY created_at, id").map(Self.decode)
        }
    }

    public func delete(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM replacement_rule WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// One-click rollback of a bad rule.
    public func setEnabled(_ enabled: Bool, id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE replacement_rule SET enabled = ? WHERE id = ?", arguments: [enabled, id.uuidString])
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM replacement_rule") }
    }

    /// FTS5-backed prefix search over aliases.
    public func search(alias query: String) throws -> [Rule] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT replacement_rule.* FROM replacement_rule
                JOIN replacement_rule_fts ON replacement_rule_fts.rowid = replacement_rule.rowid
                WHERE replacement_rule_fts MATCH ?
                ORDER BY replacement_rule.created_at, replacement_rule.id
                """, arguments: [pattern]).map(Self.decode)
        }
    }

    static func upsert(_ rule: Rule, _ db: Database) throws {
        let contextData = (try? jsonEncoder.encode(rule.context)) ?? Data("[]".utf8)
        let contextJSON = String(decoding: contextData, as: UTF8.self)
        try db.execute(sql: """
            INSERT OR REPLACE INTO replacement_rule
            (id, alias, canonical, phonetic_key, context, confidence, enabled, hit_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                rule.id.uuidString, rule.alias, rule.canonical, rule.phoneticKey,
                contextJSON, rule.confidence, rule.enabled, rule.hitCount,
                rule.createdAt.timeIntervalSinceReferenceDate,
            ])
    }

    static func decode(_ row: Row) -> Rule {
        let id: String = row["id"]
        let alias: String = row["alias"]
        let canonical: String = row["canonical"]
        let phoneticKey: String? = row["phonetic_key"]
        let contextJSON: String = row["context"]
        let confidence: Double = row["confidence"]
        let enabled: Bool = row["enabled"]
        let hitCount: Int = row["hit_count"]
        let createdAt: Double = row["created_at"]
        let context = (try? jsonDecoder.decode([String].self, from: Data(contextJSON.utf8))) ?? []
        return Rule(
            id: UUID(uuidString: id) ?? UUID(),
            alias: alias,
            canonical: canonical,
            phoneticKey: phoneticKey,
            context: context,
            confidence: confidence,
            enabled: enabled,
            hitCount: hitCount,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }
}

// MARK: - Dictionary

public struct DictionaryRepository: Sendable {
    let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func save(_ entry: DictionaryEntry) throws {
        try dbQueue.write { db in try Self.upsert(entry, db) }
    }

    public func saveAll(_ entries: [DictionaryEntry]) throws {
        try dbQueue.write { db in for entry in entries { try Self.upsert(entry, db) } }
    }

    public func all() throws -> [DictionaryEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM dictionary_entry ORDER BY created_at, id").map(Self.decode)
        }
    }

    public func delete(id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM dictionary_entry WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM dictionary_entry") }
    }

    /// FTS5-backed prefix search over terms.
    public func search(term query: String) throws -> [DictionaryEntry] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: query) else { return [] }
        return try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT dictionary_entry.* FROM dictionary_entry
                JOIN dictionary_entry_fts ON dictionary_entry_fts.rowid = dictionary_entry.rowid
                WHERE dictionary_entry_fts MATCH ?
                ORDER BY dictionary_entry.created_at, dictionary_entry.id
                """, arguments: [pattern]).map(Self.decode)
        }
    }

    static func upsert(_ entry: DictionaryEntry, _ db: Database) throws {
        try db.execute(sql: """
            INSERT OR REPLACE INTO dictionary_entry
            (id, term, weight, locale, source, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                entry.id.uuidString, entry.term, entry.weight, entry.locale,
                entry.source.rawValue, entry.createdAt.timeIntervalSinceReferenceDate,
            ])
    }

    static func decode(_ row: Row) -> DictionaryEntry {
        let id: String = row["id"]
        let term: String = row["term"]
        let weight: Double = row["weight"]
        let locale: String = row["locale"]
        let source: String = row["source"]
        let createdAt: Double = row["created_at"]
        return DictionaryEntry(
            id: UUID(uuidString: id) ?? UUID(),
            term: term,
            weight: weight,
            locale: locale,
            source: DictionaryEntry.Source(rawValue: source) ?? .manual,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }
}

// MARK: - Corrections

public struct CorrectionRepository: Sendable {
    let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    public func save(_ correction: Correction) throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO correction
                (id, raw_text, corrected_text, app_bundle_id, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    correction.id.uuidString, correction.rawText, correction.correctedText,
                    correction.appBundleID, correction.createdAt.timeIntervalSinceReferenceDate,
                ])
        }
    }

    public func all() throws -> [Correction] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM correction ORDER BY created_at, id").map(Self.decode)
        }
    }

    public func deleteAll() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM correction") }
    }

    static func decode(_ row: Row) -> Correction {
        let id: String = row["id"]
        let rawText: String = row["raw_text"]
        let correctedText: String = row["corrected_text"]
        let appBundleID: String? = row["app_bundle_id"]
        let createdAt: Double = row["created_at"]
        return Correction(
            id: UUID(uuidString: id) ?? UUID(),
            rawText: rawText,
            correctedText: correctedText,
            appBundleID: appBundleID,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }
}

// MARK: - Stats

public struct StatRepository: Sendable {
    private static let key = "learned"
    let dbQueue: DatabaseQueue
    init(dbQueue: DatabaseQueue) { self.dbQueue = dbQueue }

    /// The cumulative "Learned" counters, or a fresh `LearnedStats` if none saved.
    public func load() throws -> LearnedStats {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT json FROM stat WHERE key = ?", arguments: [Self.key]) else {
                return LearnedStats()
            }
            let json: String = row["json"]
            return (try? jsonDecoder.decode(LearnedStats.self, from: Data(json.utf8))) ?? LearnedStats()
        }
    }

    public func save(_ stats: LearnedStats) throws {
        let data = try jsonEncoder.encode(stats)
        let json = String(decoding: data, as: UTF8.self)
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO stat (key, json) VALUES (?, ?)", arguments: [Self.key, json])
        }
    }
}
