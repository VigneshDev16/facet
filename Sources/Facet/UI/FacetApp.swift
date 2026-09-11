import SwiftUI

struct FacetApp: App {
    @StateObject private var state: AppState
    @State private var startupError: String?

    init() {
        let created: AppState
        do {
            created = try AppState()
        } catch {
            // AppState only fails if the library database can't be opened at all.
            fatalError("Could not open Facet library: \(error)")
        }
        _state = StateObject(wrappedValue: created)
    }

    var body: some Scene {
        WindowGroup("Facet") {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { state.indexer.start() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Folder…") { state.addFolder() }
                    .keyboardShortcut("i", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("Rescan Library") { state.indexer.start() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }

        Settings {
            SettingsView().environmentObject(state)
        }
    }
}
