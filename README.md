# TokenScope

macOS menu bar app showing local LLM token usage — per call, per session, per day —
for **Claude Code**, **Codex**, and **Ollama**, plus optional **claude.ai** and
experimental **ChatGPT** plan-limit views and Anthropic service status.

## How it measures

Token usage comes from two independent sources, reconciled automatically:

1. **Claude Code transcripts** (`~/.claude/projects/**/*.jsonl`). Every API response
   Claude Code receives is logged there with exact `usage` counts (input, output,
   cache read, cache write), the session ID, and the project directory. TokenScope
   tails these files once a second. This covers native Anthropic usage *and* Claude
   Code pointed at Ollama — no configuration needed. On launch it replays today's
   transcripts so the day's history is populated immediately. Session names are
   Claude Code's own auto-generated titles (the ones you see in `/resume`).

2. **Codex session telemetry** (`~/.codex/sessions/**/*.jsonl`). TokenScope reads
   only Codex `token_count` records: input, cached input, output, reasoning-output,
   and the currently observed quota windows. Prompts, replies, and tool payloads are
   never retained. This covers local Codex app/CLI sessions without a Cookie.

3. **Local Ollama proxy** (`127.0.0.1:11435 → 127.0.0.1:11434`). A transparent TCP
   relay that parses token counts out of responses as they stream — Ollama-native,
   OpenAI-format, and Anthropic-format alike. This is what gives you the **live,
   while-it's-generating** counter, and it captures Ollama clients that aren't
   Claude Code (`ollama run`, scripts, other apps). When the same call is seen by
   both sources (Claude Code routed through the proxy), the proxy copy is shadowed
   so totals count it once.

Two more panels track things tokens alone don't tell you (features adapted from
[ClaudeUsageBar](https://github.com/Artzainnn/ClaudeUsageBar)):

4. **claude.ai plan limits** (optional). Paste your claude.ai Cookie header in Settings and
   the Now tab shows your 5-hour session and 7-day weekly utilization as
   color-coded bars with reset countdowns, and alerts you at 25/50/75/90%. This is
   the "how close am I to being throttled" view. Uses an unofficial claude.ai
   endpoint; the cookie is stored locally and sent only to claude.ai.

5. **ChatGPT web limits** (experimental, optional). Paste a ChatGPT Cookie header
   and TokenScope queries ChatGPT's private usage surface for whatever limit windows
   it returns. This is intentionally limits-only: ChatGPT web conversations do not
   provide a reliable local per-chat token transcript. The endpoint may change.

6. **Service status**. Polls Anthropic's public status page so you can tell "is it
   me, or is Claude down?" — shown in the footer, with optional change alerts.

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

The window separates the two things it measures by **scope**:

- **claude.ai limits** (always-visible header) — your session (5h) and weekly (7d)
  utilization as color-coded bars (green < 70%, gradient to yellow by 80%, to red
  by 90%) with reset countdowns and a refresh button, or a "Connect claude.ai"
  prompt if no cookie is set. Labeled *whole account* because it covers claude.ai
  web + desktop + Claude Code (but not Ollama). A click away in the four tabs is
  everything denominated in **local tokens** (Claude Code + Ollama on this Mac):

- **Activity** — *Live*: in-flight calls with a growing output counter (proxy
  streams update live; Anthropic-format streams count chunks until the exact total
  lands at message end), plus the Ollama model resident in memory and its VRAM.
  *Latest calls*: the 8 most recent (time, provider dot, model,
  `↑ input (+cache read) ↓ output`), not period-scoped.
- **Usage** — obeys the Today / 7 Days / 30 Days picker (with a source caption):
  the bar chart (per **hour** for Today, per **day** otherwise; future slots blank)
  with a Stacked ↔ Grouped toggle, "Hide weekends" filter, and a dashed kernel-
  regression trendline; provider totals with per-model breakdown; sessions (green
  dot = active in the last 15 min; named with Claude Code's own `/resume` titles).
- **History** — GitHub-style 6-month heatmap with month labels. Cell hue marks the
  dominant local source (orange = Claude Code, purple = Codex, blue = Ollama);
  opacity carries the day's volume. Days that age out of the 31-day live window
  fold permanently into `daily-history.json`, which outlives Claude Code's own
  transcript cleanup, so this fills in over time.
- **Settings** — paste claude.ai and optional ChatGPT Cookie headers; choose what the **menu bar
  shows** (any of session limit %, weekly limit %, daily token count); toggle
  limit/status notifications; and show/hide any section.

The title-bar headline shows today's local tokens split by source (orange Claude
Code / purple Codex / blue Ollama) rather than one merged total.

The **footer** (always visible) shows Anthropic service status on the left and the
proxy on the right. The **menu bar gauge** tints green/yellow/red to your nearest
limit (or the service-status color). By default the menu bar shows today's total
tokens (a live `↓` counter while a call streams through the proxy); enable session
and/or weekly limit % in Settings to show those too — each colored green < 70%,
yellow < 90%, red ≥ 90%.

Proxy events persist in `~/Library/Application Support/TokenScope/proxy-events.jsonl`.

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
- Codex token counts are observed from local session telemetry. ChatGPT web limits
  are an unsupported Cookie-based integration and may need reconnecting after web
  changes or session expiry.
