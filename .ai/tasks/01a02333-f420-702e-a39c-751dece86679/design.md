# Design

## Problem

Type4Me v2.1.0 contains a broad set of user-visible changes between tags `v2.0.0`
(`8f065f4`) and `v2.1.0` (`244478b`), but the public materials are uneven:

- `CHANGELOG.md` and `updates.json` contain a compact v2.1.0 summary;
- the bilingual `README.md` documents Revise, but still describes translation as
  the old English-only mode and does not explain Intelli Sense, Ask Anything
  history, per-mode multiple hotkeys, final-output formatting, or vocabulary
  automation;
- the current README screenshot grid shows the redesigned application generally,
  but does not demonstrate the main v2.1.0 workflows;
- README claims that the companion Skill achieves "100%" accuracy, which cannot
  be proven from repository code or tests.

The release-material update must make the v2.1.0 feature set discoverable without
claiming behavior beyond the tagged implementation. Chinese and English README
sections must remain semantically aligned. Missing screenshots may be represented
by explicit placeholders.

## Audit Baseline

- Comparison range: `git diff v2.0.0..v2.1.0`.
- Public materials: `README.md`, `CHANGELOG.md`, `updates.json`.
- Product documentation index: `docs/README.md`.
- Evidence standard: a user-facing claim must be supported by tagged production
  code and, where practical, focused tests. Product/design documents are context,
  not sole proof of implementation.
- This task changes documentation only. It does not change product behavior,
  settings defaults, release binaries, checksums, or update feed structure.

## Current System and Evidence Matrix

| Capability | Repository evidence | Safe public claim | Boundary to preserve |
| --- | --- | --- | --- |
| Redesigned settings and recording UI | `Type4Me/UI/Settings/*`, `Type4Me/UI/FloatingBar/*`; commits `73f8e52`, `d1537c9`; `SettingsDraftCoordinatorTests.swift` | Home, Modes, History, Vocabulary, Model settings, recording feedback, and live transcript visibility were redesigned | Avoid claiming every settings page is new; several were reorganized or restyled |
| Multiple hotkeys per mode | `Type4Me/Input/HotkeyManager.swift`, `ProcessingMode.hotkeyBindings`, `Type4MeApp` fan-out; `HotkeyConflictTests.swift`, `HotkeyStateMachineTests.swift`; commit `a8d63ff` | One mode can bind multiple hold or toggle shortcuts | A shortcut conflict can prevent a new binding; Revise has a separate global binding |
| Intelli Sense | `Type4MeIntelliSenseCore/*` (defaults in `Type4MeIntelliSenseCore/IntelliSenseDomain.swift:135-138`), `Type4Me/Services/IntelliSenseContext.swift`, `Type4Me/UI/Settings/IntelliSenseSettingsView.swift`; Intelli Sense test suites; baseline `302e9b4` plus later fixes | Uses the current App/control and limited context to polish text, with optional learning from stable corrections, expression preferences, and list structure | `applicationAwarenessEnabled`, `contextAwarenessEnabled`, `correctionDetectionEnabled`, and `expressionLearningEnabled` default to `false`; do not present learning as always active |
| Ask Anything history | `AskAnythingStore.swift`, `AskAnythingCoordinator.swift`, `AskAnythingPage.swift`; Ask Anything tests; commit `3f4212a` | Search, reopen, rename, delete, and continue saved conversations by voice | History can be disabled; active follow-up operations constrain deletion/switching |
| Unified translation | `TranslationLanguage.swift`, `TranslationPromptBuilder.swift`, `TranslationOutputValidator.swift`; translation tests; commits `5076296`, `0bc9bf8` | Automatically infers source language and translates to one of 18 selectable target languages; retries once if output language validation fails | Say "18 target languages", not "18 source languages"; existing stored target settings are migrated/preserved |
| Revise | `Type4MeReviseCore/*`, `ReviseCoordinator.swift`, tracked replacement engine, Revise tests; commits `08d8653`, `15c5f80` | Voice-edit the most recent still-trackable Type4Me insertion, preserve unrelated content, and undo a successful revision | Revise is not arbitrary document editing; it fails safely when the target is stale/unavailable. Default `Fn+R` may be left unassigned during migration if it conflicts with an existing binding |
| Final-output formatting | `TextOutputFormatter.swift`; `TextOutputFormatterTests.swift`; commits `a5e7026`, `0e0d3ba` | Optional Pangu-style CJK/Latin spacing and corner-quote conversion are applied at final output | English apostrophes are preserved; describe settings as optional |
| Vocabulary automation | `VocabularyCommands.swift`, `VocabularyActions.swift`, `Type4MeApp` URL handling; `VocabularyCommandsTests.swift`; commit `6458b1c` | External tools can open vocabulary management and request a vocabulary reload through Type4Me URL commands | Do not claim every vocabulary edit or recognition error is automatically corrected |
| Stability/performance | commits `791d421`, `e6ceac0`, `f27121d`, `36a65d5`, `7b93c16`, `dbc8d1f`, `08e9726` and corresponding tests | Mention concrete fixes: Volcano transcript snapshots, Fn tap completion, login registration, internal clipboard history, LLM-client reuse, inactive-settings resource release, runtime cache compaction | Avoid numeric speed/memory claims; no tagged benchmark supports them |

