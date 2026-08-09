# Type4Me 智能感知（Intelli Sense）开发设计文档

> 文档状态：开发设计草案
> 上游文档：`docs/smart-perception-mode-personalization-prd.md`
> 适用平台：macOS 14+
> 技术栈：Swift 6.2 工具链、SwiftUI、AppKit、Accessibility API、SQLite、JSON 文件存储
> 最后更新：2026-08-09
> 当前阶段：仅完成设计，不实施代码

产品界面和对外文案统一写作“Intelli Sense”；Swift 类型与文件名遵循标识符规范，使用不含空格的 `IntelliSense`。

---

## 1. 设计目标

本设计为 Type4Me 新增官方自带模式“智能感知 / Intelli Sense”。它是现有语音润色的增强版本，继续遵守单一处理契约：

> 将本次语音识别结果润色成可以直接输入的文字，不回答、不生成额外内容、不处理其他内容、不执行动作。

开发范围只包含：

1. 基础语音润色；
2. 应用感知；
3. 上下文感知；
4. 表达习惯感知；
5. 纠错词检测迁移；
6. 原意与事实保真保护；
7. 智能感知模式设置、存储、迁移和测试。

### 1.1 明确不实现

- 意图分类和能力路由；
- 问答或内容生成；
- 选中文本、剪贴板处理；
- 翻译；
- Mac 操作或工具调用；
- 处理完成后的场景标签；
- “更忠实”“更自然”等快速纠偏；
- 独立一级个性化设置页；
- 用户可见的表达习惯列表、置信度或确认卡片；
- 智能感知专属纠错词库。

---

## 2. 已确认产品配置

| 配置项 | 默认值 | 生效范围 | 说明 |
|---|---:|---|---|
| 应用感知 | 关闭 | 仅智能感知 | 读取 App 与输入控件，选择场景策略 |
| 上下文感知 | 关闭 | 仅智能感知 | 后续阶段读取光标附近有限文字 |
| 表达习惯感知 | 关闭 | 仅智能感知 | 后台学习，不显示偏好清单或卡片 |
| 纠错词检测 | 关闭 | 观察仅智能感知 | 升级保留旧开关状态 |
| App 黑名单 | 空 | 所有感知项 | 命中后使用基础润色且不学习 |

纠错词检测的作用域分为两段：

- **观察阶段**：只在智能感知模式中启动；
- **确认后生效阶段**：写入现有全局热词与片段替换，在所有模式中生效。

“清除表达习惯数据”只清除内部表达习惯模型，不清除全局生词表。

---

## 3. 当前实现基线

### 3.1 可直接复用的能力

| 当前组件 | 文件 | 可复用能力 |
|---|---|---|
| `ProcessingMode` | `Type4Me/UI/AppState.swift` | 稳定模式 ID、名称、Prompt、快捷键、执行类型 |
| `ModeStorage` | `Type4Me/Services/ModeStorage.swift` | 模式持久化、官方模式补入和旧模式迁移 |
| `RecognitionSession` | `Type4Me/Session/RecognitionSession.swift` | 录音、ASR、speculative LLM、后处理、注入、历史保存主流水线 |
| `PromptContext` | `Type4Me/LLM/PromptContext.swift` | AX 调用超时与一次性 Prompt 变量展开模式 |
| `TextInjectionEngine` | `Type4Me/Injection/TextInjectionEngine.swift` | 聚焦控件快照、注入结果检测、注入范围追踪 |
| `CorrectionLearningCoordinator` | `Type4Me/Services/CorrectionLearning.swift` | 60 秒观察、4 秒防抖、词级 diff、敏感过滤、确认和保存 |
| `CorrectionLearningPanelController` | `Type4Me/UI/FloatingBar/CorrectionLearningPanel.swift` | 现有纠错确认卡片，保持不变 |
| `HotwordStorage` | `Type4Me/Services/HotwordStorage.swift` | 全局用户热词、缓存失效和 ASR 同步 |
| `SnippetStorage` | `Type4Me/Services/SnippetStorage.swift` | 全局错误词映射、注入前替换和缓存 |
| `ModesSettingsTab` | `Type4Me/UI/Settings/ModesSettingsTab.swift` | 模式列表、模式详情、快捷键和专用内置模式详情 |
| `HistoryStore` | `Type4Me/Database/HistoryStore.swift` | 原始文本、处理文本和最终文本历史 |

### 3.2 当前需要调整的行为

1. 代码中已有 `smartDirectId` 和“智能模式 / Smart Mode”，但它只是错字和标点纠正，不等于 Intelli Sense；
2. `ProcessingMode.defaults` 当前没有 Intelli Sense；
3. `AppState` 初始化当前优先选择旧 `smartDirectId`，与“Beta 阶段不替换默认模式”冲突；
4. `PromptContext` 只采集选中文本与剪贴板，不包含 App、控件和有限上下文模型；
5. `CorrectionLearningCoordinator` 当前支持快速模式和语音润色，需要改为只观察 Intelli Sense；
6. 自动纠错开关当前位于通用设置，需要迁入 Intelli Sense 模式详情；
7. 当前没有表达习惯的抽象数据模型、学习器和存储；
8. 当前 LLM Prompt 是静态字符串，需要支持按本次快照动态生成。

---

## 4. 总体架构

