import AppKit
import ApplicationServices
import CoreGraphics

struct KeyboardEventInterpreter {
    static let f5KeyCode: Int64 = 96
    static let dictationSystemKeyCode = 0xCF

    static func isF5(keyCode: Int64) -> Bool {
        keyCode == f5KeyCode
    }

    static func isDictationKey(data1: Int64) -> Bool {
        let systemKeyCode = Int((data1 & 0xFFFF_0000) >> 16)
        return systemKeyCode == dictationSystemKeyCode
    }

    static func isSystemKeyDown(data1: Int64) -> Bool {
        let keyFlags = Int(data1 & 0x0000_FFFF)
        let keyState = (keyFlags & 0xFF00) >> 8
        let isRepeat = (keyFlags & 0x1) != 0
        return keyState == 0xA && !isRepeat
    }

    static func isSystemKeyUp(data1: Int64) -> Bool {
        let keyFlags = Int(data1 & 0x0000_FFFF)
        let keyState = (keyFlags & 0xFF00) >> 8
        return keyState == 0xB
    }
}

final class KeyboardMonitor {
    enum ShortcutPhase {
        case pressed
        case released
    }

    var onShortcutEvent: ((ShortcutPhase) -> Void)?
    var onPermissionChanged: ((Bool) -> Void)?

    private(set) var hasAccessibilityPermission = false
    private(set) var hasInputMonitoringPermission = false
    var isShortcutActive: Bool {
        guard let eventTap else { return false }
        return CGEvent.tapIsEnabled(tap: eventTap)
    }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionTimer: Timer?

    func start(promptForPermission: Bool) {
        updatePermissionState()
        if promptForPermission {
            requestShortcutPermissions()
        }
        installEventTapIfPossible()

        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.updatePermissionState()
            self.installEventTapIfPossible()
        }
    }

    func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil

        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        runLoopSource = nil
        eventTap = nil
    }

    func requestShortcutPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }

    private func updatePermissionState() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        let changed = accessibility != hasAccessibilityPermission
            || inputMonitoring != hasInputMonitoringPermission

        hasAccessibilityPermission = accessibility
        hasInputMonitoringPermission = inputMonitoring
        if changed {
            onPermissionChanged?(isShortcutActive)
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
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        onPermissionChanged?(isShortcutActive)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            onShortcutEvent?(.released)
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown || type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard KeyboardEventInterpreter.isF5(keyCode: keyCode) else {
                return Unmanaged.passUnretained(event)
            }

            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onShortcutEvent?(.pressed)
            } else if type == .keyUp {
                onShortcutEvent?(.released)
            }
            return nil
        }

        if type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) {
            let data1 = Int64(nsEvent.data1)
            guard KeyboardEventInterpreter.isDictationKey(data1: data1) else {
                return Unmanaged.passUnretained(event)
            }

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
