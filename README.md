# WebSearch

A tiny web search engine, built on the [LocalLM Lab SDK](https://github.com/ancientcomputing/locallm).
Give it a topic, get back 5 web pages about it — and keep refining the same search
conversationally, chat-style.

Two targets, sharing the same idea:

- **`WebSearch`** — a `swift run` CLI. Apple's on-device model only, one search, no history.
- **`WebSearchApp`** — a SwiftUI `.app`. Chat-style transcript of past searches (scrolls up,
  keeps the last 100), Tavily's key in the Keychain, and a runtime model picker (on-device or
  any hosted provider — GPT, Claude, OpenRouter — via `Components`' settings panel).

## WebSearchApp (the SwiftUI app)

```bash
brew install xcodegen   # once
xcodegen generate
open WebSearchApp.xcodeproj    # Run
```

First launch shows a blocking "Connect Tavily" sheet — get a key at
[app.tavily.com](https://app.tavily.com) (`tvly-...`) and paste it in. It's stored via
`MCPServerManager`'s own Keychain-backed PAT store (see
[`locallm/docs/mcp-tavily.md`](locallm/docs/mcp-tavily.md)), not in a file — the app only
persists the server's shape (URL, which tool is enabled) so it can reconnect next launch without
asking again.

Pick a model from the toolbar picker — Apple on-device by default; add a hosted provider (API
key, also Keychain-backed) via the gear icon → Settings, same `AIModelsSettingsView` panel as the
SDK's `model-switch` example.

**Conversational search.** Type a topic, get 5 links. Keep typing in the same box to narrow the
same search — "just her music career," "more recent" — and the model sees the earlier turns of
that topic when it re-runs `tavily_search`, so it can pick a better query than your literal words.
When you type something the model judges unrelated to the current topic, it closes that thread
and starts a fresh one with no memory of the last topic — that's the one classification call
`AppModel.classify(query:)` makes before every turn after the first. Every topic thread (and its
turns) is kept in the scrolling history, oldest at the top, capped at the last 100 threads.

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
  .pat` — a static Bearer API key, no OAuth round-trip. Only `tavily_search` is enabled; Tavily
  also offers `tavily_extract`/`crawl`/`map`, but those assume a starting URL this task never has,
  and less schema means a more reliable tool call from a small model.
- The system prompt pins `tavily_search`'s own arguments (`max_results: 5`, `search_depth:
  "basic"`) rather than leaving the model to guess.
- Output is structured (`@Generable SearchResults`), not prose — the result is always exactly 5
  `(title, url)` pairs, never something the caller has to re-parse for links.
- `WebSearchApp` drives everything through `LocalLMLab` (`LocalLMLabSDKCore` +
  `LocalLMLabSDKComponents` + `LocalLMLabSDKRemote`): `lab.mcp` is the same `MCPServerManager` the
  CLI uses directly, `lab.models` handles routing between on-device/hosted models, and
  `lab.makeSession` assembles a session's tools from whichever MCP tools are enabled — no manual
  `MCPTool` wiring needed once `tavily_search` is enabled.
- A topic thread owns one real `LanguageModelSession`. Refining a search reuses it (the model
  sees prior turns); switching topics discards it for a fresh one. The classification call that
  tells them apart runs on its own disposable session so it never pollutes the thread's own
  transcript.

## Repo layout

- `Package.swift` — CLI target (`WebSearch`) + the `LocalLMLabSDKRemote` binary the app needs.
- `Sources/WebSearch/` — the CLI.
- `Sources/WebSearchApp/`, `project.yml`, `WebSearchApp.xcodeproj/`, `xcodeproj/` — the SwiftUI
  app (generated via `xcodegen`; regenerate after editing `project.yml`, not the `.xcodeproj`
  directly).
- `locallm/` — a local clone of the SDK repo (docs, examples, `locallm/Components` — the
  Components package the app depends on — and the Claude Code skill under
  `locallm/skills/locallmlab-swift-app/`), gitignored here since it's a separate repo kept only
  as a local reference.
