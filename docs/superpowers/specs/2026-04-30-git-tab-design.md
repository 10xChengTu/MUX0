# Git Tab —— Design

## Context

mux0 目前所有 tab 内容都是 ghostty surface（一个或多组 split），用户要看 git 状态只能在某个 pane 里手动敲 `git diff`、`git log`，或者自己 ⌘D 拆个 pane 跑 `lazygit`。

用户希望在 mux0 里有一种"看 diff / 看历史 / 操作 git"的常驻入口：右上角点一下，就能在当前 workspace 看到当前仓库的 git 视图，并且重启后这个视图能自动恢复。

## Goals

- **零自研 git UI**——直接复用社区成熟工具（`lazygit` 默认）作为 git 视图的载体，跑在一个常规的 ghostty surface 里。
- **每个 workspace 最多一个 git tab**，重复点 git 图标只切换不新建。
- **重启后 git tab 自动恢复并重新执行 git viewer 命令**（不只是恢复成空 shell）。
- **tab pill 视觉上能一眼区分 git tab 与普通 terminal tab**——两类都加 leading icon。
- **git viewer 命令可配**：默认 `lazygit`，用户可以改 `gitui` / `tig` / 任意 shell 命令。

## Non-Goals

- 不自研原生 SwiftUI/AppKit 的 diff / log viewer。
- 不嵌 WebView，不打包 lazygit 二进制（依赖用户 PATH）。
- 不做 inline split git pane（决定走"独立 tab"形态，而不是当前 tab 内 split）。
- 不做 drawer / overlay 形态。
- 不做"每个 workspace 默认 pin 一个 git tab"的自动化。
- 不为 git 图标做"非 git 仓库时禁用"的预检测（让 lazygit 自己报错，避免与 5s metadata refresh 形成 race）。
- 不打包 lazygit；不做未安装时的引导弹窗（设置文案里提一行安装命令即可）。
- 不为 git tab 做特殊的关闭确认 / 重命名锁定（沿用现有 tab 流程）。

## Architecture

```
[ContentView ZStack]
   ├─ HStack (sidebar + cards)
   ├─ sidebarToggleButton (top-leading, 已存在)
   └─ gitTabButton (top-trailing, 新增)
            │ click
            ▼
   WorkspaceStore.ensureGitTab(in:)
            │
            ├─ 已有 kind==.git 的 tab → selectTab + return (isNew: false)
            └─ 没有 → addTab(kind: .git) + 继承当前焦点 pane 的 pwd
                       │
                       └─ store 推送 → TabBridge → TabContentView.loadWorkspace
                                  │
                                  └─ buildSplitPane → terminalViewFor(id) → resolvedStartupCommand
                                              │
                                              └─ 检测 tab.kind == .git
                                                  → 注入 "{viewerCommand}\n" 作为 initial_input
                                                  → ghostty surface 启动后自动跑 lazygit
```

## Data Model 变更

### `TerminalTab.kind: TabKind?`

新增 enum，nil 表示普通 terminal tab：

```swift
enum TabKind: String, Codable {
    case git
    // 未来可扩展：.logs, .aiSummary, ...
}

struct TerminalTab: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var layout: SplitNode
    var focusedTerminalId: UUID
    var kind: TabKind? = nil   // ← 新增
    // ...
}
```

Codable 走 `decodeIfPresent`，老持久化数据自动落到 nil，向后兼容。Identity 仍然只看 `id`，`kind` 不参与 Equatable 之外的索引。

**为什么不用 bool**：未来若要再加"logs viewer"这类语义化 tab，不必再加一个 bool。enum + Codable 表达力强、迁移成本同样为零。

### `WorkspaceStore.ensureGitTab(in:)`

```swift
@discardableResult
func ensureGitTab(in workspaceId: UUID) -> (
    tabId: UUID,
    terminalId: UUID,
    isNew: Bool,
    sourcePwdTerminalId: UUID?   // 切换前焦点 tab 的 focusedTerminalId，用于 pwd 继承
)
```

行为：
1. **先 capture** `workspace.selectedTab?.focusedTerminalId` 到 `sourcePwdTerminalId`——必须在改 selectedTabId 之前取，否则之后取到的就是新 git tab 自己的终端。
2. 在指定 workspace 的 `tabs` 中找首个 `kind == .git` 的 tab。
3. 找到 → `selectTab(id:in:)` 切过去，返回 `(existing.id, existing.focusedTerminalId, false, sourcePwdTerminalId)`。
4. 没找到 → 调用 `addTab(to:kind:)` 创建 `kind = .git` 且 `title = "Git"` 的 tab，selectTab 切过去，返回 `(new.id, new.firstTerminalId, true, sourcePwdTerminalId)`。
5. 不做"如果 git tab 存在但被用户重命名了"这类追加判断——识别只看 kind。

