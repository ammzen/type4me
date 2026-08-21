# Review 001 — Design (MSOR-6 发版材料更新)

Type: Design review
Reviewer: Reviewer (independent)
Artifact under review: `.ai/tasks/01a02333-f420-702e-a39c-751dece86679/design.md` (386 lines)
Repository baseline verified: `v2.0.0` = `8f065f4`, `v2.1.0` = `244478b` (both tags resolve; 53 commits in range)

## Scope

Independent review of feature coverage, claim evidence, bilingual consistency,
release boundaries, and the screenshot-placeholder plan, with product/marketing
decisions separated from directly-implementable content.

## Evidence Verification (independent)

All spot-checks run against the `v2.1.0` tag, not the working tree (HEAD is
`v2.1.0-15-gbe7b0bb`, 15 commits ahead — reviewed at the tag to match the design's
audit baseline).

Verified TRUE:
- All 12 cited commit SHAs resolve to commits (`73f8e52 d1537c9 a8d63ff 302e9b4 3f4212a 5076296 0bc9bf8 08d8653 15c5f80 a5e7026 0e0d3ba 6458b1c`).
- Translation exposes exactly **18** target-language enum cases (`Type4Me/Models/TranslationLanguage.swift`), supporting the "18 target languages" wording and refuting any "18 source languages" phrasing.
- The four Intelli Sense boundary flags **default to `false`** in `Type4MeIntelliSenseCore/IntelliSenseDomain.swift:135-138` (`applicationAwarenessEnabled`, `contextAwarenessEnabled`, `correctionDetectionEnabled`, `expressionLearningEnabled`). The "opt-in / not silently enabled" boundary is accurate.
- `Type4MeIntelliSenseCore/*` and `Type4MeReviseCore/*` module directories exist at the tag.
- README still carries the stale English-only translation row (`英文翻译` / `English Translation`, README lines 87 / 272) and the unsupported `100%` accuracy prose (README lines 24, 71, 187, 256). The stale-mode and overstatement problems the design targets are real.
- The `100%` accuracy claim **is present as text inside both header SVGs** (`docs/images/header-combined.svg`, `...-en.svg`: "…配套Skill，打造属于你的100%准确率输入法" / "100% accur…"). The design's claim that the wording lives in the artwork is correct.
- All reusable screenshot assets the design lists **exist** on disk (`docs/screenshots/*.png`, `docs/images/screenshot-*.webp`), and `prototype-revise.png` is correctly identified as a prototype.
- `updates.json` v2.1.0 note is currently 4 lines with intact metadata; the design's "extend to 5 lines only if the client display allows" caution matches the current structure.

Verified with nuance (see findings):
- SVG `100%` text coexists with CSS `@keyframes` (`0%…100%`) and `width="100%"`; a bare `100%` search is noisy (DR-002).
- Intelli Sense flag defaults live in `IntelliSenseDomain.swift`, not the `IntelliSenseSettings.swift` cited by the matrix (DR-003).

## Findings

## DR-001

Severity: Major
Category: Compatibility / Persistence / Handoff

Location:
`.ai/` (repository `.gitignore`) — the entire task directory including
`design.md` and this review.

Problem:
`.ai/` is git-ignored (`git check-ignore .ai/tasks/.../design.md` → match, exit 0).
The design exists **only** in the Architect's local checkout
(`/Users/kchen/Projects/type4me`), untracked and unshared. It is absent from this
review's worktree and from any fresh clone.

Evidence:
DevLead flagged three times that the file could not be found at the canonical path;
the Architect's "verified `test -f … exit 0`" checks all passed because they ran in
the one checkout that has the untracked file. The disagreement is fully explained by
the gitignore, not by a missing file.

Impact:
The Builder will likely run in a different worktree and cannot consume the design;
independent review is not reproducible across checkouts; this same problem will make
`reviews/001-design.md` invisible too. This is a real workflow blocker even though
the design *content* is sound.

Required Change:
Decide and apply a shared-persistence mechanism before Builder handoff — e.g.
un-ignore `.ai/tasks/**` (or commit these artifacts explicitly with `git add -f`),
or relocate task artifacts to a tracked path. Not an engineering flaw in the
document; it is a persistence/handoff defect that must be resolved for the design to
be actionable outside one machine.

## DR-002

Severity: Minor
Category: Testability

