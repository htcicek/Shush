import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics
import OSLog

struct KeyboardEventInterpreter {
    static let f5KeyCode: Int64 = 96
    static let macOS26DictationKeyCode: Int64 = 176
    static let legacyDictationSystemKeyCode = 0xCF

    static func isShortcutKey(keyCode: Int64) -> Bool {
        keyCode == f5KeyCode || keyCode == macOS26DictationKeyCode
    }

    static func isLegacyDictationKey(data1: Int64) -> Bool {
        systemKeyCode(data1: data1) == legacyDictationSystemKeyCode
    }

    static func systemKeyCode(data1: Int64) -> Int {
        Int((data1 & 0xFFFF_0000) >> 16)
    }

    static func systemKeyState(data1: Int64) -> Int {
        Int((data1 & 0x0000_FFFF) >> 8)
    }

    static func isSystemKeyDown(data1: Int64) -> Bool {
        let keyFlags = Int(data1 & 0x0000_FFFF)
        let keyState = systemKeyState(data1: data1)
        let isRepeat = (keyFlags & 0x1) != 0
        return keyState == 0xA && !isRepeat
    }

    static func isSystemKeyUp(data1: Int64) -> Bool {
        systemKeyState(data1: data1) == 0xB
    }
}

@MainActor
final class KeyboardMonitor {
    enum Status: Equatable, Sendable {
        case needsAccessibility
        case active
        case eventTapUnavailable

        var description: String {
            switch self {
            case .needsAccessibility:
                return "Accessibility access required"
            case .active:
                return "F5 shortcut active"
            case .eventTapUnavailable:
                return "Could not start the F5 shortcut"
            }
        }
    }

    enum ShortcutPhase: Sendable {
        case pressed
        case released
    }

    var onShortcutEvent: (@MainActor (ShortcutPhase) -> Void)?
    var onStatusChanged: (@MainActor (Status) -> Void)?
    var onDiagnosticEvent: (@MainActor (String) -> Void)?

    private(set) var hasAccessibilityPermission = false
    private(set) var status = Status.needsAccessibility
    private(set) var lastDiagnosticEvent = "No F5/Dictation event observed"
    private(set) var diagnosticEvents: [String] = []

    var isShortcutActive: Bool {
        status == .active
    }

    private let logger = Logger(subsystem: "com.htcicek.Shush", category: "KeyboardMonitor")
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTask: Task<Void, Never>?

    func start(promptForPermission: Bool) {
        updatePermissionState()
        logger.info("Starting keyboard monitor; accessibility trusted: \(self.hasAccessibilityPermission)")
        if promptForPermission {
            requestAccessibilityPermission()
        }
        installEventTapIfPossible()

        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                self?.updatePermissionState()
                self?.installEventTapIfPossible()
            }
        }
    }

    func stop() {
        permissionTask?.cancel()
        permissionTask = nil
        removeEventTap()
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        updatePermissionState()
        installEventTapIfPossible()
    }

    private func updatePermissionState() {
        let accessibility = AXIsProcessTrusted()
        let changed = accessibility != hasAccessibilityPermission

        hasAccessibilityPermission = accessibility
        if !accessibility, eventTap != nil {
            removeEventTap()
        }
        if changed {
            publishCurrentStatus()
        }
    }

    private func installEventTapIfPossible() {
        guard hasAccessibilityPermission, eventTap == nil else { return }

        let systemDefined = CGEventType(rawValue: 14)!
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << systemDefined.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyboardEventTapCallback,
            userInfo: context
        ) else {
            setStatus(.eventTapUnavailable)
            logger.error("CGEvent.tapCreate returned nil despite Accessibility access")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        publishCurrentStatus()
        logger.info("F5 event tap started")
    }

    private func removeEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
        publishCurrentStatus()
    }

    private func publishCurrentStatus() {
        if !hasAccessibilityPermission {
            setStatus(.needsAccessibility)
        } else if let eventTap, CGEvent.tapIsEnabled(tap: eventTap) {
            setStatus(.active)
        } else {
            setStatus(.eventTapUnavailable)
        }
    }

    private func setStatus(_ newStatus: Status) {
        guard status != newStatus else { return }
        status = newStatus
        onStatusChanged?(newStatus)
    }

    private func recordDiagnostic(_ description: String) {
        lastDiagnosticEvent = description
        diagnosticEvents.append(description)
        if diagnosticEvents.count > 20 {
            diagnosticEvents.removeFirst(diagnosticEvents.count - 20)
        }
        onDiagnosticEvent?(description)
        logger.info("\(description, privacy: .public)")
    }

    nonisolated fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        MainActor.assumeIsolated {
            handleOnMainActor(type: type, event: event)
        }
    }

    private func handleOnMainActor(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onShortcutEvent?(.released)
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            publishCurrentStatus()
            logger.warning("F5 event tap was disabled and has been re-enabled")
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard KeyboardEventInterpreter.isShortcutKey(keyCode: keyCode) else {
                return Unmanaged.passUnretained(event)
            }

            let phaseDescription = type == .keyDown ? "down" : "up"
            let flags = event.flags.rawValue
            recordDiagnostic("Dictation key \(phaseDescription); keyCode=\(keyCode), flags=0x\(String(flags, radix: 16))")

            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onShortcutEvent?(.pressed)
            } else if type == .keyUp {
                onShortcutEvent?(.released)
            }
            return nil
        }

        if type.rawValue == 14 {
            guard let nsEvent = NSEvent(cgEvent: event) else {
                recordDiagnostic("System-defined key event could not be decoded")
                return Unmanaged.passUnretained(event)
            }

            let data1 = Int64(nsEvent.data1)
            let data2 = Int64(nsEvent.data2)
            let subtype = Int(nsEvent.subtype.rawValue)
            let isLegacyDictation = KeyboardEventInterpreter.isLegacyDictationKey(data1: data1)
            guard isLegacyDictation else {
                return Unmanaged.passUnretained(event)
            }

            let systemKeyCode = KeyboardEventInterpreter.systemKeyCode(data1: data1)
            let keyState = KeyboardEventInterpreter.systemKeyState(data1: data1)
            let keyCodeField = event.getIntegerValueField(.keyboardEventKeycode)
            recordDiagnostic(
                "System event subtype=\(subtype), data1=0x\(String(data1, radix: 16)), data2=0x\(String(data2, radix: 16)), keyCodeField=\(keyCodeField), decodedKey=0x\(String(systemKeyCode, radix: 16)), state=0x\(String(keyState, radix: 16))"
            )

            if KeyboardEventInterpreter.isSystemKeyDown(data1: data1) {
                onShortcutEvent?(.pressed)
            } else if KeyboardEventInterpreter.isSystemKeyUp(data1: data1) {
                onShortcutEvent?(.released)
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}

private func keyboardEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
