# CLAUDE.md

TokenScope is a macOS menu bar app (SwiftPM, SwiftUI `MenuBarExtra`) that meters
local LLM token usage — live, per call, per session, per day — for Claude Code
(native Anthropic or pointed at Ollama), Codex local sessions, any Ollama client
routed through its local proxy, and completed LM Studio LLM generations (via an
output-only `lms log stream --source model` telemetry feed — counts/stats only,
never retained prompt/reply text). It also tracks claude.ai plan limits,
observed Codex quota windows, experimental ChatGPT web limits, and Claude/OpenAI
service status.

**`docs/REFERENCE.md` is the complete, authoritative reference** — every subsystem,
rule, and constant, written so an AI can understand the app without reading source.
Read it before any non-trivial change. `docs/ARCHITECTURE.md` is a one-screen overview
that points there. The sections below are the terse always-loaded working checklist;
`REFERENCE.md` carries the full rationale for each item.

UI uses a fixed three-zone popup: aggregate-status header + adaptive pinned limit
rail, one fixed-height facet at a time, and bottom tabs (Usage / Activity / History /
Settings). Supporting provider/session/settings detail drills in within its facet;
legacy section visibility preferences are retained under Usage-chart settings.

## Build, verify, install

```sh
swift build -c release                       # compile
./build-app.sh                               # build TokenScope.app (bundle + icon)

# Pure regression suites (framework-free so CommandLineTools-only Macs work):
swiftc Sources/TokenScope/Models.swift Sources/TokenScope/LimitRailPresentation.swift Sources/TokenScope/EventReconciler.swift Sources/TokenScope/PerformanceAggregator.swift Sources/TokenScope/ProcessReaper.swift Sources/TokenScope/Fmt.swift tools/verify-models.swift -o /tmp/tokenscope-model-checks && /tmp/tokenscope-model-checks
swiftc Sources/TokenScope/Models.swift Sources/TokenScope/HTTPRequestScanner.swift Sources/TokenScope/HTTPIdentityEncodingRewriter.swift Sources/TokenScope/HTTPResponseFramer.swift Sources/TokenScope/ResponseScanner.swift tools/verify-protocols.swift -o /tmp/tokenscope-protocol-checks && /tmp/tokenscope-protocol-checks
swiftc Sources/TokenScope/Models.swift Sources/TokenScope/LMStudioEventParser.swift tools/verify-lmstudio.swift -o /tmp/tokenscope-lmstudio-checks && /tmp/tokenscope-lmstudio-checks

# VERIFY UI BEFORE INSTALLING — render the menu with real data:
.build/release/TokenScope --snapshot /tmp/menu.png
SNAPSHOT_PERIOD=month SNAPSHOT_HIDE_WEEKENDS=1 .build/release/TokenScope --snapshot /tmp/menu-30d.png
# SNAPSHOT_PERIOD=today|week|month, SNAPSHOT_HIDE_WEEKENDS=0|1, SNAPSHOT_BAR_STYLE=stacked|grouped, SNAPSHOT_INCLUDE_CACHE=0|1
# SNAPSHOT_TAB=usage|now|history|settings, SNAPSHOT_LIMITS=all|three|two|one|none

# Full redesign checkpoint (requires a complete Xcode toolchain):
./scripts/verify-redesign.sh
# Command Line Tools only (parsing and non-UI regressions; no app/snapshots):
CLI_ONLY=1 ./scripts/verify-redesign.sh

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
- **Transcript dedup** is `message.id:requestId`; `EventReconciler` keeps the
  strongest observation so a final rewrite upgrades a partial/zero record and a
  later stale replay cannot downgrade it.
- **Byte-level pre-filters** in `TranscriptWatcher.parse` (`"assistant"`,
  `"type":"summary"`, `"type":"user"` markers) keep the 30-day replay fast.
  Don't JSON-decode every line.
- **The proxy is a transparent TCP relay.** It never rewrites response bytes;
  the only request mutation is forcing `Accept-Encoding: identity` so responses
  stay scannable. Request and response transport use bounded HTTP/1.1 framing
  (Content-Length, chunked, keep-alive, close-delimited); NDJSON/SSE body records
  are parsed only after transfer framing is removed.
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
  (`screencapture` needs Screen Recording permission; in headless/sandboxed
  runs it writes nothing — fall back to `--menubar`, which uses the identical
  `MenuBarRender.image` path the live bar does.)
- **Provider brand marks** (`BrandMark`/`BrandMarkView`) identify Claude / Codex
  / Ollama everywhere a provider appears (menu-bar gauges, provider rows, session
  filter, heatmap legend, title chips) — one source of truth for the mark and its
  accent color (`BrandMark.color`). They're base64-embedded alpha-mask PNGs, NOT
  bundled resources: `Bundle.module` is unreliable in the bare `--snapshot`/
  `--menubar` binary, so the constants keep every entry point identical. Tint via
  `.renderingMode(.template).foregroundStyle(color)` — works both in-app and
  inside the ImageRenderer-composited menu-bar label. Regenerate with
  `scripts/regen-brand-marks.sh` (fetches the Simple Icons SVGs, rasterizes via
  `qlmanage -t -s 128`, converts black-on-white → alpha mask `alpha = 255 −
  luminance` in a CGContext, base64s, and re-emits `BrandMarks.swift`) — don't
  hand-edit the base64. The heatmap legend tints marks with the richer cell hues
  (`heatHue`), not the flat accent colors, so the key matches the cells.
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
- Pollers: limits/status 5 min, Ollama health + `/api/ps` 10 s, LM Studio status +
  loaded models 30 s. Ollama Desktop DB/WAL observation is vnode-driven and debounced.
  Don't add per-second work.
- **Publish only on significant change.** `updateRuntimeHealth` gates on
  `RuntimeHealth.significantlyDiffers` (excludes the `lastSuccess`/`lastEvent`
  heartbeats — kept in a non-published pulse map, overlaid by the computed
  `runtimeHealth`); `setLoadedModels` gates on `LoadedModel.displayEquals`
  (excludes Ollama's `expiresAt` countdown). Unconditional publishing re-rendered
  the scene — incl. the ImageRenderer menu-bar bitmap — every 10 s poll and took
  idle CPU from ~0.2% to ~2%. If a new poller stamps timestamps, keep them out of
  the published comparison.
- **Never leak the `lms log stream` child.** Three layers, all required: headless
  paths (`--snapshot`/`--menubar`/`--gauges`) never start the LM Studio services
  (side effect: LM Studio's Settings row shows its not-started default in
  snapshots — that's expected, not a bug); the app terminates the child in
  `applicationWillTerminate` AND via a SIGTERM DispatchSource (`pkill -x
  TokenScope` is our own install flow); `ProcessReaper` runs once at startup and
  kills launchd-adopted (`ppid == 1`) strays matching the stream argv — this
  covers SIGKILL/crash. Before these, 28 orphans (~1.6 GB) had accumulated.
- LM Studio spawns are **skipped while the app isn't running**
  (`LMStudioCLI.appIsRunning`, bundle id ai.elementlabs.lmstudio) — the 30 s
  retry cadence itself never stops, so a renamed bundle id degrades gracefully.

## Runtime files

- `~/Library/Application Support/TokenScope/usage-events-v2.jsonl` — versioned,
  compacted journal for non-replayable Ollama proxy, Ollama Desktop metadata, and LM
  Studio observations.
  A legacy `proxy-events.jsonl` is migrated once when the v2 journal is absent.
- `~/Library/Application Support/TokenScope/daily-history.json` — frozen per-day
  aggregates + `completeThrough`; outlives Claude Code's transcript cleanup.
  If absent, it is rebuilt with a one-time backfill (≤366 days) on next launch.
- Codex raw session logs remain in `~/.codex/sessions/**/*.jsonl`; TokenScope
  reads only `session_meta` and `token_count` records, then retains the same
  31-day event window and permanent day aggregates as other local sources. Its
  own persisted watermark drives the one-time ≤366-day history backfill.
- `~/Library/Logs/TokenScope.log` — lifecycle summaries and sanitized diagnostics;
  first place to look when verifying behavior. Per-event logging is deliberately off.
- Ports via `defaults write com.tokenscope ProxyPort|OllamaPort -int N`
  (defaults 11435 → 11434).
