# CLAUDE.md

TokenScope is a macOS menu bar app (SwiftPM, SwiftUI `MenuBarExtra`) that meters
local LLM token usage — live, per call, per session, per day — for Claude Code
(native Anthropic or pointed at Ollama), Codex local sessions, and any Ollama
client routed through its local proxy. It also tracks claude.ai plan limits,
observed Codex quota windows, experimental ChatGPT web limits, and Claude/OpenAI
service status. See
`docs/ARCHITECTURE.md` for the full design.

UI is tabbed (Now / Usage / History / Settings); sections within a tab are
collapsible (persisted) and hideable from Settings.

## Build, verify, install

```sh
swift build -c release                       # compile
./build-app.sh                               # build TokenScope.app (bundle + icon)

# VERIFY UI BEFORE INSTALLING — render the menu with real data:
.build/release/TokenScope --snapshot /tmp/menu.png
SNAPSHOT_PERIOD=month SNAPSHOT_HIDE_WEEKENDS=1 .build/release/TokenScope --snapshot /tmp/menu-30d.png
# SNAPSHOT_PERIOD=today|week|month, SNAPSHOT_HIDE_WEEKENDS=0|1, SNAPSHOT_BAR_STYLE=stacked|grouped

# install (the login item points at /Applications — ALWAYS re-ditto after rebuild):
pkill -x TokenScope; ./build-app.sh
rm -rf /Applications/TokenScope.app && ditto TokenScope.app /Applications/TokenScope.app
open /Applications/TokenScope.app
```

Never ship a UI change without looking at a snapshot first. In snapshots,
AppKit-backed controls (segmented `Picker`, checkbox `Toggle`, `ScrollView`,
`ProgressView`) render as placeholders or not at all — that's an `ImageRenderer`
limitation, not a bug. The snapshot renders the scroll content inline for this
reason (`MenuView(snapshotInline: true)`).

## Hard-won gotchas — do not regress these

- **MenuBarExtra windows size to the view's IDEAL height.** A `ScrollView`'s
  ideal height is ~0, so it MUST get a fixed `.frame(height:)`. Using only
  `maxHeight` collapses the entire middle of the menu invisibly (this shipped
  broken for several rounds before being caught).
- **The events window is whole days.** `UsageStore.eventsCutoff` is
  startOfDay(now) − 31 days. A calendar day is either entirely live (in
  `events`) or entirely frozen (in `history`) — `trim()`/`fold()`/backfill all
  rely on this; don't reintroduce a rolling timestamp cutoff.
- **Double-count prevention.** A Claude Code call routed through the proxy is
  seen twice (proxy + transcript). Live: ±90s output-token match marks the proxy
  copy `shadowed`. Startup: `replayFinished` re-reconciles persisted proxy
  events. Totals exclude shadowed events; don't count them anywhere else.
- **Transcript dedup** is `message.id:requestId`, first occurrence wins
  (streaming rewrites repeat messages across lines).
- **Byte-level pre-filters** in `TranscriptWatcher.parse` (`"assistant"`,
  `"type":"summary"`, `"type":"user"` markers) keep the 30-day replay fast.
  Don't JSON-decode every line.
- **The proxy is a transparent TCP relay.** It never rewrites response bytes;
  the only request mutation is forcing `Accept-Encoding: identity` so responses
  stay scannable. Scanning is newline-framed (NDJSON/SSE) with a regex fallback
  for lines split by chunked-transfer framing.
- Claude Code transcript classification is `model.hasPrefix("claude")` →
  `claudeCode`, else `ollama`; Codex comes only from its explicit local watcher.
  Transcript `model == "<synthetic>"` lines are skipped.
- **Session names** come from Claude Code's `{"type":"ai-title","aiTitle":…}`
  line (the exact `/resume` name), then older `"summary"` lines, then first user
  message. ai-title overwrites; fallback only fills gaps.
- **Notifications** must be gated on `Bundle.main.bundleIdentifier != nil` —
  `UNUserNotificationCenter.current()` raises an NSException in the bare
  `--snapshot` binary. See `Notifier.available`.
