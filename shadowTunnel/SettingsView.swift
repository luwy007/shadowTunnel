import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    leftColumn
                    rightColumn
                }
                .frame(maxWidth: .infinity, alignment: .top)
                .padding(.bottom, 8)
            }
        }
        .padding(20)
        .onAppear {
            viewModel.reloadConfig()
            viewModel.syncSupadataAPIKeyInput()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    viewModel.isSettingsPresented = false
                }
            }
        }
        .sheet(isPresented: $viewModel.isHotkeyRecorderPresented) {
            HotKeyRecorderView { config in
                viewModel.applyHotkey(config)
                viewModel.isHotkeyRecorderPresented = false
            } onCancel: {
                viewModel.isHotkeyRecorderPresented = false
            }
            .frame(width: 360, height: 160)
            .padding(16)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Text("Adjust behavior, providers, and integrations. Text fields save immediately unless a card has an explicit save button.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button {
                viewModel.isSettingsPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "General", subtitle: "Display and quick access.") {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Font Size")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text("\(Int(viewModel.userSettings.fontSize)) pt")
                                .font(.footnote.weight(.medium))
                                .foregroundColor(.secondary)
                        }

                        Slider(
                            value: Binding(
                                get: { viewModel.userSettings.fontSize },
                                set: { viewModel.userSettings.fontSize = $0 }
                            ),
                            in: 11...20,
                            step: 1
                        )
                        .controlSize(.small)
                    }

                    Divider()

                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hotkey")
                                .font(.subheadline.weight(.medium))
                            Text("Current shortcut")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text(viewModel.hotkeyString)
                            .font(.system(.footnote, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color(NSColor.windowBackgroundColor))
                            )

                        Button("Set Hotkey") {
                            viewModel.isHotkeyRecorderPresented = true
                        }
                        .controlSize(.small)
                    }
                }
            }

            settingsCard(title: "Open Behavior", subtitle: "Control what happens when the panel appears.") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(
                        "Translate automatically when opening the panel",
                        isOn: Binding(
                            get: { viewModel.userSettings.autoTranslateOnOpen },
                            set: { viewModel.userSettings.autoTranslateOnOpen = $0 }
                        )
                    )
                    hintText("When enabled, newly selected text is translated as soon as the panel opens.")
                }
            }

            settingsCard(title: "Translation Save File", subtitle: "Store short translations for vocabulary review.") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(
                        "Translation save file path",
                        text: Binding(
                            get: { viewModel.userSettings.translationSaveFilePath },
                            set: { viewModel.userSettings.translationSaveFilePath = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    hintText("When translating a word or short phrase, the app appends one line as `source=translation`.")
                    hintText("Use an absolute path or `~/...`, for example `/Users/yourname/Documents/shadowTunnel-vocab.txt`.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsCard(title: "Provider", subtitle: "Choose the active provider and manage its API key.") {
                VStack(alignment: .leading, spacing: 10) {
                    if viewModel.providers.isEmpty {
                        hintText("No providers available. Check `Providers.example.json`.")
                    } else {
                        Text("Active Provider")
                            .font(.subheadline.weight(.medium))
                        Picker("Provider", selection: $viewModel.selectedProviderId) {
                            ForEach(viewModel.providers, id: \.id) { provider in
                                Text(provider.id).tag(provider.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: viewModel.selectedProviderId) { _ in
                            viewModel.syncApiKeyInput()
                            viewModel.saveSelectedProviderAsDefault()
                        }

                        SecureField("API Key", text: $viewModel.apiKeyInput)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
                            Button("Save API Key") {
                                viewModel.saveApiKey()
                            }
                            if !viewModel.apiKeySavedMessage.isEmpty {
                                statusText(viewModel.apiKeySavedMessage)
                            }
                            Spacer()
                        }
                    }
                }
            }

            if viewModel.hasProviderSelected() {
                settingsCard(title: "Model", subtitle: "Fine-tune the model used by the current provider.") {
                    VStack(alignment: .leading, spacing: 10) {
                        if !viewModel.modelOptions.isEmpty {
                            Text("Suggested Models")
                                .font(.subheadline.weight(.medium))
                            Picker("Suggestions", selection: $viewModel.modelSelection) {
                                ForEach(viewModel.modelOptions, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }

                        if viewModel.selectedProviderType == .doubao {
                            hintText("Doubao usually requires endpoint ID as model, for example `ep-xxxxxx`.")
                        }

                        TextField(viewModel.modelInputPlaceholder, text: $viewModel.modelSelection)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 10) {
                            if !viewModel.modelOptions.isEmpty {
                                Button("Use Suggested Model") {
                                    guard let first = viewModel.modelOptions.first else { return }
                                    viewModel.modelSelection = first
                                }
                            }
                            Spacer()
                            Button("Save Model") {
                                viewModel.saveModelSelection()
                            }
                            if !viewModel.modelSavedMessage.isEmpty {
                                statusText(viewModel.modelSavedMessage)
                            }
                        }
                    }
                }
            }

            settingsCard(title: "Supadata", subtitle: "Used for YouTube transcript fetching and subtitle coverage.") {
                VStack(alignment: .leading, spacing: 10) {
                    SecureField("Supadata API Key", text: $viewModel.supadataAPIKeyInput)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 10) {
                        Button("Save Supadata Key") {
                            viewModel.saveSupadataAPIKey()
                        }
                        if !viewModel.supadataAPIKeySavedMessage.isEmpty {
                            statusText(viewModel.supadataAPIKeySavedMessage)
                        }
                        Spacer()
                    }

                    hintText("Sent with the `x-api-key` header when requesting transcripts.")
                    hintText("The app uses Supadata `GET /v1/transcript` with `mode=auto` for better YouTube subtitle coverage.")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func settingsCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.secondary)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundColor(.green)
    }
}
