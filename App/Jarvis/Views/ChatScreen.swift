import SwiftUI
import JarvisKit

struct ChatScreen: View {
    @EnvironmentObject var model: ChatViewModel
    @State private var draft = ""
    @State private var showDrawer = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                if let line = model.busyLine.isEmpty ? nil : model.busyLine {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(line).font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Button("Stop") { model.abort() }
                            .font(.footnote)
                            .tint(Palette.errorText)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                if let proposal = model.proposal {
                    ProposalCard(proposal: proposal)
                }
                composer
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showDrawer = true } label: {
                        Image(systemName: "line.3.horizontal")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    ConnectionChip(state: model.state)
                }
            }
            .sheet(isPresented: $showDrawer) {
                DrawerView(showSettings: $showSettings)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert(model.toast ?? "", isPresented: toastShown) {
                Button("OK", role: .cancel) {}
            }
        }
        .tint(Palette.accent)
    }

    private var title: String {
        guard let active = model.activeConversation,
              let row = model.conversations.first(where: { $0.id == active })
        else { return "Jarvis" }
        return row.title
    }

    private var toastShown: Binding<Bool> {
        Binding(get: { model.toast != nil }, set: { if !$0 { model.toast = nil } })
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.items) { item in
                        BubbleView(item: item)
                            .id(item.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.items) { items in
                guard let last = items.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask Jarvis…", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().strokeBorder(Palette.accent, lineWidth: 1.2))
                .onSubmit(sendDraft)
            Button(action: sendDraft) {
                Image(systemName: "paperplane.fill")
                    .foregroundStyle(Palette.accent)
                    .font(.title3)
            }
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func sendDraft() {
        model.sendIntent(draft)
        draft = ""
    }
}

struct BubbleView: View {
    @EnvironmentObject var model: ChatViewModel
    let item: ChatItem

    var body: some View {
        HStack {
            if item.role == "user" { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .foregroundStyle(item.role == "error" ? Palette.errorText : .primary)
                    .font(item.role == "system" ? .footnote : .body)
                ForEach(item.files) { file in
                    Button {
                        model.download(file)
                    } label: {
                        Label(file.name, systemImage: "doc")
                            .font(.footnote)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(item.role == "user" ? Palette.userBubble
                          : Palette.assistantBubble))
            if item.role != "user" { Spacer(minLength: 40) }
        }
    }
}

struct ProposalCard: View {
    @EnvironmentObject var model: ChatViewModel
    let proposal: Proposal

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(proposal.summary).font(.callout.bold())
            if !proposal.will.isEmpty {
                Text(proposal.will).font(.footnote).foregroundStyle(.secondary)
            }
            if !proposal.estimate.isEmpty {
                Text(proposal.estimate).font(.footnote).foregroundStyle(.secondary)
            }
            HStack {
                Button("Approve") { model.approve(proposal.id, yes: true) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                Button("Deny") { model.approve(proposal.id, yes: false) }
                    .buttonStyle(.bordered)
                    .tint(Palette.errorText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(Palette.userBubble.opacity(0.5)))
        .padding(.horizontal)
    }
}

struct ConnectionChip: View {
    let state: ConnState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption2)
        }
    }

    private var color: Color {
        switch state {
        case .live: return .green
        case .connecting: return .orange
        default: return .red
        }
    }

    private var label: String {
        switch state {
        case .live: return "Connected"
        case .connecting: return "Connecting"
        case .pairRequired: return "Pair again"
        default: return "Offline"
        }
    }
}

struct DrawerView: View {
    @EnvironmentObject var model: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Binding var showSettings: Bool

    var body: some View {
        NavigationStack {
            List {
                Button {
                    model.newChat()
                    dismiss()
                } label: {
                    Label("New chat", systemImage: "plus")
                }
                Section("Chats") {
                    ForEach(model.conversations) { row in
                        Button(row.title) {
                            model.selectConversation(row.id)
                            dismiss()
                        }
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    }
                }
            }
            .navigationTitle(model.macName.isEmpty ? "Jarvis" : model.macName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .tint(Palette.accent)
    }
}
