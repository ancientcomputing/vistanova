import SwiftUI

@available(macOS 27, *)
struct TavilySetupView: View {
    @Bindable var model: AppModel
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connect Tavily").font(.title2).bold()
            Text("WebSearch uses Tavily's search API to find pages about your topic. Get a key at \(Text("app.tavily.com").underline())")
            SecureField("tvly-…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(connect)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func connect() {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        isConnecting = true
        error = nil
        Task {
            let failure = await model.connectTavily(apiKey: key)
            isConnecting = false
            error = failure
        }
    }
}