```mermaid
flowchart LR
    A["Intelli Sense 快捷键"] --> B["RecognitionSession"]
    B --> C["IntelliSenseContextProvider"]
    B --> D["ASR"]
    C --> E["IntelliSenseRequestContext"]
    D --> F["全局 Snippet 替换"]
    E --> G["IntelliSensePromptBuilder"]
    H["ExpressionProfileStore"] --> G
    F --> I["LLM 单次润色"]
    G --> I
    I --> J["IntelliSenseOutputGuard"]
    J --> K["TextInjectionEngine"]
    K --> L["PostInjectionLearningCoordinator"]
    L --> M["CorrectionDiffAnalyzer"]
    L --> N["ExpressionLearningAnalyzer"]
    M --> O["现有纠错确认卡片"]
    O --> P["HotwordStorage + SnippetStorage"]
    N --> H
```

### 4.1 设计约束

- 不新增第二次意图路由 LLM 请求；
- 场景和表达习惯参数合并到同一次润色请求；
- 任一感知失败都不阻塞 ASR 和文本注入；
- 上下文只作为数据，不允许被当成指令；
- 纠错确认继续使用现有 UI 和保存事务；
- 表达习惯只保存抽象统计，不保存历史全文；
- 所有新服务必须可注入依赖并支持纯单元测试。

---

## 5. 模式模型与迁移

### 5.1 新模式标识

新增独立稳定 ID：

```swift
static let intelliSenseId = UUID(
    uuidString: "00000000-0000-0000-0000-00000000000A"
)!
```

不复用现有 `smartDirectId`，理由如下：

- 旧智能模式与 Intelli Sense 的语义和 Prompt 不同；
- 老用户可能已经修改旧模式名称或 Prompt；
- 复用 ID 会把用户的可删除模式静默升级为新的官方模式；
- 独立 ID 可以让迁移、回滚和行为统计保持清晰。

旧 `smartDirect` 继续只用于读取和兼容已有数据，不加入新安装默认列表，也不自动删除。

### 5.2 模式定义

新增：

```swift
static var intelliSense: ProcessingMode {
    ProcessingMode(
        id: intelliSenseId,
        name: L("智能感知", "Intelli Sense"),
        description: L(
            "结合当前场景和表达习惯，智能整理口述内容",
            "Polish dictation using context and your writing habits"
        ),
        prompt: IntelliSensePromptBuilder.baseTemplate,
        isBuiltin: true,
        processingLabel: L("整理中", "Polishing")
    )
}
```

Intelli Sense 的核心 Prompt 不允许用户直接编辑，避免破坏模式契约。快捷键仍可配置。

### 5.3 官方模式列表

- `ProcessingMode.builtins` 加入 `.intelliSense`；
- `ProcessingMode.defaults` 在 `.direct` 之后加入 `.intelliSense`；
- 新安装显示在快速模式与语音润色之间；
- 现有安装由 `ModeStorage` 的官方模式补入逻辑添加；
- 对现有用户，新模式追加到当前列表末尾，避免改变用户已定制的顺序；
- 不自动为新模式绑定快捷键，避免与现有快捷键冲突。

### 5.4 默认模式

Beta 阶段不改变用户默认模式：

- 移除 `AppState.init()` 中优先选择 `smartDirectId` 的特殊逻辑；
- 启动时使用持久化的当前模式；如果当前机制没有保存该状态，则回退列表第一项；
- 不因为补入 Intelli Sense 自动切换当前模式。

### 5.5 模式配置不写入 `ProcessingMode`

感知开关和黑名单不扩展到通用 `ProcessingMode`，原因是这些字段只属于 Intelli Sense，并且需要独立版本迁移。

新增独立设置存储：

```swift
struct IntelliSenseSettings: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var applicationAwarenessEnabled: Bool = false
    var contextAwarenessEnabled: Bool = false
    var correctionDetectionEnabled: Bool = false
    var expressionLearningEnabled: Bool = false
    var blacklistedApps: [BlacklistedApp] = []
}

struct BlacklistedApp: Codable, Equatable, Identifiable, Sendable {
    var bundleIdentifier: String
    var displayName: String
    var id: String { bundleIdentifier }
}
```

存储位置：

```text
~/Library/Application Support/Type4Me/intelli-sense-settings.json
```

由 `IntelliSenseSettingsStore` 负责原子写入、默认值、去重和损坏回退。

---

## 6. 设置页面设计

### 6.1 页面位置

在 `ModesSettingsTab.modeDetail(_:)` 中增加 Intelli Sense 专用分支：

```swift
if mode.id == ProcessingMode.intelliSenseId {
    IntelliSenseModeDetail(...)
}
```

不新增 Settings 一级导航。

### 6.2 页面内容

按以下顺序展示：

1. 模式说明；
2. 快捷键；
3. 应用感知开关；
4. 上下文感知开关；
5. 表达习惯感知开关；
6. 纠错词检测（Beta）开关；
7. App 黑名单；
8. 清除表达习惯数据。

所有开关默认关闭。

### 6.3 开关关系

- 四个感知开关相互独立；
- 上下文感知开启但应用感知关闭时，仍捕获 Bundle ID 只用于黑名单判断，不使用 App 类别策略；
- 表达习惯感知开启时，只学习当前未被拉黑的 App；
- 纠错词检测开启时，只在 Intelli Sense 成功注入后观察；
- App 黑名单优先级最高，命中后四项感知全部跳过；
- 关闭表达习惯感知后，已有模型保留但不读取、不更新；
- “清除表达习惯数据”删除模型文件和内存缓存，不删除热词或片段替换。

