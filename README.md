# WebSearch

A tiny web search engine: give it a topic, get back 5 web pages about it.

Built on the [LocalLM Lab SDK](https://github.com/ancientcomputing/locallm) — Apple's on-device
model (`SystemLanguageModel`) drives one `tavily_search` MCP tool call and returns a structured
list of 5 `(title, url)` results. Same reference shape as the SDK's own
[`repo-qa`](https://github.com/ancientcomputing/locallm/tree/main/examples/repo-qa) example: a
bare `swift run` CLI, Core linked as a binary framework, no app bundle or signing needed.

## Setup

1. Get a Tavily API key at [app.tavily.com](https://app.tavily.com) (`tvly-...`).
2. macOS 26+ with Apple Intelligence enabled.

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

## How it works

- `MCPServerManager` connects to `https://mcp.tavily.com/mcp/` with `authType: .pat` (Tavily
  accepts a static Bearer API key — no OAuth round-trip, so this works headless from a CLI).
  See [`locallm/docs/mcp-tavily.md`](locallm/docs/mcp-tavily.md) for how that auth path and
  `tavily_search`'s schema were verified against the live server.
- Only `tavily_search` is built into a `Tool` (via `MCPTool`, straight from the server's own
  live JSON Schema) — Tavily also offers `tavily_extract`/`tavily_crawl`/`tavily_map`, but those
  assume a starting URL this task never has, and a small on-device model does better with less
  schema to choose from.
- The system prompt pins `tavily_search`'s own `max_results`/`search_depth` arguments (5,
  `"basic"`) rather than leaving the model to guess reasonable defaults.
- `session.respond(to:generating: SearchResults.self)` asks for structured output directly, so
  the result is always a clean 5-item list rather than prose you'd have to re-parse for links.

## Repo layout

- `Package.swift`, `Sources/WebSearch/` — this app.
- `locallm/` — a local clone of the SDK repo (docs, examples, the Claude Code skill under
  `locallm/skills/locallmlab-swift-app/`), gitignored here since it's a separate repo, kept only
  as a local reference.
