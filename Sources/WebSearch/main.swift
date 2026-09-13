// WebSearch — a standalone LocalLM Lab SDK CLI: give it a topic, get back 5 web pages about it.
// Same shape as the SDK's repo-qa example (Apple's on-device model + MCPTool built at runtime
// from a live server's schema, no OAuth needed), pointed at Tavily instead of Deepwiki — see
// locallm/docs/mcp-tavily.md for how the `.pat` auth path and `tavily_search`'s schema were
// verified against the real server.
//
// Unlike repo-qa's free-form answer, this app asks the model for structured output
// (`@Generable SearchResults`) so the result is always a clean list of (title, url) pairs
// rather than prose the caller would have to re-parse for links.
//
//   export TAVILY_API_KEY=tvly-...
//   swift run WebSearch "Dolly Parton"

import Foundation
import FoundationModels
import LocalLMLabSDKCore

func note(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

@Generable
struct WebPage {
    @Guide(description: "A short, descriptive title for the page")
    let title: String
    @Guide(description: "The page's full URL, starting with http:// or https://")
    let url: String
}

@Generable
struct SearchResults {
    @Guide(description: "Exactly 5 distinct web pages that cover the topic")
    let pages: [WebPage]
}

@available(macOS 26.0, *)
@MainActor
func run() async {
    let query = CommandLine.arguments.dropFirst().joined(separator: " ")
    guard !query.isEmpty else {
        note("usage: swift run WebSearch <topic>")
        exit(1)
    }

    guard let apiKey = ProcessInfo.processInfo.environment["TAVILY_API_KEY"], !apiKey.isEmpty else {
        note("Set TAVILY_API_KEY to your tvly-... key (https://app.tavily.com).")
        exit(1)
    }

    let model = SystemLanguageModel.default
    guard case .available = model.availability else {
        note("On-device model unavailable: \(model.availability)")
        return
    }

    let manager = MCPServerManager()
    note("Connecting to Tavily…")
    let connectResult = await manager.addServer(
        url: URL(string: "https://mcp.tavily.com/mcp/")!,
        displayName: "Tavily",
        authType: .pat,
        patToken: apiKey
    )
    guard case .success(let state) = connectResult else {
        note("Could not connect to Tavily: \(connectResult)")
        return
    }

    // Only tavily_search is offered — see locallm/docs/mcp-tavily.md: with all four of Tavily's
    // tools in scope the on-device model has more schema than it needs for "find pages about X",
    // and tavily_extract/crawl/map assume a starting URL this task never has.
    guard let searchDescriptor = state.tools.first(where: { $0.name == "tavily_search" }) else {
        note("Tavily didn't offer tavily_search.")
        return
    }
    let tools: [any Tool]
    do {
        tools = [try MCPTool(descriptor: searchDescriptor, manager: manager)]
    } catch {
        note("Could not build tavily_search tool: \(error)")
        return
    }

    let session = LanguageModelSession(tools: tools) {
        """
        You are a web search engine. Given a topic, call tavily_search exactly once with \
        max_results set to 5 and search_depth set to "basic", then report back the 5 results \
        tavily_search returned. Do not answer from your own knowledge and do not add commentary \
        beyond the requested titles and URLs.
        """
    }

    note("\nSearching: \(query)\n")

    do {
        let response = try await session.respond(to: query, generating: SearchResults.self)
        for (index, page) in response.content.pages.enumerated() {
            print("\(index + 1). \(page.title)")
            print("   \(page.url)")
        }
    } catch {
        note("Error: \(await GenerationErrorDescription.describe(error))")
    }
}

if #available(macOS 26.0, *) {
    await run()
} else {
    print("Requires macOS 26 or later.")
}
