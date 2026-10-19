import SwiftUI

@main
struct RemoteControlApp: App {
    @State private var connection = MacConnection()
    @State private var speech = SpeechInput()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ControllerView(connection: connection, speech: speech)
                .onChange(of: phase) { _, phase in
                    connection.setActive(phase != .background)
                    if phase == .background { speech.cancel() }
                }
        }
    }
}
