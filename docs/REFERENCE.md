# TokenScope — Complete Reference

> **This is the single source of truth for how TokenScope works.** It is written so
> that an AI (or a new engineer) can understand every subsystem, rule, and constant
> *without reading the Swift source*. Where a fact is load-bearing, the file and the
> exact value are named so you can jump to it.
>
> **Reflects:** v0.1.2 (`CFBundleVersion` 3) plus the local-runtime parity work in
> this working tree, 2026-07-13.
> When you change behavior, update this file in the same commit.
>
> **Companion docs:** `CLAUDE.md` is the always-loaded working checklist for coding
> agents (build commands + terse do-not-regress reminders). `docs/ARCHITECTURE.md`
> is a one-screen overview that points here. `README.md` is user-facing. This file
> supersedes and expands all three on any point of detail.

---

## Table of contents

1. [What TokenScope is](#1-what-tokenscope-is)
2. [Scope: what it measures and what it does not](#2-scope-what-it-measures-and-what-it-does-not)
3. [Data flow at a glance](#3-data-flow-at-a-glance)
4. [Core concepts / glossary](#4-core-concepts--glossary)
5. [The data model](#5-the-data-model)
6. [Data sources (the eight inputs)](#6-data-sources-the-eight-inputs)
7. [UsageStore: the reconciliation engine](#7-usagestore-the-reconciliation-engine)
8. [Provider identity, colors, and brand marks](#8-provider-identity-colors-and-brand-marks)
9. [The UI](#9-the-ui)
10. [The menu-bar label and gauge](#10-the-menu-bar-label-and-gauge)
11. [Notifications](#11-notifications)
12. [Preferences reference (every key)](#12-preferences-reference-every-key)
13. [Runtime files and directories](#13-runtime-files-and-directories)
14. [Build, verify, install, release](#14-build-verify-install-release)
15. [Footprint and efficiency invariants](#15-footprint-and-efficiency-invariants)
16. [Do-not-regress invariants](#16-do-not-regress-invariants)
17. [Known limitations](#17-known-limitations)
18. [Module index](#18-module-index)
19. [Licensing and attribution](#19-licensing-and-attribution)

---

## 1. What TokenScope is

TokenScope is a **macOS menu-bar app** (SwiftPM executable, SwiftUI `MenuBarExtra`,
no Dock icon via `LSUIElement`) that meters **local LLM token usage** — live, per
call, per session, per day — and displays **plan-limit utilization** for the hosted
services. It has **no third-party Swift dependencies**; everything (OKLab color math,
proxy, JSON scanning, charts) is hand-rolled.

- **Language/toolchain:** Swift 5.9, `platforms: [.macOS(.v14)]` (macOS 14 Sonoma+),
  Apple Silicon builds shipped.
- **Bundle id:** `com.tokenscope`. (Historically `com.baysora.tokenscope`; that id is
  cursed — see [§16](#16-do-not-regress-invariants).)
- **Entry point:** `@main enum Main` in `TokenScopeApp.swift` dispatches on CLI args:
  `--snapshot <png>`, `--gauges <dir>`, `--menubar <png>`, else the normal app.
- **Service wiring:** `AppServices.shared` (singleton) constructs and starts every
  watcher/poller/manager once, and holds the shared `UsageStore`.

The product answers two different questions that share **neither units nor window nor
source**, and the UI is deliberately split along that seam:

1. **"How many tokens have I actually used locally?"** — exact counts from Claude
   Code, Codex, Ollama, and LM Studio on *this Mac*. (The tabs.)
2. **"How close am I to being throttled?"** — account-wide plan utilization % for
   claude.ai and ChatGPT/Codex. (The always-visible header.)

---

## 2. Scope: what it measures and what it does not

| Surface | Measured? | How | Ground-truth token source |
|---|---|---|---|
| Claude Code (native Anthropic) | ✅ exact | transcript tail | `message.usage.*` in the JSONL |
| Claude Code → Ollama (`ANTHROPIC_BASE_URL`) | ✅ exact | transcript tail (classified as Ollama) | same JSONL usage |
| Codex app / CLI (local) | ✅ exact | Codex session-log tail | `token_count.last_token_usage` |
| Ollama via proxy (`ollama run`, scripts, any client → :11435) | ✅ exact + **live** | TCP relay + response scan | `eval_count` / `prompt_eval_count` |
| Ollama Desktop app's own chats | ✅ activity; tokens unavailable | metadata-only SQLite watcher | model/chat/timestamps; DB has no runtime token counts |
| LM Studio completed LLM generations visible in shared model telemetry | ✅ exact | output-only `lms log stream` tap | `stats.{promptTokensCount, predictedTokensCount}` |
| claude.ai web / Claude desktop | limits-only | claude.ai usage endpoint | utilization %, not tokens |
| ChatGPT web / desktop | limits-only (experimental) | ChatGPT usage endpoint | utilization %, not tokens |
| Gemini (any surface) | ❌ (roadmap) | — | — |

**Privacy rule (hard invariant):** TokenScope persists **only operational metadata**:
counts, model/source identity, lifecycle, sanitized error category, and performance
metrics. It never stores or transmits prompt text, reply text, tool payloads, raw
provider errors, or conversation content. LM Studio is launched with `--filter output`
so formatted prompts do not enter TokenScope's process.

**Two units, never mixed:** local sources produce **token counts**; the limit panels
produce **utilization percentages**. They are never added together or shown in the
same figure.

---

## 3. Data flow at a glance

```
  Claude Code ── api.anthropic.com            ┌────────────────────────┐
       │                                       │  ~/.claude/projects/   │
       └── writes transcripts ──────────────► │  **/*.jsonl            │
                                               └──────────┬─────────────┘
  Codex app/CLI ─► ~/.codex/sessions/**/*.jsonl ──────────┤
  Claude Code ──┐                                          │ tail (1s poll)
  ollama run ───┤                                          ▼
  any client ───┴─► 127.0.0.1:11435 ─────────►  ┌──────────────────────┐
                    OllamaProxy (TCP relay)      │      UsageStore      │ ─► MenuView
                      │            │             │  events (31 days)    │   (MenuBarExtra)
                      ▼            ▼             │  history (forever)   │
                 127.0.0.1:11434  ResponseScanner ─► live + per-call    │
                    (Ollama)                     └──────────┬───────────┘
  LM Studio (GUI + CLI + :1234) ─► `lms log stream` ────────┘

  claude.ai/usage ─► LimitsManager ─┐
  chatgpt.com/usage ─► ChatGPTLimits ┼─► header cards + menu-bar gauge (utilization %)
  Codex local quota ─► OpenAILimits ─┘
  status.claude.com / status.openai.com ─► StatusManager ×2 ─► footer
```

Everything funnels into **one `UsageStore`**, which owns the 31-day live event window,
the permanent daily history, and all reconciliation. The UI is a pure function of the
store plus the limit/status managers.

---

## 4. Core concepts / glossary

- **UsageEvent** — one observed model call (input/output/cache/reasoning tokens +
  provider + source + optional session/project). The atom of local metering.
- **Provider (`UsageOrigin`)** — *what produced the tokens*: `claudeCode`, `codex`,
  `ollama`, `lmStudio`. Not inferred from a model name alone (see classification rule).
- **Source (`EventSource`)** — *how we observed it*: `transcript`, `codexTranscript`,
  `proxy`, `lmStudioLog`. Two sources can observe the same call (→ shadowing).
- **Live call (`LiveCall`)** — an in-flight call the proxy is currently streaming;
  drives the `↓` counter. Only the proxy produces these.
- **Events window** — the last **31 whole days** of raw `UsageEvent`s, kept in memory.
- **History (`DayAgg`)** — frozen per-day totals for days that have aged out of the
  window, persisted forever so the 6-month heatmap survives transcript deletion.
- **Whole-day rule** — a calendar day is *entirely* live or *entirely* frozen, never
  split. Everything downstream relies on this.
- **Shadowing** — when the same call is seen by two sources (Claude Code routed
  through the proxy), one copy is marked `shadowed` and excluded from all totals but
  kept in the call log.
- **Backfill** — a one-time-per-gap scan of old transcripts to populate history for
  days before the app first ran.
- **Utilization** — a plan-limit percentage (0–100) for a rolling window (5h/7d),
  distinct from token counts.

---

## 5. The data model

Defined in `Models.swift`. All token integers; money/percent never here.

### `UsageOrigin` (the provider enum)
`enum UsageOrigin: String, CaseIterable { claudeCode, codex, ollama, lmStudio }`
- `displayName` → `"Claude"`, `"Codex"`, `"Ollama"`, `"LM Studio"`.
- **Classification rule** (`classifyClaudeCode(model:)`): a Claude Code transcript
  line is `.claudeCode` iff `model.lowercased().hasPrefix("claude")`, otherwise
  `.ollama`. This is how "Claude Code pointed at Ollama" is attributed to Ollama even
  though the durable record is a Claude Code transcript. Codex and LM Studio never go
  through this path — they come only from their own watchers.

### `EventSource`
`enum EventSource: String { transcript, codexTranscript, proxy, lmStudioLog }`

### `UsageEvent` (the atom)
`Identifiable`. Fields: `id: UUID`, `timestamp: Date`, `provider: UsageOrigin`,
`source: EventSource`, `model: String`, `sessionId: String?`, `projectName: String?`,
`inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheCreationTokens`, and
`reasoningTokens` (a **subset of output**, never re-added to the headline). Operational
fields include token accuracy, operation, status, execution location, endpoint/request
id, HTTP/finish/error category, duration breakdown, TTFT, and tokens/sec. Errors are
sanitized categories only. The type is versioned-journal `Codable` and `Equatable`.

### `LiveCall`
`id, provider, model, inputTokens, outputTokens, outputAccuracy, operation, startedAt,
lastUpdate`. The proxy upserts these;
`inputTokens` here = `input + cacheRead`, `outputTokens` = the streaming display count.

### `Totals`
Accumulator: `input, output, cacheRead, cacheCreate, reasoning, calls`; `add(_ e:)`.

### `SessionAgg`
`id, title, project, provider, totals, lastActivity, models: Set<String>`.
`isActive` ⟺ `Date().timeIntervalSince(lastActivity) < 15*60` (**15-minute** window —
this is the green dot in the Sessions list).

### `StatsPeriod`
`enum { today, week, month }`. `label` → `"Today"`, `"7 Days"`, `"30 Days"`;
`days` → `1`, `7`, `30`.

### `DayStat` (in-memory chart/heatmap bucket)
`day: Date` + `claude, codex, ollama, lmStudio` ints; `total` = their sum.

### `DayAgg` (persisted frozen day) — `Codable, Equatable`
Provider-keyed `ProviderDayAgg` values (input/output/cache/reasoning/calls). The
decoder migrates legacy fixed Claude/Codex/Ollama/LM Studio fields; the encoder writes
the extensible provider map.
- Computed: `claude/codex/ollama/lmStudio` = In+Out; `*WithCache` = +Cache; `total` = sum.
- **Back-compat is deliberate:** a custom `init(from:)` decodes every key with
  `decodeIfPresent(...) ?? 0`. Old history files predate Codex, LM Studio, and the
  cache fields; absent keys decode to 0 so a user's accumulated heatmap survives
  upgrades. Days frozen before cache tracking have `*Cache == 0`, so `*WithCache`
  equals the fresh-only figure for them (graceful degradation).
- `add(_ e: UsageEvent)` routes by `provider` and folds `cacheRead+cacheCreation` into
  `*Cache`. `merge(_ o:)` sums two aggregates (used by backfill).

---

## 6. Data sources (the eight inputs)

Each subsection: **what it reads → how it parses → ground-truth count → timing →
how it feeds the store → privacy → limitations.** Source file named in the heading.

### 6.1 Claude Code transcripts — `TranscriptWatcher.swift`

- **Reads:** `~/.claude/projects/<project>/<session>.jsonl`. Every API response Claude
  Code receives is appended here with exact usage. Covers **native Anthropic and
  Claude Code → Ollama** with no configuration.
- **Poll discipline:** a `DispatchSourceTimer`, `deadline: .now()+3.0, repeating: 1.0`
  (starts 3s after launch, then every **1 s**). Tracks a per-file **byte offset**;
  only advances past **complete lines** (a trailing partial line is left for next
  tick). Stats only recently-modified ("hot") files each tick; a full directory walk
  runs every **10th** tick (idle-CPU discipline — see [§15](#15-footprint-and-efficiency-invariants)).
- **Byte pre-filters (before any JSON decode):** a line is decoded as a usage event
  only if it contains the literal bytes `"assistant"` (`assistantMarker`); title
  extraction keys off `"ai-title"`, `"summary"`, and a user marker. This keeps the
  30-day replay fast.
- **Usage parse:** decodes `type == "assistant"`, reads `message.model` and
  `message.usage.{input_tokens, output_tokens, cache_read_input_tokens,
  cache_creation_input_tokens}`. Provider = `classifyClaudeCode(model:)`. **Skips
  `model == "<synthetic>"`** lines entirely.
- **Ground truth:** the `usage` object Anthropic returns — exact, but only present when
  a message *completes* (no mid-call number for direct Anthropic traffic).
- **Session titles** (best → fallback):
  1. `{"type":"ai-title","aiTitle":…}` — the exact name shown in `/resume`;
     **overwrites** (authoritative).
  2. older `{"type":"summary","summary":…}` lines.
  3. first real user message — **fallback only fills a gap**, 60-char-ish cap, skips
     lines starting with `<` (e.g. `<command-…>`) or `Caveat:`.
- **Feeds store:** `addTranscriptEvent(_, dedupKey:)`. **Dedup key = `message.id:requestId`**;
  `EventReconciler` retains the strongest observation so final rewrites upgrade partial
  usage and stale replays cannot downgrade it.
- **Launch replay:** replays transcripts newer than the events cutoff (~seconds for a
  month) so today is populated immediately; then a one-time backfill covers the gap
  `(historyCompleteThrough, cutoff)` from whatever old transcripts still exist (≤366d);
  then calls `replayFinished(coverThrough:)`.
- **Privacy:** reads only usage numbers, model, session/project ids, and titles.

### 6.2 Codex session telemetry — `CodexTranscriptWatcher.swift`

- **Reads:** `~/.codex/sessions/YYYY/MM/DD/*.jsonl`. Same complete-line + hot-file
  polling as above (`deadline: .now()+3, repeating: 1` → **1 s**).
- **Byte pre-filters:** `"token_count"` (`tokenCountMarker`), `"session_meta"`
  (`sessionMetaMarker`), and a `turn_context` marker. Only lines matching are decoded.
- **Parse:**
  - `session_meta` → session/project attribution.
  - `turn_context` → names the model for the turn's subsequent `token_count` records
    (turn_context precedes its token_counts in file order; the watcher tracks the
    latest model per file).
  - `event_msg` with `payload.type == "token_count"` → the usage event, taken from
    `payload.info.last_token_usage` (input, cached input, output, reasoning output).
    Cached and reasoning counts are retained as detail, **not** double-added to the
    headline. `payload.rate_limits.{primary,secondary}` → the observed Codex quota
    windows, forwarded to `OpenAILimitsManager.observe(...)`.
- **Ground truth:** `last_token_usage` — exact local counts.
- **Feeds store:** as `provider = .codex, source = .codexTranscript`; deduped by
  source-file byte offset. Has its **own persisted watermark**
  (`codexHistoryCompleteThrough`) because the Codex log tree is independent of the
  Claude transcript tree; backfills ≤366 days of daily history exactly once, matching
  Claude's launch behavior. Both sources still merge into the *same* day aggregate.
- **Source independence:** local session-token scanning always runs. Selecting the
  cookie limits source disables only local quota-window observation; cookie telemetry
  does not contain per-turn token usage.
- **Privacy:** no prompt/reply/tool payload is ever read.

### 6.3 Local Ollama proxy — `OllamaProxy.swift` → `Relay` → `ResponseScanner.swift`

- **What it is:** a **transparent TCP relay**, default `127.0.0.1:11435 → 127.0.0.1:11434`
  (ports overridable via `ProxyPort` / `OllamaPort`). It forwards bytes **verbatim in
  both directions**. The **only** request mutation is forcing
  `Accept-Encoding: identity` so responses stay uncompressed and scannable (gzip would
  blind the scanner).
- **Scanning:** `HTTPRequestScanner` frames Content-Length/chunked requests and keeps
  only method/path/model/stream/request id/location. `HTTPResponseFramer` removes
  Content-Length/chunked/close-delimited transport framing and supports keep-alive;
  `ResponseScanner` then parses NDJSON, SSE, or single JSON bodies. Split request
  headers are handled by `HTTPIdentityEncodingRewriter` before forwarding.
- **Three wire formats understood:**

  | Format | Detected by | Input tokens | Output tokens | End of call |
  |---|---|---|---|---|
  | Ollama native | `"done"` key | `prompt_eval_count` | `eval_count` | `"done":true` |
  | Anthropic | `"type"` events | `usage.input_tokens` (`message_start`) | `usage.output_tokens` (`message_delta`) | `message_stop` / `"type":"message"` |
  | OpenAI | `"object"`/Responses lifecycle | `prompt_tokens`/`input_tokens` | `completion_tokens`/`output_tokens` | object completion / `[DONE]` |
  | Embedding | endpoint attribution | input usage when returned | n/a | framed response end |

- **Live counter:** while streaming, chunk counts approximate output (`approxOutput`)
  until a real count arrives (`displayOutput = output > 0 ? output : approxOutput`) —
  this is the only source that sees tokens *mid-stream*, and the only one that sees
  **non-Claude-Code** Ollama clients (`OLLAMA_HOST=127.0.0.1:11435`). Every usage field
  is merged with `max(existing, new)` so a late/duplicate/stale chunk can never regress
  a count; live updates are throttled to ~5/s (0.2 s), forced only on `message_start`.
- **Finalize is idempotent** — `message_stop`, `chat.completion`, `"done":true`,
  `[DONE]`, the regex fallback, and connection-close all call it; it no-ops once the
  call state is cleared. A 4 MB carry-buffer cap guards a runaway un-newlined stream.
- **Feeds store:** `upsertLiveCall(...)` during streaming; `finishLiveCall(...)` at end.
  Finalize retains token-bearing calls and failures (including input-only embeddings),
  while dropping empty successful pings. Finished
  proxy events are `provider = .ollama, source = .proxy, sessionId = "ollama-direct"`,
  and are **persisted** to the shared `usage-events-v2.jsonl` journal.
- **Health:** `/api/version` distinguishes daemon health from proxy-listener health;
  failures, cancellation, exact/estimated accuracy, cloud-model location, Ollama
  nanosecond durations, derived tokens/sec, and observed TTFT are retained.
- **Privacy:** relays bytes but stores only extracted counts + model.

### 6.3.1 Ollama Desktop metadata — `OllamaDesktopWatcher.swift`

- **Why it exists:** Ollama Desktop connects directly to its daemon on `:11434`,
  bypassing TokenScope's `:11435` proxy.
- **Source:** read-only access to `~/Library/Application Support/Ollama/db.sqlite`.
  The query selects only message row id, chat id, model, start/update timestamps, and
  streaming state. It never selects content, thinking, tool, or attachment columns.
- **Wakeups/history:** startup replays only the live 31-day metadata window using
  stable chat/row dedup keys. After that, vnode notifications on the SQLite DB/WAL
  trigger debounced reads; there is no idle polling loop.
- **Accuracy boundary:** the desktop schema does not store `prompt_eval_count` or
  `eval_count`. Completed calls therefore use `tokenAccuracy = unknown` with zero
  invented tokens and render as `tokens unavailable`; model and duration remain exact
  to the DB metadata.
- **Deduplication:** if a matching model/start/end/duration proxy observation exists,
  the metadata-only desktop record is shadowed and the proxy's stronger evidence wins.

### 6.4 LM Studio — `LMStudioLogWatcher.swift`

- **What it does:** spawns
  `lms log stream --source model --filter output --stats --json` and reads its NDJSON
  output. This captures completed LLM-generation telemetry exposed by LM Studio's
  shared model log without requiring the HTTP API server. The coverage is deliberately
  not described as "every inference" (embeddings and events lacking stats are absent).
- **CLI discovery** (`cliCandidates`, first that exists):
  `~/.lmstudio/bin/lms`, `/usr/local/bin/lms`, `/opt/homebrew/bin/lms`. If none exist,
  the provider is simply **off** (no subprocess, no respawn churn).
- **Parse:** each line is JSON; keeps only records where `data.type ==
  "llm.prediction.output"`, then reads `data.stats.promptTokensCount` (→ input) and
  `data.stats.predictedTokensCount` (→ output), model = `data.modelIdentifier` ??
  `data.modelPath` ?? `"LM Studio"`, and `obj.timestamp` as **epoch milliseconds**
  (epoch seconds/milliseconds or ISO8601). Records with both counts zero are dropped.
  Reasoning, stop reason, tokens/sec, TTFT, load/duration fields are retained when present.
- **Ground truth:** LM Studio's own `stats` counts — exact, matches the tokens/sec the
  GUI shows.
- **Feeds store:** `addLocalEvent(...)` with `provider = .lmStudio,
  source = .lmStudioLog, sessionId = "lmstudio:<model>"`. The stream has no session id,
  so events group per model. **Dedup key** =
  `"lmstudio:<ts>:<prompt>:<predicted>:<model>"`.
- **Resilience:** `lms log stream` exits when LM Studio isn't running or on a transient
  error; the watcher relaunches **30 s** later (`asyncAfter(deadline: .now()+30)`).
- **Requires:** the CLI's `--source model --stats` flags (LM Studio **v0.3.26+**).
- **Limitation:** **live-only** — no history before the app launched (there is no
  backfill from `~/.lmstudio/conversations/*.json`; that is a documented fast-follow).
- **Privacy:** requests output-only events and persists only stats/model/lifecycle;
  content fields and raw stderr are discarded.

### 6.5 Runtime status/model pollers — `OllamaStatusPoller.swift`, `LMStudioStatusPoller.swift`

- **Ollama reads:** documented `/api/version` and `/api/ps` every **10 s**
  (`deadline: .now()+2, repeating: 10.0`, 3 s request timeout). A failed poll blanks
  `loadedModels` rather than keeping the last value.
- **LM Studio reads:** `lms --version`, `lms server status --json --quiet`, and
  `lms ps --json` every **30 s**. Both publish `RuntimeHealth` plus provider-owned
  `LoadedModel` records; the UI shows version/server/collector coverage and available
  size, VRAM, context, generation, parallel, and queue metadata. Not token sources.

### 6.6 claude.ai plan limits — `LimitsManager.swift`

- **Endpoints:**
  `GET https://claude.ai/api/organizations/<orgId>/usage` (primary);
  `GET https://claude.ai/api/bootstrap` (org-id fallback).
- **Auth:** the user's pasted **claude.ai Cookie header**, sent verbatim as `Cookie`,
  with `Accept: */*`, `Origin`/`Referer: https://claude.ai`, a Chrome desktop
  `User-Agent`, `timeoutInterval = 15`. **No bearer exchange** — the cookie authorizes
  directly.
- **Org-id derivation:** first from the `lastActiveOrg=` crumb in the cookie; else
  `/api/bootstrap` → first membership's `organization.uuid`.
- **Parse:** top-level dict; for each of `five_hour`, `seven_day`, `seven_day_sonnet`
  reads `utilization` (Double|Int→Double, default 0) and `resets_at` (ISO8601, with or
  without fractional seconds). Produces `LimitWindow`s labeled `"Session · 5h"`,
  `"Weekly · 7d"`, `"Weekly Sonnet · 7d"`.
- **Timing:** `start()` polls every **60 s** and refreshes immediately.
- **UI-facing:** `@Published windows, connected, lastUpdated, errorMessage,
  notificationsEnabled`; computed `sessionPercent` (`five_hour`), `weeklyPercent`
  (`seven_day`). Also the app-wide **color ramp** lives here — see
  [§10](#10-the-menu-bar-label-and-gauge).
- **Degradation (exact `errorMessage` strings):** no cookie → silent no-op;
  no org id → `"Couldn't find org ID in cookie"`; 401/403 →
  `"Cookie rejected (expired?) — re-copy it"`; other non-200 → `"HTTP <code>"`;
  bad JSON → `"Couldn't parse usage response"`; network → `"Network error: …"`.
- **Scope:** covers claude.ai web + desktop + Claude Code; **excludes Ollama**.
  Unofficial endpoint. Adapted from ClaudeUsageBar.

### 6.7 Codex quota (two interchangeable sources)

Codex has **one active quota source at a time**, chosen by the `CodexSource`
preference (`"local"` | `"cookie"` | `""`=auto). Both feed the **same** "CODEX LIMITS"
header card and the same menu-bar gauges, and both emit `LimitWindow`s with ids
`"codex-primary"` / `"codex-secondary"`.

**(a) Local — `OpenAILimitsManager.swift`.** *No network.* Codex writes rolling-window
quota state (`rate_limits.primary/secondary`) alongside its token counts;
`CodexTranscriptWatcher` forwards it via `observe(primary:secondary:at:)`. Windows are
labeled `"Session · <dur>"` / `"Weekly · <dur>"` where duration is derived from the
observed window minutes (`Nd` / `Nh` / `Nm` / `"limit"`). Gated on
`monitoringEnabled` (`CodexMonitoringEnabled`, default true); ignores out-of-order
(stale) replays via a `lastUpdated` guard.

**(b) Cookie — `ChatGPTLimitsManager.swift`.** *Two-step web auth, experimental.*
- `GET https://chatgpt.com/api/auth/session` (cookie-authenticated) → mints a
  short-lived `accessToken`.
- `GET https://chatgpt.com/backend-api/wham/usage` with `Authorization: Bearer <token>`.
- **Cloudflare gotcha:** the `User-Agent` must match the browser the cookie was copied
  from (`Version/26.5 Safari/605.1.15`) because `cf_clearance` is UA-bound.
- **Parse is defensive** — the private response has changed across ChatGPT releases, so
  it recursively walks all dicts collecting any `used_percent`/`utilization` (0–100),
  window seconds/minutes (`window_seconds`/`window_minutes`/…), and reset
  (`resets_at`/`reset_at`/`reset_time`, epoch or ISO8601). Dedups, sorts by window
  length, takes the first two → primary/secondary.
- **Timing:** polls every **60 s** while active; `stop()` when cookie is not the
  selected source.
- **Degradation:** distinct strings for signed-out (`"Signed out on chatgpt.com — …"`),
  rejected cookie, HTTP errors, and "No recognized limits returned — ChatGPT's web
  response may have changed."

**Shared notification identity:** both (a) and (b) use the **same** ThresholdTracker
keys (`chatgpt_limit_notified_primary/secondary`) and the same notification ids
(`codex-limit-primary-<t>` / `codex-limit-secondary-<t>`), so switching sources does
**not** re-fire a band already alerted.

**Startup source selection** (`AppServices.init`): if `CodexSource` is unset, default
to `"cookie"` when a ChatGPT cookie is already connected, else `"local"`. Only the
selected *quota* source runs — `openAILimits.monitoringEnabled = !cookie`, and
`chatGPTLimits.start()` is called only when cookie is the source. The Codex session
watcher always runs for local per-turn token tracking.

### 6.8 Service status — `StatusManager.swift` (×2 instances)

- **Endpoints (public, no auth):**
  `GET https://status.claude.com/api/v2/summary.json` and
  `.../status.openai.com/...`, every **300 s** (5 min), `timeoutInterval = 15`,
  `cachePolicy = .reloadIgnoringLocalCacheData`.
- **Parse:** `status.{indicator, description}`; `components[]` (drop `operational`,
  drop `group == true`); `incidents[]` (drop `resolved`/`postmortem`, `update` = first
  `incident_updates[].body`). **Government/FedRAMP filter:** components/incidents whose
  name contains `"government"` (Claude) or `"fedramp"`/`"fed ramp"` (OpenAI) are
  excluded, and if *only* those were elevated, the indicator is forced back to `"none"`
  / `"All systems operational"`.
- **UI-facing:** `indicator` (`none|minor|major|critical`), `summary`, `degraded`,
  `incidents`, `color` (green/yellow/orange/red/gray), `allOperational`.
- **Notifications:** **state-change**, not threshold — fires only when the indicator
  changes after the first fetch, gated on `notificationsEnabled`. "Back online" vs a
  degraded-state message.
- **No error surfacing:** network/parse failures return silently (stale state stays);
  HTTP status codes are not checked.

---

## 7. UsageStore: the reconciliation engine

`UsageStore.swift` — an `ObservableObject` on the main queue that owns all local
metering state and every reconciliation rule. `AppServices` holds one instance.

### 7.1 State it publishes
`events: [UsageEvent]` (oldest→newest), `liveCalls`, `proxyStatus`/`proxyHealthy`,
provider-owned `loadedModels`, `runtimeHealth`, `history: [String: DayAgg]` (keyed `yyyy-MM-dd`), `sessionNames`,
`now`. Plus non-published watermarks `historyCompleteThrough`,
`codexHistoryCompleteThrough`, and the resolved `proxyPort`/`upstreamPort`.

### 7.2 The live window — 31 whole days
- `retentionDays = 31` ("a hair more than the longest display window", 30d).
- `eventsCutoff` = `startOfDay(now) − 31 days` — **aligned to a day boundary** so a
  day is entirely live or entirely frozen. `trim()`, `fold()`, backfill, and time-based
  reconciliation all depend on this; **never** reintroduce a rolling timestamp cutoff.
- Hard cap: if `events.count > 60_000`, the oldest overflow is folded out too.

### 7.3 Permanent history + backfill
- Days leaving the window are **folded** into `history` (`fold()`), summing non-shadowed
  events into `DayAgg`s, then `saveHistory()`.
- `history` persists to `daily-history.json` as
  `{completeThrough, codexCompleteThrough, days:{…}}`. This outlives Claude Code's own
  transcript cleanup — it is what lets the 6-month heatmap accumulate.
- **Backfill:** each watcher, once per gap, scans old transcripts/logs for the range
  `(completeThrough, cutoff)` (≤366 days) and calls `mergeHistorical` /
  `mergeCodexHistorical`. Deleting `daily-history.json` triggers a fresh one-time
  backfill on next launch.

### 7.4 Double-count prevention (shadowing)
A Claude Code call routed through the proxy is observed **twice** (proxy + transcript).
Exactly one copy is counted:
- **Runtime, transcript arrives second:** `addTranscriptEvent` scans the last ~60
  events for a `proxy`, non-shadowed Ollama event within **±90 s** and **±2 output
  tokens**; marks it `shadowed`.
- **Runtime, proxy finishes second:** `finishLiveCall` does the reverse scan against
  recent transcript events (±90 s, ±2 tokens).
- **Startup:** `replayFinished` sorts events, indexes **exact** transcript Ollama events by
  output count, and shadows any persisted proxy event matching within **±120 s** and
  **±2 tokens** (the wider window covers bulk replay ordering).
- Shadowed events are excluded from **every** aggregate and from the heatmap, but kept
  in the "Latest calls" log.

### 7.5 Dedup
- Claude Code transcript events: **`message.id:requestId`**, strongest observation wins.
- Codex events: by source-file **byte offset**.
- LM Studio: prediction id when present, else
  `"lmstudio:<ts>:<prompt>:<predicted>:<model>"`.
- `eventIDByDedupKey` plus `EventReconciler` upgrades an existing record in place.

### 7.6 Aggregates (computed on demand, no caches to invalidate)
- `events(in:)` — filters to the period and **excludes shadowed**.
- `totals(for:in:)`, `modelTotals(for:in:)`, `sessions(in:)`.
- `chartTokens(_, includeCache:)` = `input + output (+ cache if enabled)`. Cache is
  **included by default** because cache reads/writes are real context processed per
  call and usually dwarf fresh input; the Settings toggle drops them for a billing-ish
  view.
- `dailyTotals(in:includeCache:)` — one `DayStat` per day in the period, future days
  present but empty.
- `hourlyTotals(includeCache:)` — today bucketed into 24 hour slots.
- `heatmapDays(weeks:includeCache:)` — `weeks*7` consecutive days: live-window events
  **plus** frozen `history` for each day (using `*WithCache` when cache is on).
- `sessionTitle(for:sample:)` — proxy → `"Ollama (direct)"`; desktop metadata →
  `"Ollama Desktop"`; else the transcript
  title; LM Studio → `"LM Studio · <model>"`; Codex → `"Codex · <project>"` or
  `"Codex session <id8>"`; else `"Session <id8>"`.
- `menuTitle` — a live `↓<compact output>` if a call updated within **8 s**, else
  today's `input+output` compacted.

### 7.7 Persistence & the clock
- `usage-events-v2.jsonl` — versioned shared journal for non-replayable Ollama proxy,
  Ollama Desktop metadata, and LM Studio observations, compacted and strongest-per-key on load. If absent,
  legacy `proxy-events.jsonl` migrates once with unknown accuracy. Written on a serial
  utility `ioQueue`.
- `daily-history.json` — rewritten on each fold/backfill/replay-finish.
- The 1 Hz clock timer runs **only while `liveCalls` is non-empty**
  (`startTickingIfNeeded`) and stops itself when they drain — no idle wakeups.

---

## 8. Provider identity, colors, and brand marks

### 8.1 ProviderPalette — `ProviderPalette.swift`
The single source of truth for every provider color (bars, heatmap, gauges, brand
marks all read it). A plain `ObservableObject` singleton (`ProviderPalette.shared`) —
**not** `@AppStorage` — because colors must be read synchronously from non-View
contexts (`BrandMark.color`, and the headless `--snapshot`/`--menubar` binaries where
`NSApp` is nil), which `@AppStorage` can't serve.

- **Default hex (`fallbackHex`):**
  Claude `#F5942E` (orange), Codex `#34C759` (green), Ollama `#5A9EFA` (blue),
  LM Studio `#B052DE` (purple). Chosen byte-identical to the first preset swatches so a
  provider's default highlights its own swatch out of the box.
- **Persistence keys (`key(_:)`):** `ProviderColorClaude`, `ProviderColorCodex`,
  `ProviderColorOllama`, `ProviderColorLMStudio` — `#RRGGBB` strings in UserDefaults. A
  user pick overrides the default; `resetAll()` removes all four keys; `isDefault` is
  true only when all four are absent. **We never stomp a user's stored pick** — but a
  stale persisted value *does* override the code default (this bit us once: a red
  `ProviderColorCodex` survived a default change until `defaults delete`d).
- **`blend(claude:codex:ollama:lmStudio:)`** — perceptual **OKLab** mean weighted by
  each provider's share of a day's tokens (returns nil if all weights ≤0). It restores
  chroma after averaging near-complementary hues (scale factor capped at **1.6×**) so a
  mixed Claude+Ollama day doesn't collapse to grey. Pure-Swift OKLab transforms
  (Björn Ottosson), no dependency.
- **Preset swatches** offered in Settings (same 7 for every provider):
  `#F5942E, #B052DE, #5A9EFA, #34C759, #FF3B30, #FF2D80, #30C7C0` (orange, purple,
  blue, green, red, pink, teal). No `NSColorPanel` — it would dismiss the popup.

### 8.2 Brand marks — `BrandMarks.swift` + `scripts/regen-brand-marks.sh`
- `BrandMark.image(_:)` returns a tinted template `NSImage` per provider; `BrandMarkView`
  is the SwiftUI wrapper (observes the palette so a color edit re-renders).
- Marks are **base64-embedded alpha-mask PNGs**, *not* bundled resources —
  `Bundle.module` is unreliable in the bare `--snapshot`/`--menubar` binary, so
  embedding keeps every entry point identical. Tint with
  `.renderingMode(.template).foregroundStyle(color)`.
- **Regeneration pipeline** (`regen-brand-marks.sh`, don't hand-edit the base64):
  fetch Simple Icons SVGs (`claude`, `openai`, `ollama`, `lmstudio`) → rasterize with
  `qlmanage -t -s 128` → convert black-on-white to an alpha mask
  (`alpha = 255 − luminance`) in an RGBA8 `CGContext` → base64 → emit `BrandMarks.swift`.

---

## 9. The UI

`MenuView.swift` — the `MenuBarExtra(.window)` popup. Structure: an always-visible
**Limits header**, a custom **tab bar**, the active tab's **collapsible sections** in a
`ScrollView`, and an always-visible **footer** (service status).

### 9.1 Why the header is not a tab
The Limits header (claude.ai + Codex utilization) sits **above** the tabs and renders
on **every** tab (including Settings) so the tab bar never jumps vertically. Its scope
(whole account) and unit (%) differ from the local-token tabs, and "how close to the
wall" is the most actionable glance.

### 9.2 The tab bar
A **custom button row** (`HStack` of `Button`s), deliberately **not** a segmented
`Picker`, because AppKit-backed pickers render as blank placeholders in `--snapshot`.
Four tabs (raw value / title / SF Symbol):

| raw (persisted) | title | icon |
|---|---|---|
| `now` | **Activity** | `bolt.fill` |
| `usage` | **Usage** | `chart.bar.fill` |
| `history` | **History** | `calendar` |
| `settings` | **Settings** | `gearshape.fill` |

Default tab `now`. (Note the intentional raw≠title mismatch for `now`/"Activity".)

### 9.3 Limits header cards
Two cards, `limitRow` each:
- **CLAUDE LIMITS** — shown only when `limits.connected`; a "Connect claude.ai" prompt
  (jumps to Settings) otherwise. One row per `five_hour`/`seven_day`/`seven_day_sonnet`.
- **CODEX LIMITS** — always shown, fed by the active source; connect/enable prompt
  varies by cookie-vs-local.
- Each row: label · `resets <until>` · `NN%` (colored by the ramp) · a 5 pt capsule bar
  (min fill width 3 pt so 0% is still visible).
- **Reset countdown format** (`untilString`): `now` / `in Nm` / `in Nh Nm` / `in Nd Nh`.

### 9.4 Activity ("now") tab
- **Live** section: either "Idle — no call in flight" (gray dot) or, per live call,
  provider/model/operation + `↑ input ↓ ~estimated-output`; plus loaded Ollama and LM
  Studio models with provider and available runtime metadata.
- **Latest calls** section: the **8** most recent **non-shadowed** events (not
  period-scoped), including operation, failed state/HTTP code, accuracy marker, and
  available duration or throughput.

### 9.5 Usage tab
- **Period picker** (segmented): Today / 7 Days / 30 Days. Fixed caption naming the
  four local providers and the exclusions.
- **Tokens over time** (chart): per-**hour** for Today, per-**day** otherwise; future
  slots blank. **Stacked ↔ Grouped** toggle (`BarChartStyle`); **Hide weekends**
  (daily views only, `HideWeekends`); a dashed **kernel-regression trendline**
  (Gaussian Nadaraya–Watson, bandwidth `max(1.25, n/6)`, drawn when ≥3 points).
  Stacked order bottom→top: lmStudio, ollama, codex, claude. Per-bar `.help` tooltip
  gives the exact split. `· incl. cache` appears when `ChartIncludeCache` is on.
- **Providers & models**: one `providerRow` per provider (Claude, Codex, Ollama, LM
  Studio) with `↑in (+cache) ↓out · N calls` and `· X reasoning` where present, then up
  to **5** per-model rows (`+ N more models` beyond that).
- **Performance & reliability**: the shared `PerformanceAggregator` summarizes Ollama
  and LM Studio with call/completion/failure/cancellation/estimated counts and medians
  for tokens/sec, TTFT, and duration using only events that report each metric.
- **Sessions**: an origin filter pill row (All / Claude / Codex / Ollama / LM Studio,
  `SessionOriginFilter`), then up to **6** sessions (`+ N more`). Green dot = active in
  the last **15 min**; titles are Claude Code's `/resume` names where available.

### 9.6 History tab
- **Last 6 months**: a `26×7` heatmap (`weeks = 26`), 13 pt cells, 2 pt gaps, month
  labels along the top, a provider legend, and a per-cell `.help` tooltip with the
  exact split. Cell **hue** = OKLab `blend(...)` weighted by each provider's share;
  **opacity** = `0.32 + 0.68·√(day/maxInWindow)` (0.32 floor for any non-zero day, 1.0
  at the busiest day). Zero days and future days render as faint gray / clear.

### 9.7 Settings tab
Three clusters — **SOURCES**, **DISPLAY**, **NOTIFICATIONS**:
- **Sources:** claude.ai cookie `SecureField` + Save/Disconnect; Codex method pills
  (Cookie *recommended* vs Local sessions) with the matching cookie field or status;
  Ollama daemon + proxy-listener health and **Copy Ollama env**; LM Studio
  install/version/telemetry/API-server health. Each states its actual coverage.
- **Display:** *Menu bar shows* (5 checkboxes → `MenuBarItems`), *Include cached tokens
  in chart & heatmap* (`ChartIncludeCache`), *Provider colors* (7 swatches + hex field
  per provider, Reset), *Show sections* (one checkbox per collapsible section).
- **Notifications:** Claude thresholds, Codex thresholds, Anthropic status changes,
  OpenAI status changes.

### 9.8 Collapsible / hideable sections
Two comma-joined `@AppStorage` string sets: `CollapsedSections` (body chevron-collapsed,
header still shown) and `HiddenSections` (removed entirely, re-enabled from Settings).
The seven section ids (`AppSection`): `live`, `latest` (Activity); `chart`, `providers`,
`performance`, `sessions` (Usage); `heatmap` (History). The Limits header is **not** an `AppSection` —
it cannot be collapsed or hidden.

### 9.9 Footer
Always visible: Claude and OpenAI service status, each linked to its public status page;
up to 2 incidents and 3 degraded components shown.

### 9.10 Snapshot rendering
`MenuView(snapshotInline: true)` renders the active tab **inline** (no `ScrollView`,
no height plumbing) because `NSScrollView` won't draw in `ImageRenderer`. Live, the
scroll area is clamped to `min(max(contentHeight, 80), 520)`.

---

## 10. The menu-bar label and gauge

`TokenScopeApp.swift` builds the label; `MenuBarRender.swift` composites it;
`MenuBarGauge.swift` draws each gauge; the color ramp lives in `LimitsManager`.

- **One bitmap, always.** The macOS bar drops elements from a multi-part SwiftUI label
  and forces text monochrome, so the whole label (gauges + brand marks + `%` + token
  count) is drawn once via `ImageRenderer` into a single **non-template** `NSImage`
  (non-template so its colors survive). `.fixedSize()` is required or the renderer
  truncates (`28%`→`2…`). Light/dark comes from `AppearanceWatcher` (re-renders on
  `AppleInterfaceThemeChangedNotification`; defaults to dark when `NSApp` is nil).
- **What shows** is driven by `MenuBarItems` (default `tokens`): any of the Claude
  session/weekly gauges, the Codex primary/secondary gauges (persisted ids are the
  **legacy** `chatgptPrimary`/`chatgptSecondary` even though the UI says "Codex" — do
  not rename them or you silently reset users' choices), and the daily token count.
  Token count always shows if nothing else resolves, so the bar is never empty. A live
  `↓` counter replaces it while a proxied call streams. Codex gauges read whichever
  source is active (auto-prefer cookie when connected unless the user chose local).
- **The gauge** (`MenuBarGauge`): a ~250° dial (start 215°, sweep 250°), 20×15 canvas,
  neutral gray track always drawn; when connected, a filled arc + needle + hub tinted
  by the percent ramp. No fill/needle when disconnected (`fraction == nil`).
- **The color ramp** (`LimitsManager.rgb/color/nsColor(forPercent:)`) — used by both the
  header bars and the gauge:

  | Percent | Color |
  |---|---|
  | `< 75` | solid green `(0.20, 0.78, 0.35)` |
  | `75–80` | gradient green→yellow |
  | `80–85` | solid yellow `(1.0, 0.80, 0.0)` |
  | `85–90` | gradient yellow→red |
  | `≥ 90` | solid red `(1.0, 0.23, 0.19)` |

  (These color breakpoints — 75/80/85/90 — are **distinct** from the notification
  threshold bands — 25/50/75/90 — below.)

---

## 11. Notifications

`Notifier.swift`. All local, via `UNUserNotificationCenter`.

- **Bundle-id gate (hard requirement):** `Notifier.post`/`requestAuthorization` are
  silent no-ops when `Bundle.main.bundleIdentifier == nil`. The bare
  `--snapshot`/`--menubar` binary has no bundle id, and `UNUserNotificationCenter.current()`
  raises an `NSException` there — so this gate must stay.
- **ThresholdTracker** (shared by all limit managers): fires each band **once per
  climb** and **re-arms on drop**, persisting the last-fired band in UserDefaults so a
  relaunch mid-window doesn't re-alert. A multi-band jump in one poll fires only the
  **highest** crossed band.
- **Threshold bands:** session/primary `[25, 50, 75, 90]`; weekly/secondary/sonnet
  `[50, 75, 90]`.
- **Persisted tracker keys:** `limit_notified_session`, `limit_notified_weekly`,
  `limit_notified_weekly_sonnet` (Claude); `chatgpt_limit_notified_primary`,
  `chatgpt_limit_notified_secondary` (Codex — **shared** by the local and cookie
  sources so switching doesn't double-fire).
- **Status notifications** are state-change (indicator changed after first fetch), not
  threshold-based.
- Each manager builds its own title/body/id; the tracker only decides *whether* and
  *which band*.

---

## 12. Preferences reference (every key)

All in `UserDefaults.standard` (domain `com.tokenscope`). `@AppStorage` keys are
View-bound; the rest are read directly.

### Display / UI (mostly `@AppStorage`, set in `MenuView`)
| Key | Type | Default | Meaning |
|---|---|---|---|
| `ActiveTab` | String | `now` | selected tab |
| `StatsPeriod` | String | `today` | Usage period picker |
| `BarChartStyle` | String | `stacked` | chart stacked vs grouped |
| `HideWeekends` | Bool | `false` | weekend filter (daily views) |
| `ChartIncludeCache` | Bool | `true` | include cache tokens in chart & heatmap |
| `CollapsedSections` | String (CSV) | `""` | collapsed section ids |
| `HiddenSections` | String (CSV) | `""` | hidden section ids |
| `MenuBarItems` | String (CSV) | `tokens` | menu-bar gauges/count: `session,weekly,chatgptPrimary,chatgptSecondary,tokens` |
| `SessionOriginFilter` | String | `all` | Sessions-list provider filter |

### Provider colors (via `ProviderPalette`, read synchronously — not `@AppStorage`)
| Key | Type | Default | Meaning |
|---|---|---|---|
| `ProviderColorClaude` | String `#RRGGBB` | `#F5942E` | Claude color override |
| `ProviderColorCodex` | String `#RRGGBB` | `#34C759` | Codex color override |
| `ProviderColorOllama` | String `#RRGGBB` | `#5A9EFA` | Ollama color override |
| `ProviderColorLMStudio` | String `#RRGGBB` | `#B052DE` | LM Studio color override |

### Sources / auth
| Key | Type | Default | Meaning |
|---|---|---|---|
| `ProxyPort` | Int | `11435` | proxy listen port |
| `OllamaPort` | Int | `11434` | Ollama upstream port |
| `CodexSource` | String | `""` (auto) | `local` \| `cookie` \| `""` |
| `CodexMonitoringEnabled` | Bool | `true` | local Codex scan on/off |
| `claude_session_cookie` | String | — | claude.ai cookie (secret) |
| `chatgpt_session_cookie` | String | — | ChatGPT cookie (secret) |

### Notification toggles + tracker state
| Key | Type | Meaning |
|---|---|---|
| `limit_notifications_enabled` | Bool | Claude limit alerts |
| `chatgpt_limit_notifications_enabled` | Bool | Codex limit alerts (shared local/cookie) |
| `status_notifications_enabled` | Bool | Anthropic status alerts |
| `openai_status_notifications_enabled` | Bool | OpenAI status alerts |
| `limit_notified_session` / `_weekly` / `_weekly_sonnet` | Int | last-fired band (Claude) |
| `chatgpt_limit_notified_primary` / `_secondary` | Int | last-fired band (Codex) |

> **Cookies are session credentials stored in plain UserDefaults** (matching the
> upstream ClaudeUsageBar). A Keychain move is the obvious hardening if this graduates
> beyond personal use.

---

## 13. Runtime files and directories

- `~/Library/Application Support/TokenScope/usage-events-v2.jsonl` — versioned,
  compacted local-event journal for Ollama proxy, Ollama Desktop metadata, and LM
  Studio observations.
- `~/Library/Application Support/TokenScope/proxy-events.jsonl` — legacy proxy-only
  journal, read only for one-time migration when the v2 journal is absent.
- `~/Library/Application Support/TokenScope/daily-history.json` — frozen per-day
  aggregates + `completeThrough` + `codexCompleteThrough`. Outlives Claude Code's
  transcript cleanup. If absent, it is rebuilt with a one-time backfill (≤366d).
- `~/Library/Logs/TokenScope.log` — every lifecycle step (replay complete, proxy,
  limits, status, folds/backfills). **Not** per-event (that produced a 17 MB log). One
  file handle held open, serialized on a dedicated queue. First place to look when
  verifying behavior.
- **Read-only inputs:** `~/.claude/projects/**/*.jsonl`, `~/.codex/sessions/**/*.jsonl`,
  `~/.lmstudio/bin/lms` (spawned). Codex raw logs are never modified.

---

## 14. Build, verify, install, release

```sh
swift build -c release            # compile
./build-app.sh                    # bundle TokenScope.app (Info.plist + icon + ad-hoc codesign)

# Framework-free domain/protocol/LM Studio regression suites: see CLAUDE.md
```

`build-app.sh` writes the `Info.plist` (bundle id `com.tokenscope`,
`CFBundleShortVersionString` = 0.1.2, `CFBundleVersion` = 3, `LSUIElement true`),
generates the icon from `tools/make-icon.swift` if missing, and `codesign --force
--sign -` (ad-hoc). `Package.swift` is a single executable target, no dependencies.

**Verify UI before installing — always look at a snapshot:**
```sh
.build/release/TokenScope --snapshot /tmp/menu.png
SNAPSHOT_PERIOD=month SNAPSHOT_HIDE_WEEKENDS=1 .build/release/TokenScope --snapshot /tmp/menu-30d.png
```
`--snapshot` boots the real services, waits **8 s** for replay, and renders the active
tab inline at 2× via `ImageRenderer`. Env overrides (pre-seed the matching prefs):
`SNAPSHOT_PERIOD`, `SNAPSHOT_HIDE_WEEKENDS`, `SNAPSHOT_BAR_STYLE`, `SNAPSHOT_INCLUDE_CACHE`,
`SNAPSHOT_TAB`, `SNAPSHOT_PROVIDER_{CLAUDE,CODEX,OLLAMA}`, `SNAPSHOT_APPEARANCE`.
AppKit-backed controls (segmented pickers, checkboxes, `SecureField`, `ScrollView`,
`ProgressView`) render as placeholders — that's an `ImageRenderer` limit, not a bug.
The **menu-bar label** isn't in the popup: verify it with `screencapture` of the top
strip, or render offline with `--menubar out.png` (identical `MenuBarRender.image` path).
`--gauges <dir>` dumps the gauge at representative levels.

**Install (login item points at `/Applications` — re-ditto after every rebuild):**
```sh
pkill -x TokenScope; ./build-app.sh
rm -rf /Applications/TokenScope.app && ditto TokenScope.app /Applications/TokenScope.app
open /Applications/TokenScope.app
```

**Release:** bump `CFBundleShortVersionString` + `CFBundleVersion` in `build-app.sh`,
clean-build, verify (version prints, watchers start, app stays alive), zip the app, and
`gh release create vX.Y.Z TokenScope.zip`. Builds are **ad-hoc signed, not notarized**
(first launch needs right-click → Open, or `xattr -dr com.apple.quarantine`) and
**Apple-Silicon only**.

---

## 15. Footprint and efficiency invariants

It runs 24/7, so idle cost is a design constraint. Measured idle (~7.9k events in
window): **~0.2% CPU** (mostly 0.0%), **~165 MB RSS** (SwiftUI/AppKit baseline; our
data is a couple MB), 8 threads, ~7 KB log. **CPU is the metric to guard.** Do not undo:
- **TranscriptWatcher/CodexWatcher** stat only recently-modified ("hot") files each
  second; a full directory walk runs every 10th tick (a full stat of ~300 files/sec was
  ~3–20% idle CPU).
- **UsageStore's clock timer runs only while calls are live** and stops itself when
  `liveCalls` empties — no idle wakeups recomputing the label.
- **FileLog** holds one handle open and logs lifecycle only, never per-event.
- **Poll cadence:** limits 60 s, ChatGPT limits 60 s, status 300 s, Ollama health/models 10 s,
  LM Studio health/models 30 s, transcript/codex 1 s (hot-file only), LM Studio relaunch backoff 30 s. Don't add
  per-second work.

---

## 16. Do-not-regress invariants

These have each broken before. `CLAUDE.md` carries the terse always-loaded checklist;
the rationale lives here.

1. **Bundle id must stay `com.tokenscope`.** `com.baysora.tokenscope` triggers a cursed
   per-bundle-id macOS state where the `MenuBarExtra` scene self-terminates ~1 s after
   launch (clean exit 0, no crash), surviving reboots and cache clears. This is *not* a
   code bug; the only fix was changing the id. Never revert it.
2. **The events window is whole days.** Keep `eventsCutoff = startOfDay − 31d`; never a
   rolling timestamp cutoff.
3. **Shadowed events count nowhere** except the call log. Keep both runtime directions
   and the startup reconcile.
4. **Transcript dedup = `message.id:requestId`, strongest wins.** A final rewrite must
   upgrade partial usage and a stale replay must not downgrade it.
5. **Byte pre-filters before JSON decode** (`"assistant"`, `"token_count"`,
   `"session_meta"`, …) — keep them; they make the 30-day replay fast.
6. **The proxy never rewrites response bytes**; the only mutation is forcing
   `Accept-Encoding: identity`. Gzip would blind the scanner.
7. **Skip `model == "<synthetic>"`** transcript lines.
8. **Notifications gated on a non-nil bundle id** (NSException otherwise).
9. **The tab bar is a custom button row, not a segmented Picker** (so it renders in
   snapshots). Don't "simplify" it.
10. **The menu bar takes ONE composited bitmap** (`MenuBarRender`), non-template so
    color survives; `.fixedSize()` to avoid truncation. A multi-element label renders
    only the trailing text.
11. **Menu-bar item ids keep the legacy `chatgpt*` spelling** even though the domain is
    "Codex" — renaming resets users' choices.
12. **`ScrollView` needs a fixed `.frame(height:)`** — `MenuBarExtra` sizes to the
    view's *ideal* height and a ScrollView's ideal height is ~0 (collapses the middle).
13. **Provider colors read synchronously via `ProviderPalette`**, not `@AppStorage`
    (needed in the headless binary). Never stomp a user's stored pick.
14. **Regenerate brand marks with the script**, never hand-edit the base64;
    embed, don't bundle (`Bundle.module` is unreliable headless).
15. **`glassEffect` is banned inside the popup** — it's already system glass, and
    `ImageRenderer` renders glass as opaque white. Use `.sectionCard()` (a flat fill).
16. **Privacy:** persist only operational metadata; never persist prompt/reply/tool
    content or raw provider/CLI errors. Keep LM Studio's `--filter output` boundary.

---

## 17. Known limitations

- **Direct-to-Anthropic calls have no mid-call live counter** — the API reports usage
  only at completion. Live streaming numbers require routing through the proxy.
- **Proxy events carry no session identity** — they group under "Ollama (direct)".
- **Ollama Desktop token counts are not meterable** — its DB exposes completed-call
  metadata but no runtime token counts. TokenScope shows those calls, model, and
  duration as `tokens unavailable`; exact counts still require the proxy.
- **LM Studio history begins at first observation** — no backfill before first launch;
  events persist thereafter; a `lms`
  older than v0.3.26 (no `--source model --stats`) means the provider stays off.
- **Heatmap hue/intensity trade-off** — a heavy single-provider day and a light mixed
  day can look similar; the tooltip carries the exact split.
- **claude.ai / ChatGPT limit endpoints are unofficial** — they may break without
  notice; cookies expire; ChatGPT's UA must match the cookie's origin browser.
- **Fast-follows (documented, not built):** LM Studio history backfill from
  `~/.lmstudio/conversations/*.json`; dedup if Claude Code/Codex are pointed *at* LM
  Studio (double-count risk); Gemini and an in-app updater (roadmap).

---

## 18. Module index

| File | Responsibility |
|---|---|
| `TokenScopeApp.swift` | `@main` dispatch, `AppServices` wiring, `MenuBarExtra` scene, menu-bar image assembly, `--snapshot/--gauges/--menubar` |
| `Models.swift` | `UsageOrigin`, `EventSource`, `UsageEvent`, `LiveCall`, `Totals`, `SessionAgg`, `StatsPeriod`, `DayStat`, `DayAgg` |
| `UsageStore.swift` | event window, history, backfill, shadowing, dedup, aggregates, persistence, clock |
| `TranscriptWatcher.swift` | Claude Code transcript tail + session titles + backfill |
| `CodexTranscriptWatcher.swift` | Codex session-log tail (token_count/rate_limits) + backfill |
| `OllamaProxy.swift` | transparent TCP relay + connection handling |
| `HTTPRequestScanner.swift` / `HTTPIdentityEncodingRewriter.swift` | request attribution + split-safe identity-encoding rewrite |
| `HTTPResponseFramer.swift` / `ResponseScanner.swift` | HTTP transport framing + Ollama/Anthropic/OpenAI/Responses usage/lifecycle parse |
| `EventReconciler.swift` / `PerformanceAggregator.swift` | strongest-observation merge + provider-neutral operational summaries |
| `LMStudioLogWatcher.swift` / `LMStudioEventParser.swift` | output-only model telemetry + privacy-boundary parser |
| `LMStudioCLI.swift` / `LMStudioStatusPoller.swift` | bounded CLI execution + LM runtime/model health |
| `OllamaStatusPoller.swift` | `/api/version` health + `/api/ps` resident-model poll |
| `LimitsManager.swift` | claude.ai usage + the shared percent→color ramp |
| `OpenAILimitsManager.swift` | local Codex quota (event-driven `observe`) |
| `ChatGPTLimitsManager.swift` | ChatGPT web usage (cookie→bearer, defensive parse) |
| `StatusManager.swift` | Statuspage summary for Claude & OpenAI |
| `Notifier.swift` | `UNUserNotificationCenter` wrapper + `ThresholdTracker` |
| `MenuView.swift` | the entire popup UI |
| `MenuBarRender.swift` | composited menu-bar bitmap + `AppearanceWatcher` |
| `MenuBarGauge.swift` | the dial gauge drawing |
| `ProviderPalette.swift` | provider colors + OKLab blend (single source of truth) |
| `BrandMarks.swift` | base64 alpha-mask brand marks (generated) |
| `Fmt.swift` | `Fmt.compact` number formatting + `FileLog` |
| `Glassy.swift` | `.sectionCard()` flat card modifier |
| `Snapshot.swift` | `--snapshot` boot + render |

**`Fmt.compact`:** `< 1000` → raw; `< 1M` → `N.Nk` (1 dp below 100k, 0 dp to 999k);
else → `N.NNM`.

---

## 19. Licensing and attribution

MIT (`LICENSE`, © 2026 Asa Laws). Plan-limit tracking + threshold-notification logic
adapted from **ClaudeUsageBar** (MIT). Brand marks rendered from **Simple Icons**
(CC0-1.0; the CC0 covers the icon files, not the underlying trademarks). Full text in
`THIRD-PARTY-NOTICES.md`. Claude/Anthropic, ChatGPT/OpenAI, Ollama, and LM Studio names
and marks are trademarks of their owners; TokenScope is independent and unaffiliated.
```