### 6.4 纠错开关迁移

旧开关：

```text
tf_autoCorrectionLearningEnabled
```

迁移规则：

1. 首次加载 `IntelliSenseSettingsStore` 时检查迁移标志；
2. 如果存在旧 key，复制其布尔值到 `correctionDetectionEnabled`；
3. 如果旧 key 不存在，保持默认关闭；
4. 写入 `tf_intelliSenseSettingsMigratedV1 = true`；
5. 通用设置页删除旧开关 UI；
6. 暂时保留旧 key 一个发布周期以支持回滚；
7. 新代码只读取新设置文件。

### 6.5 App 黑名单

- 使用 Bundle ID 作为唯一键，显示名称只用于 UI；
- App 选择器可复用词汇页中已有的应用选择交互模式；
- 自动排除 Type4Me 本身；
- 重命名 App 不影响黑名单；
- App 卸载后条目保留，用户可手动移除；
- 黑名单命中时不采集控件、上下文或修改行为，只保留完成输入所需的目标 Bundle ID。

---

## 7. 上下文模型

### 7.1 快照结构

新增只读、不可变快照：

```swift
struct IntelliSenseContextSnapshot: Sendable, Equatable {
    let capturedAt: Date
    let processIdentifier: pid_t?
    let bundleIdentifier: String?
    let applicationName: String?
    let applicationCategory: ApplicationCategory
    let controlRole: String?
    let controlSubrole: String?
    let controlKind: InputControlKind
    let isEditable: Bool
    let isSecure: Bool
    let surroundingText: String?
    let surroundingTextWasTruncated: Bool
    let availability: ContextAvailability
}
```

辅助枚举：

```swift
enum ApplicationCategory: String, Codable, Sendable {
    case messaging, email, document, browser, development, terminal, other
}

enum InputControlKind: String, Codable, Sendable {
    case singleLine, multiLine, search, title, code, terminal, unknown
}

enum ContextAvailability: Sendable, Equatable {
    case disabled
    case blacklisted
    case appOnly
    case appAndControl
    case full
    case unavailable
    case sensitive
}
```

### 7.2 捕获时机

快照必须以录音开始时的焦点为准：

1. 同步读取前台 App、PID、Bundle ID 和显示名称；
2. 立即检查 App 黑名单；
3. 若未命中黑名单，创建异步 AX 捕获任务；
4. 音频录制和 ASR 连接不等待 AX 任务；
5. 在首次 speculative LLM 或最终 LLM 前等待快照，最长 300ms；
6. 超时则只使用已经得到的 App 信息或完全回退基础润色。

这样既锁定用户开始录音时的场景，又不增加录音启动延迟。

### 7.3 L1：应用感知

`AppContextClassifier` 使用确定性 Bundle ID 规则，不调用 LLM：

```swift
protocol AppContextClassifying: Sendable {
    func classify(bundleIdentifier: String?, appName: String?) -> ApplicationCategory
}
```

初始类别：

| 类别 | 示例 | 策略重点 |
|---|---|---|
| messaging | Slack、微信、飞书、Discord | 简短自然、少结构化 |
| email | Mail、邮件客户端 | 完整句、礼貌但不补称呼落款 |
| document | Notion、Word、Pages、Obsidian | 自然分段、多要点才结构化 |
| browser | Safari、Chrome、Arc | 结合控件判断搜索或正文 |
| development | Xcode、VS Code、JetBrains | 保留标识符、技术术语和格式 |
| terminal | Terminal、iTerm2、Ghostty | 最大程度忠实，不解释命令 |
| other | 未知 App | 基础润色策略 |

映射表作为代码内产品配置，必须有单元测试；用户不能手动修改类别。

### 7.4 L2：输入控件感知

通过 Accessibility 读取：

- `kAXRoleAttribute`；
- `kAXSubroleAttribute`；
- 可编辑性；
- 单行或多行特征；
- 搜索框、标题输入框等已知角色。

所有同步 AX IPC 设置短超时，沿用 `PromptContext` 和 `TextInjectionEngine` 已有的超时、防挂死模式。

### 7.5 L3：上下文感知

后续阶段在用户开启“上下文感知”时读取光标附近有限文字：

- 优先使用 `kAXStringForRangeParameterizedAttribute`；
- 基于 `kAXSelectedTextRangeAttribute` 获取光标位置；
- 最多读取光标前 300 字符、后 100 字符；
- 如果目标不支持参数化范围，可读取 `kAXValueAttribute` 后在本地截断；
- 对超大值设置最大读取上限，避免复制完整文档；
- 不使用 Command+C 或剪贴板回退；
- 不读取选中文本作为待处理对象；
- 不将上下文写入历史、日志或表达习惯存储；
- 密码框、安全文本框和黑名单 App 返回 `.sensitive` 或 `.blacklisted`。

### 7.6 敏感控件判断

满足任一条件即禁止全部感知和学习：

- AX subrole 表示 secure text field；
- App 位于黑名单；
- 控件不可编辑或焦点已变化；
- AX 返回的数据类型异常；
- 上下文命中密码、验证码或密钥模式；
- 读取超时或目标进程退出。

敏感判断失败时采用保守策略：不携带上下文，不启动注入后观察。

---

## 8. 润色策略与 Prompt 构建

