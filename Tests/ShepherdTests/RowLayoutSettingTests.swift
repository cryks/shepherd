// Pins the storage contract of the row layout preference: an edited layout
// survives a relaunch with its line order and per-side styles intact, an absent
// key leaves storage untouched, and neither undecodable data nor a style name
// this build does not know can cost the user more than the one side that names
// it. Each test owns a UserDefaults suite, so nothing here reads or writes the
// settings of the machine it runs on.
//
// Not exercised here: what the built-in layout renders (RowLayoutTests) and the
// settings pane, which is a view over the same value.

import Foundation
import XCTest
@testable import Shepherd

final class RowLayoutSettingTests: XCTestCase {
    @MainActor
    func testStoredLayoutRoundTripsLineOrderAndPerSideStyles() {
        let defaults = makeDefaults()
        let edited = RowLayout(
            lines: [
                RowLine(
                    left: RowTemplate("{title}"),
                    leftStyle: .monospace,
                    right: RowTemplate("{herdr.agent.agent}"),
                    rightStyle: .status
                ),
                RowLine(
                    left: RowTemplate("{excerpt}"),
                    leftStyle: .heading,
                    right: RowTemplate(""),
                    rightStyle: .subdued
                ),
            ],
            linesByAgent: [
                "codex": [
                    RowLine(
                        left: RowTemplate("{herdr.tab.label}"),
                        leftStyle: .body,
                        right: RowTemplate(""),
                        rightStyle: .body
                    )
                ]
            ],
            notification: NotificationTemplates(
                title: RowTemplate("{title}"),
                subtitle: RowTemplate(""),
                body: RowTemplate("{herdr.workspace.branch}")
            )
        )

        let setting = RowLayoutSetting(defaults: defaults)
        setting.layout = edited

        // Whole-value equality is the point: reordered lines, a leftStyle that
        // came back on the right, or a per-agent entry that did not survive are
        // each a failure this comparison names.
        XCTAssertEqual(RowLayoutSetting(defaults: defaults).layout, edited)
    }

    @MainActor
    func testAbsentKeyReadsTheBuiltInLayoutAndStaysAbsent() {
        let defaults = makeDefaults()

        let setting = RowLayoutSetting(defaults: defaults)

        XCTAssertEqual(setting.layout, .default)
        XCTAssertNil(defaults.data(forKey: RowLayoutSetting.layoutKey))
    }

    @MainActor
    func testUndecodableDataReadsTheBuiltInLayout() {
        let defaults = makeDefaults()
        defaults.set(Data("{ not a layout".utf8), forKey: RowLayoutSetting.layoutKey)

        XCTAssertEqual(RowLayoutSetting(defaults: defaults).layout, .default)
    }

    @MainActor
    func testUnknownStyleNameCostsOnlyThatSidesAppearance() {
        let defaults = makeDefaults()
        let stored = """
        {
          "lines": [
            {
              "left": "{title}",
              "leftStyle": "banner",
              "right": "{herdr.agent.agent_status}",
              "rightStyle": "status"
            }
          ],
          "linesByAgent": {},
          "notification": {
            "title": "{title}",
            "subtitle": "",
            "body": "{herdr.agent.agent}"
          }
        }
        """
        defaults.set(Data(stored.utf8), forKey: RowLayoutSetting.layoutKey)

        let layout = RowLayoutSetting(defaults: defaults).layout

        XCTAssertEqual(layout.lines.count, 1)
        XCTAssertEqual(layout.lines.first?.leftStyle, .body)
        XCTAssertEqual(layout.lines.first?.rightStyle, .status)
        XCTAssertEqual(layout.lines.first?.left.source, "{title}")
        XCTAssertEqual(layout.notification.body.source, "{herdr.agent.agent}")
    }

    /// An isolated UserDefaults suite per test. The whole domain is removed at teardown.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "RowLayoutSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Pass only the Sendable suiteName to teardown; do not send the UserDefaults
        // instance across the actor boundary (avoids SendingRisksDataRace).
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