### `WorkspaceStore.addTab(to:kind:)` 微调

把现有 `addTab(to:)` 改签名加可选 `kind`：

```swift
func addTab(to workspaceId: UUID, kind: TabKind? = nil) -> (tabId: UUID, terminalId: UUID)?
```

调用点（`TabContentView.addNewTab`、菜单 `mux0NewTab` 等）默认走 `kind: nil`，行为不变。

## UI 变更

### 1. 右上角 git 图标按钮

在 `ContentView.body` 的 ZStack 里追加一个对称于 `sidebarToggleButton` 的 overlay 节点：

```swift
gitTabButton
    .frame(maxWidth: .infinity, alignment: .topTrailing)
    .padding(.trailing, cardInset + 4)   // 与右侧 cards 对齐
    .padding(.top, DT.Space.xs)          // 与 sidebar toggle 同 Y
```

`gitTabButton` 用现有 `IconButton`：

```swift
IconButton(
    theme: themeManager.theme,
    help: String(localized: L10n.Topbar.gitButton.tooltip.withLocale(locale))
) {
    guard let wsId = store.selectedId else { return }
    let result = store.ensureGitTab(in: wsId)
    if result.isNew, let prev = result.sourcePwdTerminalId {
        // 与 addNewTab 同路径：从切换前焦点 pane 继承 pwd
        pwdStore.inherit(from: prev, to: result.terminalId)
    }
} label: {
    Image(systemName: "arrow.triangle.branch")
        .font(.system(size: 13, weight: .regular))
        .foregroundColor(Color(themeManager.theme.textSecondary))
}
.disabled(store.selectedId == nil)
```

`previouslyFocusedTerminalId(in:)` 的取值是"切到 git tab **之前**那个 tab 的 focusedTerminalId"——为了拿到这个值，`ensureGitTab` 内部要在 `selectTab` **之前**先 capture 旧的 focused，并把它一起回传，否则切完 tab 之后取到的就是新 git tab 自己的终端：

```swift
@discardableResult
func ensureGitTab(in workspaceId: UUID) -> (tabId: UUID, terminalId: UUID, isNew: Bool, sourcePwdTerminalId: UUID?)
```

按钮 disabled 条件仅是"没有选中的 workspace"。**不**因为不在 git 仓库就 disable——5s metadata refresh 与点击会形成 race，且 lazygit 本身会优雅报错，没必要在 mux0 这边再造一层判断。

### 2. Tab pill 加 leading icon（git tab 与普通 terminal tab **都加**）

`TabBarView.swift` 内部的 `TabItemView`（private）当前布局：

```
[ pillView background ]
  margin       margin
   ↓             ↓
   titleLabel ── statusIcon (右对齐, 仅 showStatusIndicators 时显示)
```

改为：

```
[ pillView background ]
  margin              margin
   ↓                    ↓
   kindIcon  titleLabel ── statusIcon
       gap6        gap6
```

实现细节：
- 新增 `private let kindIcon = NSImageView()`，`addSubview(kindIcon)`。
- 用 `NSImage(systemSymbolName:)` + `NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)` 渲染。
- `tab.kind == .git` → SF Symbol `arrow.triangle.branch`；nil → SF Symbol `terminal`。
- `kindIcon.contentTintColor` 跟随 `titleLabel.textColor`（`updateStyle()` 里同步设）：选中走 `theme.textPrimary`，hover/idle 走 `theme.textSecondary`。这样 kind icon 不会跟标题脱节。
- `layout()` 把 kindIcon 放在最左侧（`x = margin`），titleLabel 的起点向右挪 `kindIconSize + gap` (≈ 11 + 6 = 17pt)。其余规则不变。
- **kind icon 一直显示**，与 `showStatusIndicators` 这套 agent 开关解耦——它表达的是 tab 的"身份"，不是 agent 状态。
- **重命名模式不影响 kind icon**：`renameField` 替换的是 `titleLabel` 区域，kindIcon 是独立 subview，layout 不变。

#### 视觉预算

tab pill 固定 140pt 宽：
- 当前：`margin(10) + title + (statusIcon 时 gap6 + 10)` ≈ ~110pt 留给 title。
- 之后：`margin(10) + kindIcon(11) + gap6 + title + (statusIcon 时 gap6 + 10) + margin(10)` ≈ ~93pt 留给 title。

