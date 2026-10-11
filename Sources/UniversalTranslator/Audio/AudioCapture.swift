import AVFoundation
import CoreAudio
import os
import TranslatorCore

struct AudioInputDevice: Identifiable, Hashable {
    var id: String { uid }
    let uid: String
    let name: String
    let deviceID: AudioDeviceID
}

enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(uid: uid, name: name, deviceID: id)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.deviceID
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}

/// Converts captured buffers to the format a consumer needs (e.g. 16 kHz mono for speech models).
final class BufferConverter: @unchecked Sendable {
    enum ConversionError: Error { case cannotCreateConverter, failed(NSError?) }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
            if format.channelCount < buffer.format.channelCount { converter?.downmix = true }
        }
        guard let converter else { throw ConversionError.cannotCreateConverter }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw ConversionError.cannotCreateConverter
        }
        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw ConversionError.failed(error) }
        return output
    }
}

/// Audio capture: the microphone (AVAudioEngine, optionally a specific input device), or audio other apps are
/// playing (`SystemAudioCapture`).
final class AudioCapture {
    enum CaptureError: LocalizedError {
        case noInput
        var errorDescription: String? { "No usable microphone input was found." }
    }

    private var engine = AVAudioEngine()
    private var configObserver: NSObjectProtocol?
    /// Called on the audio thread.
    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    /// Called on the main thread when the input device changes underneath the engine.
    var onConfigurationChange: (() -> Void)?

    private var fileSource: FileAudioSource?
    private var systemAudio: SystemAudioCapture?

    func start(settings: AppSettings) throws {
        if let path = ProcessInfo.processInfo.environment["UT_AUDIO_FILE"], let onBuffer {
            // Debug/test hook: stream an audio file in real time instead of the microphone.
            fileSource = try FileAudioSource(url: URL(fileURLWithPath: path), onBuffer: onBuffer)
            fileSource?.start()
            return
        }
        switch settings.audioSource {
        case .microphone:
            try startMicrophone(deviceUID: settings.inputDeviceUID)
        case .systemAudio, .app:
            guard let onBuffer else { return }
            let capture = SystemAudioCapture()
            let app = settings.audioSource == .app ? settings.sourceAppBundleID : nil
            try capture.start(bundleID: app, appName: settings.sourceAppName, onBuffer: onBuffer)
            systemAudio = capture
        }
    }

    private func startMicrophone(deviceUID: String) throws {
        engine = AVAudioEngine()
        let input = engine.inputNode
        if !deviceUID.isEmpty, var deviceID = AudioDevices.deviceID(forUID: deviceUID), let unit = input.audioUnit {
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInput }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.onBuffer?(buffer)
        }
        engine.prepare()
        try engine.start()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.onConfigurationChange?() }
    }

    func stop() {
        fileSource?.stop()
        fileSource = nil
        systemAudio?.stop()
        systemAudio = nil
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    /// Microphone permission (other sources are covered by the system audio recording permission, which macOS
    /// asks for when capture starts).
    static func requestPermission(for source: AudioSource) async -> Bool {
        if ProcessInfo.processInfo.environment["UT_AUDIO_FILE"] != nil || source != .microphone { return true }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}

/// Plays an audio file into the pipeline at real-time pace, followed by silence (for testing).
final class FileAudioSource: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private let silence: AVAudioPCMBuffer
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    private let timer: DispatchSourceTimer
    private var index = 0

    init(url: URL, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1024
        var list: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            list.append(buffer)
        }
        buffers = list
        silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        silence.frameLength = chunk
        self.onBuffer = onBuffer
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "file-audio", qos: .userInteractive))
        let interval = Double(chunk) / format.sampleRate
        timer.schedule(deadline: .now() + 0.5, repeating: interval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.next() }
    }

    func start() { timer.resume() }
    func stop() { timer.cancel() }

    private func next() {
        let buffer = index < buffers.count ? buffers[index] : silence
        index += 1
        onBuffer(buffer)
    }
}
