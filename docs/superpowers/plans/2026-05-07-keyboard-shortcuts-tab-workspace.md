# Tab / Workspace 切换快捷键 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 mux0 加入 `Cmd+1-9` 切 workspace、`Cmd+Option+1-9` 切 tab、`Ctrl+Tab`/`Ctrl+Shift+Tab` 循环 tab 三组键盘快捷键。

**Architecture:** 沿用现有"SwiftUI Commands → Notification → @Observable store"模式。新加 `mux0SelectWorkspaceAtIndex` notification 由 `SidebarView` 接收并落到 `WorkspaceStore.select(id:)`。`Ctrl+Tab` 用 NSEvent local monitor 实现（与现有 `⌘⌥↑/↓` 同方式），不进菜单，避免菜单 blink。

**Tech Stack:** Swift 6, SwiftUI Commands, AppKit NSEvent monitor, Xcode String Catalog (xcstrings)

**Spec:** `docs/superpowers/specs/2026-05-07-keyboard-shortcuts-tab-workspace-design.md`

---

## File Map

| 文件 | 改动 |
|------|------|
| `mux0/Localization/Localizable.xcstrings` | 加 `"menu.selectWorkspace %lld"` 中英翻译 |
| `mux0/Localization/L10n.swift` | 加 `Menu.selectWorkspaceN(_:)` helper |
| `mux0Tests/L10nSmokeTests.swift` | 把新 key 加入 `allKeys` |
| `mux0/ContentView.swift` | `extension Notification.Name` 加 `mux0SelectWorkspaceAtIndex` |
| `mux0Tests/NotificationNamesTests.swift` | 加 raw value 断言 |
| `mux0/Sidebar/SidebarView.swift` | 加 `.onReceive(.mux0SelectWorkspaceAtIndex)` 处理 |
| `mux0Tests/WorkspaceStoreTests.swift` | 加 `select(id:)` 越界 / 未知 id 的回归测试 |
| `mux0/mux0App.swift` | 新 `workspaceCommands` 挂 File 菜单；Terminal 菜单 `selectTabN` modifier 改 `[.command, .option]` |
| `mux0/TabContent/TabContentView.swift` | `installKeyMonitor()` 加 `Ctrl+Tab` / `Ctrl+Shift+Tab` 分支 |

---

## Task 1: 加入 "Select Workspace" i18n key（中英 + smoke test）

**Files:**
- Modify: `mux0/Localization/Localizable.xcstrings`
- Modify: `mux0/Localization/L10n.swift:226-247`
- Modify: `mux0Tests/L10nSmokeTests.swift:32`

- [ ] **Step 1: 把 "menu.selectWorkspace %lld" 加进 L10nSmokeTests.allKeys（先写测试）**

打开 `mux0Tests/L10nSmokeTests.swift`，在 `allKeys` 数组的 `// Menu` 区段里、`"menu.selectTab %lld"` 这行**后面**插入一行：

```swift
        "menu.selectTab %lld",
        "menu.selectWorkspace %lld",   // ← 新增
        "menu.settings",
```

保持字母升序（selectTab → selectWorkspace → settings）。

- [ ] **Step 2: 跑 smoke test 看到失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/L10nSmokeTests
```

预期：`testAllKeysResolveInEnBundle` 和 `testAllKeysResolveInZhHansBundle` 失败，错误信息包含 `Missing en translation for: menu.selectWorkspace %lld` 等。

- [ ] **Step 3: 在 xcstrings 加翻译**

打开 `mux0/Localization/Localizable.xcstrings`。文件是 JSON，找到现有 `"menu.selectTab %lld"` 这一段（约第 102 行）：

```json
    "menu.selectTab %lld" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Select Tab %lld" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "切换到第 %lld 个 Tab" } }
      }
    },
```

在它**下方**（紧跟 `,` 之后、下一个 key 之前）插入：

```json
    "menu.selectWorkspace %lld" : {
      "extractionState" : "manual",
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Select Workspace %lld" } },
        "zh-Hans" : { "stringUnit" : { "state" : "translated", "value" : "切换到第 %lld 个工作区" } }
      }
    },
