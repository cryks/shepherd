// Pins numeric fidelity through the raw decode. herdr pane revisions run past
// 2^53, where Double stops representing consecutive integers, so a value that
// took the floating-point branch would come back one short and
// `{herdr.agent.revision}` would name a revision that never existed.
//
// Not exercised here: key spelling and record indexing, which HerdrProtocolTests
// pins on the full protocol fixture.

import Foundation
import XCTest
@testable import Shepherd

final class HerdrRawSnapshotTests: XCTestCase {
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
