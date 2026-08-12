import SwiftUI

@main
struct BackupPilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("BackupPilot") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 940, minHeight: 620)
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