```

按 catalog 内字母升序，新条目应位于 `menu.selectTab %lld` 之后、`menu.settings` 之前。

- [ ] **Step 4: 在 L10n.swift 加 selectWorkspaceN helper**

打开 `mux0/Localization/L10n.swift`，找到 `enum Menu` 末尾的 `selectTabN`（约第 244 行）：

```swift
        /// `%lld` will be formatted at call site in mux0App.
        static func selectTabN(_ n: Int) -> LocalizedStringResource {
            LocalizedStringResource("menu.selectTab \(n)")
        }
    }
```

在 `selectTabN` 紧后、`}` 之前追加：

```swift
        /// `%lld` will be formatted at call site in mux0App.
        static func selectWorkspaceN(_ n: Int) -> LocalizedStringResource {
            LocalizedStringResource("menu.selectWorkspace \(n)")
        }
```

整段变成：

```swift
        /// `%lld` will be formatted at call site in mux0App.
        static func selectTabN(_ n: Int) -> LocalizedStringResource {
            LocalizedStringResource("menu.selectTab \(n)")
        }
        /// `%lld` will be formatted at call site in mux0App.
        static func selectWorkspaceN(_ n: Int) -> LocalizedStringResource {
            LocalizedStringResource("menu.selectWorkspace \(n)")
        }
    }
```

- [ ] **Step 5: 跑 smoke test 看到通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/L10nSmokeTests
```

预期：全部 testcase PASS。

- [ ] **Step 6: 提交**

```bash
git add mux0/Localization/Localizable.xcstrings \
        mux0/Localization/L10n.swift \
        mux0Tests/L10nSmokeTests.swift
git commit -m "i18n(menu): add 'Select Workspace N' string for Cmd+1-9 menu items

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: 加入 `mux0SelectWorkspaceAtIndex` notification

**Files:**
- Modify: `mux0/ContentView.swift:351-381`
- Modify: `mux0Tests/NotificationNamesTests.swift`

- [ ] **Step 1: 在 NotificationNamesTests 增加 raw value 断言（先写测试）**

打开 `mux0Tests/NotificationNamesTests.swift`，把整个 `testNewMenuNotificationRawValues` 改为：

```swift
    func testNewMenuNotificationRawValues() {
        XCTAssertEqual(Notification.Name.mux0FocusNextPane.rawValue, "mux0.focusNextPane")
        XCTAssertEqual(Notification.Name.mux0FocusPrevPane.rawValue, "mux0.focusPrevPane")
        XCTAssertEqual(Notification.Name.mux0SelectWorkspaceAtIndex.rawValue,
                       "mux0.selectWorkspaceAtIndex")
        // 注：mux0Copy / mux0Paste / mux0SelectAll 已删除——⌘C/⌘V/⌘A 不再走通知，
        // 改由 mux0App 的 pasteboard CommandGroup 通过 NSApp.sendAction(:to:nil)
        // 沿 responder chain 派发标准 selector，命中 NSText（rename / 设置 TextField）
        // 或终端 GhosttyTerminalView 的同名 selector。
    }
```

- [ ] **Step 2: 跑 test 看到编译失败**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/NotificationNamesTests
```

预期：编译失败，错误是 `Type 'Notification.Name' has no member 'mux0SelectWorkspaceAtIndex'`。

- [ ] **Step 3: 在 ContentView 的 Notification.Name extension 加新名字**

打开 `mux0/ContentView.swift`，找到 `extension Notification.Name` 块（约第 351 行）。在 `mux0SelectTabAtIndex` 后面插入一行：

```swift
    static let mux0SelectNextTab        = Notification.Name("mux0.selectNextTab")
    static let mux0SelectPrevTab        = Notification.Name("mux0.selectPrevTab")
    static let mux0SelectTabAtIndex     = Notification.Name("mux0.selectTabAtIndex")
    static let mux0SelectWorkspaceAtIndex = Notification.Name("mux0.selectWorkspaceAtIndex")
```

