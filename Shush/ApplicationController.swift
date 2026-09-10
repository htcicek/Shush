import AppKit

@MainActor
final class ApplicationController: NSObject {
    private enum ShortcutMode: String {
        case toggle
        case pushToTalk
    }

    private static let shortcutModeDefaultsKey = "shortcutMode"

    private let audioController = AudioInputController()
    private let keyboardMonitor = KeyboardMonitor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private var refreshTimer: Timer?
    private var snapshot = AudioInputSnapshot.unavailable(message: "Checking microphone…")
    private var lastError: String?
    private var hasShownPermissionGuidance = false

    private var shortcutMode: ShortcutMode {
        get {
            guard let value = UserDefaults.standard.string(forKey: Self.shortcutModeDefaultsKey) else {
                return .toggle
            }
            return ShortcutMode(rawValue: value) ?? .toggle
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.shortcutModeDefaultsKey)
        }
    }

    func start() {
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "mic.badge.xmark",
                accessibilityDescription: "Shush is starting"
            )
            image?.isTemplate = true
            button.image = image
            button.title = " Shush"
            button.toolTip = "Shush is starting"
            button.imagePosition = .imageLeading
        }

        keyboardMonitor.onShortcutEvent = { [weak self] phase in
            Task { @MainActor in
                self?.handleShortcut(phase)
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

        if shortcutMode == .pushToTalk {
            setMicrophoneMuted(true)
        } else {
            refresh()
        }
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
        button.title = " Shush"
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

        let toggleTitle = shortcutMode == .pushToTalk
            ? "Hold F5 to Talk"
            : (snapshot.state == .muted ? "Unmute Microphone" : "Mute Microphone")
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleMuteFromMenu), keyEquivalent: "")
        toggleItem.target = self
        toggleItem.isEnabled = snapshot.state != .unavailable && shortcutMode == .toggle
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        let modeLabel = NSMenuItem(title: "Dictation Key Mode", action: nil, keyEquivalent: "")
        modeLabel.isEnabled = false
        menu.addItem(modeLabel)

        let toggleModeItem = NSMenuItem(
            title: "Toggle",
            action: #selector(selectToggleMode),
            keyEquivalent: ""
        )
        toggleModeItem.target = self
        toggleModeItem.state = shortcutMode == .toggle ? .on : .off
        menu.addItem(toggleModeItem)

        let pushToTalkItem = NSMenuItem(
            title: "Push to Talk (Hold F5)",
            action: #selector(selectPushToTalkMode),
            keyEquivalent: ""
        )
        pushToTalkItem.target = self
        pushToTalkItem.state = shortcutMode == .pushToTalk ? .on : .off
        menu.addItem(pushToTalkItem)

        if !keyboardMonitor.isShortcutActive {
            menu.addItem(.separator())
            let permissionStatus = NSMenuItem(
                title: "F5 shortcut is not active",
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

            let inputSettingsItem = NSMenuItem(
                title: "Open Input Monitoring Settings…",
                action: #selector(openInputMonitoringSettings),
                keyEquivalent: ""
            )
            inputSettingsItem.target = self
            menu.addItem(inputSettingsItem)
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

    @objc private func selectToggleMode() {
        shortcutMode = .toggle
        updateMenu()
    }

    @objc private func selectPushToTalkMode() {
        shortcutMode = .pushToTalk
        setMicrophoneMuted(true)
    }

    @objc private func openAccessibilitySettings() {
        keyboardMonitor.requestShortcutPermissions()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openInputMonitoringSettings() {
        keyboardMonitor.requestShortcutPermissions()
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openMenuBarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func showPermissionGuidanceIfNeeded() {
        guard !keyboardMonitor.isShortcutActive, !hasShownPermissionGuidance else { return }
        hasShownPermissionGuidance = true

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.alertStyle = .warning
        alert.messageText = "Shush needs setup"
        alert.informativeText = "The F5/Dictation shortcut is not active. Enable Shush in Accessibility and Input Monitoring. If Shush is missing from the menu bar, enable it in System Settings → Menu Bar."
        alert.addButton(withTitle: "Open Accessibility")
        alert.addButton(withTitle: "Open Menu Bar Settings")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openAccessibilitySettings()
        } else if response == .alertSecondButtonReturn {
            openMenuBarSettings()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
