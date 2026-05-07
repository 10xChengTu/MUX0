# Quick Action Agent Resume Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Quick Action tabs (claude / codex / opencode) participate in agent session resume on next launch instead of always running the bare command.

**Architecture:** Refactor the inline `resolvedStartupCommand(forTerminal:)` logic in `TabContent/TabContentView.swift` into a pure static `StartupCommandResolver.resolve(...)` helper, then add a new "0a" branch that returns the stored resume prefill when the tab's `quickActionId` matches a builtin agent and that agent's Resume toggle is enabled.

**Tech Stack:** Swift 5.9, AppKit, XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-05-08-quick-action-agent-resume-design.md`

---

## File Map

| File | Role |
|------|------|
| `mux0/TabContent/StartupCommandResolver.swift` (new) | Pure static resolver — deterministic, no I/O. Holds the precedence logic (Quick Action → resume → default) so it can be unit-tested independently of NSView / WorkspaceStore / SettingsConfigStore. |
| `mux0/TabContent/TabContentView.swift` (modify, ~5 lines) | `resolvedStartupCommand(forTerminal:)` becomes a thin call site: gathers tab/workspace/store state and forwards to `StartupCommandResolver.resolve`. |
| `mux0Tests/StartupCommandResolverTests.swift` (new) | Unit tests for every branch in the resolver. |
| `docs/agent-hooks.md` (modify, 1 line) | Note that Quick Action tabs now participate in resume. |

`project.yml`'s `mux0` source group is `path: mux0` (recursive); the new resolver file is auto-picked up. `mux0Tests` is `sources: [mux0Tests]` flat — keep test files at the top level of `mux0Tests/`. **No `xcodegen generate` needed** for adding files inside these existing globs.

---

## Task 1: Extract pure resolver, no behavior change

**Files:**
- Create: `mux0/TabContent/StartupCommandResolver.swift`
- Modify: `mux0/TabContent/TabContentView.swift:291-312` (the `resolvedStartupCommand` method)
- Test: `mux0Tests/StartupCommandResolverTests.swift`

This task introduces the helper file with logic that is **byte-for-byte equivalent** to today's behavior. The "Quick Action eats the prefill" bug is preserved here on purpose — Task 2 fixes it under failing tests. Doing the refactor first under green tests gives us a safety net.

- [ ] **Step 1: Create `mux0/TabContent/StartupCommandResolver.swift` with the current logic**

```swift
import Foundation

/// Pure resolver for the shell command auto-injected into a freshly created
/// ghostty surface. Mirrors the precedence rules previously inlined in
/// `TabContentView.resolvedStartupCommand(forTerminal:)`.
///
/// Source order:
///   0. Quick action tab's first terminal — return
///      `"<quickActionCommand>\n"` (built-in default or user override).
///   1. Pending agent resume command (`claude --resume <id>` /
///      `codex resume <id>` / `opencode --session <id>`) — only when the
///      matching agent's Resume toggle is on. Default OFF means stale
///      UserDefaults entries are ignored, not replayed.
///   2. Workspace-level `defaultCommand`.
///
/// Inputs are passed explicitly (rather than wiring up real stores) so the
/// resolver can be unit-tested without bringing up an NSView, WorkspaceStore,
/// SettingsConfigStore, or QuickActionsStore.
enum StartupCommandResolver {
    static func resolve(
        terminalId: UUID,
        tab: TerminalTab?,
        workspaceDefaultCommand: String?,
        quickActionCommand: (QuickActionId) -> String?,
        isResumeEnabled: (HookMessage.Agent) -> Bool,
        pendingPrefill: String?
    ) -> String? {
        // (0) Quick action tab's first terminal.
        if let tab,
           let actionId = tab.quickActionId,
           terminalId == tab.layout.allTerminalIds().first,
           let cmd = quickActionCommand(actionId) {
            return "\(cmd)\n"
        }

        // (1) Agent resume.
        if let pending = pendingPrefill,
           let agent = HookMessage.Agent.fromResumeCommand(pending),
           isResumeEnabled(agent) {
            return pending
        }

        // (2) Workspace default command.
        return workspaceDefaultCommand
    }
}
```

- [ ] **Step 2: Replace the body of `TabContentView.resolvedStartupCommand(forTerminal:)` with a delegating call**

Find the existing implementation in `mux0/TabContent/TabContentView.swift` (around line 291). Keep its doc comment block. Replace its body so it forwards to the resolver. The selected workspace, tab, and pending prefill come from the existing `store` reference; agent toggles come from `settingsStore`.

```swift
private func resolvedStartupCommand(forTerminal id: UUID) -> String? {
    let workspace = store?.selectedWorkspace
    let tab = workspace?.tabs.first { $0.layout.allTerminalIds().contains(id) }
    let pendingPrefill = store?.consumePendingPrefill(terminalId: id)
    return StartupCommandResolver.resolve(
        terminalId: id,
        tab: tab,
        workspaceDefaultCommand: workspace?.defaultCommand,
        quickActionCommand: { [quickActionsStore] actionId in
            quickActionsStore?.command(for: actionId)
        },
        isResumeEnabled: { [settingsStore] agent in
            settingsStore?.get(agent.resumeSettingsKey) == "true"
        },
        pendingPrefill: pendingPrefill
    )
}
```

Note: keep the existing doc comment block (`/// Pick the shell command...`) directly above this method — only the body changes.