- [ ] **Step 4: 跑 test 看到通过**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/NotificationNamesTests
```

预期：PASS。

- [ ] **Step 5: 提交**

```bash
git add mux0/ContentView.swift mux0Tests/NotificationNamesTests.swift
git commit -m "feat(bridge): add mux0SelectWorkspaceAtIndex notification

Pre-wires the channel for the Cmd+1-9 workspace-switch shortcut.
Receiver in SidebarView arrives in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: SidebarView 接收 `mux0SelectWorkspaceAtIndex` + WorkspaceStore 边界回归测试

**Files:**
- Modify: `mux0/Sidebar/SidebarView.swift:71-73`
- Modify: `mux0Tests/WorkspaceStoreTests.swift`

- [ ] **Step 1: 给 WorkspaceStore.select(id:) 写边界回归测试（先写测试）**

打开 `mux0Tests/WorkspaceStoreTests.swift`，找到 `func testSelectWorkspace()`（约第 18 行）。在它**正下方**插入两条新测试：

```swift
    func testSelectWorkspace_unknownIdIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "alpha")
        let alphaId = store.workspaces[0].id
        let unknownId = UUID()
        store.select(id: unknownId)
        XCTAssertEqual(store.selectedId, alphaId,
                       "Selecting an unknown workspace id should not change selectedId")
    }

    func testSelectWorkspace_sameIdIsNoop() {
        let store = WorkspaceStore(persistenceKey: "test-\(UUID())")
        store.createWorkspace(name: "alpha")
        let alphaId = store.workspaces[0].id
        store.select(id: alphaId)  // already selected
        XCTAssertEqual(store.selectedId, alphaId)
    }
```

- [ ] **Step 2: 跑测试看到通过（行为已存在）**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests -only-testing:mux0Tests/WorkspaceStoreTests
```

预期：PASS。两条新测试都不应该 fail —— `WorkspaceStore.select(id:)` 已有 `guard contains` 防御。这步是"锁定行为"防止未来回归。

- [ ] **Step 3: 在 SidebarView 加 onReceive 处理**

打开 `mux0/Sidebar/SidebarView.swift`，找到现有 `.onReceive(NotificationCenter.default.publisher(for: .mux0BeginCreateWorkspace))`（约第 71 行）：

```swift
        .onReceive(NotificationCenter.default.publisher(for: .mux0BeginCreateWorkspace)) { _ in
            createWorkspaceWithDefaultName()
        }
```

在它**正下方**插入：

```swift
        .onReceive(NotificationCenter.default.publisher(for: .mux0SelectWorkspaceAtIndex)) { note in
            guard let idx = note.userInfo?["index"] as? Int,
                  idx >= 0, idx < store.workspaces.count else { return }
            store.select(id: store.workspaces[idx].id)
        }
```

> 防御性地双重保险（这里 `idx < count` + `WorkspaceStore.select` 内部 `guard contains`）—— `select` 已有保护，但 `userInfo` 是 `Any?`，外层校验让 store 层调用更干净。

- [ ] **Step 4: 跑 build 看编译通过**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -5
```

