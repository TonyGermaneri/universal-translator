import AppKit
import AudioToolbox
import AVFoundation
import CoreAudio
import os

/// An app that can be captured, for the "Listen to" picker.
struct AudioApp: Identifiable, Hashable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    /// Playing audio right now.
    let isPlaying: Bool
}

enum AudioProcesses {
    /// Running apps the user might want to caption, those playing audio first.
    static func apps() -> [AudioApp] {
        let playing = Set(processes().filter(\.isRunningOutput).map(\.bundleID))
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> AudioApp? in
                guard let id = app.bundleIdentifier, id != own, seen.insert(id).inserted else { return nil }
                let isPlaying = playing.contains { $0 == id || $0.hasPrefix(id + ".") }
                return AudioApp(bundleID: id, name: app.localizedName ?? id, isPlaying: isPlaying)
            }
            .sorted { ($0.isPlaying ? 0 : 1, $0.name.lowercased()) < ($1.isPlaying ? 0 : 1, $1.name.lowercased()) }
    }

    struct Process {
        let object: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningOutput: Bool
    }

    /// Core Audio's process objects (every process that has used audio).
    static func processes() -> [Process] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            Process(object: id,
                    pid: value(id, kAudioProcessPropertyPID, default: pid_t(-1)),
                    bundleID: string(id, kAudioProcessPropertyBundleID) ?? "",
                    isRunningOutput: value(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0)
        }
    }

    /// The process object for a PID (our own, to exclude it from a system-wide tap).
    static func processObject(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func defaultOutputDeviceUID() -> String? {
        let device: AudioDeviceID = value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice,
                                          default: AudioDeviceID(kAudioObjectUnknown))
        return device == kAudioObjectUnknown ? nil : string(device, kAudioDevicePropertyDeviceUID)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, default fallback: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var result = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr ? result : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}

/// Captures audio other apps are playing, with a Core Audio process tap (macOS 14.2+): everything the Mac
/// plays (except this app), or one app and its helper processes. The audio keeps playing normally.
///
/// macOS asks once for permission ("System Audio Recording Only" in Privacy & Security). If it's denied the
/// tap delivers silence.
final class SystemAudioCapture {
    enum CaptureError: LocalizedError {
        case appNotPlaying(String)
        case tapFailed(OSStatus)
        case deviceFailed(OSStatus)
        case noFormat

        var errorDescription: String? {
            switch self {
            case .appNotPlaying(let name): return "\(name) isn't running. Open it, or choose another source in Settings → General."
            case .tapFailed(let status): return "Couldn't capture system audio (error \(status)). Allow it in System Settings → Privacy & Security → Screen & System Audio Recording."
            case .deviceFailed(let status): return "Couldn't start system audio capture (error \(status))."
            case .noFormat: return "System audio capture returned an unknown audio format."
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "system-audio", qos: .userInteractive)
    private let log = Logger(subsystem: "UniversalTranslator", category: "system-audio")

    /// - Parameter bundleID: the app to capture (with its helpers), or nil for all system audio.
    func start(bundleID: String?, appName: String, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let description: CATapDescription
        if let testPID = ProcessInfo.processInfo.environment["UT_TAP_PID"].flatMap(pid_t.init),
           let object = AudioProcesses.processObject(pid: testPID) {
            // Test hook: capture one process, muted so nothing is heard.
            description = CATapDescription(stereoMixdownOfProcesses: [object])
            description.muteBehavior = .muted
        } else if let bundleID {
            let objects = AudioProcesses.processes()
                .filter { $0.bundleID == bundleID || $0.bundleID.hasPrefix(bundleID + ".") }
                .map(\.object)
            guard !objects.isEmpty else { throw CaptureError.appNotPlaying(appName) }
            description = CATapDescription(stereoMixdownOfProcesses: objects)
        } else {
            let own = AudioProcesses.processObject(pid: ProcessInfo.processInfo.processIdentifier).map { [$0] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        }
        description.uuid = UUID()
        description.name = "Universal Translator"
        if ProcessInfo.processInfo.environment["UT_TAP_PID"] == nil { description.muteBehavior = .unmuted }
        description.isPrivate = true

        var status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else { throw CaptureError.tapFailed(status) }

        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd)
        guard status == noErr, let format = AVAudioFormat(streamDescription: &asbd) else {
            stop()
            throw CaptureError.noFormat
        }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Universal Translator Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if let output = AudioProcesses.defaultOutputDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            stop()
            throw CaptureError.deviceFailed(status)
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, input, _, _, _ in
            // The buffer list is only valid during the callback: copy it.
            guard let view = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  view.frameLength > 0,
                  let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: view.frameLength) else { return }
            copy.frameLength = view.frameLength
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: view.audioBufferList))
            let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for (from, to) in zip(source, destination) {
                if let src = from.mData, let dst = to.mData { memcpy(dst, src, Int(min(from.mDataByteSize, to.mDataByteSize))) }
            }
            onBuffer(copy)
        }
        guard status == noErr else {
            stop()
            throw CaptureError.deviceFailed(status)
        }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            stop()
            throw CaptureError.deviceFailed(status)
        }
        log.info("Capturing \(bundleID ?? "system audio", privacy: .public) at \(format.sampleRate) Hz, \(format.channelCount) ch")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