- [ ] **Step 3: Build to confirm no compilation regressions**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build
```

Expected: `** BUILD SUCCEEDED **`. If you get an "ambiguous use of `allTerminalIds()`" or similar, double-check that the resolver file imports only `Foundation` (the model types are in the same target).

- [ ] **Step 4: Create `mux0Tests/StartupCommandResolverTests.swift` with tests pinning current behavior**

These tests cover **branches that should NOT change** in Task 2. We deliberately do not test the "Quick Action claude with toggle on + prefill" case here — that's the broken behavior Task 2 will flip.

```swift
import XCTest
@testable import mux0

final class StartupCommandResolverTests: XCTestCase {
    // MARK: - Quick Action branch (unchanged after Task 2)

    func testQuickActionGitui_returnsNakedCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "gitui")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "should-not-fire",
            quickActionCommand: { _ in "gitui" },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc"  // ignored: gitui isn't an agent
        )
        XCTAssertEqual(result, "gitui\n")
    }

    func testQuickActionClaude_noPrefill_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "claude\n")
    }

    func testQuickActionClaude_toggleOff_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in false },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "claude\n")
    }

    // MARK: - Naked terminal Agent resume branch (must not regress)

    func testNakedTerminal_resumeOn_returnsPrefill() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "claude --resume abc")
    }

    func testNakedTerminal_resumeOff_returnsDefaultCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in false },
            pendingPrefill: "claude --resume abc"
        )
        XCTAssertEqual(result, "default-cmd")
    }

    func testNakedTerminal_noPrefill_returnsDefaultCommand() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "default-cmd")
    }

    func testNakedTerminal_noPrefill_noDefault_returnsNil() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: nil)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in nil },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertNil(result)
    }

    // MARK: - Quick Action tab, non-first pane (split sibling)

    func testQuickActionTab_secondPane_fallsThroughToDefault() {
        let firstTerm = UUID()
        let secondTerm = UUID()
        // SplitNode.split is positional: (UUID, SplitDirection, CGFloat,
        // SplitNode, SplitNode).
        let layout: SplitNode = .split(
            UUID(),
            .horizontal,
            0.5,
            .terminal(firstTerm),
            .terminal(secondTerm)
        )
        var tab = TerminalTab(title: "T", terminalId: firstTerm, quickActionId: "claude")
        tab.layout = layout
        // resolve for the SECOND terminal — not the first leaf.
        let result = StartupCommandResolver.resolve(
            terminalId: secondTerm,
            tab: tab,
            workspaceDefaultCommand: "default-cmd",
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            pendingPrefill: nil
        )
        XCTAssertEqual(result, "default-cmd")
    }
}
```

- [ ] **Step 5: Run the new tests + full test suite**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/StartupCommandResolverTests
```

Expected: 7/7 pass.

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests
```

Expected: full suite green. The refactor must not break anything else.

- [ ] **Step 6: Commit**

```bash
git add mux0/TabContent/StartupCommandResolver.swift \
        mux0/TabContent/TabContentView.swift \
        mux0Tests/StartupCommandResolverTests.swift
git commit -m "refactor(tabcontent): extract StartupCommandResolver

Move the source-order precedence (quick action / agent resume / workspace
default) out of TabContentView into a pure static helper so it can be
exercised by unit tests without an NSView. Behavior unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Add resume-aware branch (0a) for Quick Action agent tabs