预期：`** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
git add mux0/Sidebar/SidebarView.swift mux0Tests/WorkspaceStoreTests.swift
git commit -m "feat(sidebar): route mux0SelectWorkspaceAtIndex to WorkspaceStore.select

Adds regression tests locking down WorkspaceStore.select(id:) behavior
for unknown-id and same-id cases.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: 改菜单 — File 菜单加 `Cmd+1-9` 切 workspace；Terminal 菜单切 tab 改成 `Cmd+Opt+1-9`

**Files:**
- Modify: `mux0/mux0App.swift:21-92` (body), `mux0/mux0App.swift:108-158` (terminalCommands)

- [ ] **Step 1: 在 mux0App.swift 新增 `workspaceCommands` `@CommandsBuilder`**

打开 `mux0/mux0App.swift`，找到 `@CommandsBuilder private var terminalCommands: some Commands {` 这一行（约第 108 行）。在 `terminalCommands` **正上方**插入新的 builder：

```swift
    @CommandsBuilder private var workspaceCommands: some Commands {
        // 把 Cmd+1-9 绑成「切第 N 个 workspace」放在 File 菜单的 New Workspace 后面。
        // 旧的「Cmd+1-9 切第 N 个 Tab」被降级到 Cmd+Opt+1-9（见 terminalCommands 末尾）。
        // workspace 数量 < N 时由 SidebarView.onReceive 静默忽略，不弹 alert / 不 beep。
        CommandGroup(after: .newItem) {
            Divider()
            ForEach(1...9, id: \.self) { idx in
                Button(String(localized: L10n.Menu.selectWorkspaceN(idx)
                                  .withLocale(LanguageStore.shared.locale))) {
                    NotificationCenter.default.post(
                        name: .mux0SelectWorkspaceAtIndex,
                        object: nil,
                        userInfo: ["index": idx - 1])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: .command)
            }
        }
    }

```

- [ ] **Step 2: 把 `workspaceCommands` 挂进 body 的 `.commands` 块**

仍在 `mux0App.swift`，找到 body 里的 `.commands { ... }`（约第 37-91 行）。在末尾 `terminalCommands` 之前/之后插入 `workspaceCommands` —— 推荐在 `terminalCommands` 上方（这样 .commands 闭包内的物理顺序与最终菜单顺序一致：File → Edit → Terminal）：

把这一段：

```swift
            terminalCommands
        }
    }
```

改成：

```swift
            workspaceCommands
            terminalCommands
        }
    }
```

> SwiftUI `@CommandsBuilder` 闭包的 tuple 上限是 10 个；当前 body 加 workspaceCommands 后是 6 个 `Commands`，仍在限内。

- [ ] **Step 3: 把 Terminal 菜单的 `selectTabN` 改 modifier 到 `[.command, .option]`**

仍在 `mux0App.swift`，找到 `terminalCommands` 末尾的 ForEach（约第 148-156 行）：

```swift
            ForEach(1...9, id: \.self) { idx in
                Button(String(localized: L10n.Menu.selectTabN(idx).withLocale(LanguageStore.shared.locale))) {
                    NotificationCenter.default.post(
                        name: .mux0SelectTabAtIndex,
                        object: nil,
                        userInfo: ["index": idx - 1])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: .command)
            }
```

把 `modifiers: .command` 改成 `modifiers: [.command, .option]`：

```swift
            ForEach(1...9, id: \.self) { idx in
                Button(String(localized: L10n.Menu.selectTabN(idx).withLocale(LanguageStore.shared.locale))) {
                    NotificationCenter.default.post(
                        name: .mux0SelectTabAtIndex,
                        object: nil,
                        userInfo: ["index": idx - 1])
                }
                .keyboardShortcut(KeyEquivalent(Character(String(idx))), modifiers: [.command, .option])
            }
```

- [ ] **Step 4: 跑 build**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -10
```

预期：`** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
git add mux0/mux0App.swift
git commit -m "feat(menu): bind Cmd+1-9 to workspaces; move tab index to Cmd+Opt+1-9

- New File-menu items 'Select Workspace 1…9' bound to Cmd+1…Cmd+9.
- Existing Terminal-menu 'Select Tab N' moved from Cmd+N to Cmd+Opt+N.
- Routes through mux0SelectWorkspaceAtIndex notification → SidebarView →
  WorkspaceStore.select(id:); workspace count < N silently ignored.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: TabContentView 的 keyMonitor 加 `Ctrl+Tab` / `Ctrl+Shift+Tab`

**Files:**
- Modify: `mux0/TabContent/TabContentView.swift:483-498`

- [ ] **Step 1: 改写 installKeyMonitor 加新分支**

打开 `mux0/TabContent/TabContentView.swift`，找到 `private func installKeyMonitor()`（约第 483 行）。当前实现：

```swift
    private func installKeyMonitor() {
        // ⌘⌥→ and ⌘⌥← are now menu items (Terminal → Focus Next/Previous Pane),
        // so SwiftUI dispatches those via .mux0FocusNextPane / .mux0FocusPrevPane.
        // The monitor remains only for the ↑/↓ aliases — intentional hidden duplicates
        // not shown in the menu, kept because they're a common pane-nav habit.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  event.modifierFlags.intersection([.command, .option]) == [.command, .option]
            else { return event }
            switch event.keyCode {
            case 125: self.focusAdjacentPane(forward: true);  return nil  // ↓
            case 126: self.focusAdjacentPane(forward: false); return nil  // ↑
            default: return event
            }
        }
    }
