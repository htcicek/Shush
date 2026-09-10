import AppKit
import Combine
import SwiftUI

enum ShortcutMode: String, CaseIterable, Identifiable, Sendable {
    case toggle
    case pushToTalk

    var id: Self { self }

    var title: String {
        switch self {
        case .toggle:
            return "Toggle"
        case .pushToTalk:
            return "Push to Talk (Hold F5)"
        }
    }
}

@MainActor
final class ShushModel: ObservableObject {
    private static let shortcutModeDefaultsKey = "shortcutMode"

    @Published private(set) var snapshot = AudioInputSnapshot.unavailable(message: "Checking microphone…")
    @Published private(set) var lastError: String?
    @Published private(set) var isShortcutActive = false
    @Published var shortcutMode: ShortcutMode {
        didSet {
            UserDefaults.standard.set(shortcutMode.rawValue, forKey: Self.shortcutModeDefaultsKey)
            if shortcutMode == .pushToTalk {
                setMicrophoneMuted(true)
            }
        }
    }

    private let audioController = AudioInputController()
    private let keyboardMonitor = KeyboardMonitor()
    private var refreshTask: Task<Void, Never>?
    private var hasShownPermissionGuidance = false

    init() {
        let storedMode = UserDefaults.standard.string(forKey: Self.shortcutModeDefaultsKey)
        shortcutMode = ShortcutMode(rawValue: storedMode ?? "") ?? .toggle

        keyboardMonitor.onShortcutEvent = { [weak self] phase in
            self?.handleShortcut(phase)
        }
        keyboardMonitor.onPermissionChanged = { [weak self] active in
            self?.isShortcutActive = active
        }
        keyboardMonitor.start(promptForPermission: false)

        if shortcutMode == .pushToTalk {
            setMicrophoneMuted(true)
        } else {
            refresh()
        }

        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.showPermissionGuidanceIfNeeded()
        }
    }

    var statusSymbolName: String {
        switch snapshot.state {
        case .muted:
            return "mic.slash.fill"
        case .live:
            return "mic.fill"
        case .unavailable:
            return "mic.badge.xmark"
        }
    }

    var manualControlTitle: String {
        if shortcutMode == .pushToTalk {
            return "Hold F5 to Talk"
        }
        return snapshot.state == .muted ? "Unmute Microphone" : "Mute Microphone"
    }

    var canToggleManually: Bool {
        shortcutMode == .toggle && snapshot.state != .unavailable
    }

    func toggleMute() {
        do {
            try audioController.toggleMute()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSSound.beep()
        }
        refresh()
    }

    func requestShortcutPermissions() {
        keyboardMonitor.requestShortcutPermissions()
    }

    func openAccessibilitySettings() {
        requestShortcutPermissions()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openInputMonitoringSettings() {
        requestShortcutPermissions()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    func openMenuBarSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refresh() {
        snapshot = audioController.snapshot()
        isShortcutActive = keyboardMonitor.isShortcutActive
    }

    private func setMicrophoneMuted(_ muted: Bool) {
        do {
            try audioController.setMuted(muted)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSSound.beep()
        }
        refresh()
    }

    private func handleShortcut(_ phase: KeyboardMonitor.ShortcutPhase) {
        switch shortcutMode {
        case .toggle:
            if phase == .pressed {
                toggleMute()
            }
        case .pushToTalk:
            setMicrophoneMuted(phase == .released)
        }
    }

    private func openSystemSettings(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    private func showPermissionGuidanceIfNeeded() {
        guard !isShortcutActive, !hasShownPermissionGuidance else { return }
        hasShownPermissionGuidance = true
        requestShortcutPermissions()

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.icon = NSApplication.shared.applicationIconImage
        alert.alertStyle = .warning
        alert.messageText = "Shush needs setup"
        alert.informativeText = "The F5/Dictation shortcut is not active. Enable Shush in Accessibility and Input Monitoring. If Shush is missing from the menu bar, enable it in System Settings → Menu Bar."
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            openAccessibilitySettings()
        case .alertSecondButtonReturn:
            openMenuBarSettings()
        default:
            break
        }

        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

struct ShushMenu: View {
    @ObservedObject var model: ShushModel

    var body: some View {
        Text(model.snapshot.statusText)
            .disabled(true)

        if let deviceName = model.snapshot.deviceName {
            Text("Input: \(deviceName)")
                .disabled(true)
        }

        if let method = model.snapshot.methodDescription {
            Text("Method: \(method)")
                .disabled(true)
        }

        if let lastError = model.lastError {
            Text(lastError)
                .disabled(true)
        }

        Divider()

        Button(model.manualControlTitle) {
            model.toggleMute()
        }
        .disabled(!model.canToggleManually)

        Picker("Dictation Key Mode", selection: $model.shortcutMode) {
            ForEach(ShortcutMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }

        if !model.isShortcutActive {
            Divider()

            Text("F5 shortcut is not active")
                .disabled(true)

            Button("Open Accessibility Settings…") {
                model.openAccessibilitySettings()
            }

            Button("Open Input Monitoring Settings…") {
                model.openInputMonitoringSettings()
            }

            Button("Open Menu Bar Settings…") {
                model.openMenuBarSettings()
            }
        }

        Divider()

        Button("Quit Shush") {
            model.quit()
        }
        .keyboardShortcut("q")
    }
}
