// Pins the screen-derived Excerpt contract with synthetic Codex and Claude
// terminal fixtures. The fixtures reproduce only stable UI structure—message
// markers, tool trees, prompt boxes, and footer chrome—and contain no captured
// session content. Tests exercise the state machine boundary instead of parser
// helpers so status evidence remains part of every published excerpt: the
// newest visible message is cached from a single working read, while settled
// screens must repeat a changed message before it replaces the cache.

import XCTest
@testable import Shepherd

final class CodexAgentExcerptTests: XCTestCase {
    func testWorkingWithoutVisibleMessagePublishesActivity() throws {
        var machine = try makeMachine("codex")

        XCTAssertEqual(
            machine.ingest(input(.working, 20, Fixtures.codexWorking)),
            .replace(excerpt(
                "Checking extraction paths",
                kind: .activity,
                confidence: .medium,
                revision: 20
            ))
        )
        XCTAssertEqual(
            machine.ingest(input(.working, 21, Fixtures.codexWorking)),
            .keep
        )
        XCTAssertEqual(machine.excerpt?.screenRevision, 21)
    }

    func testWorkingPublishesLatestVisibleMessage() throws {
        var machine = try makeMachine("codex")

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                22,
                Fixtures.codexWorkingWithPriorResponse
            )),
            .replace(excerpt(
                "The previous turn left this response visible.",
                kind: .response,
                confidence: .medium,
                revision: 22
            ))
        )
    }

    func testActivityDoesNotReplaceCachedMessage() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(
            .working,
            23,
            Fixtures.codexWorkingWithPriorResponse
        ))

        // The message scrolled out of view; the live status alone must not
        // demote the cached message back to a spinner line.
        XCTAssertEqual(
            machine.ingest(input(.working, 24, Fixtures.codexWorking)),
            .keep
        )
        XCTAssertEqual(
            machine.excerpt?.text,
            "The previous turn left this response visible."
        )
        XCTAssertEqual(machine.excerpt?.kind, .response)
    }

    func testBlockedFormsPublishOnlyTheirQuestion() throws {
        var approvalMachine = try makeMachine("codex")
        XCTAssertEqual(
            approvalMachine.ingest(input(.blocked, 30, Fixtures.codexApproval)),
            .replace(excerpt(
                "Would you like to run the following command?",
                kind: .attention,
                confidence: .high,
                revision: 30
            ))
        )

        var questionMachine = try makeMachine("codex")
        XCTAssertEqual(
            questionMachine.ingest(input(.blocked, 31, Fixtures.codexQuestion)),
            .replace(excerpt(
                "Which preview should appear in the agent list?",
                kind: .attention,
                confidence: .high,
                revision: 31
            ))
        )

        var chromeMachine = try makeMachine("codex")
        XCTAssertEqual(
            chromeMachine.ingest(input(.blocked, 32, Fixtures.codexChromeOnly)),
            .keep
        )
        XCTAssertNil(chromeMachine.excerpt)

        var extensionMachine = try makeMachine("codex")
        XCTAssertEqual(
            extensionMachine.ingest(input(
                .blocked,
                33,
                Fixtures.codexExtensionBlocker
            )),
            .keep
        )
        XCTAssertNil(extensionMachine.excerpt)

        var staleFallbackMachine = try makeMachine("codex")
        XCTAssertEqual(
            staleFallbackMachine.ingest(input(
                .blocked,
                34,
                Fixtures.codexStaleFallbackBlocker
            )),
            .keep
        )
        XCTAssertNil(staleFallbackMachine.excerpt)

        var staleFormMachine = try makeMachine("codex")
        let staleForm = Fixtures.codexApproval + "\nWaiting for permission"
        XCTAssertEqual(
            staleFormMachine.ingest(input(.blocked, 35, staleForm)),
            .keep
        )
        XCTAssertNil(staleFormMachine.excerpt)

        var plainYesMachine = try makeMachine("codex")
        XCTAssertEqual(
            plainYesMachine.ingest(input(
                .blocked,
                36,
                Fixtures.codexPlainYesApproval
            )),
            .replace(excerpt(
                "Allow this command?",
                kind: .attention,
                confidence: .high,
                revision: 36
            ))
        )
    }

    func testQuestionFormWithFullWidthQuestionMarkPublishesItsQuestion() throws {
        var machine = try makeMachine("codex")

        XCTAssertEqual(
            machine.ingest(input(
                .blocked,
                37,
                Fixtures.codexQuestionFullWidth
            )),
            .replace(excerpt(
                "いま食べたい sweet なおやつはどれ？",
                kind: .attention,
                confidence: .high,
                revision: 37
            ))
        )
    }

    func testSettledReplacementRequiresTwoStableReads() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(.working, 20, Fixtures.codexWorking))

        XCTAssertEqual(
            machine.ingest(input(.done, 21, Fixtures.codexCompleted)),
            .remove
        )
        XCTAssertNil(machine.excerpt)
        XCTAssertTrue(machine.requiresVerificationRead)

        let response = excerpt(
            "Preview now keeps the latest completed reply while tools are running.",
            kind: .response,
            confidence: .medium,
            revision: 21
        )
        XCTAssertEqual(
            machine.ingest(input(.idle, 21, Fixtures.codexCompleted)),
            .replace(response)
        )
        XCTAssertEqual(machine.excerpt, response)
        XCTAssertFalse(machine.requiresVerificationRead)

        XCTAssertEqual(
            machine.ingest(input(.idle, 22, Fixtures.codexChromeOnly)),
            .keep
        )
        XCTAssertEqual(machine.excerpt, response)
    }

    func testInitialSettledScreenBootstrapsAfterTwoReads() throws {
        for status in [AgentStatus.idle, .done] {
            var machine = try makeMachine("codex")
            let revision: UInt64 = status == .idle ? 130 : 131

            XCTAssertEqual(
                machine.ingest(input(status, revision, Fixtures.codexCompleted)),
                .keep
            )
            XCTAssertNil(machine.excerpt)
            XCTAssertTrue(machine.requiresVerificationRead)

            XCTAssertEqual(
                machine.ingest(input(status, revision, Fixtures.codexCompleted)),
                .replace(excerpt(
                    "Preview now keeps the latest completed reply while tools are running.",
                    kind: .response,
                    confidence: .medium,
                    revision: revision
                ))
            )
            XCTAssertFalse(machine.requiresVerificationRead)
        }
    }

    func testToolOnlySettledTurnKeepsCachedMessage() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(
            .working,
            50,
            Fixtures.codexWorkingWithPriorResponse
        ))
        let accepted = try XCTUnwrap(machine.excerpt)

        // The message is still visible above the tool history: no change.
        XCTAssertEqual(
            machine.ingest(input(
                .done,
                51,
                Fixtures.codexToolOnlyWithPriorResponse
            )),
            .keep
        )
        XCTAssertFalse(machine.requiresVerificationRead)

        // The message scrolled out of view entirely: the cache remains.
        XCTAssertEqual(
            machine.ingest(input(.idle, 52, Fixtures.codexToolOnly)),
            .keep
        )
        XCTAssertEqual(machine.excerpt, accepted)
    }

    func testRevisionRegressionClearsCachedMessage() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(
            .working,
            60,
            Fixtures.codexWorkingWithPriorResponse
        ))
        XCTAssertNotNil(machine.excerpt)

        XCTAssertEqual(
            machine.ingest(input(.idle, 1, Fixtures.codexChromeOnly)),
            .remove
        )
        XCTAssertNil(machine.excerpt)
    }

    func testSuppressedViewerKeepsCache() throws {
        var freshMachine = try makeMachine("codex")
        XCTAssertEqual(
            freshMachine.ingest(input(
                .working,
                69,
                Fixtures.codexTranscriptViewer
            )),
            .keep
        )
        XCTAssertNil(freshMachine.excerpt)

        var cachedMachine = try makeMachine("codex")
        _ = cachedMachine.ingest(input(
            .working,
            70,
            Fixtures.codexWorkingWithPriorResponse
        ))
        XCTAssertEqual(
            cachedMachine.ingest(input(
                .working,
                71,
                Fixtures.codexTranscriptViewer
            )),
            .keep
        )
        XCTAssertEqual(
            cachedMachine.excerpt?.text,
            "The previous turn left this response visible."
        )
    }

    func testSystemCellsAreNotMessages() throws {
        var machine = try makeMachine("codex")

        XCTAssertEqual(
            machine.ingest(input(.idle, 68, Fixtures.codexSystemCells)),
            .keep
        )
        XCTAssertEqual(
            machine.ingest(input(.idle, 68, Fixtures.codexSystemCells)),
            .keep
        )
        XCTAssertNil(machine.excerpt)
        XCTAssertFalse(machine.requiresVerificationRead)
    }

    func testNewestGenericLiveStatusDoesNotFallBackToOlderStatusBlock()
        throws
    {
        for (offset, title) in ["Working", "Thinking"].enumerated() {
            var machine = try makeMachine("codex")
            let revision = UInt64(134 + offset)

            XCTAssertEqual(
                machine.ingest(input(
                    .working,
                    revision,
                    Fixtures.codexGenericLiveStatus(title)
                )),
                .replace(excerpt(
                    title,
                    kind: .activity,
                    confidence: .medium,
                    revision: revision
                ))
            )
        }
    }

    func testNarrowStatusIsActivityAndSearchCellsDoNotHideTheFinalMessage() throws {
        var machine = try makeMachine("codex")
        XCTAssertEqual(
            machine.ingest(input(.working, 78, Fixtures.codexNarrowWorking)),
            .replace(excerpt(
                "Investigating rendering code",
                kind: .activity,
                confidence: .medium,
                revision: 78
            ))
        )
        _ = machine.ingest(input(.done, 79, Fixtures.codexSearchedThenFinal))
        XCTAssertEqual(
            machine.ingest(input(.idle, 79, Fixtures.codexSearchedThenFinal)),
            .replace(excerpt(
                "Final response.",
                kind: .response,
                confidence: .medium,
                revision: 79
            ))
        )
    }

    func testStatusLikeProseWithoutDurationMetadataRemainsAMessage() throws {
        var machine = try makeMachine("codex")

        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                136,
                Fixtures.codexStatusLikeResponse
            )),
            .keep
        )
        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                136,
                Fixtures.codexStatusLikeResponse
            )),
            .replace(excerpt(
                "Explain this hint (press Esc to interrupt)",
                kind: .response,
                confidence: .medium,
                revision: 136
            ))
        )
    }

    func testViewerShortcutVocabularyCanBeMessageText() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(
            .idle,
            83,
            Fixtures.codexViewerVocabularyResponse
        ))

        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                83,
                Fixtures.codexViewerVocabularyResponse
            )),
            .replace(excerpt(
                "Document ↑/↓ to scroll, pgup/pgdn to page, home/end to jump, and q to quit.",
                kind: .response,
                confidence: .medium,
                revision: 83
            ))
        )
    }

    func testBlockerWordsInsideAMessageRemainMessageText() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(.idle, 41, Fixtures.codexBlockerWordsResponse))

        XCTAssertEqual(
            machine.ingest(input(.idle, 41, Fixtures.codexBlockerWordsResponse)),
            .replace(excerpt(
                "Treat “Press enter to confirm or esc to cancel” as normal prose unless the agent is blocked.",
                kind: .response,
                confidence: .medium,
                revision: 41
            ))
        )
    }

    func testVerbLeadingProseIsAMessage() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(.idle, 68, Fixtures.codexVerbResponse))

        XCTAssertEqual(
            machine.ingest(input(.idle, 68, Fixtures.codexVerbResponse)),
            .replace(excerpt(
                "Working with remote panes requires an endpoint-scoped reader.",
                kind: .response,
                confidence: .medium,
                revision: 68
            ))
        )
    }

    func testStreamingStatusPhraseCanBeASettledMessage() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(.idle, 81, Fixtures.codexStreamingResponse))

        XCTAssertEqual(
            machine.ingest(input(.idle, 81, Fixtures.codexStreamingResponse)),
            .replace(excerpt(
                "Streaming response.",
                kind: .response,
                confidence: .medium,
                revision: 81
            ))
        )
    }

    func testScrolledLongMessagePublishesItsTailParagraph() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(.idle, 90, Fixtures.codexScrolledLongResponse))

        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                90,
                Fixtures.codexScrolledLongResponse
            )),
            .replace(excerpt(
                "Rebuild and reopen the menu to see the fixed height.",
                kind: .response,
                confidence: .medium,
                revision: 90
            ))
        )
    }

    func testIncoherentStatusPairContributesNoEvidence() throws {
        var machine = try makeMachine("codex")
        let incoherent = AgentExcerptInput(
            statusBeforeRead: .working,
            statusAfterRead: .done,
            revision: 84,
            text: Fixtures.codexCompleted
        )

        XCTAssertEqual(machine.ingest(incoherent), .keep)
        XCTAssertNil(machine.excerpt)
        XCTAssertFalse(machine.requiresVerificationRead)
    }

    func testIncoherentPairCancelsPendingVerification() throws {
        var machine = try makeMachine("codex")
        _ = machine.ingest(input(.working, 85, Fixtures.codexWorking))
        _ = machine.ingest(input(.done, 86, Fixtures.codexCompleted))
        XCTAssertTrue(machine.requiresVerificationRead)

        let racedTransition = AgentExcerptInput(
            statusBeforeRead: .working,
            statusAfterRead: .done,
            revision: 87,
            text: Fixtures.codexCompleted
        )
        XCTAssertEqual(machine.ingest(racedTransition), .keep)
        XCTAssertFalse(machine.requiresVerificationRead)

        // Verification restarts from scratch: the next two settled reads are
        // needed again before the candidate becomes the cached message.
        XCTAssertEqual(
            machine.ingest(input(.done, 88, Fixtures.codexCompleted)),
            .keep
        )
        XCTAssertTrue(machine.requiresVerificationRead)
        XCTAssertNil(machine.excerpt)
    }
}

