# TokenScope Architecture (overview)

> **The complete, authoritative reference is [`docs/REFERENCE.md`](REFERENCE.md).**
> It documents every subsystem, rule, and constant so an AI or engineer can
> understand the app without reading the source. This file is a one-screen
> orientation that points there — it deliberately restates no mechanisms or
> constants, so there is nothing here to drift.

TokenScope is a macOS menu-bar app (SwiftPM executable, SwiftUI `MenuBarExtra`, no
third-party dependencies) that meters **local LLM token usage** — Claude Code, Codex,
Ollama, and LM Studio — and displays **plan-limit utilization** for claude.ai and
ChatGPT/Codex plus Claude/OpenAI service status.

Everything funnels into one `UsageStore`, which owns a 31-day live event window, a
permanent daily history, and all reconciliation (double-count shadowing, dedup,
backfill). The UI (`MenuView`) and the menu-bar label are pure functions of the store
plus the limit/status managers.

## Where to read about each part (all in `REFERENCE.md`)

- **What it measures / doesn't** → §2 Scope
- **Data flow diagram** → §3
- **Data model** (`UsageEvent`, `DayAgg`, …) → §5
- **The eight inputs** (transcripts, Codex, proxy+scanner, LM Studio, `/api/ps`,
  claude.ai, Codex quota, status) → §6
- **Reconciliation engine** (windows, history, shadowing, dedup) → §7
- **Colors & brand marks** → §8
- **The UI** → §9; **menu-bar label & gauge** → §10
- **Notifications** → §11; **every preference key** → §12; **runtime files** → §13
- **Build / verify / release** → §14; **efficiency** → §15
- **Do-not-regress invariants** → §16; **known limitations** → §17
- **File-by-file module index** → §18

For working-agent build commands and the terse do-not-regress checklist, see
[`../CLAUDE.md`](../CLAUDE.md) (auto-loaded in Claude Code sessions).
