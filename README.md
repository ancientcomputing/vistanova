# VistaNova

*The new AltaVista. A brighter web ahead.*

A tiny local-first search engine, built on the [LocalLM Lab SDK](https://github.com/ancientcomputing/locallm).
Give it a topic, get back 5 web pages about it, and refine it yourself — no AI guessing at your
intent.

Two targets, sharing the same idea:

- **`WebSearch`** — a `swift run` CLI. Apple's on-device model only, one search, no history.
- **`VistaNova`** — a SwiftUI `.app`. Chat-style scrolling history (last 100 topic threads),
  Tavily's key in the Keychain (via the SDK's own MCP PAT store), and two independent local model
  choices — a search model (tool-calling reliability matters most, so Apple on-device by default)
  and a summary model (pure text synthesis, no tool call at all, so it defaults to a downloaded
  MLX model instead — see below). No cloud model providers by design: the goal is on-device
  inference with online *search* (Tavily today; a user-configurable choice of search backend —
  Brave, Exa, etc. — is planned but not built yet).

## VistaNova (the SwiftUI app)

```bash
brew install xcodegen   # once
xcodegen generate
open VistaNova.xcodeproj    # Run
```

First launch shows a blocking "Connect Tavily" sheet — get a key at
[app.tavily.com](https://app.tavily.com) (`tvly-...`) and paste it in. It's stored via
`MCPServerManager`'s own Keychain-backed PAT store (see
[`locallm/docs/mcp-tavily.md`](locallm/docs/mcp-tavily.md)), not in a file — the app only
persists the server's shape (URL, which tool is enabled) so it can reconnect next launch without
asking again.

**Two model choices, in Settings only** (no picker in the main window): "Web search" (default:
Apple on-device — reliable tool-calling matters most here) and "Summary" (default:
`mlx-community/Qwen3-4B-4bit`, not downloaded until first use). The first time you click
Summarize with an undownloaded summary model, a progress sheet appears; Cancel skips that one
summary, though the current (1.0.0-beta.4) SDK gives no way to actually abort the in-flight download once started.

**Search is user-refined, not AI-refined.** Type a topic, get 5 links plus the actual query the
model sent to `tavily_search` (shown as a subtitle — it can legitimately differ from what you
typed). The box keeps your text after results land instead of clearing it: edit it in place to
narrow the search ("last ceo" → "yahoo last ceo") and it stays in the same topic thread, or hit
the clear (×) button to start a genuinely new one. An earlier version had the model itself guess
whether a new query continued the topic, silently expanding ambiguous follow-ups using thread
context — confirmed live that this fails exactly where it matters ("last ceo" inside a Yahoo
thread got grounded to Tim Cook), so there's no automatic grounding or classification anymore.

**Summarize.** Below a turn's links, a "Summarize" button asks the model for a 2-3 sentence
paragraph over the snippets `tavily_search` already returned (no extra tool call — Tavily returns
a snippet per result that the search step already captures).

Links are plain `Link`s — clicking one opens your default browser.

## WebSearch (the CLI)

```bash
export TAVILY_API_KEY=tvly-...
swift run WebSearch "Dolly Parton"
```

```
1. Dolly Parton - Wikipedia
   https://en.wikipedia.org/wiki/Dolly_Parton
2. Dolly Parton Official Website
   https://dollyparton.com
...
```

No history, no model picker, one shot — the smallest possible version of the idea, same shape as
the SDK's own [`repo-qa`](locallm/examples/repo-qa) example.

## How it works

- Both targets connect to Tavily's MCP server (`https://mcp.tavily.com/mcp/`) with `authType:
  .pat` — a static Bearer API key, no OAuth round-trip.
- `VistaNova` uses a hand-written `TavilySearchTool` (Path B), not the SDK's auto-assembled
  `MCPTool` — this pins `max_results`/`search_depth` in Swift (the model only ever chooses
  `query`) and lets an actor (`SearchQueryCapture`) record the query argument actually used, which
  `session.events` alone can't expose (see `locallm-sdk-feedback.md`).
- Output is structured (`@Generable SearchResults`) when the model supports guided generation;
  otherwise a plain-text fallback parses `(title, url)` pairs out of unstructured output —
  verified via `searchCapability(_:)`, since not every MLX model supports either guided
  generation or reliable tool-calling.
- `search(...)` watches `session.events` for `.toolCallStarted("tavily_search")` and rejects a
  turn where the model answered from its own training data instead of calling the tool — confirmed
  live that several MLX models will do exactly that despite explicit instructions not to.
- Apple's on-device guardrail can intercept a turn about a real person/sensitive topic even after
  producing a fully valid result; `search(...)` recovers the embedded payload when there's
  something to recover (strict JSON decode, then a lenient regex fallback for cases where the
  decline path drops quote characters) rather than surfacing a dead end for a turn that actually
  worked.
- `VistaNova` drives everything through `LocalLMLab` (`LocalLMLabSDKCore` + `LocalLMLabSDKInference`):
  `lab.mcp` is the same `MCPServerManager` the CLI uses directly, `lab.models` handles routing
  between `SystemModelProvider` and `MLXModelProvider`, and both model choices persist through the
  SDK's own `lab.snapshot()`/`lab.restore(from:)`, not a hand-rolled setting.

## Repo layout

- `Package.swift` — CLI target (`WebSearch`) + the `LocalLMLabSDKInference` (MLX) binary the app
  needs.
- `Sources/WebSearch/` — the CLI.
- `Sources/VistaNova/`, `project.yml`, `VistaNova.xcodeproj/`, `xcodeproj/` — the SwiftUI app
  (generated via `xcodegen`; regenerate after editing `project.yml`, not the `.xcodeproj`
  directly).