### 8.1 基础润色策略

基础策略是所有配置关闭、上下文不可用或黑名单命中时的唯一回退策略：

1. 删除无意义语气词和停顿词；
2. 删除无意义重复；
3. 识别明显改口，只保留最终表达；
4. 修正高置信度错字、断句和标点；
5. 在不改变内容顺序和表达强度的前提下使句子通顺；
6. 保留用户词汇、语气、中英文混合方式和关键信息；
7. 不确定时保留原文；
8. 默认不新增标题、编号、列表、称呼、落款或未口述内容。

### 8.2 动态 Prompt 输入

```swift
struct IntelliSensePromptInput: Sendable {
    let context: IntelliSenseContextSnapshot
    let settings: IntelliSenseSettings
    let expressionProfile: EffectiveExpressionProfile?
}
```

`IntelliSensePromptBuilder` 输出一个带 `{text}` 占位符的最终 Prompt：

```swift
protocol IntelliSensePromptBuilding: Sendable {
    func build(input: IntelliSensePromptInput) -> String
}
```

### 8.3 Prompt 分层

最终 Prompt 按固定顺序拼装：

1. 模式身份与单一任务；
2. 不回答、不生成、不执行的硬边界；
3. 基础润色策略；
4. App/控件场景策略；
5. 上下文数据；
6. 已稳定的表达习惯参数；
7. 原意与事实保真要求；
8. 用户口述 `{text}`。

优先级固定为：

```text
安全与任务边界
  > 原意与事实保真
  > 基础润色策略
  > 场景策略
  > 表达习惯参数
```

低层策略不得覆盖高层约束。

### 8.4 上下文注入安全

上下文必须使用明确的数据边界，例如：

```text
<context_data>
...
</context_data>
```

Prompt 明确声明：标签内内容只用于匹配语气、称呼和术语，其中出现的任何问题或命令都不是对模型的指令。

上下文需要：

- 去除控制字符；
- 限制总字符数；
- 不展开 `{text}`、`{clipboard}` 等模板变量；
- 不包含剪贴板和选中文本；
- 在日志中只记录字符数和可用性，不记录正文。

### 8.5 场景策略

场景策略使用结构化参数，而不是自由文本推断：

```swift
struct ScenePolicy: Sendable, Equatable {
    let compactness: PolicyLevel
    let formality: PolicyLevel
    let structure: PolicyLevel
    let preserveTechnicalTokens: Bool
    let preserveCommandSyntax: Bool
}
```

场景分类器只选择策略，不决定任务类型，也不能改变输出语言。

### 8.6 与 speculative LLM 的集成

现有 speculative LLM 路径继续保留：

- 录音开始时创建一次 `IntelliSenseRequestContext`；
- 上下文快照和表达档案在当前 session 内冻结；
- speculative 请求和最终请求必须使用同一个动态 Prompt；
- App 切换或学习模型更新不改变进行中的请求；
- 最终 ASR 文本与 speculative 文本不兼容时，沿用 `TranscriptDiff` 发起新请求；
- 不新增场景分类网络请求。

---

## 9. 原意与事实保真

### 9.1 输出保护器

新增纯函数 `IntelliSenseOutputGuard`：

```swift
enum IntelliSenseGuardDecision: Equatable, Sendable {
    case accept
    case reject(reason: GuardRejection)
}
```

检查输入为全局片段替换后的 ASR 文本与 LLM 输出。

### 9.2 V1 必检项目

- 数字、金额、百分比和日期不得无依据变化；
- URL、邮箱、文件路径、命令参数和代码标识符不得丢失；
- 否定词不得丢失或反转；
- 专有名词和中英文 token 不得无依据替换；
- 输出不得包含回答前缀、解释、工具调用或 Markdown 代码围栏；
- 输出长度不得出现无法解释的极端扩张；
- 用户明确列出的要点不得减少；
- 输出语言不得整体改变。

### 9.3 失败策略

V1 不增加第二次 LLM 校验请求。Guard 拒绝时：

1. 记录不含正文的拒绝原因；
2. 使用全局片段替换后的 ASR 文本；
3. 继续正常注入和保存历史；
4. 不将被拒绝的 LLM 输出作为表达习惯学习样本。

后续如果误拒绝过高，再评估轻量语义校验；不在首版引入额外延迟。

---

## 10. 纠错词检测

### 10.1 观察资格

将当前：

```swift
modeID == directId || modeID == formalWritingId
```

调整为：

```swift
modeID == intelliSenseId
```

同时满足：

- `correctionDetectionEnabled == true`；
- App 不在黑名单；
- 注入结果为 `.inserted`；
- 非敏感控件；
- 非取消或 ESC 中止；
- 能准确获得注入范围。

### 10.2 分析与卡片

完整复用：

- `CorrectionDiffAnalyzer`；
- 60 秒观察窗口；
- 4 秒防抖；
- 单一词汇修改限制；
- 中文多字替换规则；
- 邮箱、URL、长数字和密钥过滤；
- `CorrectionLearningPanelController` 和现有卡片 UI。

本项目不修改卡片尺寸、字段、按钮、动画或文案。

### 10.3 全局保存

完整复用 `CorrectionLearningStore.learn(_:)` 的事务语义：

