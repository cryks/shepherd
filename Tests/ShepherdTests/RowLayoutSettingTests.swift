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
                    rightStyle: .subdued,
                    maxLines: 3
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
                body: [
                    NotificationLine(RowTemplate("{herdr.agent.agent}")),
                    NotificationLine(RowTemplate("{herdr.workspace.branch}")),
                ]
            )
        )

        let setting = RowLayoutSetting(defaults: defaults)
        setting.layout = edited

        // One whole-value comparison catches reordered lines, a style that came
        // back on the other side, and a per-agent entry that did not survive.
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
    }

    // The first line is what builds before maxLines existed wrote; the second
    // is what a hand edit can leave behind.
    @MainActor
    func testAbsentOrSubOneMaxLinesReadsAsOne() {
        let defaults = makeDefaults()
        let stored = """
        {
          "lines": [
            {
              "left": "{title}",
              "leftStyle": "body",
              "right": "",
              "rightStyle": "body"
            },
            {
              "left": "{excerpt}",
              "leftStyle": "monospace",
              "right": "",
              "rightStyle": "monospace",
              "maxLines": 0
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

        XCTAssertEqual(layout.lines.map(\.maxLines), [1, 1])
    }

    // Builds that stored one body template still appended the excerpt when
    // delivering, so the second line is what keeps those banners unchanged.
    @MainActor
    func testASingleStoredBodyTemplateReadsWithAnExcerptLine() {
        let defaults = makeDefaults()
        let stored = """
        {
          "lines": [],
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

        XCTAssertEqual(
            layout.notification.body.map(\.template.source),
            ["{herdr.agent.agent}", "{excerpt}"]
        )
    }

    // A suite per test keeps the machine's own settings out of reach.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "RowLayoutSettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // The teardown block captures the Sendable suiteName only; sending the
        // UserDefaults instance itself raises SendingRisksDataRace.
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
