# TokenScope

macOS menu bar app showing live LLM token usage — per call, per session, per day —
for both **native Claude (Claude Code)** and **Ollama**.

## How it measures

Two independent sources, reconciled automatically:

1. **Claude Code transcripts** (`~/.claude/projects/**/*.jsonl`). Every API response
   Claude Code receives is logged there with exact `usage` counts (input, output,
   cache read, cache write), the session ID, and the project directory. TokenScope
   tails these files once a second. This covers native Anthropic usage *and* Claude
   Code pointed at Ollama — no configuration needed. On launch it replays today's
   transcripts so the day's history is populated immediately.

2. **Local Ollama proxy** (`127.0.0.1:11435 → 127.0.0.1:11434`). A transparent TCP
   relay that parses token counts out of responses as they stream — Ollama-native,
   OpenAI-format, and Anthropic-format alike. This is what gives you the **live,
   while-it's-generating** counter, and it captures Ollama clients that aren't
   Claude Code (`ollama run`, scripts, other apps). When the same call is seen by
   both sources (Claude Code routed through the proxy), the proxy copy is shadowed
   so totals count it once.

## Build & run

```sh
./build-app.sh
open TokenScope.app
```

To keep it across logins: System Settings → General → Login Items → add TokenScope.app
(copy it to /Applications first if you like).

## Routing traffic through the proxy

**Claude Code → Ollama** (gets you live streaming counts; there's a "Copy env" button
in the menu too):

```sh
export ANTHROPIC_BASE_URL=http://127.0.0.1:11435
export ANTHROPIC_AUTH_TOKEN=ollama
claude --model gemma4:12b-mlx
```

(Without the proxy — `ANTHROPIC_BASE_URL=http://127.0.0.1:11434` — usage still shows
up via the transcripts, just not live during generation.)

**Any other Ollama client:**

```sh
export OLLAMA_HOST=127.0.0.1:11435
ollama run gemma4:12b-mlx
```

**Native Claude Code:** nothing to do. Transcripts are watched automatically.

## Reading the menu

The menu is four zones, top to bottom by immediacy, each answering one question:

- **Now** — what's happening this second: in-flight calls with a growing output
  counter (proxy streams update live; Anthropic-format streams count chunks until
  the exact total arrives at message end), plus which Ollama model is resident in
  memory and its VRAM. Shows "Idle" when nothing is streaming.
- **Usage** — everything in this zone obeys the Today / 7 Days / 30 Days picker in
  its header: the bar chart (per **hour** for Today, per **day** otherwise; future
  slots are blank), provider totals with per-model breakdown, and sessions (green
  dot = active in the last 15 minutes; direct Ollama traffic groups under "Ollama
  (direct)"). The chart toggles Stacked ↔ Grouped via the mini control — Stacked
  scales to combined totals, Grouped scales per-provider so orange and blue bars
  compare directly.
- **Latest calls** — the 8 most recent calls (time, provider dot, model,
  `↑ input (+cache read) ↓ output`), deliberately *not* period-scoped.
- **Last 6 months** — GitHub-style heatmap with month labels. Cell hue mixes the
  provider colors by that day's share (orange = all Claude, blue = all Ollama,
  amber/violet in between); opacity carries the day's volume. Hover any cell for
  the exact split. Days that age out of the 31-day live window fold permanently
  into `~/Library/Application Support/TokenScope/daily-history.json`, which
  outlives Claude Code's own transcript cleanup, so this fills in over time.

The menu bar itself shows today's total tokens (input + output, cache excluded),
switching to a live `↓` counter while a call streams through the proxy. Proxy
events persist in `~/Library/Application Support/TokenScope/proxy-events.jsonl`.

## Settings

Defaults: listen 11435, upstream 11434. Override with:

```sh
defaults write com.baysora.tokenscope ProxyPort -int 11435
defaults write com.baysora.tokenscope OllamaPort -int 11434
```

Events are also appended to `~/Library/Logs/TokenScope.log` for debugging.

## Notes

- Retention is 31 days: transcript history is replayed from disk on every launch,
  proxy-only events are persisted and reloaded, and anything older is dropped.
- "Native Claude" per-call usage appears when each message completes — the
  Anthropic API only reports usage in the response, so there is no mid-call
  counter for direct Anthropic traffic.