1. 正确词追加到 `HotwordStorage`；
2. 错误词到正确词追加或更新到 `SnippetStorage`；
3. 映射保存失败时回滚热词写入；
4. 缓存失效并通知 UI；
5. 热词同步到支持的本地或云端 ASR；
6. 后续所有模式在 ASR 和片段替换阶段使用该词汇。

不增加 Intelli Sense 专属作用域字段。

---

## 11. 注入后统一观察器

### 11.1 重构目的

纠错词检测和表达习惯学习都需要观察同一输入控件。为避免两个 AXObserver、两个定时器和相互冲突的生命周期，将现有协调器重构为：

```swift
@MainActor
final class PostInjectionLearningCoordinator
```

它统一持有：

- 一个 AXObserver；
- 一个 60 秒超时任务；
- 一个 4 秒防抖任务；
- 当前注入上下文；
- 是否已经显示过纠错候选；
- 最新读取到的控件值；
- 纠错与表达学习两个独立开关。

### 11.2 兼容现有卡片

UI 控制器保持原类和原接口。协调器发现纠错候选时调用现有：

```swift
panelController.show(candidate:onLearn:onIgnore:)
```

显示卡片不应终止表达习惯的最终采样；只标记本 session 已处理纠错候选，避免重复弹卡。

### 11.3 生命周期

观察结束条件：

- 60 秒到期；
- 开始下一次录音；
- 目标 AX 元素销毁；
- App 切换或进程退出；
- 控件值不可读；
- 用户关闭对应设置；
- App 新增到黑名单；
- 应用退出。

任何结束路径都必须取消任务、移除通知和释放 AX 引用。

---

## 12. 表达习惯学习

### 12.1 目标与边界

表达习惯学习只回答“用户通常如何表达”，不学习事实内容。它不向用户展示推断结果，也不使用确认卡片。

### 12.2 学习样本

```swift
struct ExpressionObservation: Sendable {
    let sessionID: String
    let createdAt: Date
    let appBundleIdentifier: String?
    let appCategory: ApplicationCategory
    let injectedText: String
    let finalObservedText: String
    let correctionCandidateRange: NSRange?
}
```

`injectedText` 与 `finalObservedText` 只在内存中用于本次特征提取，提取完成后立即释放，不写入表达模型文件。

### 12.3 样本过滤

以下样本不学习：

- 黑名单或敏感控件；
- 注入失败、取消或 LLM Guard 拒绝；
- 文本过短，无法形成稳定风格特征；
- 修改包含数字、日期、金额、邮箱、URL、路径或密钥；
- 修改明显改变事实或语义；
- 多处大范围增删，无法区分风格与内容变化；
- 输入法组合、撤销或自动格式化导致的异常序列；
- 用户在观察窗口中清空全部内容。

纠错词候选对应的词级变化从表达习惯特征中排除，避免把拼写修正误学成风格。

### 12.4 V1 特征集合

只学习可稳定量化且不包含具体内容的特征：

```swift
enum ExpressionFeature: String, Codable, CaseIterable {
    case averageSentenceLength
    case averageParagraphLength
    case lineBreakDensity
    case listUsage
    case headingUsage
    case fillerRetention
    case terminalPunctuationUsage
    case exclamationUsage
    case chineseEnglishSpacing
    case compactness
}
```

不在 V1 学习“幽默”“专业”“友好”等难以稳定定义的主观标签。

### 12.5 证据权重

- 用户主动修改后的最终文本：强证据；
- 注入后未修改：弱接受证据；
- 相同方向的跨 session 修改：累积证据；
- 相反方向修改：负证据；
- 同一 session 的连续键盘事件：只计一个样本。

V1 阈值确定为：

- 至少 5 个有效 session 才能从 `insufficient` 进入 `learning`；
- 至少 10 个有效 session、跨 3 个自然日且方向一致才进入 `stable`；
- 使用指数衰减降低旧习惯权重；
- 设置迟滞区间，避免特征在生效与失效之间频繁抖动。

阈值定义为配置常量并通过离线样本调优，不展示给用户。

### 12.6 作用域

```text
具体 App
  → App 类别
    → 全局
      → 产品默认
```

- App 样本不足时回退 App 类别；
- 类别样本不足时回退全局；
- 仅 `stable` 特征进入 Prompt；
- 具体层级只覆盖同一特征，不覆盖整个档案；
- 黑名单 App 不读也不写任何档案。

### 12.7 模型存储

文件：

```text
~/Library/Application Support/Type4Me/intelli-sense-expression-profile.json
```

存储结构：

```swift
struct ExpressionProfileDocument: Codable, Sendable {
    var schemaVersion: Int
    var global: ScopeExpressionProfile
    var categories: [String: ScopeExpressionProfile]
    var applications: [String: ScopeExpressionProfile]
}

struct ScopeExpressionProfile: Codable, Sendable {
    var sampleCount: Int
    var editedSampleCount: Int
    var firstObservedAt: Date?
    var lastObservedAt: Date?
    var features: [String: FeatureAccumulator]
}

struct FeatureAccumulator: Codable, Sendable {
    var weightedMean: Double
    var totalWeight: Double
    var positiveEvidence: Int
    var negativeEvidence: Int
    var state: FeatureLearningState
    var updatedAt: Date
}
```

`ExpressionProfileStore` 使用 actor 隔离和原子文件写入；内存缓存只保存聚合值。

### 12.8 应用到 Prompt

`EffectiveExpressionProfile` 只输出少量结构化指令，例如：