## Proposed Design

### 1. README information architecture

Apply the same structure and feature order to both `# 中文` and `# English`:

1. Keep the existing hero, download table, system requirements, architecture,
   development instructions, acknowledgements, and license.
2. Replace the current terse top feature list with a v2.1-aware overview. Include:
   speech recognition; configurable processing modes; Intelli Sense; Ask Anything;
   unified translation; Voice Revise; vocabulary/companion Skill; multiple hotkeys;
   history; provider integration.
3. Replace the old "英文翻译 / English Translation" row in the mode table with
   "翻译 / Translation" and describe automatic source-language detection plus a
   selectable target among 18 languages.
4. Add focused subsections after the mode table, in this order:
   - Intelli Sense
   - Ask Anything
   - Translation
   - Multiple hotkeys and recording behavior (including live transcript visibility setting)
   - Vocabulary management and companion Skill
   - Voice Revise (retain and tighten the existing section)
5. Add a short "Output formatting" paragraph under text processing rather than a
   standalone major section.
6. Keep feature prose user-oriented. Move implementation/module details to the
   existing architecture section instead of mixing them into feature descriptions.

### 2. Copy-ready README claims

The Builder may use the following Chinese copy directly, with an equivalent English
translation immediately mirrored in the English section.

#### Intelli Sense

> **Intelli Sense（可选）**：根据当前 App、输入控件和有限上下文安全润色文字；还可按需学习你稳定的纠错、表达和列表结构偏好。各项感知与学习能力可独立开启，默认不会静默学习。

English equivalent:

> **Intelli Sense (optional)** safely polishes text using the current app, input control, and limited context. You can separately enable learning from stable corrections, expression preferences, and list structure; awareness and learning are not silently enabled by default.

#### Ask Anything

> **Ask Anything**：围绕选中文本直接提问，并把连续追问保存为会话；可在设置中搜索、恢复、重命名或删除历史会话，也可从历史会话继续语音追问。

English equivalent:

> **Ask Anything** lets you ask about selected text and continue with spoken follow-ups. Saved conversations can be searched, reopened, renamed, deleted, or resumed from Settings.

#### Translation

> **统一翻译模式**：自动识别输入语言，翻译为你选择的 18 种目标语言之一，并在输出语言不符时进行校验与一次重试。

English equivalent:

> **Unified Translation** detects the source language automatically, translates into one of 18 selectable target languages, and validates the output language with one retry when needed.

#### Multiple hotkeys and recording behavior

> 每个模式可绑定多个全局快捷键，并为每个快捷键选择「按住说话」或「按一下开始、再按一下停止」；录音期间也可用另一个模式的快捷键结束并按该模式处理。录音浮窗支持按需开启或隐藏实时转写内容。

English equivalent:

> Each mode can have multiple global shortcuts. Every shortcut can use hold-to-talk or press-to-start/press-again-to-stop, and another mode's shortcut can finish the active recording and process it with that mode. The recording floating bar supports toggling live transcript visibility on or off as needed.

