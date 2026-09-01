import Foundation
import SwiftUI
import JarvisKit

struct ChatItem: Identifiable, Equatable {
    let id = UUID()
    let role: String
    let text: String
    var files: [FileRef] = []
}

struct ConvRow: Identifiable, Equatable {
    let id: Int
    let title: String
}

struct Proposal: Equatable {
    let id: String
    let summary: String
    let will: String
    let estimate: String
}

let kokoroVoices: [(String, String)] = [
    ("af_heart", "Heart, US female"), ("af_bella", "Bella, US female"),
    ("af_nicole", "Nicole, US female"), ("af_sky", "Sky, US female"),
    ("am_adam", "Adam, US male"), ("am_michael", "Michael, US male"),
    ("bf_emma", "Emma, UK female"), ("bf_isabella", "Isabella, UK female"),
    ("bm_george", "George, UK male"), ("bm_daniel", "Daniel, UK male"),
]

// The phone's whole model of the world: one connection, one transcript, the
// conversations list, and whatever question Jarvis is currently asking. The
// Mac's daemon stays the source of truth; this class just keeps up.
@MainActor
final class ChatViewModel: ObservableObject {
    let prefs = Prefs()
    let conn = ConnectionManager()
    private let speaker = Speaker()

    @Published var items: [ChatItem] = []
    @Published var conversations: [ConvRow] = []
    @Published var activeConversation: Int?
    @Published var proposal: Proposal?
    @Published var busy = false
    @Published var busyLine = ""
    @Published var state: ConnState = .disconnected
    @Published var macName = ""
    @Published var macTheme = "dark"
    @Published var currentVoice = "af_heart"
    @Published var toast: String?

    // Messages written while the link was down wait here and go out the
    // moment it returns; nothing typed ever just sits and dies.
    private var outbox: [[String: Any]] = []
    private var pendingPair = false
    private var savedFiles: [String: URL] = [:]

