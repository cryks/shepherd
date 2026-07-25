// Pins the grammar RowTemplate implements: a fallback picks the first
// alternative that resolves NON-EMPTY rather than the first one that exists, a
// group renders only when a variable inside it resolved, a group holding no
// variable is literal text, and every malformed form renders as text instead of
// failing. Cases run against one fixed variable table, so each expectation
// states a grammar rule rather than a fact about herdr data.
//
// Not exercised here: which names Shepherd resolves (the resolver is a closure
// this file supplies), how JSON values become empty (JSONValueTemplateTests),
// and icon runs, which RowLayoutTests covers through the built-in lines.

import XCTest
@testable import Shepherd

final class RowTemplateGrammarTests: XCTestCase {
    /// `known_empty` is a name the resolver answers with the empty string. Every
    /// rule below has to treat it exactly like the unknown name `absent`.
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
        // Two variables, one of them resolved, keeps the group and its separator.
        assertRenders("{a}[ · {absent}{b}]", "A · B")
    }

    func testGroupWithoutVariablesIsLiteralText() {
        assertRenders("[literal]{a}", "literalA")
        assertRenders("[]", "")
    }

    func testNestedGroupsDecideIndependentlyOfTheirParent() {
        assertRenders("{a}[ ({b}[/{known_empty}])]", "A (B)")
        assertRenders("{a}[ ({b}[/{a}])]", "A (B/A)")
        // The outer group holds no variable of its own, so it goes when the only
        // variable below it stays empty.
        assertRenders("{a}[ ([{known_empty}])]", "A")
        assertRenders("[{known_empty|b}]", "B")
    }

    func testMalformedFormsStayLiteralText() {
        assertRenders("{a", "{a")
        assertRenders("{a|b", "{a|b")
        assertRenders("x}y", "x}y")
        assertRenders("x]y", "x]y")
        assertRenders("[{a}", "[A")
        // A brace holding anything outside the name charset is not a variable.
        assertRenders("{ a }", "{ a }")
        // `{}` is a variable whose name no resolver knows, so it renders empty.
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
