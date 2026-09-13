# LocalLM Lab SDK feedback — from building WebSearch

Three gaps surfaced by real friction while building `WebSearchApp` (a SwiftUI search app: Apple
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

## 3. `DownloadableModelProvider` has no way to cancel an in-progress download

The full protocol:

```swift
protocol DownloadableModelProvider: ModelProvider {
    var installed: [InstalledModel] { get }
    func download(_ repoID: String) -> AsyncThrowingStream<DownloadEvent, any Error>
    func validate(_ repoID: String) async throws -> PreflightResult
    func capabilityProbe(_ id: ModelID) async -> ModelCapabilityReport
    func remove(_ id: ModelID) throws
    var storageUsed: Int64 { get }
    var residencyEventStream: AsyncStream<ResidencyEvent>? { get }
}
```

`remove(_:)` deletes an *installed* model's weights — it's not usable mid-download, and there's no
other call that is. We added a "Cancel" button to our download-progress sheet (triggered the first
time our default summary model isn't downloaded yet) and initially implemented it as a plain
boolean flag our own consuming loop checked between stream events. Confirmed live that this doesn't
work: the flag only stopped *us* from waiting on the `AsyncThrowingStream`, not the actual
background fetch, which kept running unattended and finished on its own — the very next attempt
found the model already installed, with no download prompt at all, as if cancel had silently done
nothing.

We since switched to wrapping the consumption in a real `Task<Bool, Never>` and calling `.cancel()`
on it, which is the idiomatic mechanism such an API is generally *expected* to cooperate with (an
`AsyncThrowingStream` backed by a network transfer would typically tie cleanup to the consuming
task's cancellation). But this is an assumption on our part, not a documented guarantee — nothing
in the SDK's reference confirms `download(_:)`'s internal implementation actually aborts the
transfer when the caller's `Task` is cancelled, versus continuing to fetch into a stream nobody is
listening to anymore.

**Suggested fix:** an explicit, documented cancel path — either a `cancelDownload(_ id: ModelID)`
method on `DownloadableModelProvider`, or documentation confirming that cancelling the `Task`
consuming `download(_:)`'s stream is guaranteed to abort the underlying transfer (not just stop
local consumption of it).

## Context for all three

All three came from a single small app with one tool and one route. None is a "we couldn't figure
out the API" complaint — the workarounds are small and were straightforward to write once each gap
was clear. They're flagged because the underlying capabilities (a tool call's real arguments/
result; "prefer no reasoning" as a preference rather than a hard requirement; actually cancelling a
download) seem generally useful beyond this app, not specific to Tavily or search.