- **Tab bar is a custom button row, not a segmented Picker** — deliberately, so
  it renders in snapshots. Don't "simplify" it to a Picker.
- The **claude.ai and ChatGPT usage endpoints are unofficial** and their cookies
  are session credentials stored in UserDefaults (matches the upstream
  ClaudeUsageBar; a Keychain move is the obvious hardening if this graduates
  beyond personal use). Keep ChatGPT's parser isolated: it may change without
  affecting local Claude/Codex/Ollama tracking.
- **The menu bar drops elements from a multi-part SwiftUI label** and forces
  text monochrome. Compose the WHOLE label (gauges + text) into ONE bitmap via
  ImageRenderer and hand the bar a single `Image(nsImage:)` — see `MenuBarRender`.
  A multi-element `HStack { Image; Label; Text }` silently rendered only the
  trailing text. Gauges are non-template `NSImage` (`MenuBarGauge`) so their
  color survives. Text color tracks light/dark via `AppearanceWatcher`
  (re-render on `AppleInterfaceThemeChangedNotification`). `NSApp` is nil in the
  `--snapshot`/`--menubar` paths — guard it.
- **Verify the menu bar with `screencapture`**, not snapshots (the bar isn't in
  the popup): `screencapture -x` full screen, then crop the top-right strip.
  `--menubar <png>` dumps the composited label offline for a quick check.
- **Liquid Glass: the MenuBarExtra(.window) popup is ALREADY system glass.**
  Per Apple ("avoid glass on glass; glass is only the navigation layer above
  content"), add NO `glassEffect` inside the popup — that was the "mess of radius
  and glass." Controls are flat (the tab bar is a plain segmented control with a
  solid accent selection); content groups use the subtle `.sectionCard()` fill.
- **ImageRenderer renders `glassEffect` as opaque WHITE** — another reason not to
  use it here; everything now snapshots faithfully.

## Efficiency (it's a 24/7 menu-bar app — keep idle cost ~0)

Measured idle footprint (2026-06-11, ~7.9k events in window): **~0.2% CPU**
average (most samples 0.0%, brief sub-2% blips from the 1 s hot-file check and
pollers), **~165 MB RSS** (almost all SwiftUI/AppKit baseline — our data is a
couple MB), 8 threads, ~7 KB log. CPU is the metric to guard; memory is
framework baseline and not cheaply reducible without leaving SwiftUI.

Idle CPU must stay near zero. Measured regressions that were fixed; don't undo:
- **TranscriptWatcher** stats only recently-modified ("hot") files each second
  and does a full directory walk every 10th tick — NOT a full stat of all ~300
  files every second (that alone was ~3–20% idle CPU).
- **UsageStore's clock timer runs only while calls are live** (`startTickingIfNeeded`),
  stopping itself when `liveCalls` empties — no idle wakeups recomputing the label.
- **FileLog holds one file handle open** and does NOT log per-event (per-event at
  replay scale produced a 17 MB / 178k-line log). Lifecycle summaries only.
- Pollers: limits 5 min, status 5 min, `/api/ps` 10 s. Don't add per-second work.

## Runtime files

- `~/Library/Application Support/TokenScope/proxy-events.jsonl` — persisted
  proxy observations (compacted to 31 days at load).
- `~/Library/Application Support/TokenScope/daily-history.json` — frozen per-day
  aggregates + `completeThrough`; outlives Claude Code's transcript cleanup.
  Deleting it triggers a fresh one-time backfill (≤366 days) on next launch.
- Codex raw session logs remain in `~/.codex/sessions/**/*.jsonl`; TokenScope
  reads only `session_meta` and `token_count` records, then retains the same
  31-day event window and permanent day aggregates as other local sources. Its
  own persisted watermark drives the one-time ≤366-day history backfill.
- `~/Library/Logs/TokenScope.log` — every ingested event and lifecycle step;
  first place to look when verifying behavior.
- Ports via `defaults write com.baysora.tokenscope ProxyPort|OllamaPort -int N`
  (defaults 11435 → 11434).
