import XCTest
@testable import mux0

final class TerminalStatusTests: XCTestCase {

    func testNeverRanIsDefault() {
        let s: TerminalStatus = .neverRan
        XCTAssertEqual(s, .neverRan)
    }

    func testEqualityIgnoresTimestampDetailsOfRunningStart() {
        let t1 = Date(timeIntervalSince1970: 1000)
        let t2 = Date(timeIntervalSince1970: 2000)
        // Different startedAt values are NOT equal — Equatable is strict
        XCTAssertNotEqual(TerminalStatus.running(startedAt: t1),
                          TerminalStatus.running(startedAt: t2))
    }

    func testAggregateEmptyIsNeverRan() {
        XCTAssertEqual(TerminalStatus.aggregate([]), .neverRan)
    }

    func testAggregateAllNeverRanIsNeverRan() {
        let inputs: [TerminalStatus] = [.neverRan, .neverRan, .neverRan]
        XCTAssertEqual(TerminalStatus.aggregate(inputs), .neverRan)
    }

    func testAggregateAnyRunningBeatsEverything() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude),
            .failed(exitCode: 1, duration: 2, finishedAt: now, agent: .claude),
            .running(startedAt: now),
            .neverRan,
        ]
        if case .running = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected running to win aggregation")
        }
    }

    func testAggregateFailedBeatsSuccessAndNeverRan() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude),
            .failed(exitCode: 2, duration: 3, finishedAt: now, agent: .claude),
            .neverRan,
        ]
        if case .failed = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected failed to win over success+neverRan")
        }
    }

    func testIdleBeatsNeverRanButLosesToSuccess() {
        let now = Date()
        XCTAssertEqual(TerminalStatus.aggregate([.idle(since: now), .neverRan]).priorityCaseName, "idle")
        XCTAssertEqual(
            TerminalStatus.aggregate([.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude), .idle(since: now)]).priorityCaseName,
            "success")
    }

    func testNeedsInputBeatsEverything() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .running(startedAt: now),
            .failed(exitCode: 1, duration: 1, finishedAt: now, agent: .claude),
            .success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude),
            .needsInput(since: now),
            .idle(since: now),
            .neverRan
        ]
        XCTAssertEqual(TerminalStatus.aggregate(inputs).priorityCaseName, "needsInput")
    }

    func testFullPriorityChain() {
        let now = Date()
        let order: [(TerminalStatus, String)] = [
            (.needsInput(since: now), "needsInput"),
            (.running(startedAt: now), "running"),
            (.failed(exitCode: 1, duration: 1, finishedAt: now, agent: .claude), "failed"),
            (.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude), "success"),
            (.idle(since: now), "idle"),
            (.neverRan, "neverRan")
        ]
        for (i, (high, expected)) in order.enumerated() {
            for j in (i + 1)..<order.count {
                let low = order[j].0
                XCTAssertEqual(TerminalStatus.aggregate([low, high]).priorityCaseName, expected,
                               "\(expected) should beat \(order[j].1)")
            }
        }
    }

    func testAggregateSuccessBeatsNeverRan() {
        let now = Date()
        let inputs: [TerminalStatus] = [
            .success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude),
            .neverRan,
        ]
        if case .success = TerminalStatus.aggregate(inputs) { /* pass */ } else {
            XCTFail("Expected success over neverRan")
        }
    }

    func testAggregateTwoSuccessPicksOneSuccess() {
        let now = Date()
        let s1 = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude)
        let s2 = TerminalStatus.success(exitCode: 0, duration: 2, finishedAt: now, agent: .claude)
        if case .success = TerminalStatus.aggregate([s1, s2]) { /* pass */ } else {
            XCTFail("Expected success when multiple successes present")
        }
    }

    func testTooltipFormatDuration() {
        XCTAssertEqual(TerminalStatusIconView.formatDuration(0.2), "<1s")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(5), "5s")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(59), "59s")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(60), "1m")
        XCTAssertEqual(TerminalStatusIconView.formatDuration(151), "2m31s")
    }

    func testTooltipTextForEachState() {
        XCTAssertNil(TerminalStatusIconView.tooltipText(for: .neverRan))
        let now = Date()
        XCTAssertEqual(
            TerminalStatusIconView.tooltipText(for: .success(exitCode: 0, duration: 151,
                                                              finishedAt: now, agent: .claude)),
            "Claude: turn finished · 2m31s")
        XCTAssertEqual(
            TerminalStatusIconView.tooltipText(for: .failed(exitCode: 1, duration: 5,
                                                             finishedAt: now, agent: .claude)),
            "Claude: turn had tool errors · 5s")
        let rt = TerminalStatusIconView.tooltipText(for: .running(startedAt: now)) ?? ""
        XCTAssertTrue(rt.hasPrefix("Running for"))
    }

    func testTooltipIdleAndNeedsInput() {
        let now = Date()
        let idleText = TerminalStatusIconView.tooltipText(for: .idle(since: now)) ?? ""
        XCTAssertTrue(idleText.hasPrefix("Idle for"), "Got: \(idleText)")
        let needsText = TerminalStatusIconView.tooltipText(for: .needsInput(since: now)) ?? ""
        XCTAssertTrue(needsText.hasPrefix("Needs input"), "Got: \(needsText)")
    }

    func testSuccessWithAgentClaudeAndSummary() {
        let now = Date()
        let s = TerminalStatus.success(exitCode: 0, duration: 5, finishedAt: now,
                                       agent: .claude, summary: "Refactored X.")
        if case .success(_, _, _, let agent, let summary, _) = s {
            XCTAssertEqual(agent, .claude)
            XCTAssertEqual(summary, "Refactored X.")
        } else {
            XCTFail("Expected .success case")
        }
    }

    func testRunningWithDetail() {
        let now = Date()
        let r = TerminalStatus.running(startedAt: now, detail: "Edit Foo.swift")
        if case .running(_, let detail) = r {
            XCTAssertEqual(detail, "Edit Foo.swift")
        } else {
            XCTFail("Expected .running case")
        }
    }

    func testSuccessSummaryParticipatesInEquality() {
        let now = Date()
        let a = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                       agent: .claude, summary: "A")
        let b = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                       agent: .claude, summary: "B")
        XCTAssertNotEqual(a, b)
    }

    // MARK: - readAt modifier

    func testSuccessReadAtDefaultsToNil() {
        let now = Date()
        let s = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude)
        guard case .success(_, _, _, _, _, let readAt) = s else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNil(readAt)
    }

    func testSuccessReadAtCanBeSet() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let s = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        guard case .success(_, _, _, _, _, let actual) = s else {
            XCTFail("Expected .success"); return
        }
        XCTAssertEqual(actual, readAt)
    }

    func testFailedReadAtDefaultsToNil() {
        let now = Date()
        let f = TerminalStatus.failed(exitCode: 1, duration: 1, finishedAt: now, agent: .claude)
        guard case .failed(_, _, _, _, _, let readAt) = f else {
            XCTFail("Expected .failed"); return
        }
        XCTAssertNil(readAt)
    }

    func testSuccessReadAtParticipatesInEquality() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let a = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now, agent: .claude)
        let b = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - aggregate unread tie-break

    func testAggregateUnreadSuccessBeatsReadSuccess() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let read   = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                             agent: .claude, summary: nil, readAt: readAt)
        let unread = TerminalStatus.success(exitCode: 0, duration: 2, finishedAt: now,
                                             agent: .claude)
        let agg1 = TerminalStatus.aggregate([read, unread])
        let agg2 = TerminalStatus.aggregate([unread, read])
        // order-independent: unread wins regardless of position
        guard case .success(_, _, _, _, _, let r1) = agg1,
              case .success(_, _, _, _, _, let r2) = agg2 else {
            XCTFail("Expected .success from both aggregations"); return
        }
        XCTAssertNil(r1)
        XCTAssertNil(r2)
    }

    func testAggregateUnreadFailedBeatsReadFailed() {
        let now = Date()
        let read   = TerminalStatus.failed(exitCode: 1, duration: 1, finishedAt: now,
                                            agent: .claude, summary: nil,
                                            readAt: Date(timeIntervalSince1970: 99))
        let unread = TerminalStatus.failed(exitCode: 1, duration: 2, finishedAt: now,
                                            agent: .claude)
        let agg = TerminalStatus.aggregate([read, unread])
        guard case .failed(_, _, _, _, _, let r) = agg else {
            XCTFail("Expected .failed"); return
        }
        XCTAssertNil(r)
    }

    func testAggregateAllReadSuccessStaysRead() {
        let now = Date()
        let readAt = Date(timeIntervalSince1970: 99)
        let a = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        let b = TerminalStatus.success(exitCode: 0, duration: 2, finishedAt: now,
                                        agent: .claude, summary: nil, readAt: readAt)
        let agg = TerminalStatus.aggregate([a, b])
        guard case .success(_, _, _, _, _, let r) = agg else {
            XCTFail("Expected .success"); return
        }
        XCTAssertNotNil(r)
    }

    func testAggregatePriorityLadderUnchangedByReadAt() {
        // needsInput still beats any success regardless of read state.
        let now = Date()
        let readSuccess = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                                  agent: .claude, summary: nil,
                                                  readAt: Date(timeIntervalSince1970: 99))
        let inputs: [TerminalStatus] = [readSuccess, .needsInput(since: now)]
        XCTAssertEqual(TerminalStatus.aggregate(inputs).priorityCaseName, "needsInput")
    }

    // MARK: - isRead

    func testIsReadFalseForNonTerminalStates() {
        let now = Date()
        XCTAssertFalse(TerminalStatus.neverRan.isRead)
        XCTAssertFalse(TerminalStatus.running(startedAt: now).isRead)
        XCTAssertFalse(TerminalStatus.idle(since: now).isRead)
        XCTAssertFalse(TerminalStatus.needsInput(since: now).isRead)
    }

    func testIsReadTrueOnlyWhenReadAtIsSet() {
        let now = Date()
        let unreadSuccess = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                                    agent: .claude)
        let readSuccess   = TerminalStatus.success(exitCode: 0, duration: 1, finishedAt: now,
                                                    agent: .claude, summary: nil, readAt: now)
        let unreadFailed  = TerminalStatus.failed(exitCode: 1, duration: 1, finishedAt: now,
                                                   agent: .claude)
        let readFailed    = TerminalStatus.failed(exitCode: 1, duration: 1, finishedAt: now,
                                                   agent: .claude, summary: nil, readAt: now)
        XCTAssertFalse(unreadSuccess.isRead)
        XCTAssertTrue(readSuccess.isRead)
        XCTAssertFalse(unreadFailed.isRead)
        XCTAssertTrue(readFailed.isRead)
    }
}

private extension TerminalStatus {
    var priorityCaseName: String {
        switch self {
        case .neverRan:   return "neverRan"
        case .running:    return "running"
        case .idle:       return "idle"
        case .needsInput: return "needsInput"
        case .success:    return "success"
        case .failed:     return "failed"
        }
    }
}
