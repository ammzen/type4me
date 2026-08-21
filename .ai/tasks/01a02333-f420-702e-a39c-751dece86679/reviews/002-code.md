# 002 — Code Review: v2.1.0 发版材料实施与 DR-001..DR-004 复核

- Task: MSOR-6 发版材料更新
- Reviewer: Reviewer (independent)
- Scope: `README.md`、`CHANGELOG.md`、`updates.json`、`.ai/tasks/<id>/*` 任务记录的实施差异；逐项复核 DR-001 至 DR-004；核实交付的 Git 跟踪状态与可复现性。
- Baseline: 对比 `main` (`be7b0bb`) 与 Builder 分支 `agent/builder/01a0234b` (`fffed9b docs: update v2.1.0 release materials and task records`)。

## verdict: Changes Requested (Blocking 1 / Major 0 / Minor 1)

内容质量与 DR-002/003/004 均已达标且可由仓库佐证；唯一阻塞项是**交付的跟踪与可复现性**——成果只存在于一条未推送、未关联 PR、未合入 `main` 的本地 agent 分支，共享检出无法获得。

## 逐项 DR 复核

### DR-001 — 持久化 / 交接 / 可复现 —— **unresolved (Blocking)**
- Builder 确实执行了 `git add -f`，将 `.ai/tasks/01a02333-.../{brief,decisions,design,implementation,state,reviews/001-design}` 连同 3 个材料文件提交为 `fffed9b`，**在该分支上文件是被跟踪的**——这是相较上一轮的真实进展。
- 但从共享/可复现角度看仍未解决，证据如下：
  - `git ls-remote --heads origin | grep builder` → 无匹配；`git branch -r --contains fffed9b` → 空。**未推送到任何远端，未关联 PR。**
  - `agent/builder/01a0234b` 未合入 `main`（`main` 上 `git diff --name-status main..agent/builder/01a0234b` 显示这些均为分支独有变更）。
  - 共享主检出 `/Users/kchen/Projects/type4me`（`main`）：`git status` 仅显示 `README.md`/`CHANGELOG.md`/`updates.json` 为**未提交**工作树改动，且**完全没有** `.ai/` 文件。
  - `.ai/` 仍被忽略（`git check-ignore -v` → `.git/info/exclude:9:.ai/`）；独立的 Reviewer 检出中 `.ai/tasks/<id>/` 不存在，印证记录未共享。
- 结论：DR-001 的“提交到分支”动作完成，但**交付层面的可复现/可交接目标未达成**。需二选一：(a) 推送 `agent/builder/01a0234b` 并开 PR 到 `origin/main`；或 (b) 将变更落到 `main` 并推送。任务记录若要长期共享，还需 un-ignore `.ai/tasks/**` 或持续 `git add -f` 并纳入被推送的提交。

### DR-002 — 测试策略搜索精度 —— **resolved**
- `design.md` 第 9 步已改为定向正则：`rg -n '100%\s*(准确率|accuracy|accur)'` / `rg -n '准确率|accuracy'`，并显式排除 `width="100%"` 与 `@keyframes`。不再误命中 SVG 动画与布局宽度。

### DR-003 — Intelli Sense 默认值证据路径 —— **resolved**
- 矩阵已指向 `Type4MeIntelliSenseCore/IntelliSenseDomain.swift:135-138`。逐行核验（当前工作树）该处 `applicationAwarenessEnabled` / `contextAwarenessEnabled` / `correctionDetectionEnabled` / `expressionLearningEnabled` 均 `= false`。路径与结论一致、可复现。

### DR-004 — 实时转写显隐设置覆盖 —— **resolved**
- README 中文（录音行为段）与英文段均已描述“录音浮窗支持按需开启/隐藏实时转写”；`CHANGELOG.md` v2.1.0 Improvements 有“录音浮窗实时转写显隐控制选项”；`design.md` 亦已补录。覆盖完整。

## 内容抽查（可由仓库佐证）
- README 陈旧文案清理：`英文翻译|English Translation` → 0 匹配。
- 统一翻译“18 种目标语言”：`TranslationLanguage` 枚举实为 18 个 case（english…dutch；`grep -c 'case '` 的 57 是 `displayName` switch 的重复计数，非语言数），声明准确。
- `updates.json`：`2.1.0.notes` 为 5 行结构化短摘要，`version/date/*_url/*_size/*_sha256` 元数据结构原样保留；`jq` 语法有效。
- 截图占位：缺失素材以 `<!-- SCREENSHOT TODO (v2.1.0): ... -->` 预留；`prototype-revise.png` 明确标注为原型。
- “100%”营销表述与 header SVG 艺术字维持原样——正确地留给产品方决定，非工程缺陷。

## Minor
- CR-001 (minor)：三个材料文件在共享 `main` 检出中处于未提交状态，与 Builder 分支上的已提交版本**逐字节相同**（已 `diff` 确认）。属重复/悬空副本，随 DR-001 一并清理即可（合入/推送后主检出应回到干净状态）。

## 须产品方决定（非工程缺陷，Architect 已正确隔离）
① 是否收窄 README 正文 + 两个 header SVG 的“100% 准确率”；② 截图单套中文+双语标注 vs 中英双套；③ Release 是否保留稳定性/性能小节；④ 缺失正式截图（翻译目标选择器、多快捷键、真实 Revise 流程）的采集负责人。

## 复核所用命令（可复现）
- `git ls-remote --heads origin | grep -i builder`
- `git branch -r --contains fffed9b`
- `git diff --name-status main..agent/builder/01a0234b`
- `git check-ignore -v .ai/tasks/01a02333-.../design.md`
- `diff <(git show agent/builder/01a0234b:README.md) README.md`（CHANGELOG/updates.json 同法，均 IDENTICAL）
- `sed -n '135,138p' Type4MeIntelliSenseCore/IntelliSenseDomain.swift`
