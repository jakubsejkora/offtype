import XCTest
import OfftypeCore
@testable import LearningEngine

final class PhoneticsTests: XCTestCase {

    func testHomophonesCollapseToSameKey() {
        // The hero equivalence: a hard-C "Cuba" and "Kuba" must bucket together.
        XCTAssertEqual(Phonetics.key("cuba"), Phonetics.key("kuba"))
        XCTAssertEqual(Phonetics.key("Cuba"), Phonetics.key("Kuba"))
        XCTAssertEqual(Phonetics.key("evil"), Phonetics.key("eval"))
    }

    func testCaseInsensitive() {
        XCTAssertEqual(Phonetics.key("HETZNER"), Phonetics.key("hetzner"))
        XCTAssertEqual(Phonetics.key("Parakeet"), Phonetics.key("parakeet"))
    }

    func testNonLettersIgnored() {
        XCTAssertEqual(Phonetics.key("ku-ba!"), Phonetics.key("kuba"))
        XCTAssertEqual(Phonetics.key("k u b a"), Phonetics.key("kuba"))
    }

    func testEmptyAndDigitsProduceEmptyKey() {
        XCTAssertEqual(Phonetics.key(""), "")
        XCTAssertEqual(Phonetics.key("123"), "")
        XCTAssertEqual(Phonetics.key("  "), "")
    }

    func testDistinctSoundsDiffer() {
        XCTAssertNotEqual(Phonetics.key("cuba"), Phonetics.key("table"))
        XCTAssertNotEqual(Phonetics.key("offtype"), Phonetics.key("hetzner"))
    }

    func testKeysAreUppercaseCodes() {
        let key = Phonetics.key("Kuba")
        XCTAssertFalse(key.isEmpty)
        XCTAssertEqual(key, key.uppercased())
    }

    func testStartsWithVowelKeepsInitialVowel() {
        // Initial vowels are retained; internal vowels are dropped.
        XCTAssertTrue(Phonetics.key("eval").hasPrefix("E"))
        XCTAssertTrue(Phonetics.key("offtype").hasPrefix("O"))
    }
}