- 倾向短句；
- 降低列表使用；
- 保留自然段；
- 保留句末标点；
- 不在中文与英文之间自动加空格。

每次最多注入 3–5 条最稳定、与当前场景不冲突的特征，避免 Prompt 过长或规则互相打架。

---

## 13. RecognitionSession 集成

### 13.1 新 session 状态

新增：

```swift
private var intelliSenseContextTask: Task<IntelliSenseContextSnapshot, Never>?
private var intelliSenseRequestContext: IntelliSenseRequestContext?
```

`IntelliSenseRequestContext` 包含本 session 冻结的设置、上下文与有效表达档案。

### 13.2 开始录音

仅当 `effectiveMode.id == intelliSenseId`：

1. 读取设置快照；
2. 同步捕获 Bundle ID 并检查黑名单；
3. 异步启动上下文快照；
4. 异步读取表达档案；
5. 继续现有录音与 ASR 启动；
6. 不调用 `PromptContext.capture()` 的剪贴板或选中文本路径来构建 Intelli Sense Prompt。

其他模式继续使用现有 `PromptContext`，不受影响。

### 13.3 ASR 阶段

所有模式继续调用：

```swift
HotwordStorage.loadEffective()
```

因此由纠错卡片确认的新词会自然进入所有模式的 ASR 请求。

### 13.4 LLM 前处理

所有模式继续在 LLM 前调用全局和 App 片段替换。Intelli Sense 在此基础上：

1. 获取本 session 动态 Prompt；
2. 将场景和表达参数合并；
3. 发起现有单次 LLM 请求；
4. 通过 `IntelliSenseOutputGuard` 检查结果；
5. 失败时回退片段替换后的 ASR 文本。

### 13.5 注入后

仅 Intelli Sense 且至少一个学习开关开启时调用跟踪注入：

```swift
let needsObservation = settings.correctionDetectionEnabled
    || settings.expressionLearningEnabled
```

注入成功后将上下文交给统一观察器。App 黑名单、敏感控件或 Guard 拒绝时，纠错观察和表达习惯学习均不启动，避免基于降级文本产生噪声样本。

### 13.6 清理

以下路径必须取消上下文任务并清空 session 快照：

- 正常完成；
- 取消录音；
- ESC 中止注入；
- ASR 失败；
- LLM 超时；
- 强制 reset；
- recovery 中断；
- session generation 变化。

---

## 14. 并发与线程安全

### 14.1 隔离策略

| 组件 | 隔离方式 |
|---|---|
| `RecognitionSession` | 保持现有 actor |
| `PostInjectionLearningCoordinator` | `@MainActor`，管理 AXObserver 与 AppKit UI |
| `ExpressionProfileStore` | actor，串行读写模型文件 |
| `IntelliSenseSettingsStore` | actor，串行读写设置文件与缓存 |
| Prompt builder、分类器、Guard、特征提取器 | 纯 `Sendable` 值类型 |
| AX 同步 IPC | detached task + 硬超时 |

### 14.2 Session 一致性

- 每个异步结果携带 `sessionGeneration`；
- 过期上下文或档案结果不得写回新 session；
- speculative 和 final 请求共享同一不可变 request context；
- 设置在录音中变化只影响下一次 session；
- 全局生词表保存后允许下一次 ASR 请求生效，不修改当前进行中的识别。

### 14.3 文件一致性

- 设置与表达档案均使用临时文件 + 原子替换；
- schema 不支持时保留原文件并回退默认，不覆盖未知新版数据；
- 表达档案写入失败只影响学习，不影响本次输入；
- 纠错词继续使用现有热词与映射的两阶段回滚。

---

## 15. 性能预算

### 15.1 目标

| 阶段 | P50 预算 | P95 预算 | 超时行为 |
|---|---:|---:|---|
| App 信息捕获 | 5ms | 20ms | 回退未知 App |
| AX 控件捕获 | 30ms | 200ms | 回退 App 级或基础策略 |
| 上下文读取 | 50ms | 300ms | 不携带上下文 |
| 表达档案读取 | 2ms | 10ms | 不应用表达习惯 |
| Prompt 构建 | 1ms | 5ms | 使用基础 Prompt |
| 输出 Guard | 2ms | 10ms | 保守拒绝并回退 ASR 文本 |

### 15.2 延迟控制

- 上下文捕获与 ASR 连接并行；
- 不新增网络请求；
- 表达模型常驻内存聚合缓存；
- Prompt 只注入有限策略，不注入完整画像；
- 学习分析在注入完成后低优先级执行；
- 文件写入防抖，多个特征更新合并为一次原子保存。

---

## 16. 隐私与日志

### 16.1 允许持久化

- 感知项开关；
- 黑名单 Bundle ID 与显示名称；
- 抽象表达特征及聚合统计；
- 用户确认的全局热词和片段替换；
- 现有识别历史字段。

### 16.2 禁止持久化

- 光标附近上下文正文；
- AX 控件完整值；
- 为表达学习临时读取的最终编辑全文；
- 密码、验证码、密钥；
- Prompt 中拼装后的上下文正文；
- 用户风格的自然语言画像或 LLM 总结。

### 16.3 日志规范

日志只允许记录：

- Bundle ID 的哈希或调试构建中的 Bundle ID；
- App 类别和控件类别；
- 上下文字符数、截断标志和可用性；
- Prompt 策略数量，不记录策略内容中的用户数据；
- Guard 拒绝枚举；
- 学习样本接受或拒绝原因；
- 模型 schema、样本计数和写入结果。