```

整段替换为：

```swift
    private func installKeyMonitor() {
        // 处理两组 menu 不可见的 hidden duplicate 快捷键：
        // - ⌘⌥↑/↓ 是 Terminal → Focus Next/Previous Pane 的别名（菜单展示
        //   ⌘⌥→/← 给水平 pane 直觉；↑/↓ 是常见 pane-nav 习惯）
        // - Ctrl+Tab / Ctrl+Shift+Tab 是 Terminal → Select Next/Previous Tab
        //   (⌘⇧]/[) 的浏览器/iTerm 风格别名
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // 只看 ⌘⌃⌥⇧ 这四位，忽略 .numericPad / .function / .capsLock 等
            let interesting: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            let mods = event.modifierFlags.intersection(interesting)

            // ⌘⌥↑/↓ — pane 切焦点
            if mods == [.command, .option] {
                switch event.keyCode {
                case 125: self.focusAdjacentPane(forward: true);  return nil  // ↓
                case 126: self.focusAdjacentPane(forward: false); return nil  // ↑
                default: break
                }
            }

            // Ctrl+Tab / Ctrl+Shift+Tab — tab 循环（keyCode 48 = Tab）
            if event.keyCode == 48 {
                if mods == [.control] {
                    self.cycleTab(forward: true);  return nil
                }
                if mods == [.control, .shift] {
                    self.cycleTab(forward: false); return nil
                }
            }

            return event
        }
    }
```

- [ ] **Step 2: 跑 build**

```bash
xcodebuild -project mux0.xcodeproj -scheme mux0 -configuration Debug build 2>&1 | tail -10
```

预期：`** BUILD SUCCEEDED **`。

- [ ] **Step 3: 跑全套 model 层测试确认没回归**

```bash
xcodebuild test -project mux0.xcodeproj -scheme mux0Tests 2>&1 | tail -20
```

预期：所有 testcase PASS。

- [ ] **Step 4: 提交**

```bash
git add mux0/TabContent/TabContentView.swift
git commit -m "feat(tabcontent): add Ctrl+Tab / Ctrl+Shift+Tab tab cycling

