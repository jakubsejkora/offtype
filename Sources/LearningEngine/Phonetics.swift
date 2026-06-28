import Foundation

/// Phonetic keying for fuzzy alias matching, so homophones collapse to the same
/// bucket (e.g. `cuba` ≈ `Kuba`, `evil` ≈ `eval`).
///
/// This is a faithful implementation of Lawrence Philips' **Metaphone** algorithm
/// — a solid, well-understood approximation of Double Metaphone that is more than
/// enough for matching short proper nouns and jargon. It is pure and deterministic.
public enum Phonetics {

    /// The Metaphone key for `s`. Non-letters are ignored; the result is uppercase
    /// phonetic codes. Empty input → empty key.
    public static func key(_ s: String) -> String {
        // Letters only, uppercased ASCII (accents are folded away by dropping
        // non-ASCII after uppercasing — adequate for the English demo domain).
        let letters = Array(s.uppercased().filter { $0.isLetter && $0.isASCII })
        if letters.isEmpty { return "" }

        let n = letters.count
        func at(_ i: Int) -> Character { (i >= 0 && i < n) ? letters[i] : " " }
        func isVowel(_ c: Character) -> Bool { "AEIOU".contains(c) }

        var result = ""
        var i = 0

        // Initial silent-letter combinations.
        let firstTwo = String(letters.prefix(2))
        if ["AE", "GN", "KN", "PN", "WR"].contains(firstTwo) {
            i = 1
        } else if letters.first == "X" {
            result.append("S")
            i = 1
        } else if firstTwo == "WH" {
            result.append("W")
            i = 2
        }

        while i < n {
            let c = letters[i]

            // Collapse doubled letters (Metaphone keeps doubled C).
            if c != "C", i > 0, at(i - 1) == c {
                i += 1
                continue
            }

            switch c {
            case "A", "E", "I", "O", "U":
                if i == 0 { result.append(c) }

            case "B":
                // Silent final B after M ("dumb", "comb").
                if !(i == n - 1 && at(i - 1) == "M") { result.append("B") }

            case "C":
                if at(i + 1) == "I", at(i + 2) == "A" {
                    result.append("X")
                } else if at(i + 1) == "H" {
                    result.append("X") // "CH" → X; following H is skipped below
                } else if "IEY".contains(at(i + 1)) {
                    if at(i - 1) != "S" { result.append("S") } // "SCI/SCE/SCY" → C silent
                } else {
                    result.append("K")
                }

            case "D":
                if at(i + 1) == "G", "IEY".contains(at(i + 2)) {
                    result.append("J")
                } else {
                    result.append("T")
                }

            case "F":
                result.append("F")

            case "G":
                if at(i + 1) == "H" {
                    // GH is pronounced only before a vowel and not word-initial.
                    if i > 0, isVowel(at(i + 2)) { result.append("K") }
                } else if at(i + 1) == "N" {
                    // GN / GNED — G silent.
                } else if "IEY".contains(at(i + 1)) {
                    result.append("J")
                } else {
                    result.append("K")
                }

            case "H":
                // Sounded only between a vowel and another vowel, and not after a
                // consonant that already absorbed it (C, S, P, T, G).
                if isVowel(at(i - 1)), !isVowel(at(i + 1)) {
                    // silent
                } else if "CSPTG".contains(at(i - 1)) {
                    // silent (handled by the preceding consonant)
                } else {
                    result.append("H")
                }

            case "J":
                result.append("J")

            case "K":
                if at(i - 1) != "C" { result.append("K") }

            case "L":
                result.append("L")

            case "M":
                result.append("M")

            case "N":
                result.append("N")

            case "P":
                result.append(at(i + 1) == "H" ? "F" : "P")

            case "Q":
                result.append("K")

            case "R":
                result.append("R")

            case "S":
                if at(i + 1) == "H" {
                    result.append("X")
                } else if at(i + 1) == "I", "OA".contains(at(i + 2)) {
                    result.append("X")
                } else {
                    result.append("S")
                }

            case "T":
                if at(i + 1) == "H" {
                    result.append("0") // theta
                } else if at(i + 1) == "I", "OA".contains(at(i + 2)) {
                    result.append("X")
                } else {
                    result.append("T")
                }

            case "V":
                result.append("F")

            case "W", "Y":
                if isVowel(at(i + 1)) { result.append(c) }

            case "X":
                result.append("K")
                result.append("S")

            case "Z":
                result.append("S")

            default:
                break
            }

            i += 1
        }

        return result
    }
}