**Files:**
- Modify: `mux0/TabContent/StartupCommandResolver.swift`
- Test: `mux0Tests/StartupCommandResolverTests.swift`

This task introduces the new behavior: a Quick Action tab whose `quickActionId` matches a builtin agent (`"claude"` / `"codex"` / `"opencode"`) returns the stored resume prefill when the toggle is on and the prefill's leading agent token matches.

- [ ] **Step 1: Add failing tests for the new behavior**

Append these to `StartupCommandResolverTests.swift` (above the existing `// MARK: - Quick Action tab, non-first pane` mark or in a new `// MARK: - Quick Action resume (Task 2)` block — placement is cosmetic).

```swift
    // MARK: - Quick Action resume (Task 2)

    func testQuickActionClaude_resumeOn_matchingPrefill_returnsPrefill() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { $0 == .claude },
            pendingPrefill: "claude --resume abc-123"
        )
        XCTAssertEqual(result, "claude --resume abc-123")
    }

    func testQuickActionClaude_resumeOn_mismatchedPrefill_returnsNakedClaude() {
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude" },
            isResumeEnabled: { _ in true },
            // prefill belongs to a DIFFERENT agent — must not be replayed.
            pendingPrefill: "codex resume xyz-789"
        )
        XCTAssertEqual(result, "claude\n")
    }

    func testQuickActionClaude_overrideCommand_resumeOn_returnsPrefill() {
        // User changed the builtin claude command to `claude --debug` AND
        // turned the Resume toggle on. Spec: resume wins, ignore override.
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "claude")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "claude --debug" },
            isResumeEnabled: { $0 == .claude },
            pendingPrefill: "claude --resume abc-123"
        )
        XCTAssertEqual(result, "claude --resume abc-123")
    }

    func testQuickActionCustomUUID_claudePrefill_returnsCustomCommand() {
        // Custom Quick Action id is a UUID string — `Agent(rawValue:)` fails,
        // so the resume branch must NOT fire for it.
        let term = UUID()
        let customId = UUID().uuidString
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: customId)
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "my-script.sh" },
            isResumeEnabled: { _ in true },
            pendingPrefill: "claude --resume abc-123"
        )
        XCTAssertEqual(result, "my-script.sh\n")
    }

    func testQuickActionCodex_resumeOn_returnsCodexResumePrefill() {
        // Codex uses `codex resume <id>` (no double-dash). Verify both
        // builtin agents work, not just claude.
        let term = UUID()
        let tab = TerminalTab(title: "T", terminalId: term, quickActionId: "codex")
        let result = StartupCommandResolver.resolve(
            terminalId: term,
            tab: tab,
            workspaceDefaultCommand: nil,
            quickActionCommand: { _ in "codex" },
            isResumeEnabled: { $0 == .codex },
            pendingPrefill: "codex resume xyz-789"
        )
        XCTAssertEqual(result, "codex resume xyz-789")
    }
```

- [ ] **Step 2: Run the new tests to verify they fail**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/StartupCommandResolverTests
```

Expected: 5 new tests fail (each currently returns the bare quick-action command instead of the prefill, except the custom-UUID test which already passes for the right reason — count it as a confirmation, not a regression). The 7 tests from Task 1 still pass.

If you want to be precise, run them individually:

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests \
  -only-testing:mux0Tests/StartupCommandResolverTests/testQuickActionClaude_resumeOn_matchingPrefill_returnsPrefill
```

- [ ] **Step 3: Add the (0a) branch to the resolver**

Edit `mux0/TabContent/StartupCommandResolver.swift`. Replace the entire `resolve(...)` body with the version below (the change is the new `if let agent = HookMessage.Agent...` block inserted **inside** the existing Quick Action `if`, before the `quickActionCommand` lookup):

