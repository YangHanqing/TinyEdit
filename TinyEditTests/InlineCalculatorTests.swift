import XCTest
@testable import TinyEdit

final class InlineCalculatorTests: XCTestCase {
    func testProposals() {
        let rows: [(String, String?)] = [
            ("1 + 1", " = 2"),
            ("1+1", " = 2"),
            ("1+2*3", " = 7"),
            ("(1+2)*3", " = 9"),
            ("8/2*2", " = 8"),
            ("8/2/2", " = 2"),
            ("1+2*3+4", " = 11"),
            ("-3+5", " = 2"),
            ("-(2+3)*4", " = -20"),
            ("+2*-3", " = -6"),
            ("1++2", " = 3"),
            ("1--2", " = 3"),
            ("0.1+0.2", " = 0.3"),
            ("0.1 + 0.2", " = 0.3"),
            ("1/2", " = 0.5"),
            ("1/4", " = 0.25"),
            ("1/5", " = 0.2"),
            ("1/8", " = 0.125"),
            ("10/4", " = 2.5"),
            ("4/2", " = 2"),
            ("1/3*3", " = 1"),
            ("1/3", " ≈ 0.333333333333"),
            ("2/3", " ≈ 0.666666666667"),
            ("-8/3", " ≈ -2.66666666667"),
            ("1/300", " ≈ 0.00333333333333"),
            ("1/6", " ≈ 0.166666666667"),
            ("1/0", nil),
            ("99999999999999999999 * 99999999999999999999", nil),
            ("0/0", nil),
            ("1/(1-1)", nil),
            ("１＋１", " = 2"),
            ("（１＋２）×３", " = 9"),
            ("2×3", " = 6"),
            ("10÷4", " = 2.5"),
            ("1 + 1 =", " 2"),
            ("1+1=", "2"),
            ("1 + 1 = ", "2"),
            ("1/3 =", " 0.333333333333"),
            ("1 + 1 = 2", nil),
            ("1+1=2", nil),
            ("1 + 1 = 2.0", nil),
            ("1+1=+2", nil),
            ("１＋１＝２", nil),
            ("1/3 ≈ 0.333333333333", nil),
            ("1/3 = 0.333333333333", nil),
            ("2 + 2 = 2", " → 4"),
            ("2+2=2", " → 4"),
            ("1/3 ≈ 0.3", " → 0.333333333333"),
            ("1", nil),
            ("+2", nil),
            ("(1)", nil),
            ("-(1)", nil),
            ("hello", nil),
            ("a = 1 + 1", nil),
            ("1 + x", nil),
            ("50%", nil),
            ("$5+1", nil),
            ("1+", nil),
            ("(1+2", nil),
            ("1+*", nil),
            ("2024-01-02", nil),
            ("2024/1/2", nil),
            ("2024 - 01 - 02", nil),
            ("2024-01-02 + 1", nil),
            ("1-2-3", " = -4"),
            ("1.2.3", nil),
            ("010-12345678", nil),
            ("555-1234", nil),
            ("021-12345678", nil),
            ("123-456-7890", nil),
            ("010+1", nil),
            ("100-20", " = 80"),
            ("1000-2000", " = -1000"),
            ("1-2", " = -1"),
            ("", nil),
            ("   ", nil),
        ]
        for (line, ghost) in rows {
            XCTAssertEqual(InlineCalculator.proposal(forLine: line)?.ghost, ghost, line)
        }
    }

    func testAdoptionEdits() {
        let fresh = InlineCalculator.proposal(forLine: "1 + 1")
        XCTAssertEqual(fresh?.edit, .append(" = 2"))

        let glued = InlineCalculator.proposal(forLine: "1+1=")
        XCTAssertEqual(glued?.edit, .append("2"))

        let spaced = InlineCalculator.proposal(forLine: "1 + 1 =")
        XCTAssertEqual(spaced?.edit, .append(" 2"))

        let mismatch = InlineCalculator.proposal(forLine: "2 + 2 = 2")
        XCTAssertEqual(mismatch?.edit, .replace(NSRange(location: 6, length: 3), "= 4"))

        let tight = InlineCalculator.proposal(forLine: "2+2=2")
        XCTAssertEqual(tight?.edit, .replace(NSRange(location: 3, length: 2), "=4"))

        let approx = InlineCalculator.proposal(forLine: "1/3=0.5")
        XCTAssertEqual(approx?.edit, .replace(NSRange(location: 3, length: 4), "≈0.333333333333"))
    }

    func testLimits() {
        XCTAssertEqual(InlineCalculator.proposal(forLine: "1+1" + String(repeating: " ", count: 197))?.ghost, "= 2")
        XCTAssertNil(InlineCalculator.proposal(forLine: "1+1" + String(repeating: " ", count: 198)))

        let ok = String(repeating: "(", count: 32) + "1+2" + String(repeating: ")", count: 32)
        XCTAssertEqual(InlineCalculator.proposal(forLine: ok)?.ghost, " = 3")
        let deep = String(repeating: "(", count: 33) + "1+2" + String(repeating: ")", count: 33)
        XCTAssertNil(InlineCalculator.proposal(forLine: deep))
    }

    func testEligibility() {
        let plain = InlineCalculator.Context(mode: .plainText, language: .plain)
        let mdMode = InlineCalculator.Context(mode: .plainTextAndMarkdown, language: .markdown)
        let lines = ["1 + 1", "```", "1 + 1", "```", "`1 + 1`", "~~~", "1 + 1", "~~~", "1 + 1"]
        let text = lines.joined(separator: "\n") as NSString
        let starts = lines.indices.map { i in lines[..<i].reduce(0) { $0 + $1.utf16.count + 1 } }
        let allowed = starts.map { InlineCalculator.isEligible(mdMode, text: text, index: $0) }
        XCTAssertEqual(allowed, [true, false, false, false, false, false, false, false, true])
        XCTAssertTrue(InlineCalculator.isEligible(plain, text: "1 + 1" as NSString, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .plainText, language: .markdown), text: text, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .plainText, language: .swift), text: "1 + 1" as NSString, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .plainTextAndMarkdown, language: .python), text: "1 + 1" as NSString, index: 0))
        XCTAssertFalse(InlineCalculator.isEligible(InlineCalculator.Context(mode: .off, language: .plain), text: "1 + 1" as NSString, index: 0))
    }
}
