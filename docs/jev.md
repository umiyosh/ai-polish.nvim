# Jev evaluation: design and validation

Implementation for [Issue #7](https://github.com/umiyosh/ai-polish.nvim/issues/7).

## Why a separate entry

Evaluation is useful before Gemini proofreading, to decide whether proofreading is worth doing. One explicit evaluation action sends the current target to Jev; a separate toggle displays cached results for free. The passive corner panel preserves editing focus. Existing correction-popup actions are unchanged, so evaluation does not introduce another acceptance mode.

A selected target stays anchored through edits. The same evaluation key follows it; `evaluate buffer` explicitly switches to the whole document. Deleting a target invalidates it instead of silently widening scope. `polish` uses the current retained target, while existing proofreading commands retain their old scopes. Active Visual hints are shown only for a matching selection (exclusive selections use the safe command fallback).

The default panel is 30 content cells and two axes on separate rows. Optional `panel_width=60` permits a single row only when all localized states fit. ASCII bars avoid East Asian Ambiguous-width symbols. Stage colors are semantic, theme-overridable, and independent of deletion red. Stale text remains readable; confidence below 0.5 replaces the stage label with a generic uncertainty cue. This threshold is a presentation choice, not calibrated accuracy.

Claude Code reviewed the entrance design in two rounds, the implementation copy/layout, and real Neovim screenshots. The implementation incorporates compact default width, explicit line units, truncated-name markers, aligned probabilities, current-stage descriptions, conditional stale notices, and a persistent close hint in the details title.

## Actual UI captures

These are crops of real Neovim terminal screenshots with **offline fixture results**. They demonstrate UI behavior, not model quality. The offline demo explicitly labels results as fixtures and intercepts all HTTP.

Japanese, retained selection, dark theme:

![Japanese corner panel](images/jev-panel-ja.png)

Traditional Chinese, low confidence, light theme:

![Traditional Chinese uncertain result](images/jev-panel-hant-light.png)

Japanese, previous result after editing:

![Previous result](images/jev-panel-stale.png)

Simplified Chinese, rejected configured key (different from no-key suppression):

![Simplified Chinese authentication error](images/jev-panel-hans-error.png)

Cached Japanese details (q/Esc closes, j/k scrolls):

![Japanese details](images/jev-details-ja.png)

Reproduce without a key or network from the repository root:

```sh
nvim -u scripts/jev-demo.lua
```

The demo uses the worktree's runtime path, not an installed plugin copy. `:lua print(vim.api.nvim_get_runtime_file("lua/ai-polish/evaluation.lua", false)[1])` shows the loaded source. Personal dotfiles and installed plugin pins are not changed.

## Model contract

[TypeSafe's API](https://docs.typesafe.ai/api) accepts a state and typed questions; two [Score](https://docs.typesafe.ai/primitives/score) questions share one HTTP request. The plugin sends only actual target text and a source-language hint. It does not send Gemini suggestions, correction counts, filenames, or neighboring text outside the target. It never uses Gemini findings to force a Jev level.

Unnaturalness asks whether another proofreading pass is worthwhile, including local suspicious wording, without treating correct regional/script variants, technical terms, notes, or mixed-language text as errors. AI style asks about formulaic patterns, repetition, empty abstraction and unwarranted emphasis, rather than AI authorship. Its scope is informed by [textlint's AI-writing preset](https://github.com/textlint-ja/textlint-rule-preset-ai-writing); the plugin does not run textlint or treat every heading/quote as evidence.

A valid answer has all five probabilities and separate confidence. Display uses the maximum-probability level plus one, lower level on a tie; the weighted mean is not rounded into a stage. Malformed responses and transport/auth failures never become level 1. The endpoint is fixed, keys travel through the existing 0600 header-file transport, callback exceptions and provider error bodies are not displayed. Cancellation removes the file and suppresses already queued callbacks.

## Validation boundary (2026-10-01)

- Local `make check`: lint, format, and all existing/new mocked tests pass. Tests cover Unicode/reversed/exclusive/linewise Visual targets, invalidated ranges, optional keys, manual-only requests, hide-during-request, late-response cancellation, per-tab visibility, special buffers, details, mapping shadows, CJK display width, and the evaluate → Gemini → accept → reevaluate round trip.
- Neovim actual UI: Japanese panel/details in dark mode; Traditional Chinese uncertainty and Japanese stale state in light mode; Simplified Chinese authentication error. Screenshot review by Claude Code. Mocked results are clearly identified.
- Real Jev multilingual quality comparison **not run**: this execution environment has no `TYPESAFE_API_KEY`. The live runner exits locally before any request. No Kotobae credential was copied. Native Chinese wording review and the user's normal Neovim acceptance remain unverified.
- CI minimum Neovim 0.11 / stable results are recorded on the PR, separately from local results.

Thirty synthetic examples are in `tests/fixtures/jev-cases.json`: six development cases plus two held-out normal/error pairs per language. They include correct prose, typos, grammar, technical terms, notes, and formulaic prose. These are comparison prompts, not guaranteed expected model classifications or native-speaker-validated Chinese benchmarks.

Once the key is configured locally, run explicitly (30 paid requests, two questions each):

```sh
nvim -l scripts/jev-live.lua /tmp/jev-results.json
```

The output path must be new. The report stores case IDs, requested model alias, rubric version, levels, distributions, confidence, latency and safe error codes; it does not store the key or provider error text. Inspect normal/error pairs and record false positives/negatives separately for each language. Do not lower a threshold merely to fit reported examples, and do not claim the Japanese baseline is calibrated for Chinese. Rerunning is another explicit paid comparison. A wrong judgment can have high confidence.
