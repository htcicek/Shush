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
            return "Push to Talk"
        }
    }
}

@MainActor
final class ShushModel: ObservableObject {
    private static let shortcutModeDefaultsKey = "shortcutMode"
    private static let debugModeDefaultsKey = "debugMode"

    @Published private(set) var snapshot = AudioInputSnapshot.unavailable(message: "Checking microphone…")
    @Published private(set) var lastError: String?
    @Published private(set) var shortcutStatus = KeyboardMonitor.Status.needsAccessibility
    @Published private(set) var lastKeyboardEvent = "No Dictation key event observed"
    @Published var isDebugModeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isDebugModeEnabled, forKey: Self.debugModeDefaultsKey)
        }
    }
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

    init() {
        let storedMode = UserDefaults.standard.string(forKey: Self.shortcutModeDefaultsKey)
        shortcutMode = ShortcutMode(rawValue: storedMode ?? "") ?? .toggle
        isDebugModeEnabled = UserDefaults.standard.bool(forKey: Self.debugModeDefaultsKey)

        keyboardMonitor.onShortcutEvent = { [weak self] phase in
            self?.handleShortcut(phase)
        }
        keyboardMonitor.onStatusChanged = { [weak self] status in
            self?.shortcutStatus = status
        }
        keyboardMonitor.onDiagnosticEvent = { [weak self] description in
            self?.lastKeyboardEvent = description
        }
        keyboardMonitor.start(promptForPermission: false)
        shortcutStatus = keyboardMonitor.status
        lastKeyboardEvent = keyboardMonitor.lastDiagnosticEvent

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
    }

    var isShortcutActive: Bool {
        shortcutStatus == .active
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
            return "Hold Dictation Key to Talk"
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
        keyboardMonitor.requestAccessibilityPermission()
    }

    func selectShortcutMode(_ mode: ShortcutMode) {
        shortcutMode = mode
    }

    func copyDiagnostics() {
        let diagnostics = """
        Shush keyboard diagnostics
        Shortcut status: \(shortcutStatus.description)
        Accessibility trusted: \(keyboardMonitor.hasAccessibilityPermission)
        Last event: \(lastKeyboardEvent)
        Recent events:
        \(keyboardMonitor.diagnosticEvents.map { "- \($0)" }.joined(separator: "\n"))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }

    func openAccessibilitySettings() {
        requestShortcutPermissions()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openMenuBarSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func refresh() {
        let updatedSnapshot = audioController.snapshot()
        if updatedSnapshot != snapshot {
            snapshot = updatedSnapshot
        }

        let updatedShortcutStatus = keyboardMonitor.status
        if updatedShortcutStatus != shortcutStatus {
            shortcutStatus = updatedShortcutStatus
        }
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

        Menu("Dictation Key Mode") {
            ForEach(ShortcutMode.allCases) { mode in
                Button {
                    model.selectShortcutMode(mode)
                } label: {
                    if model.shortcutMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        }

        Divider()

        Toggle("Debug Mode", isOn: $model.isDebugModeEnabled)

        if model.isDebugModeEnabled {
            Text("Keyboard: \(model.lastKeyboardEvent)")
                .disabled(true)

            Button("Copy Keyboard Diagnostics") {
                model.copyDiagnostics()
            }
        }

        if !model.isShortcutActive {
            Divider()

            Text(model.shortcutStatus.description)
                .disabled(true)

            if model.shortcutStatus == .needsAccessibility {
                Button("Grant Accessibility Access…") {
                    model.openAccessibilitySettings()
                }
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