    init() {
        conn.onState = { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                if case .live = newState {
                    if self?.pendingPair == true {
                        self?.pendingPair = false
                        self?.prefs.paired = true
                    }
                    self?.afterConnect()
                } else {
                    self?.busy = false
                    self?.busyLine = ""
                }
            }
        }
        conn.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        conn.onAudio = { [weak self] data in
            Task { @MainActor in self?.speaker.enqueue(data) }
        }
    }

    func connect() {
        guard prefs.paired else { return }
        conn.start(host: prefs.host, port: prefs.port,
                   token: prefs.token, secret: prefs.secret,
                   remoteHost: prefs.remoteHost, remotePort: prefs.remotePort)
    }

    // Store the details and probe; the paired flag is written only when the
    // ladder actually reaches the Mac, so a failed pairing never strands the
    // user in an unreachable chat screen.
    func pair(host: String, port: Int, token: String, secret: String) {
        prefs.host = host
        prefs.port = port
        prefs.token = token
        prefs.secret = secret
        pendingPair = true
        conn.start(host: host, port: port, token: token, secret: secret,
                   remoteHost: prefs.remoteHost, remotePort: prefs.remotePort)
    }

    func disconnect() {
        conn.stop()
    }

    private func afterConnect() {
        if prefs.speakReplies { conn.send(msg("speak_replies", ["on": true])) }
        conn.send(msg("onboarding"))
        // Flush before selecting: each queued message names its own chat, the
        // daemon records it, and the snapshot that follows already shows it.
        while !outbox.isEmpty {
            let queued = outbox[0]
            guard conn.send(queued) else { break }
            outbox.removeFirst()
            if str(queued, "type") == "intent" {
                busy = true
                busyLine = "Thinking…"
            }
        }
        conn.send(msg("conversations_list"))
        if let active = activeConversation {
            conn.send(msg("conversation_select", ["id": active]))
        }
    }

    private func handle(_ event: [String: Any]) {
        switch str(event, "type") {
        case "onboarding_result":
            guard let profile = obj(event, "profile") else { return }
            macTheme = str(profile, "theme") ?? "dark"
            macName = str(profile, "name") ?? ""
            currentVoice = obj(profile, "voice").flatMap { str($0, "voice") } ?? "af_heart"
        case "profile_changed":
            guard let profile = obj(event, "profile") else { return }
            str(profile, "theme").map { macTheme = $0 }
            str(profile, "name").map { macName = $0 }
            obj(profile, "voice").flatMap { str($0, "voice") }.map { currentVoice = $0 }
        case "conversations_result":
            conversations = (arr(event, "conversations") ?? []).compactMap { row in
                guard let convo = row as? [String: Any],
                      let id = int(convo, "id") else { return nil }
                return ConvRow(id: id, title: str(convo, "title") ?? "Chat")
            }
        case "conversation_started":
            guard let id = int(event, "id") else { return }
            activeConversation = id
            conversations.removeAll { $0.id == id }
            conversations.insert(ConvRow(id: id, title: str(event, "title") ?? "Chat"),
                                 at: 0)
        case "conversation_messages":
            activeConversation = int(event, "id")
            items = (arr(event, "messages") ?? []).compactMap { row in
                guard let message = row as? [String: Any] else { return nil }
                return ChatItem(role: str(message, "role") ?? "system",
                                text: str(message, "text") ?? "",
                                files: artifactFiles(obj(message, "artifacts")))
            }
        case "conversation_event":
            handleConversationEvent(event)
        case "intent_accepted":
            busy = true
            busyLine = "Thinking…"
        case "intent_result":
            busy = false
            busyLine = ""
            // A reply born in another chat stays there; the store has it and
            // switching back shows it.
            let home = int(event, "conversation")
            if home == nil || home == activeConversation {
                let text = str(event, "response") ?? str(event, "error") ?? "No response."
                let role = str(event, "status") == "error" ? "error" : "assistant"
                items.append(ChatItem(role: role, text: text,
                                      files: artifactFiles(obj(event, "artifacts"))))
            }
            obj(event, "proposal").map { setProposal($0) }
        case "stt_result":
            items.append(ChatItem(role: "user", text: str(event, "text") ?? ""))
        case "speak_start":
            speaker.begin()
        case "proposal_taken":
            proposal = nil
            speaker.stop()
        case "activity":
            let stage = str(event, "stage") ?? str(event, "event") ?? ""
            if !stage.isEmpty {
                busyLine = describeActivity(source: str(event, "source") ?? "",
                                            stage: stage)
            }
        case "pipeline_error":
            busy = false
            items.append(ChatItem(role: "error",
                                  text: str(event, "error") ?? "Voice failed."))
        case "speech_unavailable":
            items.append(ChatItem(role: "system",
                                  text: str(event, "message") ?? "Text only."))
        case "error":
            busy = false
            items.append(ChatItem(role: "error",
                                  text: str(event, "error") ?? "Something failed."))
        default:
            break
        }
    }

    private func handleConversationEvent(_ event: [String: Any]) {
        guard let convo = obj(event, "conversation"),
              let id = int(convo, "id") else { return }
        switch str(event, "kind") {
        case "started":
            conversations.removeAll { $0.id == id }
            conversations.insert(ConvRow(id: id, title: str(convo, "title") ?? "Chat"),
                                 at: 0)
            appendRemote(event, id)
        case "message":
            if let known = conversations.first(where: { $0.id == id }) {
                conversations.removeAll { $0.id == id }
                conversations.insert(known, at: 0)
            }
            appendRemote(event, id)
        case "proposal":
            obj(event, "proposal").map { setProposal($0) }
        case "deleted":
            conversations.removeAll { $0.id == id }
            if activeConversation == id {
                activeConversation = nil
                items = []
            }
        case "busy":
            if activeConversation == id {
                busy = bool(event, "busy") == true
                busyLine = busy ? "Working on another surface…" : ""
            }
        default:
            break
        }
    }

    private func appendRemote(_ event: [String: Any], _ id: Int) {
        guard activeConversation == id, let message = obj(event, "message") else { return }
        items.append(ChatItem(role: str(message, "role") ?? "system",
                              text: str(message, "text") ?? "",
                              files: artifactFiles(obj(message, "artifacts"))))
    }

    private func setProposal(_ raw: [String: Any]) {
        guard let id = str(raw, "id") else { return }
        proposal = Proposal(id: id,
                            summary: str(raw, "summary") ?? "Jarvis wants to do something new.",
                            will: str(raw, "will") ?? "",
                            estimate: str(raw, "estimate") ?? "")
    }

    private func describeActivity(source: String, stage: String) -> String {
        switch true {
        case source == "router": return "Deciding what this needs…"
        case source == "planner": return "Planning the steps…"
        case source == "plan": return "Running the plan…"
        case source == "generator" && stage == "verifying": return "Verifying the new skill…"
        case source == "generator": return "Writing a new skill…"
        case source == "skill": return "Running the skill…"
        default: return "Working…"
        }
    }

    func sendIntent(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        items.append(ChatItem(role: "user", text: trimmed))
        let payload = msg("intent", ["text": trimmed,
                                     "conversation": activeConversation])
        if conn.send(payload) {
            busy = true
            busyLine = "Thinking…"
        } else {
            outbox.append(payload)
            busy = true
            busyLine = "Waiting for the connection…"
        }
    }

    func approve(_ id: String, yes: Bool) {
        proposal = nil
        // The decision outranks the question: stop reading it out.
        speaker.stop()
        conn.send(msg("approval", ["id": id, "decision": yes ? "yes" : "no"]))
    }

    func abort() {
        conn.send(msg("abort"))
        outbox.removeAll()
        busy = false
        busyLine = ""
    }

    func newChat() {
        activeConversation = nil
        items = []
        conn.send(msg("conversation_select", ["id": nil]))
    }

    func selectConversation(_ id: Int) {
        conn.send(msg("conversation_select", ["id": id]))
    }

    func setSpeakReplies(_ on: Bool) {
        prefs.speakReplies = on
        conn.send(msg("speak_replies", ["on": on]))
    }

    func setVoice(_ voice: String) {
        currentVoice = voice
        let payload = msg("profile_update", ["voice": ["enabled": true, "tts": true,
                                                       "voice": voice] as [String: Any]])
        if !conn.send(payload) {
            outbox.append(payload)
            toast = "Not connected. The voice change waits for the link."
        }
    }

    // Fetch once per session; hand the bytes to the share sheet after that.
    func download(_ file: FileRef) {
        guard let id = file.id else {
            toast = "That file has no handle."
            return
        }
        if let saved = savedFiles[id] {
            share(url: saved)
            return
        }
        Task {
            do {
                let fetched = try await conn.downloadFile(id: id, name: file.name)
                guard fetched.status == 200 else {
                    toast = "Fetch refused (\(fetched.status))."
                    return
                }
                let dir = FileManager.default.temporaryDirectory
                let url = dir.appendingPathComponent(safeName(file.name))
                try fetched.bytes.write(to: url, options: .atomic)
                savedFiles[id] = url
                share(url: url)
            } catch {
                toast = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    private func safeName(_ name: String) -> String {
        let cleaned = (name.components(separatedBy: "/").last ?? "file")
            .replacingOccurrences(of: "..", with: "_")
        return cleaned.isEmpty ? "file" : cleaned
    }

    private func share(url: URL) {
        let controller = UIActivityViewController(activityItems: [url],
                                                  applicationActivities: nil)
        var presenter = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.keyWindow?.rootViewController
        while let above = presenter?.presentedViewController { presenter = above }
        presenter?.present(controller, animated: true)
    }

    func unpair() {
        conn.stop()
        prefs.unpair()
        items = []
        conversations = []
        activeConversation = nil
        proposal = nil
    }
}
