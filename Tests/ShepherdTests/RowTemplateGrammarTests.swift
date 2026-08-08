import XCTest
@testable import Shepherd

final class RowTemplateGrammarTests: XCTestCase {
    // `known_empty` resolves, unlike `absent`, yet every rule must treat the two alike.
    private static let values = ["a": "A", "b": "B", "known_empty": ""]

    func testFallbackTakesTheFirstNonEmptyAlternative() {
        assertRenders("{a|b}", "A")
        assertRenders("{known_empty|b}", "B")
        assertRenders("{absent|b}", "B")
        assertRenders("{known_empty|absent|a}", "A")
        assertRenders("{known_empty|absent}", "")
    }

    func testGroupRendersOnlyWhenAVariableInsideResolved() {
        assertRenders("{a}[ · {b}]", "A · B")
        assertRenders("{a}[ · {known_empty}]", "A")
        assertRenders("{a}[ · {absent}]", "A")
        assertRenders("{a}[ · {absent}{b}]", "A · B")
    }

    func testGroupWithoutVariablesIsLiteralText() {
        assertRenders("[literal]{a}", "literalA")
        assertRenders("[]", "")
    }

    func testNestedGroupsDecideIndependentlyOfTheirParent() {
        assertRenders("{a}[ ({b}[/{known_empty}])]", "A (B)")
        assertRenders("{a}[ ({b}[/{a}])]", "A (B/A)")
        // The " (" and ")" go too: a group with no variable of its own follows the
        // nested one.
        assertRenders("{a}[ ([{known_empty}])]", "A")
        assertRenders("[{known_empty|b}]", "B")
    }

    func testMalformedFormsStayLiteralText() {
        assertRenders("{a", "{a")
        assertRenders("{a|b", "{a|b")
        assertRenders("x}y", "x}y")
        assertRenders("x]y", "x]y")
        assertRenders("[{a}", "[A")
        // Spaces are outside the name charset, so this is not a variable at all.
        assertRenders("{ a }", "{ a }")
        // An empty name is still a variable, and no resolver answers it.
        assertRenders("{}", "")
        assertRenders("[{}]", "")
    }

    func testOnlyTheOutermostWhitespaceIsTrimmed() {
        assertRenders("  {a}  ", "A")
        assertRenders("{a}[ · {b}]  ", "A · B")
    }

    private func assertRenders(
        _ source: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = RowTemplate(source).renderText { name in
            Self.values[name].map(TemplateValue.text)
        }
        XCTAssertEqual(rendered, expected, source, file: file, line: line)
    }
}
