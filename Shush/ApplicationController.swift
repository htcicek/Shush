import AppKit

@MainActor
final class ApplicationController: NSObject {
    private let audioController = AudioInputController()
    private let keyboardMonitor = KeyboardMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    private var refreshTimer: Timer?
    private var snapshot = AudioInputSnapshot.unavailable(message: "Checking microphone…")
    private var lastError: String?
    private var hasShownPermissionGuidance = false

    func start() {
        statusItem.button?.toolTip = "Shush"

        keyboardMonitor.onToggle = { [weak self] in
            Task { @MainActor in
                self?.toggleMute()
            }
        }
        keyboardMonitor.onPermissionChanged = { [weak self] _ in
            Task { @MainActor in
                self?.updateMenu()
            }
        }
        keyboardMonitor.start(promptForPermission: true)

        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.showPermissionGuidanceIfNeeded()
            }
        }

        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        keyboardMonitor.stop()
    }

    private func refresh() {
        snapshot = audioController.snapshot()
        updateStatusItem()
        updateMenu()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let symbolName: String
        let description: String
        switch snapshot.state {
        case .muted:
            symbolName = "mic.slash.fill"
            description = "Microphone muted"
        case .live:
            symbolName = "mic.fill"
            description = "Microphone live"
        case .unavailable:
            symbolName = "mic.badge.xmark"
            description = "Microphone control unavailable"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Shush — \(description)"
    }

    private func updateMenu() {
        let menu = NSMenu()

        let status = NSMenuItem(title: snapshot.statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        if let deviceName = snapshot.deviceName {
            let device = NSMenuItem(title: "Input: \(deviceName)", action: nil, keyEquivalent: "")
            device.isEnabled = false
            menu.addItem(device)
        }

        if let method = snapshot.methodDescription {
            let methodItem = NSMenuItem(title: "Method: \(method)", action: nil, keyEquivalent: "")
            methodItem.isEnabled = false
            menu.addItem(methodItem)
        }

        if let lastError {
            let errorItem = NSMenuItem(title: lastError, action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        menu.addItem(.separator())

        let toggleTitle = snapshot.state == .muted ? "Unmute Microphone" : "Mute Microphone"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleMuteFromMenu), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = snapshot.state != .unavailable
        menu.addItem(toggleItem)

        if !keyboardMonitor.hasAccessibilityPermission {
            menu.addItem(.separator())
            let permissionStatus = NSMenuItem(
                title: "F5 shortcut needs Accessibility access",
                action: nil,
                keyEquivalent: ""
            )
            permissionStatus.isEnabled = false
            menu.addItem(permissionStatus)

            let settingsItem = NSMenuItem(
                title: "Open Accessibility Settings…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            settingsItem.target = self
            menu.addItem(settingsItem)
        }

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Shush", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func toggleMuteFromMenu() {
        toggleMute()
    }

    private func toggleMute() {
        do {
            try audioController.toggleMute()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            NSSound.beep()
        }
        refresh()
    }

    @objc private func openAccessibilitySettings() {
        keyboardMonitor.requestAccessibilityPermission()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showPermissionGuidanceIfNeeded() {
        guard !keyboardMonitor.hasAccessibilityPermission, !hasShownPermissionGuidance else { return }
        hasShownPermissionGuidance = true

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Allow Shush to use the F5 key"
        alert.informativeText = "Shush needs Accessibility access to intercept F5 system-wide and prevent Dictation from opening. It does not use this permission to read your screen or keystrokes."
        alert.addButton(withTitle: "Open Accessibility Settings")
        alert.addButton(withTitle: "Not Now")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
