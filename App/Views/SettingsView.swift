import AppKit
import AssistantKit
import SessionKit
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @State private var keyInput = ""
    @State private var hasKey = KeychainStore.apiKey.load() != nil
    @State private var keyError: String?

    var body: some View {
        Form {
            Section("Claude") {
                // The stored key is never read back into the UI; only whether one exists.
                SecureField("Anthropic API key", text: $keyInput)
                    .onSubmit(saveKey)
                HStack {
                    Button("Save", action: saveKey)
                        .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove", role: .destructive, action: removeKey)
                        .disabled(!hasKey)
                    Spacer()
                    if let keyError {
                        Text(keyError).foregroundStyle(.red)
                    } else {
                        Label(hasKey ? "Saved" : "Not set",
                              systemImage: hasKey ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(hasKey ? .green : .secondary)
                    }
                }
                Text("Stored in your macOS Keychain. Used for questions and notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Model", selection: $settings.model) {
                    ForEach(ClaudeModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Picker("Notes effort", selection: $settings.notesEffort) {
                    Text("High").tag("high")
                    Text("Medium").tag("medium")
                    Text("Low").tag("low")
                }
                Text("Most of the cost is the notes: Claude's thinking and the written notes are billed as output. Medium effort thinks less and costs less; Sonnet 5.5 costs half as much as Opus 5.5. Each session folder has a usage.md with what it cost.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Sessions") {
                LabeledContent("Output folder") {
                    HStack {
                        Text(settings.outputFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Re-transcribe full audio after stopping", isOn: $settings.retranscribeAfterStop)
                Toggle("Show floating transcript panel", isOn: $settings.showFloatingPanel)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }

    private func saveKey() {
        do {
            try KeychainStore.apiKey.save(keyInput)
            keyInput = ""
            keyError = nil
            hasKey = true
        } catch {
            keyError = "Could not save the key (\(error))."
        }
    }

    private func removeKey() {
        do {
            try KeychainStore.apiKey.delete()
            keyError = nil
            hasKey = false
        } catch {
            keyError = "Could not remove the key (\(error))."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.outputFolder
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.outputFolder = url
        }
    }
}