final class ClaudeAgentExcerptTests: XCTestCase {
    func testWorkingPublishesLatestVisibleMessage() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(.working, 70, Fixtures.claudeWorking)),
            .replace(excerpt(
                "Comparing the latest screen with the turn baseline.",
                kind: .response,
                confidence: .medium,
                revision: 70
            ))
        )
    }

    func testStreamedProseUpdatesCacheAndMatchingSettledScreenNeedsNoVerification() throws {
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(.working, 112, Fixtures.claudeWorking))

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                113,
                Fixtures.claudeWorkingWithProgress
            )),
            .replace(excerpt(
                "I found a second terminal layout to inspect.",
                kind: .response,
                confidence: .medium,
                revision: 113
            ))
        )

        // The settled screen shows exactly the cached message, so the display
        // does not flicker and no verification read is requested.
        XCTAssertEqual(
            machine.ingest(input(
                .done,
                114,
                Fixtures.claudeSettledWithProgress
            )),
            .keep
        )
        XCTAssertFalse(machine.requiresVerificationRead)
        XCTAssertEqual(
            machine.excerpt?.text,
            "I found a second terminal layout to inspect."
        )
    }

    func testWorkingWithoutVisibleMessagePublishesSubagentActivity() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                71,
                Fixtures.claudeToolOnlyWithSubagentFooter
            )),
            .replace(excerpt(
                "Inspect terminal layouts",
                kind: .activity,
                confidence: .medium,
                revision: 71
            ))
        )
    }

    func testEverySpinnerFrameGlyphPublishesFooterActivity() throws {
        for (offset, frame) in ["·", "✢", "✳", "✶", "✻", "✽"].enumerated() {
            var machine = try makeMachine("claude")
            let revision = UInt64(140 + offset)

            XCTAssertEqual(
                machine.ingest(input(
                    .working,
                    revision,
                    Fixtures.claudeSpinnerFooter(
                        "\(frame) Whirlpooling… (2m 14s · ↓ 2.8k tokens)"
                    )
                )),
                .replace(excerpt(
                    "Whirlpooling…",
                    kind: .activity,
                    confidence: .medium,
                    revision: revision
                )),
                "frame \(frame)"
            )
        }
    }

    func testFooterWithTrailingThinkingSegmentPublishesActivity() throws {
        for (offset, footer) in [
            "✻ Whirlpooling… (2m 14s · ↓ 2.8k tokens · thought for 104s)",
            "· Whirlpooling… (2m 34s · ↓ 2.8k tokens · almost done thinking with xhigh effort)",
        ].enumerated() {
            var machine = try makeMachine("claude")
            let revision = UInt64(146 + offset)

            XCTAssertEqual(
                machine.ingest(input(
                    .working,
                    revision,
                    Fixtures.claudeSpinnerFooter(footer)
                )),
                .replace(excerpt(
                    "Whirlpooling…",
                    kind: .activity,
                    confidence: .medium,
                    revision: revision
                ))
            )
        }
    }

    func testThinkingSummaryLineIsNotFooterActivity() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                148,
                Fixtures.claudeSpinnerFooter("✻ Cogitated for 1m 29s")
            )),
            .keep
        )
        XCTAssertNil(machine.excerpt)
    }

    func testBlockedFormsPublishOnlyTheirQuestion() throws {
        var permissionMachine = try makeMachine("claude-code")
        XCTAssertEqual(
            permissionMachine.ingest(input(.blocked, 80, Fixtures.claudePermission)),
            .replace(excerpt(
                "Do you want to proceed?",
                kind: .attention,
                confidence: .high,
                revision: 80
            ))
        )

        var selectionMachine = try makeMachine("claude")
        XCTAssertEqual(
            selectionMachine.ingest(input(.blocked, 81, Fixtures.claudeSelection)),
            .replace(excerpt(
                "Choose preview detail",
                kind: .attention,
                confidence: .high,
                revision: 81
            ))
        )

        var repeatedFormMachine = try makeMachine("claude")
        let repeatedForms = Fixtures.claudePermission + "\n" + Fixtures.claudeSelection
        XCTAssertEqual(
            repeatedFormMachine.ingest(input(.blocked, 82, repeatedForms)),
            .replace(excerpt(
                "Choose preview detail",
                kind: .attention,
                confidence: .high,
                revision: 82
            ))
        )

        var chromeMachine = try makeMachine("claude")
        XCTAssertEqual(
            chromeMachine.ingest(input(.blocked, 83, Fixtures.claudeChromeOnly)),
            .keep
        )
        XCTAssertNil(chromeMachine.excerpt)

        var workflowMachine = try makeMachine("claude")
        XCTAssertEqual(
            workflowMachine.ingest(input(
                .blocked,
                84,
                Fixtures.claudeDynamicWorkflow
            )),
            .replace(excerpt(
                "Run a dynamic workflow?",
                kind: .attention,
                confidence: .high,
                revision: 84
            ))
        )

        var extensionMachine = try makeMachine("claude")
        XCTAssertEqual(
            extensionMachine.ingest(input(
                .blocked,
                85,
                Fixtures.claudeExtensionBlocker
            )),
            .keep
        )
        XCTAssertNil(extensionMachine.excerpt)

        var staleFallbackMachine = try makeMachine("claude")
        XCTAssertEqual(
            staleFallbackMachine.ingest(input(
                .blocked,
                86,
                Fixtures.claudeStaleDynamicWorkflow
            )),
            .keep
        )
        XCTAssertNil(staleFallbackMachine.excerpt)

        var staleFormMachine = try makeMachine("claude")
        let staleForm =
            Fixtures.claudeSelection + "\n" + Fixtures.claudeChromeOnly
        XCTAssertEqual(
            staleFormMachine.ingest(input(.blocked, 87, staleForm)),
            .keep
        )
        XCTAssertNil(staleFormMachine.excerpt)

        var plainYesMachine = try makeMachine("claude")
        XCTAssertEqual(
            plainYesMachine.ingest(input(
                .blocked,
                88,
                Fixtures.claudePlainYesPermission
            )),
            .replace(excerpt(
                "Do you want to proceed?",
                kind: .attention,
                confidence: .high,
                revision: 88
            ))
        )
    }

    func testQuestionFormWithEscapeHatchRowBelowARulePublishesItsQuestion() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .blocked,
                89,
                Fixtures.claudeQuestionWithEscapeHatchRow
            )),
            .replace(excerpt(
                "Which option do you like?",
                kind: .attention,
                confidence: .high,
                revision: 89
            ))
        )
    }

    func testQuestionFormWithPreviewPanePublishesItsQuestion() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .blocked,
                90,
                Fixtures.claudeQuestionWithPreviewPane
            )),
            .replace(excerpt(
                "Which preview should the agent list show while a form is open?",
                kind: .attention,
                confidence: .high,
                revision: 90
            ))
        )
    }

    func testSettledReplacementIgnoresToolBlocksAndNormalizesWrappedText() throws {
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(.working, 90, Fixtures.claudeWorking))

        // The candidate changed, so the cached message stays on display while
        // the settled screen is verified.
        XCTAssertEqual(
            machine.ingest(input(.done, 91, Fixtures.claudeCompleted)),
            .keep
        )
        XCTAssertTrue(machine.requiresVerificationRead)
        XCTAssertEqual(
            machine.excerpt?.text,
            "Comparing the latest screen with the turn baseline."
        )

        XCTAssertEqual(
            machine.ingest(input(.idle, 91, Fixtures.claudeCompleted)),
            .replace(excerpt(
                "Preview now keeps the latest completed reply while tools are running.",
                kind: .response,
                confidence: .medium,
                revision: 91
            ))
        )
    }

    func testCRLFAndTerminalPaddingDoNotChangeAStableCandidate() throws {
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(.working, 110, Fixtures.claudeWorking))
        _ = machine.ingest(input(.done, 111, Fixtures.claudeCompleted))

        let padded = Fixtures.claudeCompleted
            .replacingOccurrences(of: "\n", with: "   \r\n")
        XCTAssertEqual(
            machine.ingest(input(.idle, 111, padded)),
            .replace(excerpt(
                "Preview now keeps the latest completed reply while tools are running.",
                kind: .response,
                confidence: .medium,
                revision: 111
            ))
        )
    }

    func testToolOnlySettledScreenKeepsCachedMessage() throws {
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(.working, 101, Fixtures.claudeWorking))
        let accepted = try XCTUnwrap(machine.excerpt)

        XCTAssertEqual(
            machine.ingest(input(.done, 102, Fixtures.claudeToolOnly)),
            .keep
        )
        XCTAssertEqual(
            machine.ingest(input(.idle, 102, Fixtures.claudeToolOnly)),
            .keep
        )
        XCTAssertEqual(machine.excerpt, accepted)
    }

    func testPriorResponseVisibleDuringToolTurnIsTheMessage() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                119,
                Fixtures.claudeWorkingWithPriorResponse
            )),
            .replace(excerpt(
                "Preview now keeps the latest completed reply while tools are running.",
                kind: .response,
                confidence: .medium,
                revision: 119
            ))
        )
    }

    func testMessageMayBeginWithAToolName() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(.working, 116, Fixtures.claudeVerbResponse)),
            .replace(excerpt(
                "Read the preview before choosing a target.",
                kind: .response,
                confidence: .medium,
                revision: 116
            ))
        )
    }

    func testSuppressedOverlaysAndIndentedCircleOutputAreIgnored() throws {
        var transcriptMachine = try makeMachine("claude")
        XCTAssertEqual(
            transcriptMachine.ingest(input(
                .working,
                120,
                Fixtures.claudeTranscriptViewer
            )),
            .keep
        )
        XCTAssertNil(transcriptMachine.excerpt)

        var shortcutViewerMachine = try makeMachine("claude")
        XCTAssertEqual(
            shortcutViewerMachine.ingest(input(
                .working,
                121,
                Fixtures.claudeTranscriptShortcutOnly
            )),
            .keep
        )
        XCTAssertNil(shortcutViewerMachine.excerpt)

        var modelMachine = try makeMachine("claude")
        XCTAssertEqual(
            modelMachine.ingest(input(
                .blocked,
                121,
                Fixtures.claudeModelPicker
            )),
            .keep
        )
        XCTAssertNil(modelMachine.excerpt)

        var outputMachine = try makeMachine("claude")
        XCTAssertEqual(
            outputMachine.ingest(input(
                .working,
                122,
                Fixtures.claudeCircleToolOutput
            )),
            .keep
        )
        XCTAssertNil(outputMachine.excerpt)
    }

    func testBlockerVocabularyInsideAMessageRemainsMessageText() throws {
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(
            .idle,
            124,
            Fixtures.claudeBlockerWordsResponse
        ))

        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                124,
                Fixtures.claudeBlockerWordsResponse
            )),
            .replace(excerpt(
                "“Do you want to proceed?” and “Esc to cancel” are ordinary prose here.",
                kind: .response,
                confidence: .medium,
                revision: 124
            ))
        )
    }

    func testTranscriptViewerWordsInsideAMessageAreNotSuppressed() throws {
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(
            .idle,
            126,
            Fixtures.claudeViewerWordsResponse
        ))

        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                126,
                Fixtures.claudeViewerWordsResponse
            )),
            .replace(excerpt(
                "The footer says “Showing detailed transcript” next to the shortcuts hint.",
                kind: .response,
                confidence: .medium,
                revision: 126
            ))
        )
    }

    func testSettledScreenPublishesNewestVisibleMessageWithoutAnchor() throws {
        // Best-effort contract: a settled screen's newest visible message is
        // cached even when the preceding working screens never showed it.
        // Scrolled-in history can therefore be published; the next read after
        // the viewport returns to the tail corrects it.
        var machine = try makeMachine("claude")
        _ = machine.ingest(input(
            .working,
            127,
            Fixtures.claudeWorkingWithToolA
        ))
        _ = machine.ingest(input(
            .done,
            128,
            Fixtures.claudeSettledWithToolBAndOldResponse
        ))

        XCTAssertEqual(
            machine.ingest(input(
                .idle,
                128,
                Fixtures.claudeSettledWithToolBAndOldResponse
            )),
            .replace(excerpt(
                "This response belongs to older history.",
                kind: .response,
                confidence: .medium,
                revision: 128
            ))
        )
    }

    func testScrolledLongMessagePublishesItsTailParagraphWhileWorking() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                129,
                Fixtures.claudeScrolledLongResponse
            )),
            .replace(excerpt(
                "The tail paragraph carries the conclusion.",
                kind: .response,
                confidence: .medium,
                revision: 129
            ))
        )
    }

    func testMiddleDotProseStaysAttachedToItsMessage() throws {
        var machine = try makeMachine("claude")

        XCTAssertEqual(
            machine.ingest(input(
                .working,
                130,
                Fixtures.claudeMiddleDotProse
            )),
            .replace(excerpt(
                "Keep the prose attached to its response. · Cache policy (cold · warm)",
                kind: .response,
                confidence: .medium,
                revision: 130
            ))
        )
    }
}

