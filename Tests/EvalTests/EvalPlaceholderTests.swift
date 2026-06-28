import XCTest

import OfftypeCore
@testable import Eval

// AGENT(Eval): replace with WER + proper-noun-accuracy tests over fixture
// manifests, and the anti-overfit assertions. Placeholder keeps the target compiling.
final class EvalPlaceholderTests: XCTestCase {
    func testEmptyManifestIsZero() {
        let r = Evaluator().run(manifest: [], rules: [])
        XCTAssertEqual(r.perPhrase.count, 0)
    }
}