#### Formatting

> 最终文本可按需应用中英文盘古空格和中文直角引号；英文撇号会被保留。

English equivalent:

> Final output can optionally apply Pangu-style CJK/Latin spacing and Chinese corner quotes while preserving English apostrophes.

#### Vocabulary automation

> 配套 Skill 可通过 Type4Me 的词汇命令打开词汇管理并刷新词表，帮助把反复出现的专有名词错误固化为热词或片段替换规则。

English equivalent:

> The companion Skill can use Type4Me vocabulary commands to open vocabulary management and reload the vocabulary, helping turn recurring proper-name errors into hotword or snippet-replacement rules.

#### Revise boundary

Tighten the existing Revise introduction to:

> 对最近一次仍可可靠定位的 Type4Me 输入，按下改口快捷键并说出修改指令；Type4Me 只替换授权范围，目标已变化或无法定位时会安全失败。成功后可一键或语音撤销。

English equivalent:

> For the most recent Type4Me insertion that can still be located reliably, press the Revise shortcut and speak an edit instruction. Type4Me limits changes to the authorized scope and fails safely when the target changed or cannot be found. Successful revisions can be undone by button or voice.

Do not promise that `Fn+R` is always active. If mentioned, phrase it as "the default
when available" because migration deliberately leaves it unassigned on conflict.

### 3. Accuracy wording

The absolute "100% accuracy" wording appears in both README prose and the bilingual
header SVG assets. Repository tests establish behavior, not an end-user recognition
accuracy guarantee. Preferred replacement:

- Chinese: "持续提高专有名词识别一致性，打造更懂你的输入体验"
- English: "Improve proper-name consistency and build a voice input workflow tailored to you"

If product ownership explicitly chooses to retain "100%", the Builder must leave it
unchanged consistently in both prose and header assets rather than partially
rewriting the claim. This is a product/marketing decision, not an engineering fact.

### 4. v2.1.0 long-form release note

Use the following body for the GitHub Release and expand the existing
`CHANGELOG.md` v2.1.0 entry to match it (the changelog may omit screenshot markup):

```markdown
## Type4Me v2.1.0

v2.1.0 refreshes the settings and recording experience and adds context-aware
writing, persistent voice Q&A, multilingual translation, and voice-driven revision.

### Highlights

- **Redesigned Settings and recording UI** — refreshed Home, Modes, History,
  Vocabulary, and Model pages, plus clearer recording and processing feedback.
- **Multiple shortcuts per mode** — bind more than one hold/toggle shortcut to a
  mode and finish a recording with the mode you want to use for processing.
- **Intelli Sense** — optionally use the current App, input control, and limited
  context for safer polishing, with separately controlled learning from stable
  corrections, expression preferences, and list structure.
- **Ask Anything conversation history** — search, reopen, rename, delete, and
  continue saved voice Q&A conversations.
- **Unified Translation** — detect source language automatically, select from 18
  target languages, and validate the output language with one retry when needed.
- **Voice Revise** — revise the most recent still-trackable Type4Me insertion with
  a spoken instruction, scope protection, safe failure, and undo.

### Improvements

- Optional Pangu-style CJK/Latin spacing and Chinese corner-quote formatting,
  while preserving English apostrophes.
- Added live transcript visibility setting for the recording floating bar.
- Vocabulary URL commands for opening vocabulary management and reloading changes
  made by companion automation.
- Better release of inactive Settings and Ask Anything resources, LLM-client reuse,
  and smaller runtime caches.

### Fixes

- Prevented duplicate revised snapshots in Volcano ASR transcripts.
- Restored reliable Fn quick-tap recording completion and HID-first key taps.
- Rejected invalid bare-executable login-item registrations.
- Kept Type4Me's internal clipboard writes out of clipboard history.

### Upgrade notes

- Existing translation preferences are preserved when migrating to the unified
  translation mode.
- Intelli Sense awareness and learning controls remain opt-in.
- Revise uses `Fn+R` by default when that shortcut is available; upgrades with an
  existing conflict leave the Revise shortcut unassigned for the user to choose.
```

