# CLAUDE.md

TokenScope is a macOS menu bar app (SwiftPM, SwiftUI `MenuBarExtra`) that meters
LLM token usage — live, per call, per session, per day — for Claude Code (native
Anthropic or pointed at Ollama) and for any Ollama client routed through its
local proxy. See `docs/ARCHITECTURE.md` for the full design.

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
- `ollama` provider classification is just `model.hasPrefix("claude")` → claude,
  else ollama. Transcript `model == "<synthetic>"` lines are skipped.

## Runtime files

- `~/Library/Application Support/TokenScope/proxy-events.jsonl` — persisted
  proxy observations (compacted to 31 days at load).
- `~/Library/Application Support/TokenScope/daily-history.json` — frozen per-day
  aggregates + `completeThrough`; outlives Claude Code's transcript cleanup.
  Deleting it triggers a fresh one-time backfill (≤366 days) on next launch.
- `~/Library/Logs/TokenScope.log` — every ingested event and lifecycle step;
  first place to look when verifying behavior.
- Ports via `defaults write com.baysora.tokenscope ProxyPort|OllamaPort -int N`
  (defaults 11435 → 11434).