差异不大，title 已经是 `.byTruncatingTail`，长名字会更早出现 `…`，可接受。

#### git tab 上的 status icon 行为

`TerminalStatus.aggregate` 会把 git tab 唯一终端的 `.neverRan` 算出来。如果用户启用了任何 agent toggle，`showStatusIndicators` 就是 ON，git tab 的右侧也会显示一个 `neverRan` 的 dot。

**不在 v1 做特殊处理**——`.neverRan` 当前已经是非常浅的颜色，与 git tab 的 leading icon 没有视觉冲突。如果实战发现噪点，再用一行 `if tab.kind == .git { hide statusIcon }` 灭掉。

### 3. tab 标题 / 重命名行为

- 新建 git tab 默认 `title = "Git"`（i18n key `tab.git.defaultTitle`，en/zh 都译作 "Git"）。
- **允许重命名**——沿用现有 rename 流程，无任何特例。
- 复用语义只看 `kind == .git`，与 title 无关——用户即使把 git tab 改名 "代码评审"，再点 git 图标依然命中同一个 tab。

## 命令注入

### 路径

`TabContentView.resolvedStartupCommand(forTerminal id: UUID) -> String?`

在现有逻辑之前加一段：

```swift
// Git tab 的"首终端"始终注入配置中的 git viewer 命令。
// "首终端" = 该 tab layout 中深度优先序（SplitNode.allTerminalIds()）的第一个 terminal id。
// 这意味着：用户在 git tab 内 ⌘D split 出来的新 pane 不会再跑 lazygit，
// 而是落到普通的 defaultCommand / 空 shell 路径上。
if let tab = store?.selectedWorkspace?.tabs.first(where: {
        $0.layout.allTerminalIds().contains(id)
    }),
    tab.kind == .git,
    id == tab.layout.allTerminalIds().first {
    let viewer = settingsStore?.get("mux0-git-viewer")?
                     .trimmingCharacters(in: .whitespacesAndNewlines)
    let cmd = (viewer?.isEmpty == false ? viewer! : "lazygit")
    return "\(cmd)\n"
}
// (现有 pendingPrefills agent resume 逻辑、defaultCommand 逻辑保持不变)
```

### 重启行为

`tab.kind` 持久化在 UserDefaults（走 `Workspace.tabs` 编码路径）。重启 mux0 → workspace 加载 → tab 还原 → 用户切到 git tab → `terminalViewFor` 第一次创建 surface → `resolvedStartupCommand` 命中 git 分支 → lazygit 自动重跑。

整个流程无需额外的 "git tab 恢复" 状态机——它就是普通 tab + kind 字段。

### 多 surface 的边界

如果用户在 git tab 内 ⌘D split：
- 老 pane（layout 第一个 terminal）继续跑 lazygit。
- 新 pane（layout 第二个 terminal）走 `defaultCommand` / 空 shell——不跑 lazygit，符合"想在 diff 旁边开一个普通 shell"的预期。

如果用户关闭老 pane（lazygit 那个）：
- `closeTerminal` 把它从 layout 里摘掉，剩下的"第一个"变成原来的第二个。
- 该终端的 surface 已经存在（不会再次走 `resolvedStartupCommand`），所以**不会**因为变成了"layout 第一"就突然跑 lazygit。
- 相当于这个 git tab 退化成普通 tab；用户可以手动 `lazygit` 或者关掉重新点 git 图标。

边界行为可接受、可解释。

## 设置项

新增一项配置，写入与读取走 `SettingsConfigStore`：

| Key | Default | Section | UI |
|-----|---------|---------|----|
| `mux0-git-viewer` | `"lazygit"` | Shell | TextField |

UI 文案：

```
Git viewer command  [ lazygit                              ]
点击右上角 Git 图标后，这条命令会在 Git tab 里自动执行。
推荐: lazygit、gitui、tig。
安装 lazygit: brew install lazygit
```

放到 `Settings/Sections/ShellSectionView.swift`（与 `defaultCommand` 同 section，语义最近）。

校验逻辑：用户可以清空——清空时 `resolvedStartupCommand` 退回到 `"lazygit"` 默认（避免一空字符串就崩 / 空 prefill 触发奇怪的 shell 行为）。

`docs/settings-reference.md` 同步追加该字段。

## i18n

`mux0/Localization/Localizable.xcstrings` 新增以下 key（en source / zh-Hans 翻译）：

