import SwiftUI

@main
@MainActor
struct ShushApplication: App {
    @StateObject private var model = ShushModel()

    var body: some Scene {
        MenuBarExtra {
            ShushMenu(model: model)
        } label: {
            Image(systemName: model.statusSymbolName)
                .accessibilityLabel("Shush: \(model.snapshot.statusText)")
                .help("Shush: \(model.snapshot.statusText)")
        }
        .menuBarExtraStyle(.menu)
    }
}
