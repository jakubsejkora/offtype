import Foundation
import OfftypeCore

// AGENT(Persistence): implement with GRDB (already a package dependency). Create a
// schema + migrations + FTS5 index for: dictionary_entry, replacement_rule,
// correction, stat, eval_run. Map rows to/from the OfftypeCore Codable models.
// Provide repositories with CRUD; offer an in-memory database for tests
// (`DatabaseQueue()`); store the file at AppPaths.databaseURL. Keep a clean
// repository API the app composes (e.g. RuleRepository, DictionaryRepository,
// CorrectionRepository, StatRepository).

/// Placeholder so the package compiles before implementation.
public final class Store: @unchecked Sendable {
    public let url: URL
    public init(url: URL = AppPaths.databaseURL) { self.url = url }
    // AGENT: open DatabaseQueue, run migrations, expose repositories.
}
