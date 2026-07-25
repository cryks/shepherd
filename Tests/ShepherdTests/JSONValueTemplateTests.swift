// Pins which herdr values a template treats as EMPTY. A variable bound to a
// JSON value renders that value's templateText and counts as empty when it has
// none, so this file states both halves together: the text a scalar produces,
// and whether that scalar satisfies a `{a|b}` alternative and keeps a `[...]`
// group alive.
//
// The distinction that matters is between "no value" and "a value that looks
// falsy": null, arrays, and objects have no single-line text and are empty,
// `false` and `0` are ordinary text, and only the empty string is a string that
// counts as empty.
//
// Not exercised here: the grammar itself (RowTemplateGrammarTests) and how a
// dotted path reaches a value (HerdrProtocolTests).

import XCTest
@testable import Shepherd

final class JSONValueTemplateTests: XCTestCase {
    func testScalarsRenderTheirWireForm() {
        XCTAssertEqual(JSONValue.string("main").templateText, "main")
        XCTAssertEqual(JSONValue.bool(false).templateText, "false")
        XCTAssertEqual(JSONValue.bool(true).templateText, "true")
        XCTAssertEqual(JSONValue.int(0).templateText, "0")
        XCTAssertEqual(JSONValue.int(-7).templateText, "-7")
        // Integral doubles print without the ".0" a Double description carries.
        XCTAssertEqual(JSONValue.double(3).templateText, "3")
        XCTAssertEqual(JSONValue.double(3.5).templateText, "3.5")
    }

    func testValuesWithoutSingleLineTextHaveNoTextForm() {
        XCTAssertNil(JSONValue.null.templateText)
        XCTAssertNil(JSONValue.array([.string("main")]).templateText)
        XCTAssertNil(JSONValue.object(["branch": .string("main")]).templateText)
    }

    func testFalseAndZeroSatisfyFallbacksAndGroupsWhileValuelessJSONDoesNot() {
        for value in [JSONValue.bool(false), .int(0), .string("0")] {
            let text = value.templateText ?? ""
            assertRenders("{v|fallback}", value, text)
            assertRenders("[<{v}>]", value, "<\(text)>")
        }
        for value in [JSONValue.null, .string(""), .array([]), .object([:])] {
            assertRenders("{v|fallback}", value, "FALLBACK")
            assertRenders("[<{v}>]", value, "")
        }
    }

    private func assertRenders(
        _ source: String,
        _ value: JSONValue,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rendered = RowTemplate(source).renderText { name in
            switch name {
            case "v": .text(value.templateText ?? "")
            case "fallback": .text("FALLBACK")
            default: nil
            }
        }
        XCTAssertEqual(rendered, expected, "\(source) / \(value)", file: file, line: line)
    }
}