Chinese GitHub Release prose should communicate the same content and boundaries;
do not publish an English-only long-form release when the main README remains
bilingual.

### 5. `updates.json` compact note

Keep the update feed compact and structurally unchanged. The existing four-line
v2.1.0 note is broadly correct; replace it with these five lines only if the client
display can accommodate the added line:

```text
- 全面重构设置、历史、词汇与录音浮窗，同一模式支持多个 hold/toggle 快捷键
- 新增可选 Intelli Sense：结合 App、控件和有限上下文润色，并按需学习稳定偏好
- Ask Anything 新增可搜索、恢复和继续追问的会话历史
- 统一翻译支持自动识别源语言、18 种目标语言；新增受控语音改口 Revise
- 改进最终文本格式化，并修复火山转写、Fn 点按、登录项和内部剪贴板历史问题
```

Do not modify v2.1.0 URLs, sizes, hashes, `latest`, or the JSON schema as part of
this documentation task.

## Screenshot Plan

Existing reusable assets:

- `docs/images/screenshot-1.webp` through `screenshot-4.webp`: general UI grid;
- `docs/screenshots/screenshot-homepage.png`;
- `docs/screenshots/screenshot-modes.png`;
- `docs/screenshots/screenshot-history.png`;
- `docs/screenshots/screenshot-vocabulary.png`;
- `docs/screenshots/screenshot-askit.png`;
- `docs/screenshots/screenshot-intelli-sense-history.png`;
- `docs/screenshots/prototype-revise.png` (prototype, not a final product capture).

Required README/Release placements:

1. Reuse `screenshot-modes.png` for the redesigned modes/multiple-hotkey section.
2. Reuse `screenshot-askit.png` for Ask Anything history if it visibly shows the
   shipped v2.1.0 UI.
3. Reuse `screenshot-intelli-sense-history.png` for Intelli Sense learning/history.
4. Add an explicit placeholder for a Translation target-language selector capture.
5. Add an explicit placeholder for a real Revise workflow capture showing the
   source text, revise instruction/status, and Undo result. Continue using
   `prototype-revise.png` only when labeled "prototype".
6. Add an explicit placeholder for multiple hotkey bindings if the existing modes
   screenshot does not make both hold/toggle bindings legible.

Placeholder syntax for `README.md`:

```html
<!-- SCREENSHOT TODO (v2.1.0): Translation target-language selector; capture on the
     v2.1.0 build, redact credentials, and supply matching zh/en alt text. -->
```

For GitHub Release drafts, use bracketed text rather than a broken image link:
`[Screenshot TODO: v2.1.0 Translation target-language selector]`.

## Affected Components

| Artifact | Responsibility of the change |
| --- | --- |
| `README.md` | Bilingual product overview, detailed feature descriptions, boundaries, screenshots, and accuracy wording |
| `CHANGELOG.md` | Durable long-form v2.1.0 feature/improvement/fix record |
| `updates.json` | Compact in-app v2.1.0 summary only; preserve release metadata |
| `docs/images/header-combined.svg` and `header-combined-en.svg` | Change only if the accepted accuracy wording removes the absolute claim |
| GitHub v2.1.0 Release body | Publish the long-form release note with screenshot placeholders or final captures |

No Swift source, database, settings, migration, or release-package interface changes
are required.

## Interfaces and State

- Documentation has no runtime state changes.
- `updates.json` is a consumed interface: retain valid JSON, existing object keys,
  download metadata, and escaped newline format.
- Existing stored product state must be described accurately: translation target
  migration is preserved; Intelli Sense awareness/learning is opt-in; Revise shortcut
  conflict migration can produce an unassigned shortcut.
- Bilingual README parity is an interface requirement: a claim added to Chinese must
  have an equivalent English claim in the same relative section.

## Compatibility

- Keep current v2.1.0 download URLs and macOS 14+ requirement.
- Do not remove instructions for cloud/local editions or local development.
- Existing anchors should remain stable where possible; new subsection anchors may
  be added without renaming top-level `# 中文` and `# English` anchors.
- Relative repository image paths are preferred over new external attachment URLs.
- Release notes must not imply features were introduced after the tagged build.

## Failure Modes

