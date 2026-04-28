import SwiftUI

struct ContentView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("shadowTunnel")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("History") {
                    viewModel.showHistory()
                }
                Button("Settings") {
                    viewModel.isSettingsPresented = true
                }
                Button("Close") {
                    viewModel.closePanel()
                }
            }

            GroupBox {
                KeyboardSubmitTextView(
                    text: $viewModel.selectedText,
                    fontSize: viewModel.userSettings.fontSize,
                    onSubmit: viewModel.performPrimarySubmitAction
                )
                    .frame(minHeight: 100, maxHeight: 180)
            } label: {
                Text("Selected Text")
            }

            HStack(spacing: 12) {
                selectableActionButton("trans", action: .translate)
                selectableActionButton("quickSearch", action: .searchQuick)
                selectableActionButton("search", action: .searchDetailed)
                selectableActionButton("summarize", action: .summarize)
                selectableActionButton("subtitles", action: .subtitles)

                Spacer()
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(viewModel.resultProviderLabel)
                            .font(.system(size: max(11, viewModel.userSettings.fontSize - 1), weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(viewModel.resultLatencyLabel)
                            .font(.system(size: max(11, viewModel.userSettings.fontSize - 1), weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Copy") {
                            viewModel.copyFormattedResultToPasteboard()
                        }
                        .keyboardShortcut("c", modifiers: [.command, .shift])
                    }

                    Divider()

                    ScrollView {
                        Text(viewModel.formattedResultBody.isEmpty ? "(no result)" : viewModel.formattedResultBody)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .enableTextSelectionIfAvailable()
                            .font(.system(size: viewModel.userSettings.fontSize + 1))
                            .lineSpacing(5)
                    }
                }
                .frame(minHeight: 180, maxHeight: .infinity)
            } label: {
                Text("Result")
            }

            if viewModel.lastAction == "translate", !viewModel.resultText.isEmpty {
                HStack {
                    Button("Speak") {
                        viewModel.speakTranslation()
                    }
                    Button("Save") {
                        viewModel.saveCurrentTranslation()
                    }
                    .disabled(!viewModel.canSaveCurrentTranslation)
                    if !viewModel.translationSaveMessage.isEmpty {
                        Text(viewModel.translationSaveMessage)
                            .font(.footnote)
                            .foregroundColor(viewModel.translationSaveMessage == "Saved" ? .green : .secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .onAppear {
            viewModel.reloadConfig()
        }
        .sheet(isPresented: $viewModel.isSettingsPresented) {
            SettingsView(viewModel: viewModel)
                .frame(width: 700, height: 560)
        }
    }

    private func selectableActionButton(_ title: String, action: OverlayViewModel.SubmitAction) -> some View {
        let isSelected = viewModel.selectedSubmitAction == action
        return Button {
            viewModel.triggerSubmitAction(action)
        } label: {
            Text(title)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundColor(isSelected ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    @ViewBuilder
    func enableTextSelectionIfAvailable() -> some View {
        if #available(macOS 12.0, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}
