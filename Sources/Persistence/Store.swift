import Foundation
import GRDB
import OfftypeCore

// The on-device learning store: a GRDB/SQLite database holding the personal
// dictionary, learned rules, correction history, and the cumulative "Learned"
// counters. FTS5 indexes back fuzzy lookups of terms and aliases. Everything lives
// at `AppPaths.databaseURL`; tests use an in-memory queue.

/// Typed persistence errors for recoverable paths.
public enum PersistenceError: Error, Sendable, Equatable {
    case openFailed(String)
}

/// Opens the database, runs migrations, and exposes one repository per concern.
/// `@unchecked Sendable`: `DatabaseQueue` is itself thread-safe and serializes all
/// access, so sharing a `Store` across actors is safe.
public final class Store: @unchecked Sendable {
    public let dbQueue: DatabaseQueue
    public let rules: RuleRepository
    public let dictionary: DictionaryRepository
    public let corrections: CorrectionRepository
    public let stats: StatRepository

    /// File-backed store (creates the database if needed).
    public convenience init(url: URL = AppPaths.databaseURL) throws {
        let queue: DatabaseQueue
        do {
            queue = try DatabaseQueue(path: url.path)
        } catch {
            throw PersistenceError.openFailed(error.localizedDescription)
        }
        try self.init(dbQueue: queue)
    }

    /// In-memory store for tests and ephemeral use.
    public static func inMemory() throws -> Store {
        try Store(dbQueue: DatabaseQueue())
    }

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Store.migrator.migrate(dbQueue)
        self.rules = RuleRepository(dbQueue: dbQueue)
        self.dictionary = DictionaryRepository(dbQueue: dbQueue)
        self.corrections = CorrectionRepository(dbQueue: dbQueue)
        self.stats = StatRepository(dbQueue: dbQueue)
    }

    // MARK: - Schema & migrations

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.schema") { db in
            try db.create(table: "dictionary_entry") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("term", .text).notNull()
                t.column("weight", .double).notNull().defaults(to: 1.0)
                t.column("locale", .text).notNull().defaults(to: "en_US")
                t.column("source", .text).notNull().defaults(to: "manual")
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "idx_dictionary_term", on: "dictionary_entry", columns: ["term"])

            try db.create(table: "replacement_rule") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("alias", .text).notNull()
                t.column("canonical", .text).notNull()
                t.column("phonetic_key", .text)
                t.column("context", .text).notNull().defaults(to: "[]") // JSON array
                t.column("confidence", .double).notNull().defaults(to: 1.0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("hit_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .double).notNull()
            }
            try db.create(index: "idx_rule_alias", on: "replacement_rule", columns: ["alias"])

            try db.create(table: "correction") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("raw_text", .text).notNull()
                t.column("corrected_text", .text).notNull()
                t.column("app_bundle_id", .text)
                t.column("created_at", .double).notNull()
            }

            try db.create(table: "stat") { t in
                t.column("key", .text).notNull().primaryKey()
                t.column("json", .text).notNull()
            }
        }

        migrator.registerMigration("v2.fts5") { db in
            try db.create(virtualTable: "dictionary_entry_fts", using: FTS5()) { t in
                t.synchronize(withTable: "dictionary_entry")
                t.column("term")
            }
            try db.create(virtualTable: "replacement_rule_fts", using: FTS5()) { t in
                t.synchronize(withTable: "replacement_rule")
                t.column("alias")
            }
        }

        return migrator
    }
}
