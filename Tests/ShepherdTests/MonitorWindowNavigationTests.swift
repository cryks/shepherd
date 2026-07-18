// Verifies the handoff contract between notification action routing and the
// singleton Monitor scene. The tests exercise revision signaling independently
// from SwiftUI window presentation and ensure a row target survives a brief
// closing/opening overlap without outliving its handoff lease.

import XCTest
@testable import Shepherd

final class MonitorWindowNavigationTests: XCTestCase {
    @MainActor
    func testOpenOnlyRequestStillAdvancesTheRevision() {
        let navigation = MonitorWindowNavigation()

        navigation.open()
        XCTAssertEqual(navigation.openRevision, 1)
        XCTAssertNil(navigation.currentRevealRequest())

        navigation.open()
        XCTAssertEqual(navigation.openRevision, 2)
    }

    @MainActor
    func testRevealTargetRemainsReadableDuringTheHandoffLease() {
        let navigation = MonitorWindowNavigation()
        let target = SourcePaneID(sourceID: .local, paneID: "w1:p1")

        navigation.open(revealing: target)

        XCTAssertEqual(navigation.currentRevealRequest()?.paneID, target)
        XCTAssertEqual(navigation.currentRevealRequest()?.paneID, target)
    }

    @MainActor
    func testRepeatedTargetStillProducesDistinctOpenRequests() {
        let navigation = MonitorWindowNavigation()
        let target = SourcePaneID(sourceID: .local, paneID: "w1:p1")

        navigation.open(revealing: target)
        let firstRevision = navigation.openRevision
        navigation.open(revealing: target)

        XCTAssertEqual(navigation.openRevision, firstRevision + 1)
        XCTAssertEqual(navigation.currentRevealRequest()?.paneID, target)
    }

    @MainActor
    func testLatestTargetReplacesAnOlderTarget() {
        let navigation = MonitorWindowNavigation()
        let first = SourcePaneID(sourceID: .local, paneID: "w1:p1")
        let second = SourcePaneID(sourceID: .local, paneID: "w1:p2")

        navigation.open(revealing: first)
        navigation.open(revealing: second)

        XCTAssertEqual(navigation.currentRevealRequest()?.paneID, second)
    }

    @MainActor
    func testOpenOnlyRequestClearsAnOlderReveal() {
        let navigation = MonitorWindowNavigation()
        let target = SourcePaneID(sourceID: .local, paneID: "w1:p1")

        navigation.open(revealing: target)
        navigation.open()

        XCTAssertNil(navigation.currentRevealRequest())
    }

    @MainActor
    func testRevealExpiresAfterTheHandoffLease() async throws {
        let navigation = MonitorWindowNavigation(
            revealHandoffDuration: .milliseconds(1)
        )
        let target = SourcePaneID(sourceID: .local, paneID: "w1:p1")

        navigation.open(revealing: target)
        try await Task.sleep(for: .milliseconds(20))

        XCTAssertNil(navigation.currentRevealRequest())
    }
}
