import Foundation
import XCTest
@testable import Shepherd

final class HerdrRawSnapshotTests: XCTestCase {
    // herdr revisions run past 2^53, where a Double decode would come back one short.
    func testRevisionBeyondDoublePrecisionKeepsEveryDigit() throws {
        let responseLine = Data(
            #"""
            {
              "id": "snapshot-1",
              "result": {
                "type": "session_snapshot",
                "snapshot": {
                  "agents": [
                    {
                      "pane_id": "w1:p1",
                      "workspace_id": "w1",
                      "revision": 9007199254740993
                    }
                  ]
                }
              }
            }
            """#.utf8
        )

        let raw = try HerdrRawSnapshot.decode(responseLine: responseLine)

        XCTAssertEqual(
            raw.agents["w1:p1"]?["revision"]?.templateText,
            "9007199254740993"
        )
    }
}
