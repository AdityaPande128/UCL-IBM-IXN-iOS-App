import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var speak = true
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Toggle("Spoken replies", isOn: $speak)
                        .onChange(of: speak) { model.setSpeakReplies($0) }
                    Picker("Voice", selection: voiceBinding) {
                        ForEach(kokoroVoices, id: \.0) { id, label in
                            Text(label).tag(id)
                        }
                    }
                }
                Section("Mac") {
                    LabeledContent("Name",
                                   value: model.macName.isEmpty ? "—" : model.macName)
                    LabeledContent("Theme", value: model.macTheme)
                    LabeledContent("Address",
                                   value: "\(model.prefs.host):\(model.prefs.port)")
                }
                Section {
                    Button("Unpair from this Mac", role: .destructive) {
                        confirmUnpair = true
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { speak = model.prefs.speakReplies }
            .confirmationDialog("Unpair from this Mac? The pairing token and "
                                + "secret are deleted from this phone.",
                                isPresented: $confirmUnpair,
                                titleVisibility: .visible) {
                Button("Unpair", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
            }
        }
        .tint(Palette.accent)
    }

    private var voiceBinding: Binding<String> {
        Binding(get: { model.currentVoice }, set: { model.setVoice($0) })
    }
}
