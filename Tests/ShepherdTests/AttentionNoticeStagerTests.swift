import Foundation
import Observation
import XCTest
@testable import Shepherd

@MainActor
final class AttentionNoticeStagerTests: XCTestCase {
    private let paneID = SourcePaneID(sourceID: .local, paneID: "w1:p1")

    func testNilExcerptLookupPassesDeliverThroughInBatchOrder() {
        let fixture = ExcerptStateFixture()
        let sink = EffectSink()
        let stager = makeStager(fixture: fixture, sink: sink)
        let notice = makeNotice()
        let otherID = AttentionNotificationID(rawValue: "attention.v1.other")

        stager.apply([.deliver(notice), .remove(otherID)])

        XCTAssertEqual(sink.batches, [[.deliver(notice), .remove(otherID)]])
    }

    func testFreshExcerptReleasesHeldNoticeWithAppendedBodyLine() async {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .loading
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .seconds(10)
        )

        stager.apply([.deliver(makeNotice())])
        XCTAssertTrue(sink.batches.isEmpty)

        let released = expectation(description: "released on fresh excerpt")
        sink.onBatch = { released.fulfill() }
        fixture.states[paneID] = .available(excerpt("May I edit main.swift?"))
        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(sink.batches, [[
            .deliver(makeNotice(body: "codex · main\nMay I edit main.swift?")),
        ]])
    }

    func testStagedTextIsNotFreshAndALaterChangeReleases() async {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .available(excerpt("previous answer"))
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .seconds(10)
        )

        stager.apply([.deliver(makeNotice())])
        // Re-setting the same text is not a change, so nothing may release.
        fixture.states[paneID] = .available(excerpt("previous answer"))
        await drainMainActor()
        XCTAssertTrue(sink.batches.isEmpty)

        let released = expectation(description: "released on changed excerpt")
        sink.onBatch = { released.fulfill() }
        fixture.states[paneID] = .available(excerpt("Continue with the merge?"))
        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(sink.batches, [[
            .deliver(makeNotice(body: "codex · main\nContinue with the merge?")),
        ]])
    }

    func testHoldExpiryReleasesWithCurrentlyAvailableExcerpt() async {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .available(excerpt("settled final message"))
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .milliseconds(50)
        )

        let released = expectation(description: "released on hold expiry")
        sink.onBatch = { released.fulfill() }
        stager.apply([.deliver(makeNotice())])
        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(sink.batches, [[
            .deliver(makeNotice(body: "codex · main\nsettled final message")),
        ]])
    }

    // A render returning nil models a pane that left the snapshot.
    func testRenderDecliningLeavesTheStagedNotice() async {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .available(excerpt("May I edit main.swift?"))
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .milliseconds(50),
            render: { _, _ in nil }
        )

        let released = expectation(description: "released on hold expiry")
        sink.onBatch = { released.fulfill() }
        stager.apply([.deliver(makeNotice())])
        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(sink.batches, [[.deliver(makeNotice())]])
    }

    func testHoldExpiryWithoutAvailableExcerptReleasesUnchangedBody() async {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .loading
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .milliseconds(50)
        )

        let released = expectation(description: "released on hold expiry")
        sink.onBatch = { released.fulfill() }
        stager.apply([.deliver(makeNotice())])
        await fulfillment(of: [released], timeout: 2)

        XCTAssertEqual(sink.batches, [[.deliver(makeNotice())]])
    }

    func testRemoveCancelsHeldDeliverAndPassesThrough() async throws {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .loading
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .milliseconds(50)
        )
        let notice = makeNotice()

        stager.apply([.deliver(notice)])
        stager.apply([.remove(notice.id)])
        XCTAssertEqual(sink.batches, [[.remove(notice.id)]])

        fixture.states[paneID] = .available(excerpt("too late"))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.batches, [[.remove(notice.id)]])
    }

    func testRemoveAllCancelsEveryHeldDeliver() async throws {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .loading
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .milliseconds(50)
        )

        stager.apply([.deliver(makeNotice())])
        stager.apply([.removeAll])
        XCTAssertEqual(sink.batches, [[.removeAll]])

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(sink.batches, [[.removeAll]])
    }

    func testSameIDDeliverReplacesHeldNoticeAndReleasesOnce() async {
        let fixture = ExcerptStateFixture()
        fixture.states[paneID] = .loading
        let sink = EffectSink()
        let stager = makeStager(
            fixture: fixture,
            sink: sink,
            holdDuration: .seconds(10)
        )

        stager.apply([.deliver(makeNotice(title: "🔴 Task"))])
        stager.apply([.deliver(makeNotice(title: "🟢 Task"))])

        let released = expectation(description: "released replacement")
        sink.onBatch = { released.fulfill() }
        fixture.states[paneID] = .available(excerpt("done message"))
        await fulfillment(of: [released], timeout: 2)
        await drainMainActor()

        XCTAssertEqual(sink.batches, [[
            .deliver(makeNotice(
                title: "🟢 Task",
                body: "codex · main\ndone message"
            )),
        ]])
    }

    private func makeStager(
        fixture: ExcerptStateFixture,
        sink: EffectSink,
        holdDuration: Duration = AttentionNoticeStager.defaultHoldDuration,
        render: (@MainActor (AttentionNotice, String) -> AttentionNotice?)? = nil
    ) -> AttentionNoticeStager {
        AttentionNoticeStager(
            excerptState: { fixture.state(for: $0) },
            render: render ?? { Self.appendingExcerpt($0, $1) },
            holdDuration: holdDuration,
            forward: { sink.receive($0) }
        )
    }

    // Marks the body with the excerpt it was handed, which is how the tests
    // tell which excerpt released the notice.
    private static func appendingExcerpt(
        _ notice: AttentionNotice,
        _ excerpt: String
    ) -> AttentionNotice {
        AttentionNotice(
            id: notice.id,
            kind: notice.kind,
            sourcePaneID: notice.sourcePaneID,
            threadIdentifier: notice.threadIdentifier,
            title: notice.title,
            subtitle: notice.subtitle,
            body: notice.body + "\n" + excerpt
        )
    }

    private func makeNotice(
        title: String = "🔴 Task",
        body: String = "codex · main"
    ) -> AttentionNotice {
        AttentionNotice(
            id: AttentionNotificationID(rawValue: "attention.v1.test"),
            kind: .blocked,
            sourcePaneID: paneID,
            threadIdentifier: "thread",
            title: title,
            subtitle: "This Mac · Workspace",
            body: body
        )
    }

    private func excerpt(_ text: String) -> AgentExcerpt {
        AgentExcerpt(
            text: text,
            kind: .response,
            confidence: .medium,
            screenRevision: 1
        )
    }

    // Lets the observation onChange -> MainActor hop settle, so that finding
    // nothing forwarded is a result and not a race.
    private func drainMainActor() async {
        for _ in 0..<8 {
            await Task.yield()
        }
    }
}

// @Observable so the tests drive the same withObservationTracking path the app
// uses against FleetStore. A missing entry models a pane without excerpt
// support, such as the preference being off.
@Observable @MainActor
private final class ExcerptStateFixture {
    var states: [SourcePaneID: AgentExcerptState] = [:]

    func state(for paneID: SourcePaneID) -> AgentExcerptState? {
        states[paneID]
    }
}

@MainActor
private final class EffectSink {
    private(set) var batches: [[AttentionEffect]] = []
    var onBatch: (@MainActor () -> Void)?

    func receive(_ effects: [AttentionEffect]) {
        batches.append(effects)
        onBatch?()
    }
}