Release 构建不得记录上下文正文、原始编辑 diff 或表达模型具体值。

---

## 17. 错误处理与降级矩阵

| 故障 | 用户体验 | 内部行为 |
|---|---|---|
| 设置文件缺失 | 正常使用基础润色 | 创建全关闭默认值 |
| 设置文件损坏 | 正常使用基础润色 | 保留损坏文件，记录错误 |
| 无辅助功能权限 | 正常使用基础润色 | 无控件、上下文和学习 |
| App 在黑名单 | 正常使用基础润色 | 不采集、不观察 |
| AX 超时 | 使用已获得的较低层信息 | 取消过期读取 |
| 表达档案缺失或损坏 | 不应用表达习惯 | 回退空档案 |
| LLM 未配置 | 沿用现有原始转写回退 | 不启动表达学习 |
| LLM 超时或失败 | 沿用现有回退 | 保存 `llm_error` 历史 |
| Guard 拒绝 | 注入片段替换后的 ASR 文本 | 记录拒绝原因，不学习表达 |
| 注入失败 | 保留剪贴板回退体验 | 不启动观察 |
| 纠错保存失败 | 现有卡片显示失败 | 回滚热词写入 |
| 表达模型保存失败 | 用户无感 | 保留内存旧模型，下次重试 |

---

## 18. 数据迁移与回滚

### 18.1 首次升级

1. `ModeStorage` 补入 Intelli Sense；
2. 不修改现有模式顺序、Prompt 和快捷键；
3. 创建默认全关闭的设置文件；
4. 若旧纠错开关存在，迁移其值；
5. 从通用设置移除旧入口；
6. 不移动或复制热词、片段替换；
7. 不创建表达档案，直到用户开启表达习惯感知并产生有效样本。

### 18.2 回滚

- 旧版本忽略新的 Intelli Sense ID 时不得删除其他模式；
- 新设置和表达档案使用独立文件，不污染 `modes.json`；
- 旧纠错开关保留一个发布周期；
- 全局热词和片段替换格式不变，回滚后仍可使用；
- 不做不可逆的历史数据库迁移。

---

## 19. 文件级改动计划

### 19.1 新增文件

```text
Type4Me/Services/IntelliSenseSettings.swift
Type4Me/Services/IntelliSenseContext.swift
Type4Me/Services/IntelliSensePromptBuilder.swift
Type4Me/Services/IntelliSenseOutputGuard.swift
Type4Me/Services/ExpressionLearning.swift
Type4Me/UI/Settings/IntelliSenseModeDetail.swift

Type4MeTests/IntelliSenseSettingsTests.swift
Type4MeTests/IntelliSenseContextTests.swift
Type4MeTests/IntelliSensePromptBuilderTests.swift
Type4MeTests/IntelliSenseOutputGuardTests.swift
Type4MeTests/ExpressionLearningTests.swift
```

### 19.2 修改文件

| 文件 | 修改内容 |
|---|---|
| `Type4Me/UI/AppState.swift` | 新模式 ID、定义、默认列表；移除旧智能模式默认选择 |
| `Type4Me/Services/ModeStorage.swift` | 新模式补入与兼容迁移 |
| `Type4Me/Session/RecognitionSession.swift` | 上下文任务、动态 Prompt、Guard、统一观察入口 |
| `Type4Me/Services/CorrectionLearning.swift` | 观察资格改为 Intelli Sense；抽取统一观察生命周期 |
| `Type4Me/Injection/TextInjectionEngine.swift` | 暴露可复用的安全焦点快照结构或采集器 |
| `Type4Me/UI/Settings/ModesSettingsTab.swift` | Intelli Sense 专用详情分支 |
| `Type4Me/UI/Settings/GeneralSettingsTab.swift` | 移除旧纠错开关入口 |
| `Type4MeTests/ModeStorageTests.swift` | 新模式补入、排序和迁移测试 |
| `Type4MeTests/CorrectionLearningTests.swift` | 新观察资格和全局保存回归测试 |
| `Type4MeTests/RecognitionSessionTests.swift` | 动态 Prompt、降级与观察门控测试 |

### 19.3 明确不修改

- `CorrectionLearningPanel.swift` 的卡片结构和交互；
- `HotwordStorage` 与 `SnippetStorage` 的文件格式；
- 其他官方模式的名称、Prompt 和执行行为；
- `HistoryStore` schema；
- Mac Actions、Ask Anything、翻译和 Prompt 优化流程。

---

## 20. 测试设计

### 20.1 模式与迁移

- 新安装包含 Intelli Sense；
- 现有安装只补入一次；
- 新模式 ID 与旧 `smartDirectId` 不同；
- 不覆盖用户模式顺序和快捷键；
- 不自动切换当前模式；
- 设置四项默认关闭；
- 旧纠错开关存在时正确迁移；
- 损坏设置文件安全回退。

### 20.2 上下文捕获

- 黑名单在任何 AX 读取前短路；
- App 分类映射正确；
- 未知 App 回退 `.other`；
- 单行、多行、搜索、代码和终端控件分类正确；
- AX 超时只降级、不阻塞；
- 录音后切换 App 不改变快照；
- 上下文截取前 300、后 100 字符；
- 不支持参数化范围时安全回退；
- 安全输入框不返回正文；
- 不读取剪贴板或把选择内容当处理目标。

