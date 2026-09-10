import CoreAudio
import Foundation

enum MicrophoneState: Equatable, Sendable {
    case live
    case muted
    case unavailable
}

struct AudioInputSnapshot: Equatable, Sendable {
    let state: MicrophoneState
    let deviceName: String?
    let methodDescription: String?
    let statusText: String

    static func unavailable(message: String) -> AudioInputSnapshot {
        AudioInputSnapshot(
            state: .unavailable,
            deviceName: nil,
            methodDescription: nil,
            statusText: message
        )
    }
}

enum AudioInputError: LocalizedError {
    case noDefaultInput
    case unsupported
    case coreAudio(operation: String, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .noDefaultInput:
            return "No default microphone is available."
        case .unsupported:
            return "This microphone does not expose a controllable mute or input gain."
        case let .coreAudio(operation, status):
            return "\(operation) failed (Core Audio \(status))."
        }
    }
}

@MainActor
final class AudioInputController {
    private enum Control {
        case mute(device: AudioDeviceID, elements: [AudioObjectPropertyElement])
        case volume(device: AudioDeviceID, uid: String, elements: [AudioObjectPropertyElement])
    }

    private let defaults = UserDefaults.standard
    private let inputScope = kAudioDevicePropertyScopeInput
    private let mainElement = kAudioObjectPropertyElementMain

    func snapshot() -> AudioInputSnapshot {
        do {
            let device = try defaultInputDevice()
            let name = deviceName(device)
            let control = try control(for: device)
            let muted = try isMuted(control)

            return AudioInputSnapshot(
                state: muted ? .muted : .live,
                deviceName: name,
                methodDescription: methodDescription(for: control),
                statusText: muted ? "Microphone is muted" : "Microphone is live"
            )
        } catch {
            return AudioInputSnapshot(
                state: .unavailable,
                deviceName: currentDeviceName(),
                methodDescription: nil,
                statusText: error.localizedDescription
            )
        }
    }

    func toggleMute() throws {
        let device = try defaultInputDevice()
        let control = try control(for: device)
        if try isMuted(control) {
            try unmute(control)
        } else {
            try mute(control)
        }
    }

    func setMuted(_ shouldMute: Bool) throws {
        let device = try defaultInputDevice()
        let control = try control(for: device)
        guard try isMuted(control) != shouldMute else { return }

        if shouldMute {
            try mute(control)
        } else {
            try unmute(control)
        }
    }

    private func methodDescription(for control: Control) -> String {
        switch control {
        case .mute:
            return "Device mute control"
        case .volume:
            return "Input gain fallback"
        }
    }

    private func control(for device: AudioDeviceID) throws -> Control {
        let channelCount = max(try inputChannelCount(device), 1)
        let elements = [mainElement] + (1...channelCount).map(AudioObjectPropertyElement.init)

        if let muteElements = writableElements(
            device: device,
            selector: kAudioDevicePropertyMute,
            candidates: elements
        ) {
            return .mute(device: device, elements: muteElements)
        }

        if let volumeElements = writableElements(
            device: device,
            selector: kAudioDevicePropertyVolumeScalar,
            candidates: elements
        ) {
            return .volume(device: device, uid: deviceUID(device), elements: volumeElements)
        }

        throw AudioInputError.unsupported
    }

    private func writableElements(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        candidates: [AudioObjectPropertyElement]
    ) -> [AudioObjectPropertyElement]? {
        let main = candidates.first ?? mainElement
        if propertyIsWritable(device: device, selector: selector, element: main) {
            return [main]
        }

        let channels = candidates.dropFirst().filter {
            propertyIsWritable(device: device, selector: selector, element: $0)
        }
        return channels.isEmpty ? nil : Array(channels)
    }

