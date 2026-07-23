// Exercises AgentReadMonitor's transaction orchestration without opening a
// Herdr socket. Each scripted observation preserves the production
// agent.get -> agent.read -> agent.get boundary, while explicit gates expose
// verification and cancellation states that cannot be asserted after a fully
// synchronous response.

import Foundation
import XCTest
@testable import Shepherd

final class AgentReadMonitorTests: XCTestCase {
    private let paneID = "w1:p1"
    private let terminalID = "terminal-1"

    @MainActor
    func testCoherentTransactionRunsBracketedReadAndPublishesExcerpt() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 10,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let published = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Checking extraction paths"
        }
        XCTAssertTrue(published)
        let calls = await script.recordedCalls()
        XCTAssertEqual(
            calls,
            [
                .get(paneID),
                .readVisible(paneID),
                .get(paneID),
            ]
        )
    }

    @MainActor
    func testSupportedRecordIsLoadingUntilFirstCoherentWorkingRead() async {
        let readGate = AsyncGate()
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 10,
                text: TerminalScreens.codexWorking,
                readGate: readGate
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let readStarted = await waitForReadCalls(1, in: script)
        XCTAssertTrue(readStarted)
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)

        await readGate.open()

        let expected = AgentExcerpt(
            text: "Checking extraction paths",
            kind: .activity,
            confidence: .medium,
            screenRevision: 10
        )
        let published = await waitUntil {
            monitor.excerptState(for: self.paneID) == .available(expected)
        }
        XCTAssertTrue(published)
    }

    @MainActor
    func testCoherentWorkingScreenWithoutExcerptBecomesEmpty() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 11,
                text: TerminalScreens.codexChromeOnly
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 11)])

        let completed = await waitForCompletedTransactions(1, in: script)
        XCTAssertTrue(completed)
        XCTAssertEqual(monitor.excerptState(for: paneID), .empty)
    }

    @MainActor
    func testZeroReadRevisionPublishesWhenBracketRevisionIsCoherent() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 10,
                readRevision: 0,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let published = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Checking extraction paths"
        }
        XCTAssertTrue(
            published,
            "Herdr 0.7.5 reports zero for pane_read.revision even when the " +
                "bracketing agent_info revision is coherent"
        )
        XCTAssertEqual(monitor.excerpt(for: paneID)?.kind, .activity)
        XCTAssertEqual(monitor.excerpt(for: paneID)?.screenRevision, 10)
        let completed = await script.completedTransactionCount()
        XCTAssertEqual(completed, 1)
    }

    @MainActor
    func testReadRevisionIsOpaqueToAgentInfoBracket() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 10,
                readRevision: 900,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let published = await waitUntil {
            monitor.excerpt(for: self.paneID)?.screenRevision == 10
        }
        XCTAssertTrue(published)
    }

    @MainActor
    func testChangingAgentInfoRevisionRejectsRead() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 10,
                afterRevision: 11,
                readRevision: 0,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let completed = await waitForCompletedTransactions(1, in: script)
        XCTAssertTrue(completed)
        XCTAssertNil(monitor.excerpt(for: paneID))
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)
    }

    @MainActor
    func testFailedReadPreservesLoadingState() async {
        let script = ScriptedAgentReads([])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let failed = await waitForScriptState {
            await script.getCallCount() == 1
        }
        XCTAssertTrue(failed)
        await drainMainActor()
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)
    }

    @MainActor
    func testRepeatedUnchangedSnapshotRefreshesWorkingContent() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 12,
                text: TerminalScreens.codexWorking
            ),
            transaction(
                status: .working,
                revision: 12,
                text: TerminalScreens.codexWorkingAfterResume
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        let unchangedPane = pane(status: .working, revision: 12)
        monitor.update(panes: [unchangedPane])

        let initialPublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Checking extraction paths"
        }
        XCTAssertTrue(initialPublished)

        monitor.update(panes: [unchangedPane])

        let refreshed = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Rebuilding post-resume state"
        }
        XCTAssertTrue(
            refreshed,
            "A working pane past its read interval must be observed again " +
                "even when pane metadata is unchanged"
        )
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(readCallCount, 2)
    }

    @MainActor
    func testUnsupportedAgentMakesNoReadCalls() async {
        let script = ScriptedAgentReads([])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [
            pane(
                agent: "opencode",
                status: .working,
                revision: 10
            ),
        ])
        await drainMainActor()

        let calls = await script.recordedCalls()
        XCTAssertEqual(calls, [])
        XCTAssertNil(monitor.excerpt(for: paneID))
    }

    @MainActor
    func testStatusRacePublishesNoExcerpt() async {
        let script = ScriptedAgentReads([
            transaction(
                beforeStatus: .working,
                afterStatus: .done,
                revision: 11,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let completed = await waitForCompletedTransactions(1, in: script)
        XCTAssertTrue(completed)
        await drainMainActor()

        XCTAssertNil(monitor.excerpt(for: paneID))
    }

    @MainActor
    func testStateChangeSequenceABAResetsPublishedExcerpt() async {
        let script = ScriptedAgentReads([
            transaction(status: .working, revision: 10, text: TerminalScreens.codexWorking),
            transaction(
                beforeStatus: .working,
                afterStatus: .working,
                revision: 11,
                beforeStateChangeSequence: 1,
                afterStateChangeSequence: 2,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])

        let initialExcerpt = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text == "Checking extraction paths"
        }
        XCTAssertTrue(initialExcerpt)

        monitor.update(panes: [pane(status: .working, revision: 11)])
        let completed = await waitForCompletedTransactions(2, in: script)
        XCTAssertTrue(completed)
        await drainMainActor()

        XCTAssertNil(monitor.excerpt(for: paneID))
    }

    @MainActor
    func testSameRevisionCompletionUsesAcceleratedVerification() async {
        let verificationGate = AsyncGate()
        let script = ScriptedAgentReads([
            transaction(status: .working, revision: 20, text: TerminalScreens.codexWorking),
            transaction(status: .done, revision: 21, text: TerminalScreens.codexCompleted),
            transaction(
                status: .done,
                revision: 21,
                text: TerminalScreens.codexCompleted,
                readGate: verificationGate
            ),
        ])
        let monitor = makeMonitor(script, verificationDelay: .zero)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 20)])
        let workingPublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.kind == .activity
        }
        XCTAssertTrue(workingPublished)

        monitor.update(panes: [pane(status: .done, revision: 21)])
        let verificationStarted = await waitForReadCalls(3, in: script)
        XCTAssertTrue(verificationStarted)
        XCTAssertNil(
            monitor.excerpt(for: paneID),
            "The first settled frame must not publish a response"
        )

        await verificationGate.open()

        let responsePublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Preview now keeps the latest completed reply while tools are running."
        }
        XCTAssertTrue(responsePublished)
        XCTAssertEqual(monitor.excerpt(for: paneID)?.kind, .response)
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(readCallCount, 3)
    }

    @MainActor
    func testInitialIdleResponseUsesAcceleratedVerification() async {
        let verificationGate = AsyncGate()
        let script = ScriptedAgentReads([
            transaction(
                status: .idle,
                revision: 22,
                text: TerminalScreens.codexCompleted
            ),
            transaction(
                status: .idle,
                revision: 22,
                text: TerminalScreens.codexCompleted,
                readGate: verificationGate
            ),
        ])
        let monitor = makeMonitor(script, verificationDelay: .zero)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .idle, revision: 22)])

        let verificationStarted = await waitForReadCalls(2, in: script)
        XCTAssertTrue(verificationStarted)
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)

        await verificationGate.open()

        let responsePublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Preview now keeps the latest completed reply while tools are running."
        }
        XCTAssertTrue(responsePublished)
        XCTAssertEqual(monitor.excerpt(for: paneID)?.kind, .response)
        XCTAssertEqual(
            monitor.excerptState(for: paneID),
            .available(AgentExcerpt(
                text: "Preview now keeps the latest completed reply while tools are running.",
                kind: .response,
                confidence: .medium,
                screenRevision: 22
            ))
        )
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(readCallCount, 2)
    }

    @MainActor
    func testInitialIdleChromeOnlyScreenBecomesEmptyWithoutVerification() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .idle,
                revision: 23,
                text: TerminalScreens.codexChromeOnly
            ),
        ])
        let monitor = makeMonitor(script, verificationDelay: .zero)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .idle, revision: 23)])

        // No message candidate exists, so there is nothing to verify: one
        // coherent read completes the observation as empty.
        let completed = await waitForCompletedTransactions(1, in: script)
        XCTAssertTrue(completed)
        await drainMainActor()
        XCTAssertEqual(monitor.excerptState(for: paneID), .empty)
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(readCallCount, 1)
    }

    @MainActor
    func testSourceResetDropsStoredExcerptState() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 24,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }
        monitor.update(panes: [
            pane(status: .working, revision: 24),
        ])
        let published = await waitUntil {
            if case .available = monitor.excerptState(for: self.paneID) {
                return true
            }
            return false
        }
        XCTAssertTrue(published)

        monitor.sourceUnavailable()
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)
    }

    @MainActor
    func testWorkingPaneIsNotReReadWithinReadInterval() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 25,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script, policy: {
            AgentReadPolicy(isEnabled: true, readInterval: .seconds(3600))
        })
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 25)])
        let completed = await waitForCompletedTransactions(1, in: script)
        XCTAssertTrue(completed)

        monitor.update(panes: [pane(status: .working, revision: 25)])
        await drainMainActor()

        let readCallCount = await script.readCallCount()
        XCTAssertEqual(
            readCallCount,
            1,
            "an unchanged working pane re-read before its interval elapsed"
        )
    }

    @MainActor
    func testStatusChangeTriggersImmediateReadDespiteReadInterval() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 26,
                text: TerminalScreens.codexWorking
            ),
            transaction(
                status: .done,
                revision: 27,
                text: TerminalScreens.codexCompleted
            ),
            transaction(
                status: .done,
                revision: 27,
                text: TerminalScreens.codexCompleted
            ),
        ])
        let monitor = makeMonitor(
            script,
            verificationDelay: .zero,
            policy: {
                AgentReadPolicy(isEnabled: true, readInterval: .seconds(3600))
            }
        )
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 26)])
        let workingRead = await waitForCompletedTransactions(1, in: script)
        XCTAssertTrue(workingRead)

        monitor.update(panes: [pane(status: .done, revision: 27)])

        let responsePublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Preview now keeps the latest completed reply while tools are running."
        }
        XCTAssertTrue(
            responsePublished,
            "a status change must read immediately, and its verification " +
                "follow-up must run without another snapshot tick"
        )
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(readCallCount, 3)
    }

    @MainActor
    func testDisabledPolicyMakesNoReadCalls() async {
        let script = ScriptedAgentReads([])
        let monitor = makeMonitor(script, policy: {
            AgentReadPolicy(isEnabled: false, readInterval: .zero)
        })
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 10)])
        await drainMainActor()

        let calls = await script.recordedCalls()
        XCTAssertEqual(calls, [])
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)
    }

    @MainActor
    func testDisablingPolicyDropsTheCacheOnTheNextSnapshot() async {
        let policyBox = PolicyBox(
            AgentReadPolicy(isEnabled: true, readInterval: .zero)
        )
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 11,
                text: TerminalScreens.codexWorking
            ),
        ])
        let monitor = makeMonitor(script, policy: { policyBox.policy })
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 11)])
        let published = await waitUntil {
            monitor.excerpt(for: self.paneID) != nil
        }
        XCTAssertTrue(published)

        policyBox.policy.isEnabled = false
        monitor.update(panes: [pane(status: .working, revision: 11)])

        XCTAssertNil(monitor.excerpt(for: paneID))
        XCTAssertEqual(monitor.excerptState(for: paneID), .loading)
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(
            readCallCount,
            1,
            "a disabled snapshot tick issued a terminal-content read"
        )
    }

    @MainActor
    func testStoppingDuringNonCooperativeReadClearsAndRejectsLateText() async {
        let blockedRead = AsyncGate()
        let lateScreen = TerminalScreens.codexCompleted + "\nlate raw terminal text"
        let script = ScriptedAgentReads([
            transaction(status: .working, revision: 30, text: TerminalScreens.codexWorking),
            transaction(
                status: .working,
                revision: 31,
                text: lateScreen,
                readGate: blockedRead
            ),
        ])
        let monitor = makeMonitor(script)

        monitor.update(panes: [pane(status: .working, revision: 30)])
        let initialPublished = await waitUntil {
            monitor.excerpt(for: self.paneID) != nil
        }
        XCTAssertTrue(initialPublished)

        monitor.update(panes: [pane(status: .working, revision: 31)])
        let blocked = await waitForReadCalls(2, in: script)
        XCTAssertTrue(blocked)

        monitor.stop()
        XCTAssertNil(monitor.excerpt(for: paneID))

        await blockedRead.open()
        let returned = await waitForReturnedReads(2, in: script)
        XCTAssertTrue(returned)
        await drainMainActor()

        XCTAssertNil(monitor.excerpt(for: paneID))
        let getCallCount = await script.getCallCount()
        XCTAssertEqual(
            getCallCount,
            3,
            "A cancelled late read must not start its closing agent.get"
        )
    }

    @MainActor
    func testNativeSessionReplacementClearsPriorExcerpt() async {
        let firstSession = session("session-a")
        let replacementSession = session("session-b")
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 40,
                text: TerminalScreens.codexWorking,
                agentSession: firstSession
            ),
            transaction(
                status: .idle,
                revision: 41,
                text: TerminalScreens.codexCompleted,
                agentSession: replacementSession
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 40)])
        let initialExcerpt = await waitUntil {
            monitor.excerpt(for: self.paneID)?.kind == .activity
        }
        XCTAssertTrue(initialExcerpt)

        monitor.update(panes: [pane(status: .idle, revision: 41)])
        let completed = await waitForCompletedTransactions(2, in: script)
        XCTAssertTrue(completed)
        await drainMainActor()

        XCTAssertNil(monitor.excerpt(for: paneID))
    }

    @MainActor
    func testTerminalReplacementStartsAFreshExcerptLifecycle() async {
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 45,
                text: TerminalScreens.codexWorking
            ),
            transaction(
                status: .working,
                revision: 46,
                text: TerminalScreens.codexWorkingAfterResume,
                terminal: "terminal-2"
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 45)])
        let initialPublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Checking extraction paths"
        }
        XCTAssertTrue(initialPublished)

        monitor.update(panes: [
            pane(
                status: .working,
                revision: 46,
                terminal: "terminal-2"
            ),
        ])
        XCTAssertEqual(
            monitor.excerptState(for: paneID),
            .loading,
            "a replacement terminal inherited the previous occupant's excerpt"
        )

        let replacementPublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Rebuilding post-resume state"
        }
        XCTAssertTrue(replacementPublished)
    }

    @MainActor
    func testResumeDropsScreenEvidenceAndRefillsExcerpt() async {
        let resumedRead = AsyncGate()
        let script = ScriptedAgentReads([
            transaction(
                status: .working,
                revision: 50,
                text: TerminalScreens.codexWorking
            ),
            transaction(
                status: .working,
                revision: 51,
                text: TerminalScreens.codexWorkingAfterResume,
                readGate: resumedRead
            ),
        ])
        let monitor = makeMonitor(script)
        defer { monitor.stop() }

        monitor.update(panes: [pane(status: .working, revision: 50)])

        let initialPublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Checking extraction paths"
        }
        XCTAssertTrue(initialPublished)

        monitor.suspend()
        monitor.update(panes: [pane(status: .working, revision: 51)])
        monitor.resume()

        let resumedReadStarted = await waitForReadCalls(2, in: script)
        XCTAssertTrue(resumedReadStarted)
        XCTAssertNil(monitor.excerpt(for: paneID))

        await resumedRead.open()

        let resumedPublished = await waitUntil {
            monitor.excerpt(for: self.paneID)?.text ==
                "Rebuilding post-resume state"
        }
        XCTAssertTrue(
            resumedPublished,
            "resume did not refill the excerpt from a fresh coherent read"
        )
        let readCallCount = await script.readCallCount()
        XCTAssertEqual(readCallCount, 2)
    }

    /// The policy defaults to enabled with a zero interval so scripted tests
    /// keep the read-per-snapshot behavior; cadence tests pass an hour to
    /// observe the suppression side, and preference tests flip enablement.
    @MainActor
    private func makeMonitor(
        _ script: ScriptedAgentReads,
        verificationDelay: Duration = .zero,
        policy: @escaping @MainActor () -> AgentReadPolicy = {
            AgentReadPolicy(isEnabled: true, readInterval: .zero)
        }
    ) -> AgentReadMonitor {
        AgentReadMonitor(
            dataSource: AgentReadDataSource(
                get: { target in
                    try await script.get(target)
                },
                readVisible: { target in
                    try await script.readVisible(target)
                }
            ),
            verificationDelay: verificationDelay,
            policy: policy
        )
    }

    private func pane(
        agent: String = "codex",
        status: AgentStatus,
        revision: UInt64,
        terminal: String? = nil
    ) -> Pane {
        Pane(
            agent: agent,
            agentStatus: status,
            paneId: paneID,
            workspaceId: "w1",
            terminalId: terminal ?? terminalID,
            revision: revision,
            terminalTitleStripped: "Preview task",
            tokens: PaneTokens(agentKind: "primary")
        )
    }

    private func transaction(
        status: AgentStatus,
        revision: UInt64,
        afterRevision: UInt64? = nil,
        readRevision: UInt64? = nil,
        text: String,
        agentSession: HerdrAgentSession? = nil,
        readGate: AsyncGate? = nil,
        terminal: String? = nil
    ) -> ScriptedTransaction {
        transaction(
            beforeStatus: status,
            afterStatus: status,
            revision: revision,
            beforeStateChangeSequence: 1,
            afterStateChangeSequence: 1,
            afterRevision: afterRevision,
            readRevision: readRevision,
            text: text,
            agentSession: agentSession,
            readGate: readGate,
            terminal: terminal
        )
    }

    private func transaction(
        beforeStatus: AgentStatus,
        afterStatus: AgentStatus,
        revision: UInt64,
        beforeStateChangeSequence: UInt64 = 1,
        afterStateChangeSequence: UInt64 = 1,
        afterRevision: UInt64? = nil,
        readRevision: UInt64? = nil,
        text: String,
        agentSession: HerdrAgentSession? = nil,
        readGate: AsyncGate? = nil,
        terminal: String? = nil
    ) -> ScriptedTransaction {
        ScriptedTransaction(
            before: agentInfo(
                status: beforeStatus,
                revision: revision,
                stateChangeSequence: beforeStateChangeSequence,
                agentSession: agentSession,
                terminal: terminal
            ),
            read: AgentReadResult(read: PaneRead(
                paneId: paneID,
                workspaceId: "w1",
                tabId: "w1:t1",
                source: .visible,
                format: .text,
                text: text,
                revision: readRevision ?? revision,
                truncated: false
            )),
            after: agentInfo(
                status: afterStatus,
                revision: afterRevision ?? revision,
                stateChangeSequence: afterStateChangeSequence,
                agentSession: agentSession,
                terminal: terminal
            ),
            readGate: readGate
        )
    }

    private func agentInfo(
        status: AgentStatus,
        revision: UInt64,
        stateChangeSequence: UInt64,
        agentSession: HerdrAgentSession?,
        terminal: String?
    ) -> AgentGetResult {
        AgentGetResult(agent: HerdrAgentInfo(
            agent: "codex",
            agentStatus: status,
            paneId: paneID,
            workspaceId: "w1",
            tabId: "w1:t1",
            terminalId: terminal ?? terminalID,
            revision: revision,
            stateChangeSeq: stateChangeSequence,
            agentSession: agentSession
        ))
    }

    private func session(_ value: String) -> HerdrAgentSession {
        HerdrAgentSession(
            source: "herdr:codex",
            agent: "codex",
            kind: .id,
            value: value
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @MainActor
    private func waitForCompletedTransactions(
        _ expected: Int,
        in script: ScriptedAgentReads
    ) async -> Bool {
        await waitForScriptState {
            await script.completedTransactionCount() >= expected
        }
    }

    @MainActor
    private func waitForReadCalls(
        _ expected: Int,
        in script: ScriptedAgentReads
    ) async -> Bool {
        await waitForScriptState {
            await script.readCallCount() >= expected
        }
    }

    @MainActor
    private func waitForReturnedReads(
        _ expected: Int,
        in script: ScriptedAgentReads
    ) async -> Bool {
        await waitForScriptState {
            await script.returnedReadCount() >= expected
        }
    }

    @MainActor
    private func waitForScriptState(
        timeout: Duration = .seconds(1),
        condition: @MainActor () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return await condition()
    }

    @MainActor
    private func drainMainActor() async {
        for _ in 0..<20 {
            await Task<Never, Never>.yield()
        }
    }
}

/// Mutable policy holder for tests that flip the excerpt preference between
/// snapshot ticks.
@MainActor
private final class PolicyBox {
    var policy: AgentReadPolicy

    init(_ policy: AgentReadPolicy) {
        self.policy = policy
    }
}

private struct ScriptedTransaction: Sendable {
    var before: AgentGetResult
    var read: AgentReadResult
    var after: AgentGetResult
    var readGate: AsyncGate?
}

private actor ScriptedAgentReads {
    enum Call: Equatable, Sendable {
        case get(String)
        case readVisible(String)
    }

    private enum Phase {
        case before
        case read
        case after
    }

    private let transactions: [ScriptedTransaction]
    private var transactionIndex = 0
    private var phase = Phase.before
    private var calls: [Call] = []
    private var completedTransactions = 0
    private var readsStarted = 0
    private var readsReturned = 0

    init(_ transactions: [ScriptedTransaction]) {
        self.transactions = transactions
    }

    func get(_ target: String) throws -> AgentGetResult {
        calls.append(.get(target))
        guard transactionIndex < transactions.count else {
            throw ScriptError.unexpectedCall("get(\(target)) after script end")
        }

        switch phase {
        case .before:
            phase = .read
            return transactions[transactionIndex].before
        case .after:
            let result = transactions[transactionIndex].after
            transactionIndex += 1
            completedTransactions += 1
            phase = .before
            return result
        case .read:
            throw ScriptError.unexpectedCall("get(\(target)) before agent.read")
        }
    }

    func readVisible(_ target: String) async throws -> AgentReadResult {
        calls.append(.readVisible(target))
        guard transactionIndex < transactions.count else {
            throw ScriptError.unexpectedCall("agent.read(\(target)) after script end")
        }
        guard case .read = phase else {
            throw ScriptError.unexpectedCall("agent.read(\(target)) outside read phase")
        }

        readsStarted += 1
        let transaction = transactions[transactionIndex]
        phase = .after
        if let readGate = transaction.readGate {
            await readGate.wait()
        }
        readsReturned += 1
        return transaction.read
    }

    func recordedCalls() -> [Call] {
        calls
    }

    func completedTransactionCount() -> Int {
        completedTransactions
    }

    func readCallCount() -> Int {
        readsStarted
    }

    func returnedReadCount() -> Int {
        readsReturned
    }

    func getCallCount() -> Int {
        calls.reduce(into: 0) { count, call in
            if case .get = call {
                count += 1
            }
        }
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let currentWaiters = waiters
        waiters.removeAll()
        currentWaiters.forEach { $0.resume() }
    }
}

private enum ScriptError: Error {
    case unexpectedCall(String)
}

private enum TerminalScreens {
    static let codexWorking = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Checking extraction paths (2s • esc to interrupt)

    › Add preview support

      tab to queue message                         100% context left
    """

    static let codexCompleted = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Preview now keeps the latest completed reply while tools are
      running.

    › Add preview support

      tab to queue message                         98% context left
    """

    static let codexWorkingAfterResume = """
    • Explored
      └ Read Sources/App/Lifecycle.swift

    • Rebuilding post-resume state (1s • esc to interrupt)

    › Add preview support

      tab to queue message                         97% context left
    """

    static let codexChromeOnly = """
    › Add preview support

      tab to queue message                         100% context left
    """
}
