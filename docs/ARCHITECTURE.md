# TokenScope Architecture

macOS menu bar app measuring LLM token usage across two providers (Claude /
Anthropic and Ollama), built as a SwiftPM executable with SwiftUI `MenuBarExtra`.
No third-party dependencies.

```
   Claude Code ──── api.anthropic.com            ┌────────────────────────┐
        │                                        │  ~/.claude/projects/   │
        └── writes transcripts ────────────────► │  **/*.jsonl            │
                                                 └──────────┬─────────────┘
   Claude Code ──┐                                          │ tail (1s poll)
   ollama run ───┤                                          ▼
   any client ───┴─► 127.0.0.1:11435 ─────────►  ┌──────────────────────┐
                     OllamaProxy (TCP relay)     │      UsageStore      │ ──► MenuView
                       │            │            │  events (31 days)    │     (MenuBarExtra)
                       ▼            ▼            │  history (forever)   │
                  127.0.0.1:11434  ResponseScanner ──► live + per-call  │
                     (Ollama)                    └──────────────────────┘
```

## Data sources

**1. Claude Code transcripts** (`TranscriptWatcher`). Claude Code logs every API
response to `~/.claude/projects/<project>/<session>.jsonl` with exact usage:

```json
{"type":"assistant","sessionId":"…","timestamp":"2026-06-11T22:44:18.134Z",
 "cwd":"/Users/…","requestId":"req_…",
 "message":{"id":"msg_…","model":"claude-fable-5",
   "usage":{"input_tokens":5450,"output_tokens":30620,
            "cache_read_input_tokens":17393,"cache_creation_input_tokens":5896}}}
```

This covers native Anthropic usage **and** Claude Code pointed at Ollama (via
`ANTHROPIC_BASE_URL`), since Ollama's Anthropic-compatible endpoint returns
usage that Claude Code logs identically. Exact counts, session attribution,
project attribution — but only available when each message *completes*.

The watcher polls the tree once per second, tracks per-file byte offsets, only
advances past complete lines, and byte-prefilters for `"assistant"` before
JSON-decoding. It also extracts session titles: `{"type":"summary","summary":…}`
lines (authoritative) and the first real user message (fallback, 60-char cap,
skipping `<command-…>`/`Caveat:`/meta lines).

**2. Local proxy** (`OllamaProxy` → `Relay` → `ResponseScanner`). A transparent
TCP relay `127.0.0.1:11435 → 127.0.0.1:11434`. Bytes pass through unmodified
except request `Accept-Encoding` headers are forced to `identity`. The response
direction is tapped by a per-connection `ResponseScanner` that splits on
newlines (NDJSON and SSE are newline-framed; chunked-transfer size markers
appear as bare hex lines and are filtered) and understands three shapes:

| Format | Detect | Input | Output | End of call |
|---|---|---|---|---|
| Ollama native | `"done"` key | `prompt_eval_count` | `eval_count` | `"done":true` |
| Anthropic | `"type"` events | `usage.input_tokens` (message_start) | `usage.output_tokens` (message_delta) | `message_stop` / `"type":"message"` |
| OpenAI | `"object"` | `prompt_tokens` | `completion_tokens` | `chat.completion` / `[DONE]` |

While streaming, chunk counts approximate output (`approxOutput`) until a real
count arrives; this powers the live in-flight counter. A JSON-parse failure on a
usage-bearing line falls back to regex extraction. Calls with zero output
(`count_tokens`, pings, errors) are dropped at finalize.

This is the only source that sees tokens **while they stream**, and the only
one that sees non-Claude-Code Ollama clients (`OLLAMA_HOST=127.0.0.1:11435`).

**3. `/api/ps` poller** (`OllamaStatusPoller`): every 10s, which model(s) are
resident in Ollama's memory + VRAM, for the "Now" zone.

**4. Plan limits** (`LimitsManager`): polls `claude.ai/api/organizations/{orgId}/usage`
every 5 min using the user's claude.ai Cookie header (pasted in Settings, stored
in app preferences). Parses `five_hour` / `seven_day` / `seven_day_sonnet`
`utilization` (%) + `resets_at`. Org ID comes from the `lastActiveOrg` cookie
crumb or `/api/bootstrap`. This is the "nearest rate-limit wall + reset" view.
Unofficial endpoint — degrades gracefully (no cookie → connect prompt;
401/403 → "re-copy cookie"). Fires threshold notifications (session 25/50/75/90%,
weekly 50/75/90%) via `ThresholdTracker`, which fires each band once per climb
and re-arms on drop. Adapted from github.com/Artzainnn/ClaudeUsageBar.

**5. Service status** (`StatusManager`): polls the public
`status.claude.com/api/v2/summary.json` (no auth) every 5 min for the overall
indicator, non-operational components, and active incidents; notifies on
indicator transitions. Answers "is it me or is Claude down?".

