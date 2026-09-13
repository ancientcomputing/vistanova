# LocalLM Lab SDK feedback — from building WebSearch

Two gaps surfaced by real friction while building `WebSearchApp` (a SwiftUI search app: Apple
on-device or a downloaded MLX model drives one `tavily_search` MCP tool call). Not requests in the
abstract — each one is a workaround we actually had to write, in a small app with exactly one tool
and one route.

## 1. `session.events`'s tool-call cases carry no arguments or result

`LocalLMLabSession.events` gives `.toolCallStarted(id, name)` / `.toolCallFinished(id, name,
failed)` — enough to know *that* a tool ran, never *what it was called with* or *what it
returned*.

That was a real problem for us: we needed to show the user what search query the model actually
sent to `tavily_search` (it can legitimately differ from what they typed — combining context, or
just phrasing it differently). There was no way to get that from `events`, so we dropped the
auto-assembled `MCPTool` (Path A) entirely and hand-wrote a Path B wrapper
(`TavilySearchTool`) whose only real job is recording its own `Arguments` into an actor
(`SearchQueryCapture`) before forwarding the call to `MCPServerManager.callTool`. That's a
non-trivial amount of code — a whole extra file — to answer "what did the tool actually get
called with," which feels like something the event stream should carry for free.

If `.toolCallStarted`/`.toolCallFinished` (or a new case) carried the tool's arguments and a
lightweight result summary, this would go away — including for **Path A** callers, who currently
have no way to inspect a `MCPTool`'s calls at all short of writing their own wrapper the way we
did.

**Suggested shape**, roughly:

```swift
case toolCallStarted(id: String, name: String, arguments: String)   // JSON-ish rendering is fine
case toolCallFinished(id: String, name: String, failed: Bool, resultSummary: String?)
```

## 2. `effort: .off` hard-throws for always-reasoning models instead of no-op'ing

Documented behavior, not a bug: a Qwen3-family model's `<think>…</think>` block is suppressed by
`SessionOptions(effort: .off)`, but a model that always reasons (DeepSeek-R1 and its distills)
throws `unsupportedCapability` instead of silently ignoring the request.

That means every caller who wants "minimize/suppress thinking where possible, don't care where
it isn't" has to hand-roll the same try/catch fallback:

```swift
private func makeSessionSuppressingThinking(...) throws -> LocalLMLabSession {
    do {
        return try lab.makeSession(..., options: .init(effort: .off))
    } catch {
        return try lab.makeSession(...)   // no effort option — some models can't honor .off at all
    }
}
```

This is exactly the kind of boilerplate a "best effort" semantic should absorb. Two options that'd
both remove it:

- A new value, e.g. `Effort.offIfSupported`, that behaves like `.off` where the model can honor it
  and is silently `nil` (provider default) where it can't — never throws.
- Or: have `.off` itself never throw, and expose "did the model actually suppress reasoning" as an
  out-of-band signal (a `session` property, or a `.events` case) instead of a thrown error — since
  a caller asking for `.off` is very rarely trying to *require* the guarantee, just prefer it.

## Context for both

Both of these came from a single small app with one tool and one route. Neither is a "we couldn't
figure out the API" complaint — the workarounds are small and were straightforward to write once
the gap was clear. They're flagged because the underlying capability (a tool call's real
arguments/result; "prefer no reasoning" as a preference rather than a hard requirement) seems
generally useful beyond this app, not specific to Tavily or search.