### 20.3 Prompt

- 所有感知关闭时只生成基础润色 Prompt；
- App 感知只增加场景策略；
- 上下文感知只注入受限数据块；
- 表达习惯只注入稳定特征；
- 黑名单忽略所有增强；
- 上下文中的命令不会改变 Prompt 任务；
- `{text}` 只保留一次且不会被上下文二次展开；
- speculative 与 final Prompt 完全一致。

### 20.4 Guard

- 数字、日期、金额变化被拒绝；
- 否定关系变化被拒绝；
- URL、邮箱、路径、标识符丢失被拒绝；
- 无依据翻译被拒绝；
- 回答或解释型输出被拒绝；
- 合法去语气词、去重复和断句被接受；
- 合理分段和场景语气调整被接受；
- 拒绝后回退正确文本。

### 20.5 纠错词

- 只有 Intelli Sense 启动观察；
- 快速模式和语音润色不启动观察；
- 开关关闭、黑名单、敏感控件和注入失败不观察；
- 现有卡片回调不变；
- 确认后同时更新热词与片段替换；
- 新词在所有模式的有效热词中出现；
- 映射在所有模式的前处理阶段生效；
- 映射保存失败回滚热词；
- 既有中文候选、敏感过滤和多修改拒绝测试继续通过。

### 20.6 表达习惯

- 单次样本不生效；
- 有效样本达到阈值后生效；
- 相反证据触发衰减；
- App、类别、全局逐级回退；
- 纠错词修改不进入风格特征；
- 事实修改和敏感修改被过滤；
- 黑名单 App 不读写模型；
- 开关关闭后不读不写；
- 清除后文件、缓存和当前有效档案同时失效；
- 清除表达数据不删除热词和片段替换；
- 模型文件不包含输入或输出全文。

### 20.7 生命周期与并发

- 新录音取消上一观察器；
- AX 元素销毁释放 observer；
- 超时任务和防抖任务被正确取消；
- 旧 session 的上下文不会污染新 session；
- 设置在录音中变化只影响下一次；
- App 退出、权限撤销和文件写入失败不崩溃；
- panel controller 保持懒加载，关闭纠错检测时不创建动画视图。

### 20.8 回归

执行完整 `swift test`，并重点覆盖：

- `ModeStorageTests`；
- `RecognitionSessionTests`；
- `CorrectionLearningTests`；
- `PromptContextTests`；
- `AppStateTests`；
- `VocabularyCommandsTests`；
- `Qwen3HotwordLeakSanitizerTests`；
- `SpeculativeLLMThrottleTests`；
- `TranscriptDiffTests`。

---

## 21. 实施顺序

### 阶段 A：模式与设置骨架

1. 新增独立模式 ID 和官方模式定义；
2. 完成模式补入与迁移；
3. 新增设置 Store；
4. 增加 Intelli Sense 模式详情页；
5. 迁移纠错开关入口；
6. 暂时只使用基础润色 Prompt。

验收条件：新模式可独立录音、润色、注入；其他模式零行为变化。

### 阶段 B：应用与控件感知

1. 新增上下文快照与 App 分类；
2. 接入动态 Prompt；
3. 接入输出 Guard；
4. 保持所有感知默认关闭；
5. 完成延迟和降级测试。

验收条件：开启应用感知后不同场景只改变表达形式，关闭时与基础策略一致。

### 阶段 C：纠错观察迁移

1. 观察资格切换到 Intelli Sense；
2. 通用设置移除入口；
3. 复用现有卡片与全局保存；
4. 完成全模式生效回归测试。

验收条件：只有 Intelli Sense 产生卡片，确认词在所有模式生效。

### 阶段 D：表达习惯学习

1. 统一注入后观察器；
2. 特征提取与过滤；
3. 聚合模型和存储；
4. Prompt 应用；
5. 清除表达数据；
6. 隐私和稳定性测试。

验收条件：不新增用户交互，稳定学习后平均编辑距离下降，关闭开关立即停止生效。

### 阶段 E：上下文感知

1. 有限文字读取；
2. 敏感控件和黑名单保护；
3. Prompt 数据隔离；
4. 截断、超时与隐私测试；
5. 灰度指标验证。

验收条件：上下文不持久化、不阻塞输入，并能改善称呼、术语和语气一致性。

---

## 22. 完成定义

开发完成必须同时满足：

1. Intelli Sense 作为独立官方模式稳定出现；
2. 四项感知默认关闭且设置持久化正确；
3. 关闭所有感知时严格执行基础润色策略；
4. 开启应用或上下文感知时只影响表达形式；
5. 表达习惯模型完全后台化，不产生卡片、标签或偏好管理 UI；
6. 纠错观察只在 Intelli Sense 发生；
7. 纠错确认卡片无 UI 改动；
8. 确认后的纠错词进入全局生词表并在所有模式生效；
9. App 黑名单阻止对应 App 的全部感知和学习；
10. 清除表达习惯数据不影响全局生词表；
11. 上下文、编辑全文和自然语言用户画像不进入长期存储；
12. 任一增强能力失败时仍能完成输入；
13. speculative LLM、历史、注入和其他模式无回归；
14. 完整测试套件通过；
15. 性能指标满足第 15 节预算。

本文档没有遗留产品待确认项；后续进入研发前，只需评审技术拆分、估时与发布批次。
