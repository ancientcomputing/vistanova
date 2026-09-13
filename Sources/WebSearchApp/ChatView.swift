import SwiftUI
import AppKit
import LocalLMLabSDKCore

private extension View {
    /// `Link` gives no visual cursor feedback on macOS by default — show the pointing hand a
    /// clickable URL implies.
    func pointingHandCursor() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

@available(macOS 27, *)
struct ChatView: View {
    @Bindable var model: AppModel
    @State private var showingTavilySetup = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            composer
        }
        .sheet(isPresented: .constant(!model.tavilyConfigured)) {
            TavilySetupView(model: model)
                .interactiveDismissDisabled()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Picker("Model", selection: $model.selectedModel) {
                ForEach(model.availableModels, id: \.rawValue) { id in
                    Text(id.rest.isEmpty ? id.scheme : "\(id.scheme): \(id.rest)").tag(id)
                }
            }
            .frame(maxWidth: 280)
            .onChange(of: model.selectedModel) { _, _ in
                model.persistSelectedModel()
                model.endActiveThread()
            }

            if !model.tavilyConnected {
                Label("Tavily not connected", systemImage: "exclamationmark.triangle")
                    .font(AppFont.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()
            SettingsLink { Label("Settings", systemImage: "gearshape") }
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(model.threads) { thread in
                        ThreadView(thread: thread)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: model.threads) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = model.lastError {
                Text(error).font(AppFont.caption).foregroundStyle(.red)
            }
            HStack {
                TextField("Search…", text: $model.input, axis: .vertical)
                    .font(AppFont.body)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { Task { await model.send() } }
                    .disabled(!model.tavilyConnected || model.isSearching)
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await model.send() }
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || !model.tavilyConnected)
                }
            }
        }
        .padding(10)
    }
}

@available(macOS 27, *)
private struct ThreadView: View {
    let thread: TopicThread

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.title)
                .font(AppFont.headline)
            ForEach(thread.turns) { turn in
                TurnView(turn: turn)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }
}

@available(macOS 27, *)
private struct TurnView: View {
    let turn: SearchTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // What was actually sent to tavily_search, not the user's literal input — that's
            // already shown once, either as the thread's own header (first turn) or was typed a
            // moment ago (later turns); repeating it here read as a bug, not a feature.
            Text(turn.searchQuery ?? turn.query)
                .font(AppFont.subheadline).italic()
                .foregroundStyle(.secondary)
            ForEach(turn.links) { link in
                Link(destination: URL(string: link.url) ?? URL(string: "https://example.com")!) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.title)
                            .font(AppFont.body)
                            .underline()
                            .foregroundStyle(.blue)
                        Text(link.url)
                            .font(AppFont.caption2)
                            .underline()
                            .foregroundStyle(.blue.opacity(0.8))
                    }
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