```swift
    static func resolve(
        terminalId: UUID,
        tab: TerminalTab?,
        workspaceDefaultCommand: String?,
        quickActionCommand: (QuickActionId) -> String?,
        isResumeEnabled: (HookMessage.Agent) -> Bool,
        pendingPrefill: String?
    ) -> String? {
        // (0) Quick action tab's first terminal.
        if let tab,
           let actionId = tab.quickActionId,
           terminalId == tab.layout.allTerminalIds().first {

            // (0a) If this Quick Action is a builtin agent, the agent's
            //      Resume toggle is on, AND we have a stored prefill whose
            //      leading CLI token matches the same agent → replay that
            //      `<agent> --resume <id>` instead of the bare command.
            //      The agent equality guard prevents a stale prefill written
            //      by a different agent from being replayed here.
            if let agent = HookMessage.Agent(rawValue: actionId),
               isResumeEnabled(agent),
               let pending = pendingPrefill,
               HookMessage.Agent.fromResumeCommand(pending) == agent {
                return pending
            }

            // (0b) Fallback: original Quick Action command (built-in default
            //      or user override).
            if let cmd = quickActionCommand(actionId) {
                return "\(cmd)\n"
            }
        }

        // (1) Agent resume — naked terminal path.
        if let pending = pendingPrefill,
           let agent = HookMessage.Agent.fromResumeCommand(pending),
           isResumeEnabled(agent) {
            return pending
        }

        // (2) Workspace default command.
        return workspaceDefaultCommand
    }
```

- [ ] **Step 4: Re-run the resolver tests**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/StartupCommandResolverTests
```

Expected: 12/12 pass (7 from Task 1 + 5 from Task 2).

- [ ] **Step 5: Run the full test suite to catch any regressions**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests
```

Expected: full suite green.

- [ ] **Step 6: Commit**

```bash
git add mux0/TabContent/StartupCommandResolver.swift \
        mux0Tests/StartupCommandResolverTests.swift
git commit -m "feat(tabcontent): resume agent session on quick-action tab restart

Quick Action tabs (claude / codex / opencode) now replay the stored
resume command on next launch when the matching Agent Resume toggle is
on, instead of always running the bare CLI. The agent identity is
double-checked: the prefill's leading token must match the tab's
quickActionId, otherwise we fall back to the original Quick Action
command.

Builtin command overrides (e.g. user changed 'claude' to 'claude
--debug') are intentionally bypassed when resuming — the resume command
is the agent's own canonical CLI form, and a user who toggled Resume on
expects continuity over flag preservation.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Document the new behavior in agent-hooks.md

**Files:**
- Modify: `docs/agent-hooks.md` (the "Resume command 持久化" section)

- [ ] **Step 1: Update the resume-section paragraph that mentions `TabContentView.resolvedStartupCommand`**

Find the paragraph in `docs/agent-hooks.md` that begins with:

> 下次启动 surface 时，`TabContentView.resolvedStartupCommand(forTerminal:)` 通过 `consumePendingPrefill(terminalId:)` 读取该值...

Append a new sentence at the end of that paragraph:

> Quick Action 启动的 tab（侧边栏右上角 claude / codex / opencode 按钮）也走这条路径——`tab.quickActionId` 命中 builtin agent 且对应 Resume toggle 为 ON 时，注入 `pendingPrefills` 而不是裸命令；prefill 与 agent 类型不匹配时降级到 Quick Action 的原命令。

- [ ] **Step 2: Verify the doc-drift check still passes**

```bash
./scripts/check-doc-drift.sh
```

Expected: passes (we added a Swift file inside `mux0/TabContent/`, but that directory is already enumerated in CLAUDE.md's Directory Structure under `TabContent/`; no new top-level entry is required for an internal helper file).

If the script complains that `StartupCommandResolver.swift` is missing from CLAUDE.md or `docs/architecture.md`, add a single bullet under the existing `TabContent/` block in CLAUDE.md:

```
│   ├── StartupCommandResolver.swift — pure static helper for resolving
│   │   the auto-injected initial command (quick action / agent resume /
│   │   workspace default) per surface launch
```

- [ ] **Step 3: Commit**

```bash
git add docs/agent-hooks.md
# Also include CLAUDE.md if Step 2 required an update.
git commit -m "docs(agent-hooks): note quick-action tab resume path

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Final Verification

- [ ] **Step 1: Confirm clean working tree on the right branch**

```bash
git status
git log --oneline master..HEAD
```

Expected: branch `agent/quickaction-agent-resume`, working tree clean, three new commits (refactor → feat → docs) on top of master plus the spec commit.

- [ ] **Step 2: One last full test run**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests
```

Expected: full suite green. Done. Report back to the user.

**Do not push.** Per the user's saved feedback (`feedback_no_auto_git_push.md`), local commits are fine but pushing requires per-push consent. Surface the diff and the verification results, and let the user decide.