Notifications go through `Notifier` (UNUserNotificationCenter; gated on a bundle
identifier so the bare `--snapshot` binary doesn't raise an NSException).

## UsageStore: windows, history, reconciliation

- **Live events window — 31 whole days.** `eventsCutoff` = startOfDay(now) − 31d.
  A calendar day is either entirely in `events` or entirely frozen — never split.
  On launch the watcher replays transcripts newer than the cutoff (~seconds for
  a month); persisted proxy events load from
  `Application Support/TokenScope/proxy-events.jsonl`.
- **Permanent daily history.** Days aging out of the window are folded into
  `daily-history.json` (`[yyyy-MM-dd: {claudeIn,claudeOut,ollamaIn,ollamaOut,calls}]`
  plus `completeThrough`). Claude Code deletes old transcripts, so this file is
  what lets the 6-month heatmap accumulate. A backfill scan covers the gap
  `(completeThrough, cutoff)` from whatever old transcripts still exist (≤366d),
  exactly once per gap.
- **Double-count prevention.** A Claude Code call through the proxy is observed
  twice. Runtime: when a transcript event arrives, a recent proxy event with
  matching output tokens (±2, ±90s) is marked `shadowed` (and vice versa).
  Startup: `replayFinished` sorts events and re-reconciles persisted proxy
  events against replayed transcripts (±2 tokens, ±120s). Shadowed events are
  excluded from every aggregate but kept for the call log.
- **Dedup**: transcript events dedup on `message.id:requestId` (first wins);
  streaming rewrites repeat messages across lines.
- Aggregates (`totals`, `modelTotals`, `sessions`, `dailyTotals`,
  `hourlyTotals`, `heatmapDays`) are computed on demand over the window —
  no materialized caches to invalidate.

## UI (MenuView)

The information architecture separates by **scope**, because the app reports two
things that share neither units, window, nor source:
- **claude.ai plan limits** — account-wide utilization % (covers claude.ai web +
  desktop + Claude Code; excludes Ollama), 5h/7d rolling windows.
- **Local token usage** — exact token counts from Claude Code transcripts +
  Ollama on this Mac (excludes claude.ai web/desktop; includes Ollama).

So **Limits lives in an always-visible header** above the tabs (labeled "whole
account · web + desktop + Code"), NOT in a tab — its scope/unit differ from the
local-token tabs, and "how close to the wall" is the most actionable glance. The
tabs are then purely local-token views. A custom (snapshot-renderable) **tab bar**
splits them into four; within a tab each section is **collapsible** (persisted in
`CollapsedSections`) and **hideable** from Settings (`HiddenSections`). The footer
carries Anthropic service + proxy status; the menu-bar gauge tints to the nearest
limit wall.

- **Header (always on, except Settings)** — Limits: per-window bars, % colored by
  the green→yellow→red gradient, reset countdowns, refresh; a connect prompt when
  no cookie.
- **Activity** — Live calls (spinner, growing `↓` count, loaded Ollama model +
  VRAM, stable "Idle" row) and Latest calls (8 most recent, not period-scoped).
- **Usage** — Today/7d/30d picker; a source caption ("Claude Code + Ollama on
  this Mac"); the chart (per-hour for Today, per-day otherwise; future slots
  blank), Stacked↔Grouped toggle, "Hide weekends" (daily only), a kernel-
  regression trendline; provider totals with per-model breakdown; sessions.
- **History** — 26-week heatmap with month labels; cell hue mixes provider
  colors by the day's share, opacity carries volume in 4 steps vs the 6-month max.
- **Settings** — claude.ai cookie field, menu-bar field picker, notification
  toggles, per-section show/hide checkboxes.

The title-bar headline splits today's tokens by provider (orange Claude / blue
Ollama) rather than one merged number — a single figure is misleading when free
local Ollama traffic dominates volume.

Session titles come from Claude Code's own `{"type":"ai-title","aiTitle":…}`
line (the exact name shown in `/resume`), falling back to older `"summary"`
lines, then the first user message.

Menu bar label: today's input+output (cache excluded); switches to a live `↓`
counter while a proxied call streams.

**Critical layout constraint**: MenuBarExtra windows size to the view's *ideal*
height and a ScrollView's ideal height is ~0 — the scroll area must keep its
fixed `.frame(height:)`. Segmented pickers, checkboxes, SecureField, and
ScrollView are AppKit-backed and render as placeholders in snapshots; the custom
tab bar is plain SwiftUI so it renders. `SNAPSHOT_TAB`/`SNAPSHOT_PERIOD`/
`SNAPSHOT_HIDE_WEEKENDS`/`SNAPSHOT_BAR_STYLE` env vars drive snapshot states.

## Snapshot verification

`TokenScope --snapshot out.png` boots the real services, waits 8s for replay,
and renders the menu via `ImageRenderer` (scroll content inlined — ScrollView
is NSScrollView-backed and won't render; segmented pickers/checkboxes show as
placeholders). Env overrides: `SNAPSHOT_PERIOD`, `SNAPSHOT_HIDE_WEEKENDS`,
`SNAPSHOT_BAR_STYLE`. Every UI change gets eyeballed this way before install.
The menu-bar label isn't in the popup, so verify it with `screencapture` of the
top strip, or render it offline with `--menubar out.png`.

## Footprint

It runs 24/7, so idle cost is a design constraint, not an afterthought. Measured
idle (≈7.9k events in window): ~0.2% CPU (mostly 0.0%), ~165 MB RSS, 8 threads,
~7 KB log. The work that keeps CPU near zero: the transcript watcher stats only
recently-modified files each second (full directory walk every 10th tick); the
clock timer runs only while a call is live; logging holds one handle open and is
lifecycle-only, not per-event. Pollers are infrequent (limits/status 5 min,
`/api/ps` 10 s). Memory is essentially the SwiftUI/AppKit baseline — the event
log and history are only a couple MB.

## Known limitations

- Direct-to-Anthropic calls have no mid-call live counter (the API reports
  usage only at message completion). Live streaming numbers require routing
  through the proxy.
- Proxy events carry no session identity; they group under "Ollama (direct)".
- Heatmap hue/intensity trade-off: a heavy single-provider day and a light
  mixed day can look similar — tooltips carry the exact split.
- Gzip responses would blind the scanner; the proxy prevents this by forcing
  identity encoding on requests.
