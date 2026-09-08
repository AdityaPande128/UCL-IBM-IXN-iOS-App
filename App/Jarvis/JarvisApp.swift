import SwiftUI

@main
struct JarvisApp: App {
    @StateObject private var model = ChatViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                if model.prefs.paired {
                    ChatScreen()
                } else {
                    OnboardingView()
                }
                // The app-switcher snapshot must not show the transcript:
                // cover it the moment the scene leaves the foreground.
                if scenePhase != .active {
                    Rectangle()
                        .fill(Color(uiColor: .systemBackground))
                        .ignoresSafeArea()
                        .overlay(Image(systemName: "lock.shield")
                            .font(.largeTitle)
                            .foregroundStyle(Palette.accent))
                }
            }
            .environmentObject(model)
            .onChange(of: scenePhase) { phase in
                // Foreground-only by design: the socket dies in the
                // background and the ladder reconnects on return.
                switch phase {
                case .active: model.connect()
                case .background:
                    model.endPrivateChat()
                    model.disconnect()
                default: break
                }
            }
        }
    }
}