NSEvent local monitor branches for browser/iTerm-style tab nav,
sharing TabContentView.cycleTab(forward:) with the Cmd+Shift+]/[
menu shortcut. Hidden from the menu (matching the existing ⌘⌥↑/↓
pane-nav alias) so the menu shows only one canonical shortcut.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: 文档漂移检查 + 手动验证

**Files:**
- Run: `./scripts/check-doc-drift.sh`
- Manual smoke test

- [ ] **Step 1: 跑文档漂移检查**

```bash
./scripts/check-doc-drift.sh
```

预期：脚本通过（本次没新增/删除/重命名 Swift 文件，目录结构未变；landing 版本号未动）。

如果 fail，根据脚本输出修复（不应该 fail —— 本次仅修改文件内容）。

- [ ] **Step 2: 启动应用做手动验证**

> ⚠️ 按照 CLAUDE.md "Agent Permissions"：**不要主动 `open` / `killall` mux0.app**。这一步把验证清单交给用户做。

输出验证清单到本任务的 plan 输出里：

```
请手动验证以下场景（每条勾上后回报）：

① 多 workspace 时（先在侧栏新建至少 3 个 workspace）：
   - [ ] 按 Cmd+1 → 切到第 1 个 workspace
   - [ ] 按 Cmd+2 → 切到第 2 个
   - [ ] 按 Cmd+3 → 切到第 3 个

② workspace 数 < N 时：
   - [ ] 只有 2 个 workspace 时按 Cmd+5 → 当前 workspace 不变，无 alert / 无 beep

③ 当前 workspace 多 tab 时：
   - [ ] 按 Cmd+Opt+1 → 切到第 1 个 tab
   - [ ] 按 Cmd+Opt+2 → 切到第 2 个

④ Ctrl+Tab：
   - [ ] 多 tab 时按 Ctrl+Tab → 顺时针下一个 tab
   - [ ] 按 Ctrl+Shift+Tab → 逆时针上一个 tab
   - [ ] 单 tab 时按 Ctrl+Tab → 无变化 / 无 beep

⑤ 终端 first responder 时：
   - [ ] 在终端跑 `vim`，按 Ctrl+Tab → mux0 切 tab，shell 不收到 \t
   - [ ] 切回原 tab 后 vim 状态保留

⑥ 菜单显示：
   - [ ] File 菜单底部能看到 "Select Workspace 1" … "Select Workspace 9"，
        快捷键显示 ⌘1 … ⌘9
   - [ ] Terminal 菜单的 "Select Tab 1" … "Select Tab 9" 显示 ⌘⌥1 … ⌘⌥9

⑦ 中英语言切换：
   - [ ] Settings → Appearance → Language 切到中文 → File 菜单显示 "切换到第 1 个工作区" 等
   - [ ] 切回 English → 显示 "Select Workspace 1" 等
```

- [ ] **Step 3: （用户回报全绿后）开 PR**

按记忆中的 `feedback_no_auto_git_push` 偏好：**不要自动 push** —— 让用户显式触发：

输出建议命令给用户执行：

```bash
# 当前在 master 分支，本地有 6 个 commit。建议切到 feature 分支再 push：
git checkout -b agent/keyboard-shortcuts-tab-workspace
git push -u origin agent/keyboard-shortcuts-tab-workspace
gh pr create --base master \
    --title "feat: keyboard shortcuts for tab/workspace switching" \
    --body "Summary: bind Cmd+1-9 to workspaces, move tab index to Cmd+Opt+1-9, add Ctrl+Tab/Ctrl+Shift+Tab tab cycling.

Spec: docs/superpowers/specs/2026-05-07-keyboard-shortcuts-tab-workspace-design.md"
```

> 按记忆 `feedback_pr_body_no_test_plan`，PR body 不含默认 test plan 模板，只放 Summary + spec 引用。

---

## Self-Review Checklist (作者自查，不分发)

- ✅ Spec 覆盖：
  - `Cmd+1-9 → workspace` 由 Task 1（i18n）+ Task 2（notification）+ Task 3（路由）+ Task 4（菜单）覆盖
  - `Cmd+Opt+1-9 → tab` 由 Task 4（modifier 改动）覆盖
  - `Ctrl+Tab / Ctrl+Shift+Tab` 由 Task 5 覆盖
  - 边界（workspace 数 < N、未知 id）由 Task 3 单测 + Task 6 手测覆盖
  - i18n 中英 by Task 1
- ✅ 无 placeholder：每个 step 都有完整代码块或具体命令
- ✅ 类型一致：`mux0SelectWorkspaceAtIndex` 在 NotificationNamesTests / ContentView / SidebarView / mux0App 四处用同一名字；`L10n.Menu.selectWorkspaceN` 函数签名 `(_ n: Int) -> LocalizedStringResource` 在 L10n.swift 定义、mux0App 调用一致
- ✅ frequent commit：6 个 task 每个一次 commit
- ✅ 测试设计：i18n 走 smoke test (Task 1)、notification name 走 raw value test (Task 2)、store 边界走单测 (Task 3)、UI 行为走手测 (Task 6)