    private func propertyIsWritable(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: inputScope,
            mElement: element
        )
        guard AudioObjectHasProperty(device, &address) else { return false }

        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private func isMuted(_ control: Control) throws -> Bool {
        switch control {
        case let .mute(device, elements):
            return try elements.allSatisfy {
                try readUInt32(device: device, selector: kAudioDevicePropertyMute, element: $0) != 0
            }
        case let .volume(device, _, elements):
            return try elements.allSatisfy {
                try readFloat32(device: device, selector: kAudioDevicePropertyVolumeScalar, element: $0) <= 0.0001
            }
        }
    }

    private func mute(_ control: Control) throws {
        switch control {
        case let .mute(device, elements):
            for element in elements {
                try writeUInt32(1, device: device, selector: kAudioDevicePropertyMute, element: element)
            }
        case let .volume(device, uid, elements):
            for element in elements {
                let volume = try readFloat32(
                    device: device,
                    selector: kAudioDevicePropertyVolumeScalar,
                    element: element
                )
                defaults.set(Double(volume), forKey: volumeKey(uid: uid, element: element))
                try writeFloat32(0, device: device, selector: kAudioDevicePropertyVolumeScalar, element: element)
            }
            defaults.set(true, forKey: fallbackMutedKey(uid: uid))
        }
    }

    private func unmute(_ control: Control) throws {
        switch control {
        case let .mute(device, elements):
            for element in elements {
                try writeUInt32(0, device: device, selector: kAudioDevicePropertyMute, element: element)
            }
        case let .volume(device, uid, elements):
            let hasSavedVolumes = defaults.bool(forKey: fallbackMutedKey(uid: uid))
            for element in elements {
                let key = volumeKey(uid: uid, element: element)
                let restored = hasSavedVolumes && defaults.object(forKey: key) != nil
                    ? Float32(defaults.double(forKey: key))
                    : 1
                try writeFloat32(
                    max(restored, 0.01),
                    device: device,
                    selector: kAudioDevicePropertyVolumeScalar,
                    element: element
                )
                defaults.removeObject(forKey: key)
            }
            defaults.removeObject(forKey: fallbackMutedKey(uid: uid))
        }
    }

    private func defaultInputDevice() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &device
        )
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Reading the default microphone", status: status)
        }
        guard device != kAudioObjectUnknown else { throw AudioInputError.noDefaultInput }
        return device
    }

    private func currentDeviceName() -> String? {
        guard let device = try? defaultInputDevice() else { return nil }
        return deviceName(device)
    }

    private func inputChannelCount(_ device: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: inputScope,
            mElement: mainElement
        )
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Reading microphone channels", status: status)
        }

        let memory = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { memory.deallocate() }

        status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Reading microphone channels", status: status)
        }

        let bufferList = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList).reduce(0) {
            $0 + Int($1.mNumberChannels)
        }
    }

    private func deviceName(_ device: AudioDeviceID) -> String? {
        readString(device: device, selector: kAudioObjectPropertyName)
    }

    private func deviceUID(_ device: AudioDeviceID) -> String {
        readString(device: device, selector: kAudioDevicePropertyDeviceUID) ?? String(device)
    }

    private func readString(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: mainElement
        )
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value as String : nil
    }

    private func readUInt32(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: inputScope, mElement: element)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Reading microphone mute", status: status)
        }
        return value
    }

    private func writeUInt32(
        _ value: UInt32,
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: inputScope, mElement: element)
        var value = value
        let size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Changing microphone mute", status: status)
        }
    }

    private func readFloat32(
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) throws -> Float32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: inputScope, mElement: element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Reading microphone gain", status: status)
        }
        return value
    }

    private func writeFloat32(
        _ value: Float32,
        device: AudioDeviceID,
        selector: AudioObjectPropertySelector,
        element: AudioObjectPropertyElement
    ) throws {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: inputScope, mElement: element)
        var value = value
        let size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
        guard status == noErr else {
            throw AudioInputError.coreAudio(operation: "Changing microphone gain", status: status)
        }
    }

    private func volumeKey(uid: String, element: AudioObjectPropertyElement) -> String {
        "savedInputVolume.\(uid).\(element)"
    }

    private func fallbackMutedKey(uid: String) -> String {
        "inputVolumeFallbackMuted.\(uid)"
    }
}