- **Overstatement:** optional learning or a conditional shortcut is described as
  always active. Mitigation: use the boundaries in the evidence matrix.
- **Bilingual drift:** Chinese and English make different promises. Mitigation:
  review sections as pairs.
- **Broken screenshots:** placeholders are published as missing file references.
  Mitigation: use comments/bracketed TODOs until files exist.
- **Prototype presented as shipped UI:** `prototype-revise.png` is unlabeled.
  Mitigation: label it or replace it with a v2.1.0 capture.
- **Update feed damage:** JSON metadata or escaping changes while editing prose.
  Mitigation: validate with `jq empty updates.json` and diff release metadata.
- **Unverifiable marketing claim:** "100%" is treated as a measured result.
  Mitigation: adopt the evidence-based wording or explicitly record product owner's
  decision to retain it.

## Test Strategy

Documentation implementation is complete when all of the following pass:

1. `git diff --check` reports no whitespace errors.
2. `jq empty updates.json` validates the update feed.
3. `rg -n '英文翻译|English Translation' README.md` finds no stale English-only
   mode description (historical changelog entries are not in scope).
4. `rg -n 'Intelli Sense|Ask Anything|18|Revise|盘古|Pangu|多个.*快捷键|multiple.*hotkey' README.md`
   confirms the feature families exist in both language halves.
5. A small script or manual checklist compares Chinese/English headings and claims
   for semantic parity.
6. Every relative image reference in `README.md` resolves to an existing file;
   placeholders contain no `src` until the asset exists.
7. Review `git diff v2.0.0..v2.1.0` and the evidence matrix once more to ensure no
   material shipped feature was dropped from the release note.
8. Render README Markdown in GitHub preview and inspect tables, image widths,
   anchors, code fences, and mobile readability.
9. If the accuracy claim changes, target the accuracy text specifically (e.g. `rg -n '100%\s*(准确率|accuracy|accur)'` or `rg -n '准确率|accuracy'`, explicitly excluding `width="100%"` and `@keyframes`) in `README.md` and both header SVGs so prose and artwork remain consistent.

No application build is required for prose-only edits. If screenshots are newly
captured, they must come from the tagged v2.1.0 build and be manually checked for
credentials, personal text, account data, and other sensitive content.

## Alternatives Considered

### Only expand `CHANGELOG.md`

Rejected because README is the primary discovery surface and currently contains
stale mode descriptions. It would leave the user-facing mismatch unresolved.

### Treat commit subjects as the release note

Rejected because commit subjects mix implementation detail, fixes, experiments,
and product behavior. The evidence matrix groups them into stable user-facing
capabilities and states their boundaries.

### Add every feature to the top bullet list only

Rejected because it would become hard to scan and would not explain opt-in settings,
Revise targeting, translation targets, or screenshot needs. Use a concise overview
plus focused subsections.

## Risks

- The public release may already exist; changing the repository does not update the
  GitHub Release body automatically. Builder/DevLead must update that external body.
- Marketing may prefer the current absolute accuracy language despite lack of
  repository evidence.
- Existing screenshots may depict intermediate UI. Each reused asset needs visual
  confirmation against the tagged v2.1.0 build.
- The tag date and existing `updates.json` v2.0.0 date differ from the changelog's
  v2.0.0 date. This task must not silently rewrite historical release metadata.

## Open Questions

1. Should the unsupported "100% accuracy" claim be replaced in README prose and
   the two header SVGs with the evidence-based wording above?
2. Should final screenshots use a single Chinese UI set with bilingual captions, or
   separate Chinese and English captures?
3. Should the public GitHub Release retain the stability/performance section, or
   focus only on user-visible features and fixes?
4. Who will capture the missing v2.1.0 Translation, multiple-hotkey (if needed), and
   real Revise screenshots?

These questions do not block implementation of the uncontroversial README/release
structure, feature coverage, accurate boundaries, and screenshot placeholders.

## Readiness

This design is ready for independent review. After review, a Builder can implement
all uncontroversial documentation changes and placeholders without product-behavior
guesswork. Final publication of accuracy wording and screenshot selection requires
the product choices listed under Open Questions.