private func makeMachine(
    _ agentID: String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> AgentExcerptMachine {
    try XCTUnwrap(AgentExcerptMachine(agentID: agentID), file: file, line: line)
}

private func input(
    _ status: AgentStatus,
    _ revision: UInt64,
    _ text: String
) -> AgentExcerptInput {
    AgentExcerptInput(
        statusBeforeRead: status,
        statusAfterRead: status,
        revision: revision,
        text: text
    )
}

private func excerpt(
    _ text: String,
    kind: AgentExcerpt.Kind,
    confidence: AgentExcerpt.Confidence,
    revision: UInt64
) -> AgentExcerpt {
    AgentExcerpt(
        text: text,
        kind: kind,
        confidence: confidence,
        screenRevision: revision
    )
}

private enum Fixtures {
    static let codexWorking = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Checking extraction paths (2s • esc to interrupt)

    › Add preview support

      tab to queue message                         100% context left
    """

    static let codexApproval = """
      Would you like to run the following command?

      Reason: preview reads are verified twice so a partially rendered
      response is not published

      $ echo preview

    › 1. Yes, proceed (y)
      2. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """

    static let codexQuestion = """
      Question 1/1 (1 unanswered)
      Which preview should appear
      in the agent list?

        1. Latest reply  Show the completed reply.
      › 2. Current work  Show in-progress activity.

      tab to add notes | enter to submit answer | esc to interrupt
    """

    static let codexCompleted = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Preview now keeps the latest completed reply while tools are
      running.

    › Add preview support

      tab to queue message                         98% context left
    """

    static let codexBlockerWordsResponse = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Treat “Press enter to confirm or esc to cancel” as normal prose
      unless the agent is blocked.

    › Add preview support

      tab to queue message                         99% context left
    """

    static let codexToolOnly = """
    • Explored
      └ Search preview
        Read Sources/App/Preview.swift

    › Add preview support

      tab to queue message                         99% context left
    """

    static let codexChromeOnly = """
    › Add preview support

      tab to queue message                         100% context left
    """

    static let codexExtensionBlocker = """
    Extension confirmation

    Esc to cancel
    """

    static let codexStaleFallbackBlocker = """
    Allow an earlier command? [y/n]

    Previous output one
    Previous output two
    Previous output three
    Previous output four
    Previous output five
    Previous output six

    Extension confirmation
    Esc to cancel
    """

    static let codexPlainYesApproval = """
    Allow this command?

    ❯ Yes
      No

    Press enter to confirm or esc to cancel
    """

    static let codexWorkingWithPriorResponse = """
    • The previous turn left this response visible.

    • Checking extraction paths (2s • esc to interrupt)

    › Add preview support

      tab to queue message                         100% context left
    """

    static let codexToolOnlyWithPriorResponse = """
    • The previous turn left this response visible.

    • Explored
      └ Read Sources/App/Preview.swift

    › Add preview support

      tab to queue message                         99% context left
    """

    static let codexVerbResponse = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Working with remote panes requires an endpoint-scoped reader.

    › Add preview support

      tab to queue message                         99% context left
    """

    static let codexSystemCells = """
    • Added Preview.swift (+1 -0)
        1 +struct Preview {}

    • Deleted LegacyPreview.swift (+0 -4)

    • Permissions updated to Full Access

    • Searched terminal preview extraction patterns

    › Add preview support

      tab to queue message                         99% context left
    """

    static let codexTranscriptViewer = """
    Preview transcript content

    ↑/↓ to scroll · pgup/pgdn to page · home/end to jump
    esc to edit prev · q to quit
    """

    static let codexNarrowWorking = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Investigating rendering code (0s • esc to interr…)

    › Add preview support

      tab to queue message                         99% context left
    """

    static let codexSearchedThenFinal = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Searched terminal preview extraction patterns

    • Final response.

    › Add preview support
    """

    static let codexStreamingResponse = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Waited for background terminal · swift test

    • Streaming response.

    › Add preview support
    """

    static let codexViewerVocabularyResponse = """
    • Explored
      └ Read Sources/App/Preview.swift

    • Document ↑/↓ to scroll, pgup/pgdn to page, home/end to jump,
      and q to quit.

    › Add preview support
    """

    static func codexGenericLiveStatus(_ title: String) -> String {
        """
        • “Older quoted status” (4s • esc to interrupt)

        • \(title) (0s • esc to interrupt)

        › Add preview support

          tab to queue message                         99% context left
        """
    }

    static let codexStatusLikeResponse = """
    • Explain this hint (press Esc to interrupt)

    › Add preview support
    """

    // Models the current Codex TUI after a long turn: the response's leading
    // "•" scrolled above the viewport, a "─ Worked for …" divider closes the
    // turn, and the status bar's two-space-indented line sits below the "»"
    // composer.
    static let codexScrolledLongResponse = """
      - The menu row keeps a fixed third line.
      - Loading swaps to the excerpt text.

      Rebuild and reopen the menu to see the fixed height.

    ─ Worked for 20m 25s ────────────────────────────────

    » Write tests for @filename

      ~/work/shepherd · main · Context 16% used · Main [default]
    """

    // Models the current Codex question form: a "Question N/M" header above
    // the question, and a question that ends with a full-width "？".
    static let codexQuestionFullWidth = """
    • 質問フォームを表示するよ。

      Question 1/1 (1 unanswered)
      いま食べたい sweet なおやつはどれ？

        1. クッキー      さくさくの定番だよ。
      › 2. アイス        ひんやり濃厚だよ。
        3. None of the above  Optionally, add details in notes (tab).

      tab to add notes | enter to submit answer | esc to interrupt
    """

    static let claudeWorking = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Comparing the latest screen with the turn baseline.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts

      ◯ Explore  Inspect terminal layouts · 42s
    """

    static let claudeToolOnlyWithSubagentFooter = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts

      ◯ Explore  Inspect terminal layouts · 42s
    """

    static let claudePermission = """
    ────────────────────────────────────────────────────────
     Bash command

       swift test

     Do you want to proceed?
     ❯ 1. Yes
       2. Yes, and don't ask again for swift test commands
       3. No

     Esc to cancel · Tab to amend
    """

    static let claudeSelection = """
    ────────────────────────────────────────────────────────
    Choose preview detail

      1. One line
    ❯ 2. Two lines
      3. No preview

    Enter to select · Esc to cancel
    ↑/↓ to navigate
    """

    static let claudeDynamicWorkflow = """
    ────────────────────────────────────────────────────────
    Run a dynamic workflow?

    Esc to cancel
    """

    static let claudeExtensionBlocker = """
    ────────────────────────────────────────────────────────
    Extension confirmation

    Esc to cancel
    """

    static let claudeStaleDynamicWorkflow = """
    Run a dynamic workflow?

    Previous output one
    Previous output two
    Previous output three
    Previous output four
    Previous output five
    Previous output six
    Previous output seven
    Previous output eight

    Extension confirmation
    Esc to cancel
    """

    static let claudePlainYesPermission = """
    ────────────────────────────────────────────────────────
    Do you want to proceed?

    ❯ Yes
      No

    Esc to cancel
    """

    // Models the current Claude question form: a "☐" tab title above the
    // question, and a numbered escape-hatch "Chat about this" row below its
    // own horizontal rule.
    static let claudeQuestionWithEscapeHatchRow = """
    ⏺ Asking before continuing.

    ────────────────────────────────────────────────────────
     ☐ Test question

    Which option do you like?

    ❯ 1. Option A
         A short description of option A
      2. Option B
         A short description of option B
      3. Type something.
    ────────────────────────────────────────────────────────
      4. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel
    """

    // The same form with a preview pane drawn to the right of the choices and
    // an un-numbered escape-hatch row.
    static let claudeQuestionWithPreviewPane = """
    ⏺ Preparing the form comparison.

    ────────────────────────────────────────────────────────
     ☐ Preview shape

    Which preview should the agent list show while a form is open?

      1. Single line                  ┌──────────────────────────────┐
        (Recommended)                 │ {                            │
    ❯ 2. Two lines                    │   "preview": "two-line"      │
      3. Hidden                       │ }                            │
                                      └──────────────────────────────┘

                                      Notes: press n to add notes

    ────────────────────────────────────────────────────────
      Chat about this

    Enter to select · ↑/↓ to navigate · n to add notes · Esc to cancel
    """

    static let claudeCompleted = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Comparing the latest screen with the turn baseline.

    ⏺ Preview now keeps the latest completed reply while tools are
      running.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeToolOnly = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Bash(swift test)
      ⎿ All tests passed

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeChromeOnly = """
    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeWorkingWithProgress = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Comparing the latest screen with the turn baseline.

    ⏺ I found a second terminal layout to inspect.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeSettledWithProgress = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Comparing the latest screen with the turn baseline.

    ⏺ I found a second terminal layout to inspect.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeVerbResponse = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Comparing the latest screen with the turn baseline.

    ⏺ Read the preview before choosing a target.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeWorkingWithPriorResponse = """
    ⏺ Preview now keeps the latest completed reply while tools are
      running.

    ⏺ Bash(swift test)
      ⎿ Running…

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeTranscriptViewer = """
    Showing detailed transcript

    ↑↓ scroll
    ? for shortcuts
    """

    static let claudeTranscriptShortcutOnly = """
    Previous transcript row
    Showing detailed transcript
    ? for shortcuts
    """

    static let claudeModelPicker = """
    Select model

    1. Sonnet
    2. Opus
    3. Haiku
    4. Sonnet (extended context)
    5. Opus (extended context)
    6. Default
    7. Project default
    8. User default
    9. Keep current

    Enter to set as default
    Esc to cancel
    """

    static let claudeCircleToolOutput = """
    ⏺ Bash(printf preview)
      ⎿ output
        ◯ Fake  This is command output · 1s

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeBlockerWordsResponse = """
    ⏺ Comparing the latest screen with the turn baseline.

    ⏺ “Do you want to proceed?” and “Esc to cancel” are ordinary
      prose here.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeViewerWordsResponse = """
    ⏺ Read(Sources/App/Preview.swift)
      ⎿ Read 80 lines

    ⏺ Comparing the latest screen with the turn baseline.

    ⏺ The footer says “Showing detailed transcript” next to the
      shortcuts hint.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeWorkingWithToolA = """
    ⏺ Read(Sources/A.swift)
      ⎿ Read 40 lines

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    static let claudeSettledWithToolBAndOldResponse = """
    ⏺ Read(Sources/B.swift)
      ⎿ Read 40 lines

    ⏺ This response belongs to older history.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    // Footer lines below reproduce the observed Claude Code status line: an
    // animated spinner glyph, a gerund summary, and parenthesized metadata
    // whose thinking segment appears and disappears while the model thinks.
    static func claudeSpinnerFooter(_ footerLine: String) -> String {
        """
        ⏺ Read(Sources/App/Preview.swift)
          ⎿ Read 80 lines

        \(footerLine)

        ────────────────────────────────────────────────────────
        ❯
        ────────────────────────────────────────────────────────
          ⏵⏵ accept edits on · shift+tab to cycle
          ? for shortcuts
        """
    }

    static let claudeMiddleDotProse = """
    ⏺ Keep the prose attached to its response.
      · Cache policy (cold · warm)

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    // A long streaming or settled message whose "⏺" head scrolled above the
    // viewport: only two-space-indented continuation lines remain before the
    // composer box.
    static let claudeScrolledLongResponse = """
      the message head scrolled above the viewport, so only its
      continuation lines remain visible.

      The tail paragraph carries the conclusion.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """
}
