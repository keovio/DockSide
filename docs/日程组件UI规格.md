# DockSide 日程组件 UI 规格

| 项   | 内容                                                                                                                                                                             |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 版本  | v1.3                                                                                                                                                                           |
| 日期  | 2026-10-22                                                                                                                                                                     |
| 依据  | [keovio/DockSide](https://github.com/keovio/DockSide) main 分支源码实测（2026-10-22 05:35 拉取）：`Widgets.swift`、`BasicWidgets.swift`、`Todo.swift`、`SettingsView.swift`、`Settings.swift` |
| 适用  | 新增「日程」组件（id: `schedule`），三级显示：胶囊态 → 悬停 popover → 完整窗口                                                                                                                          |
| 状态  | 待客户端实现，待测试验收                                                                                                                                                                   |
|     |                                                                                                                                                                                |

> 本文所有「size」指环境值 `\.widgetFontSize`（SideView 运行时按 Dock 粗细算出，`max(9, cross × (竖排 0.21 / 横排 0.27) × fontScale)`），胶囊内一切尺寸用它表达倍数，与现有组件做法一致；popover 与完整窗口用绝对 pt。

---

## 0. 视觉基线（照抄现有实现，不新造）

这些是已核实的设计 token，日程组件必须复用，保证与时钟/待办/番茄钟放一排时长得像一家人：

| Token  | 值                                                                                                                                                              | 来源                           |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- |
| 统一文字样式 | `.font(.system(size: size, weight: .medium, design: .rounded))` + `.monospacedDigit()` + `.lineLimit(1)` + `.foregroundStyle(ink)`，即 `.modifier(WidgetText())` | Widgets.swift `WidgetText`   |
| 文字颜色   | 环境值 `\.widgetInk`：独立胶囊/unified 用白色，融进 Dock（merged）用 `Color.primary`                                                                                            | Widgets.swift `InkKey`       |
| 毛玻璃底   | `ultraThinMaterial` + `Color.black.opacity(0.14)` 填充 + `Color.white.opacity(0.14)` 描边 0.5pt，即 `.glass(shape)`                                                  | Widgets.swift `glass()`      |
| 胶囊圆角   | `cross × 0.36`（cross = Dock 粗细方向尺寸），`.continuous` 曲率                                                                                                           | SideView.row() separate 分支   |
| 胶囊内边距  | 横排：水平 `size × 0.8`、垂直 `size × 0.45`；竖排：水平 `size × 0.45`、垂直 `size × 0.45`                                                                                       | SideView.item()              |
| 进度环    | 底环 `ink.opacity(0.2)`；进度色 `Color(red: 0.36, green: 0.82, blue: 0.55)`；round 线帽；从 -90°（12 点钟）起笔                                                                 | Widgets.swift `ProgressRing` |
| 超长滚动   | `Marquee(text:width:)`：放得下静止；放不下 30fps 滚动，间隔 40pt，速度 30pt/s                                                                                                    | Todo.swift `Marquee`         |
| 刷新     | `TimelineView(.periodic(from: .now, by: 60))`，与 DateWidget 一致，每 60s                                                                                            | BasicWidgets.swift           |
| 日期格式   | `formatDate(_:_:)`，`Locale(identifier: "zh_CN")`                                                                                                               | BasicWidgets.swift           |

---

## 1. 组件注册与文件结构

### 1.1 注册（Widgets.swift `allWidgets` 数组加一行）

```swift
WidgetDef(id: "schedule", name: "日程", symbol: "calendar.badge.clock") { AnyView(ScheduleWidget()) }
```

### 1.2 新文件 `Sources/DockSide/Schedule.swift`（对齐 Todo.swift 的分区结构）

```
MARK: - 数据        CalendarEvent 模型 / ScheduleStore（EventKit + 本地 JSON 双源）
MARK: - 提示音      ScheduleSound（复用 TodoSound 模式）
MARK: - 数据导入导出  ScheduleIO（本地 JSON 的导入/导出/在访达中显示）
MARK: - Dock 旁组件  ScheduleWidget（胶囊态）
MARK: - 悬停展开    SchedulePopover / SchedulePopoverView
MARK: - 完整窗口    ScheduleWindow / ScheduleWindowView（周/日视图）
```

设置侧：`SettingsView.swift` 的 `SettingsPage` 枚举加 `case schedule`（title「日程」，symbol `calendar.badge.clock`），插进侧栏「组件」Section 的 todo 之后；新建 `SchedulePane`。`Settings.swift` 的 `Pref` 加键并 `register(defaults:)`。

### 1.3 数据模型（Chief 方案原文）

```swift
struct CalendarEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var isAllDay = false
    var calendarName: String = ""
    var calendarColor: String = ""   // hex，如 "#4A99E9"；EventKit 来源时由 cgColor 转换
}
```

本地备选源路径：`~/Library/Application Support/DockSide/schedule.json`（对齐 `todos.json` 的存取方式：原子写入、启动时解码）。

---

## 2. 胶囊态（默认形态）

### 2.1 横排（Dock 在屏幕底部，`compact == false`）

布局模板 = TodoWidget 横排（环 + 文字列），不做图标开头——图标省给竖排用，横排信息量优先：

```
┌────────────────────────────────────────────┐
│ ● 14:30  产品评审会                    12m │
└────────────────────────────────────────────┘
  ↑绿点     ↑时间   ↑Marquee 标题          ↑距开始
```

```swift
HStack(spacing: size * 0.5) {
    状态点或时间          // 见 2.3 状态矩阵
    Marquee(text: title, width: size * 0.95 * CGFloat(scheduleTitleChars))
        .font(.system(size: size * 0.95, weight: .semibold, design: .rounded))
    剩余时间（可选尾标）
}
.modifier(WidgetText())
```

| 参数 | 值 |
|---|---|
| HStack spacing | `size × 0.5` |
| 标题字号 | `size × 0.95`，`.semibold`，rounded |
| 标题宽度 | `size × 0.95 × scheduleTitleChars`（Marquee 固定宽，设置项默认 6 字，选项 4/6/8/10/12，对齐 TodoPane 的「标题宽度」） |
| 时间字号 | `size`（WidgetText 默认），`.monospacedDigit()` 由 WidgetText 提供 |
| 时间格式 | `schedule24h` 开 → `HH:mm`；关 → `h:mm`（复用 ClockWidget 的 h24 切法） |
| 副标/尾标字号 | `size × 0.74`，opacity 0.7（对齐「点这里添加待办」） |
| 交互 | 整体 `.contentShape(Rectangle())`：单击 → toggle popover；`onHover` 进 → `SchedulePopover.shared.show()`，出 → `scheduleHide()`（仅当 `scheduleHover` 开，默认开） |
| 刷新 | `TimelineView(.periodic(from: .now, by: 60))` |

### 2.2 竖排紧凑（Dock 在屏幕左右，`compact == true`）

布局模板 = TodoWidget compact（环 + 数字）+ DateWidget compact 的双行结构：

```
   ⭕  ← 进度环（今日已过比例），环心数字 = 今日剩余事件数
  14:30  ← 下一场时间（size×0.75，超宽截断）
```

```swift
VStack(spacing: size * 0.15) {
    ProgressRing(progress: todayElapsedRatio, size: size * 1.9, lineWidth: size * 0.16) {
        Text("\(upcomingToday)").font(.system(size: size * 0.75, weight: .bold, design: .rounded))
    }
    Text(shortTime).font(.system(size: size * 0.72, weight: .semibold, design: .rounded)).opacity(0.85)
}
.modifier(WidgetText())
```

| 参数 | 值 |
|---|---|
| 环尺寸 / 线宽 | `size × 1.9` / `size × 0.16`（与 TodoWidget compact 完全同款） |
| 环进度 | 今日 00:00 → 24:00 已过比例（`(now - 今日零点) / 86400`），环色沿用默认绿 `Color(red: 0.36, 0.82, 0.55)` |
| 环心数字 | 今日尚未结束的事件数，`size × 0.75` bold rounded |
| 下方时间行 | 下一场开始时间 `HH:mm`（或「进行中」），`size × 0.72` semibold，opacity 0.85，`lineLimit(1)`；标题不放——竖排宽度不够，标题留给 hover popover |
| VStack spacing | `size × 0.15` |
| 交互 | 同横排：单击 toggle、悬停展开 |

> 竖排下方不滚动标题：cross 方向可用宽度 ≈ Dock 粗细，减去水平 padding `size × 0.45 × 2` 后放不下可读文字；Chief 方案里「下方滚动下一条标题」在竖排实现为只滚动「时间行」的 Marquee（`width: cross - size × 0.9`），时间超长（如「明天 09:00」）时滚动显示。

### 2.3 胶囊状态矩阵（状态定义是本组件的核心交付）

| 状态 | 判定 | 横排显示 | 竖排显示 |
|---|---|---|---|
| 进行中 | `now ∈ [start, end)` | 绿点 `●`（6pt 圆，绿色 `Color(red: 0.36, 0.82, 0.55)`，间距 `size × 0.3`）+ 标题；时间位显示「进行中」；尾标显示剩余 `Xm`（不足 1h）或 `Xh` | 环心数字照常；时间行显示「进行中」 |
| 即将开始（今日） | `start > now` 且 start 在今日 | `HH:mm` + 标题；距开始 ≤ 15min 时尾标 `Xm` 并每 60s 刷新逼近 | `HH:mm` |
| 跨天即将开始 | 今日无更多，取预读窗口内最近一条 | `明天 HH:mm` / `周X HH:mm`（超过明天才带星期）+ 标题 | `明天`（只放得下两字，help tooltip 放全文） |
| 无日程 | 预读窗口内无事件 | 「暂无日程」`size × 0.95` semibold opacity 0.7 | 环心 `0`，时间行显示「—」opacity 0.5 |
| 未授权（首次） | EventKit status == .notDetermined | 「授权日历」文案，单击弹系统授权框 | 环心 `?` |
| 已拒绝授权 | status == .denied 或用户选了本地模式 | 正常显示本地 JSON 数据（降级不降体验） | 同左 |

尾标规则补充：进行中且剩余 > 1h 显示 `Xh`；即将开始且距开始 > 60min 不显示尾标（避免噪音）。所有「Xm/Xh」用 `size × 0.74` opacity 0.7。

---

## 3. 悬停 Popover（今日时间轴）

### 3.1 窗口与显隐（照抄 TodoPopover 的机制，逐参数对齐）

| 参数 | 值 | 备注 |
|---|---|---|
| 窗口 | `KeyPanel`，`[.borderless, .nonactivatingPanel]`，`isOpaque=false`，`backgroundColor=.clear`，`hasShadow=true` | Todo.swift `makePanel()` 同款 |
| 宽度 | **340pt** 固定 | Chief 方案定值 |
| 高度 | `min(max(120 + rows × 34, 220), 560)`，rows = `min(事件数 + 全天数, 10)` | 对齐 Todo 的自适应公式（底部多了添加栏，起高从 170 提到 220） |
| 层级 | `dockSideLevel.rawValue + 1` | |
| 显示动画 | alpha 0 → 1，`NSAnimationContext` duration **0.15s** | |
| 隐藏延迟 | 悬停离开后 **0.35s**；鼠标在 `frame.insetBy(dx: -6, dy: -6)` 内或面板是 key window（正在输入）时不收起 | `scheduleHide()` 逐行复用 |
| 定位 | 竖排 Dock：贴 Dock 侧偏移 8pt，垂直居中于鼠标；横排 Dock：组件正上方 `top + 8`，水平居中于鼠标；屏幕边缘 8pt 收容 | Todo `position()` 同款 |
| 激活 | `.canJoinAllSpaces, .stationary, .ignoresCycle` | |

### 3.2 Popover 内容布局（`SchedulePopoverView`）

整体：外层 `padding(14)`，`VStack(alignment: .leading, spacing: 10)`，背景 `VisualEffect(material: .hudWindow)` 圆角 **14pt** `.continuous`，强制 `.environment(\.colorScheme, .dark)`——与 TodoPopoverView 逐参数一致。

```
┌──────────────────────────────────────┐
│ 10月22日 周四 · 5 项           ⤢      │ ← 头部
│ [全部] [工作] [家庭] [+]              │ ← 日历筛选 chips（可折叠）
├──────────────────────────────────────┤
│ ■ 全天 · 团队休假日                   │ ← 全天区（固定顶部）
│ ■ 全天 · 项目里程碑                   │
├──────────────────────────────────────┤
│ 09:00 – 10:00  晨会          ■      │
│ 14:30 – 15:30  产品评审会     ■      │ ← 当前进行中：整行高亮
│ 18:00 – 19:00  健身           ■      │
├──────────────────────────────────────┤
│ ＋ 添加日程…                          │ ← 底部
└──────────────────────────────────────┘
```

**头部行**（对齐 Todo 头部「待办 / N 项未完成 / 展开按钮」结构）：

| 元素 | 规格 |
|---|---|
| 主标题 | `10月22日 周四`，`font(.system(size: 16, weight: .bold))`，primary |
| 计数 | `· 5 项`（含全天；进行中单独标注 `1 进行中` 绿色），`size 12`，`.secondary` |
| 展开按钮 | 右侧 `Image(systemName: "arrow.up.left.and.arrow.down.right")`，`.buttonStyle(.plain)`，`.help("打开完整日历")`，点击 → hide popover + `ScheduleWindow.show()` |

**日历筛选 chips**（Chief 方案的多选 chips；Todo 没有此控件，规格自定但材质沿用 popover 内已有做法）：

| 参数 | 值 |
|---|---|
| 形态 | `HStack(spacing: 6)`，横排可换行（`FlowLayout` 简易实现） |
| 单个 chip | 文本 `size 12`，`padding(.horizontal, 10).padding(.vertical, 4)`，背景选中 `Color.white.opacity(0.16)` / 未选中 `Color.white.opacity(0.06)`，圆角 **9pt**（全圆角药丸），文字选中 primary / 未选中 secondary |
| 色点 | chip 文字前 6pt 圆点，颜色 = 该日历 `calendarColor`（`scheduleShowCalendarColor` 关时不显示） |
| 交互 | 单击切换选中/排除；「全部」chip = 重置。选中集存 `@AppStorage(Pref.scheduleCalendars)`（逗号分隔 calendarName），空 = 全部 |
| 数据源标签 | EventKit 已授权且在用：头部下方不加标签；本地 JSON 模式：chips 行前加 `size 11` opacity 0.6 的「本地数据」小标 |

**全天事件区**（固定在时间轴上方，Chief 方案）：

- 区头：`全天`，`size 11`，`.secondary`，`padding(.bottom, 4)`；仅当存在全天事件时渲染整区。
- 行规格同 3.3 事件行，但时间列换成日历色块 `■`（见下），标题 `size 13` primary。
- 多条全天事件按 title 排序（本地 JSON 按文件顺序）。

**时间轴主体**：`ScrollView` + `VStack(alignment: .leading, spacing: 2)`（对齐 TodoPopover 列表容器参数）。滚动区高度 = 窗口高 - 头部 - chips - 全天区 - 添加栏，超出滚动；`showsIndicators` 保留系统默认。

**「现在」分隔线**：时间轴中 `now` 所在位置插入一条辅助线——`Rectangle().fill(Color(red: 0.36, 0.82, 0.55).opacity(0.6))` 高 1pt，左侧 4pt 圆点，置于「now 之前最近一条事件行」的下方；仅当存在进行中或已过事件时出现。无进行中事件时不画（避免全天空线）。

### 3.3 事件行（`ScheduleRow`，对齐 TodoRow 的容器参数）

| 参数 | 值 |
|---|---|
| 容器 | `HStack(spacing: 8)`，`padding(.vertical, 6).padding(.horizontal, 6)`，hover 背景 `Color.white.opacity(0.07)` 圆角 **6pt**，`.onHover` 驱动 |
| 时间列 | `09:00 – 10:00`，`size 12`，`.semibold`，`.monospacedDigit()`；跨天事件显示 `明天 09:00`。宽度固定 **92pt** 右对齐不换行（`frame(width: 92, alignment: .trailing)`），不够时省略结束时间只留开始 |
| 标题 | `size 13`，primary，`lineLimit(1)` + 尾部省略号；`.help(title)` 显全文（列表是暂态浏览，不用 Marquee） |
| 日历色块 | 行尾 8×8pt 圆角 2pt 方块，颜色 = `calendarColor`；`scheduleShowCalendarColor` 关时不渲染（行尾留 `Spacer(minLength: 4)`） |
| 过去事件 | start 和 end 都 < now：整行 opacity **0.4**，标题加 `.strikethrough(false)`（保留原色仅变淡） |
| 进行中事件 | 整行背景常显 `Color.white.opacity(0.07)`（等同 hover 态）+ 圆角 6；时间列前加 6pt 绿点；标题前不加（色块已够辨识） |
| 行内操作 | hover 时行尾出现 `xmark` `size 11` `.secondary` `.help("删除")`——本地 JSON 事件直接删；EventKit 事件点击后弹确认（NSAlert，因为会写回系统日历，属高危不可恢复操作，按既有口径弹窗确认） |
| 单击行为 | 本地事件 → NSAlert 编辑（对齐 `TodoIO.askNew` 的 accessoryView 模式，字段：标题 + 开始 + 结束）；EventKit 事件 → `EKEventEditViewController`（系统编辑器，不自制表单） |

### 3.4 底部添加栏

| 参数 | 值 |
|---|---|
| 容器 | `HStack(spacing: 6)`，`padding(8)`，背景 `Color.white.opacity(0.08)`，圆角 **8pt**（对齐 TodoPopover 输入行） |
| 图标 | `Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)` |
| 文案 | `添加日程…`，`size 13`，`.secondary`；单击 → EventKit 授权时弹 `EKEventEditViewController`（默认开始时间 = 下一整点，时长 1h）；本地模式弹 NSAlert 表单（标题 NSTextField 260×24 + 两个 NSDatePicker） |
| 回车提交 | 本地模式表单内回车 = 添加 |

### 3.5 Popover 状态

| 状态 | 表现 |
|---|---|
| 无任何事件（含全天） | 时间轴区域居中显示「今天没有日程，享受空白吧」`size 13` `.secondary`，`padding(.top, 12)`（对齐 Todo 空态句式）；chips 行隐藏（无日历可筛） |
| 全天事件但无定时事件 | 只显全天区 + 空态文案改为「今天只有全天日程」 |
| 授权未决定 | 显示「点击授权日历」按钮（居中，`size 13` accent 色），单击触发 `requestAccess`；拒绝后原地变成下一条 |
| 授权被拒 | 头部下方显示一次性提示条：「日历权限被拒，正在使用本地日程」+「查看本地数据」链接（打开 schedule.json 所在文件夹），可点 x 关闭，`@AppStorage` 记住不再显示 |

---

## 4. 完整窗口（周 / 日视图）

### 4.1 窗口（对齐 TodoWindow 机制）

| 参数 | 值 |
|---|---|
| 窗口 | `NSWindow` 400 × 500 起，`[.titled, .closable, .resizable, .miniaturizable]`，`isReleasedWhenClosed = false`，`center()` |
| 标题 | 「DockSide 日程」 |
| 最小尺寸 | 380 × 440（对齐 TodoListView 的 min） |

### 4.2 布局

```
┌────────────────────────────────────┐
│  ＜ 10月21日 – 10月27日 ＞  [日|周] + │ ← 工具栏
├────┬───────────────────────────────┤
│    │ 四 10/22（今天，绿点标出）      │
│ 09 │ ███████ 晨会 09:00-10:00      │
│ 10 │                               │
│ …  │        ██████ 产品评审会      │
├────┴───────────────────────────────┤
│ 4 条本周日程 · 2 条本地              │ ← 状态栏
└────────────────────────────────────┘
```

| 区域 | 规格 |
|---|---|
| 工具栏 | `HStack` `padding(12)`（对齐 TodoListView 顶部输入框的 padding）：左右翻周箭头 `chevron.left/right` `.plain` 按钮、当前范围标题（周视图 `M月d日 – M月d日` semibold）、右侧 `Picker` 分段控件「日 / 周」（`pickerStyle(.segmented)`，`fixedSize`）、最右 `+` 按钮新建事件 |
| 周视图主体 | 7 列网格；列头 = `周四 10/22` `size 12`，今日列头带 4pt 绿点；列内事件块：背景 `calendarColor.opacity(0.25)` + 左侧 3pt 实色竖条，圆角 4pt，文字 `size 12` `lineLimit(2)`；时间轴左列 09/10/… `size 11` `.secondary` `monospacedDigit`，每小时一行，行高 **34pt**（对齐 popover 行高公式） |
| 日视图主体 | 单列全天区（同 popover 全天区行规格）+ 时间轴同周视图单列版 |
| 事件交互 | 单击事件块 → 编辑（本地 NSAlert 表单 / EventKit 系统编辑器）；双击空白处 → 新建（开始时间 = 点击位置对应整点）；右键 → 菜单「编辑 / 删除」（删除按 3.3 的确认口径） |
| 状态栏 | `HStack` `padding(12)`（对齐 TodoListView 底栏）：左侧计数 `size 12` `.secondary`；右侧按钮组「导出…」「导入…」「在访达中显示数据」（对齐 TodoPane 数据区按钮组样式，`.borderless`） |

周视图跨 midnight 的事件（如 23:00–01:00）：在结束日的列内画到底部并加 `≫` 角标，不做跨列渲染（简化实现，第二期可改）。

---

## 5. 设置页（`SchedulePane`）

结构对齐 TodoPane：`Form` + `Section` + `.formStyle(.grouped)`，全部 `@AppStorage(Pref.xxx)`。

### 5.1 Section「Dock 旁显示」

| 控件 | 类型 | Pref 键 / 默认值 |
|---|---|---|
| 标题宽度 | `Picker`：4/6/8/10/12 个字（对齐 TodoPane 的「标题宽度」选项） | `scheduleTitleChars` = 6 |
| 说明文字 | `Text` caption `.secondary`：「卡片宽度固定，标题更长会在里面滚动显示。」（对齐 TodoPane 同位置说明） | — |
| 鼠标悬停展开日程 | `Toggle` | `scheduleHover` = true |
| 预读窗口 | `Picker`：今日内 / 未来 24 小时 / 未来 3 天 | `scheduleWindow` = "today"（"24h" / "3d"） |
| 显示全天事件 | `Toggle` | `scheduleShowAllDay` = true |
| 24 小时制 | `Toggle`（与 ClockPane 的「24 小时制」同名同义，独立存储） | `schedule24h` = true |
| 显示日历色块 | `Toggle` | `scheduleShowCalendarColor` = true |

### 5.2 Section「提醒」

| 控件 | 类型 | Pref 键 / 默认值 |
|---|---|---|
| 事件开始前提示音 | `Toggle` + 说明 caption「事件开始 5 分钟前播放提示音（系统日历自身的提醒不受影响）」 | `scheduleSound` = false |

提示音用 `NSSound(named: "Tink")`（复用 TodoSound 的选型）；判定：60s 刷新时发现有事件 `start - now ∈ (4.5min, 5.5min]` 且尚未响过（`@AppStorage` 记 `lastRungEventId` 防重复）。

### 5.3 Section「日历与数据」

| 控件 | 规格 |
|---|---|
| 日历列表（EventKit 授权后） | 每个日历一行：色点 + 日历名 + `Toggle`，`Pref.scheduleCalendars` 存排除集（逗号分隔，空 = 全选）；未授权时此区显示「授权后可选择显示哪些日历」caption |
| 授权状态行 | 对齐 GeneralPane「辅助功能」行的样式：`Label("日历：已授权/未授权/被拒绝", systemImage: …)` 绿色 checkmark.seal.fill / 橙色 exclamationmark.triangle.fill + 「打开系统设置」按钮；未授权时按钮触发 `requestAccess` |
| 数据源说明 | caption `.secondary`：「未授权时使用本地日程，保存在 ~/Library/Application Support/DockSide/schedule.json」 |
| 按钮组一行 | 「从文件导入…」「从剪贴板导入」「导出 JSON…」（对齐 TodoPane 数据区按钮组排布） |
| 按钮组二行 | 「打开完整日历」「在访达中显示数据」 |

### 5.4 导入导出（`ScheduleIO`，对齐 `TodoIO` 模式）

| 功能 | 规格 |
|---|---|
| 支持格式 | 导入：`.ics`（主）、`.json`（备份恢复）、`.txt`/`.md`（简易行）；导出：`.json`（完整备份）、`.ics`（日历交换）、`.md`（人类可读） |
| 导入入口 | 设置页「从文件导入…」按钮（NSOpenPanel，允许多选）、菜单栏「导入日程…」、剪贴板导入 |
| 导入解析 | **ICS 解析**：提取 VEVENT 的 SUMMARY / DTSTART / DTEND / RRUID；时区按系统设置转本地；跳过已存在的 UID。**JSON 导入**：直接合并到本地 schedule.json，按 id 去重。**简易文本**：每行一条，格式 `时间 标题` 或 `开始时间-结束时间 标题`，自动识别 |
| 导入反馈 | 弹窗「已导入 N 条日程」（对齐 TodoIO.notify），重复项静默跳过 |
| 导出入口 | 设置页「导出 JSON…」按钮（NSSavePanel，默认名 `日程-YYYY-MM-DD.json`）、菜单栏「导出日程…」、完整窗口底部「导出…」 |
| 导出内容 | 本地 JSON 事件 + EventKit 事件（需授权）合并导出，按 start 排序；导出为 ICS 时包含日历色块信息（用 CATEGORIES 字段） |
| 数据文件路径 | `~/Library/Application Support/DockSide/schedule.json`（与 Todo 同目录，权限一致） |
| 数据模型 | 以客户端实现为准：`CalendarEvent` 含 `id, title, start, end, isAllDay, calendarName, calendarColor, ekEventID?, uid?`；`ekEventID == nil` 即本地事件（等价于早先写的 `source` 字段），`uid` 用于 ICS 去重（10-22 产品确认，不影响行为） |
| 冲突处理 | 导入时按 id 去重；**导入/导出不写系统日历**（导入的内容一律进本地 JSON）。EventKit 事件的编辑/删除走 §3.3 的系统编辑器 + 删除确认，属 UI 操作，不受本条限制（10-22 产品定论，选项 A） |
| 批量操作 | 完整窗口底部「导入…」「导出…」「清空本地数据」（清空需弹窗确认，不可恢复） |

### 5.5 设置侧栏

`SettingsPage` 枚举加 `case schedule`：`title = "日程"`，`symbol = "calendar.badge.clock"`；侧栏「组件」Section 的顺序：clock, system, todo, **schedule**, pomodoro（日程挨着待办，都是「清单类」）。

---

## 6. Pref 键与默认值汇总（`Settings.swift` 注册）

```swift
static let scheduleTitleChars       = "scheduleTitleChars"        // 6
static let scheduleHover            = "scheduleHover"             // true
static let scheduleWindow           = "scheduleWindow"            // "today" | "24h" | "3d"
static let scheduleShowAllDay       = "scheduleShowAllDay"        // true
static let schedule24h              = "schedule24h"               // true
static let scheduleShowCalendarColor = "scheduleShowCalendarColor" // true
static let scheduleSound            = "scheduleSound"             // false
static let scheduleCalendars        = "scheduleCalendars"         // ""（空=全部）
static let scheduleSource           = "scheduleSource"            // "auto"（EventKit 失败自动降级，不暴露手动切换）
static let scheduleLastRung         = "scheduleLastRung"          // ""（防提示音重复）
static let scheduleLastImport       = "scheduleLastImport"        // ""（记录上次导入时间，用于增量）
```

`Pref.register()` 的 `defaults:` 字典补齐以上默认值。

---

## 7. 状态与边界情况总表（交付验收对照）

| # | 场景 | 期望表现 | 出现层级 |
|---|---|---|---|
| 1 | EventKit 未授权（首次启用） | 胶囊显示「授权日历」；单击触发系统弹窗；popover 内有授权按钮 | 胶囊+popover |
| 2 | EventKit 被拒 | 无缝降级本地 JSON；popover 一次性提示条（可关不再现）；胶囊无任何报错样式 | 全部 |
| 3 | 本地 schedule.json 不存在/损坏 | 按空数据处理（暂无日程），不崩；损坏时忽略并重建空文件 | 胶囊+popover |
| 4 | 无任何日程 | 胶囊「暂无日程」opacity 0.7；popover 居中空态文案 | 胶囊+popover |
| 5 | 只有全天事件 | 胶囊显示第一条全天事件标题（时间位显示「全天」）；popover 全天区正常 | 胶囊+popover |
| 6 | 事件进行中 | 绿点 +「进行中」+ 剩余时长；popover 整行高亮 + now 分隔线 | 胶囊+popover |
| 7 | 超长标题（≥ 40 字） | 胶囊 Marquee 滚动；popover `lineLimit(1)` 省略 + hover 全文 help | 胶囊+popover |
| 8 | 跨天事件（明天及以后） | 胶囊带「明天/周X」前缀；popover 时间列显示日期；完整窗口周视图画到结束日列 | 全部 |
| 9 | 明暗模式切换 | 胶囊跟随 `widgetInk`（merged 用 primary 自动适配）；popover 固定 dark（hudWindow 材质） | 胶囊+popover |
| 10 | 时间过了 00:00（跨午夜） | 下一次 60s 刷新时进度环清零、状态全部重算（TimelineView 周期自然覆盖，无需额外定时器） | 胶囊 |
| 11 | 同一时刻多个日历的事件重叠 | 时间轴按 start 升序、同 start 按 calendarName 排序稳定输出 | popover+窗口 |
| 12 | 日历被用户在系统侧删除 | EventKit 源：刷新后自然消失；chips 选中集里的残留名无害（匹配不到即忽略） | popover |
| 13 | 用户把组件字号调到 0.7× | 全部尺寸随 `size` 等比缩（规格内无绝对值胶囊尺寸）；`size` 下限 9pt 由 SideView 保证 | 胶囊 |
| 14 | 鼠标快速划过组件 | 0.35s 隐藏延迟 + `insetBy(-6,-6)` 容差，不闪烁（机制同 TodoPopover） | popover |
| 15 | 导入 ICS/JSON/TXT | 自动识别格式、按 id 去重、弹窗反馈「已导入 N 条」，重复项静默跳过 | 设置页+菜单 |
| 16 | 导出 JSON/ICS | 本地 + EventKit 事件合并导出，按 start 排序，ICS 含 CATEGORIES 日历色块 | 设置页+菜单+窗口 |
| 17 | 清空本地数据 | 弹窗确认（不可恢复），清空后无缝降级本地空数据，不崩 | 完整窗口 |

---

## 8. 交付与验收口径

- 本文档 = 设计交付物；客户端按 §1–§6 实现，测试按 §7 逐条验收。
- 视觉一致性验收基线：与 TodoWidget 并排放一排（merged 样式）时，环尺寸、字号层级、胶囊 padding、绿点色值肉眼无差异。
- 交互时序验收基线：popover 显 0.15s / 隐延迟 0.35s，与 TodoPopover 并排测试手感一致。
- 遗留决策（v1.1 产品 10-22 拍板）：
  ①跨午夜事件画法：**一期按简化方案**（结束日列内画到底部 + `≫` 角标），不做跨列渲染。跨列留二期，等真实用户反馈。文档已知限制。
  ②提示音：**默认关**（`scheduleSound = false`）。理由：日程事件密度远高于待办，装完组件就自动出声是打扰；静音默认、设置页主动打开，符合 macOS 组件惯例。

---

## 归档记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-10-22 | 首版：三级显示全量规格，基于 DockSide main 分支源码实测（Widgets/BasicWidgets/Todo/SettingsView/Settings 五个文件，拉取于 10-22 05:35） |
| v1.1 | 2026-10-22 | 产品拍板两决策：①跨午夜简化方案（≫角标，二期跨列）；②提示音默认关（scheduleSound=false） |
| v1.2 | 2026-10-22 | 新增导入导出规格（§5.4）：ICS/JSON/TXT 导入 + JSON/ICS 导出 + 数据模型 + 冲突处理；验收表新增状态 15/16/17 |
| v1.3 | 2026-10-22 | 产品定论 §5.4「EventKit 只读」歧义（选 A：编辑/删除写回系统日历，导入导出不写）；客户端确认 ekEventID 判源与 source 字段等价，规格数据模型表述随实现口径勘正 |
