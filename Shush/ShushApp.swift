import SwiftUI

@main
@MainActor
struct ShushApplication: App {
    @StateObject private var model = ShushModel()

    var body: some Scene {
        MenuBarExtra {
            ShushMenu(model: model)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.statusSymbolName)
                Text("Shush")
            }
        }
        .menuBarExtraStyle(.menu)
    }
}