Location:
`design.md` Test Strategy step 9 ("search `README.md` and both header SVGs for `100%`").

Problem:
A bare `100%` search matches false positives: README `width="100%"` (README line 14 /
177) and, in the SVGs, CSS animation keyframes (`0%{…} 100%{…}`) and `width="100%"`
attributes. Only the accuracy phrase is in scope.

Impact:
The Builder may either miss the real claim among noise or edit unrelated `100%`
tokens (breaking animations/layout).

Required Change:
Target the accuracy text specifically, e.g. `rg -n '100%\s*(准确率|accuracy|accur)'`
or `rg -n '准确率|accuracy'`, and explicitly exclude `width="100%"` and `@keyframes`.

## DR-003

Severity: Minor
Category: Correctness (evidence precision)

Location:
`design.md` evidence matrix, Intelli Sense row.

Problem:
The row cites `IntelliSenseSettings.swift` as evidence for the four opt-in defaults,
but the `= false` defaults are actually declared in
`Type4MeIntelliSenseCore/IntelliSenseDomain.swift:135-138`. The claim is correct; the
pointer is imprecise. Several other matrix cells use bare filenames whose real paths
are under `Type4Me/Models`, `Type4Me/Services`, etc.

Impact:
Minor Builder friction locating evidence; no incorrect claim.

Required Change:
Point the Intelli Sense default-state evidence at `IntelliSenseDomain.swift`; keep
matrix file references path-qualified where practical.

## DR-004

Severity: Minor
Category: Coverage

Location:
`design.md` README information architecture / release-note feature set.

Problem:
The v2.0.0..v2.1.0 range includes `feat: add live transcript visibility setting`
(a user-visible recording/UI option) that is not explicitly surfaced in the proposed
README subsections or release Highlights/Improvements. Most other feature commits map
cleanly to the matrix; dev-only items (`Codex CLI 本地账号运行时`, debug-settings
redesign) are reasonably excluded.

Impact:
A small shipped, user-facing setting may go undocumented. Not a material omission.

Required Change:
Either fold "live transcript visibility" into the recording-behavior paragraph or
consciously decide to omit it; Test Strategy step 7 (re-diff against the matrix)
should catch it.

## Human Decisions Required (correctly separated by Architect — affirmed)

The design's four Open Questions are genuine product/marketing choices, not
engineering defects, and are correctly walled off from the implementable content:

1. Replace vs retain the unsupported "100% accuracy" claim (README prose + both header SVGs). **Human Decision.** Engineering note: repository code/tests establish behavior, not an end-user accuracy guarantee, so the claim is unverifiable — but retaining it is a marketing call.
2. Single Chinese screenshot set with bilingual captions vs separate zh/en captures. **Human Decision.**
3. Keep or drop the stability/performance section in the public GitHub Release. **Human Decision.**
4. Who captures the missing Translation / multi-hotkey / real-Revise screenshots on a v2.1.0 build. **Human Decision (ownership).**

Directly implementable now without product input: the bilingual IA restructure, the
stale `英文翻译`→`翻译` mode-row fix, the accurate feature subsections and boundary
copy, the long-form CHANGELOG/Release body, the `updates.json` compact note (kept
structurally unchanged), and all screenshot **placeholders** (HTML comment / bracketed
TODO forms). The design's separation here is sound.

## Assessment by requested dimension

- Feature coverage: complete except the minor DR-004 item; matrix maps to real commits/tests.
- Claim evidence: strong; every spot-checked claim is repository-backed, boundaries are accurate (opt-in defaults, 18 targets, Revise safe-failure, `Fn+R` conflict handling).
- Bilingual consistency: correctly elevated to an interface requirement (parity rule + paired-review mitigation).
- Release boundaries: correct — no URL/hash/schema/settings-default/binary changes; documentation-only; historical release metadata explicitly protected.
- Screenshot plan: sound — reuses existing assets, labels the prototype, uses non-broken placeholder syntax.

## Summary

Verdict: Changes Requested

Blocking: 0
Major: 1
Minor: 3

Architecture Concerns: 0
Human Decisions Required: 4 (correctly separated by Architect; affirmed, not defects)

The design content is well-evidenced, correctly bounded, and ready for Builder on the
implementable scope. The one Major (DR-001) is a persistence/handoff problem — the
git-ignored `.ai/` path — that must be resolved so the design and this review are
actually shareable; the three Minors refine verification and evidence precision.