| Key | en | zh-Hans |
|-----|----|---------|
| `tab.git.defaultTitle` | Git | Git |
| `topbar.gitButton.tooltip` | Open Git Viewer | 打开 Git 视图 |
| `settings.shell.gitViewer.label` | Git viewer command | Git 工具命令 |
| `settings.shell.gitViewer.help` | Runs in the Git tab created by clicking the Git icon. Try `lazygit`, `gitui`, or `tig`. | 点击 Git 图标后会在 Git tab 里自动执行的命令。可选：`lazygit`、`gitui`、`tig`。 |
| `settings.shell.gitViewer.installHint` | Install: `brew install lazygit` | 安装：`brew install lazygit` |

`L10n.swift` 同步加常量命名空间 `L10n.Topbar.gitButton.tooltip` 等。

## 弃案（Why not）

- **A. 自研 SwiftUI diff/log viewer**——工作量与 mux0 当前体量不匹配；用户也明确表示"尽量用现成方案"。
- **B. WebView 嵌 git web UI**（git instaweb / 自拼 diff2html）——没有可直接嵌的现成方案，自拼反而比 lazygit pane 还复杂。
- **C. 当前 tab 内 ⌘⇧G split 出 git pane**——能做"diff 与命令并排"但会跟正在跑的终端抢空间，关掉 lazygit 后 pane 处于半残留状态，复用语义比独立 tab 复杂。
- **D. 全局 drawer/overlay**——需要在 `TabContentView` 里加一层新布局逻辑、宽度持久化、显隐状态机；与"用现成方案"的约束相悖。
- **kind 用 bool（`isGitTab`）而不是 enum**——未来扩展性差，迁移成本一致，没理由选 bool。
- **不在 git 仓库时 disable 按钮**——会与 metadata 5s tick 形成 race；lazygit 自己会报错，UX 上少一层"为什么按钮灰着"的解释成本。

## 测试

`mux0Tests/`：

1. `WorkspaceStoreTests.testEnsureGitTab_createsNewWhenAbsent`
   - 空 workspace 调 `ensureGitTab` → 返回 `isNew: true`，workspace.tabs 增一个 `kind == .git` 的 tab，selectedTabId 指向它。
2. `WorkspaceStoreTests.testEnsureGitTab_reusesWhenPresent`
   - workspace 已有 `kind == .git` tab → `ensureGitTab` 返回 `isNew: false`，tabs 数量不变，selectedTabId 切到已有 git tab。
3. `WorkspaceStoreTests.testEnsureGitTab_returnsSourcePwdTerminal`
   - 创建场景下，sourcePwdTerminalId 等于切换前焦点 tab 的 focusedTerminalId（用于 pwd 继承）。
4. `WorkspaceStoreTests.testTerminalTabKind_codableRoundTrip`
   - kind = nil 与 kind = .git 各编码一次再解码，相等。
5. `WorkspaceStoreTests.testTerminalTabKind_decodingLegacyJSON`
   - 不含 `kind` 字段的旧 JSON 解码后 kind == nil。
6. `L10nSmokeTests`
   - 新增 5 个 key 在 en/zh 两侧都存在且非空。

`TabContentView` 的命令注入路径不直接好测（依赖 store + settings + ghostty surface），手动验证：
- 点击 git 图标 → 新 git tab → lazygit 在新 surface 里启动。
- 改 setting 为 `tig` → 关 git tab → 重新点 git 图标 → 跑 tig。
- 清空 setting → 跑 lazygit（默认）。
- 重启 mux0 → 之前的 git tab 还在 → 自动重跑配置中的 viewer。
- 在 git tab 内 ⌘D → 新 pane 是普通 shell（不跑 lazygit）。

## 文档同步

实现完成后同步更新：

- `CLAUDE.md` Directory Structure：`Models/Workspace.swift` 注释里提一句 `TabKind`；Common Tasks 加一条 "新增 tab kind"。
- `AGENTS.md`（如果与 CLAUDE.md 镜像）。
- `docs/architecture.md` Tab content 部分加 git tab 行为描述。
- `docs/settings-reference.md` 加 `mux0-git-viewer`。
- `./scripts/check-doc-drift.sh` 跑一遍。

## Rollout

单 PR 即可（feat 范围：models / store / tabbar / contentview / settings / i18n + 新 key + tests + 文档），分支 `agent/git-tab`。无功能开关——视觉变化（tab pill 加 leading icon）是温和的纯增量改动。
