import AppKit
import AVFoundation
import CoreAudio

struct SpeakingMicrophoneChunk {
    let pcm: Data
    let hostTime: UInt64
}

struct SpeakingAudioError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor protocol SpeakingAudioIO: AnyObject {
    func start(onPlayed: @escaping @MainActor (String) -> Void,
               onDeviceChange: @escaping @MainActor () -> Void) throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error>
    func setMuted(_ muted: Bool)
    func enqueue(_ pcm: Data, itemID: String) throws
    func responseFinished()
    func interrupt(_ itemID: String) -> Int?
    func stop()
}

/// Each input tap exclusively owns one converter and calls it on its serial audio callbacks.
/// Keeping it there preserves the resampler state between buffers.
final class SpeakingMicrophoneConverter: @unchecked Sendable {
    static let sampleRate = 24_000.0
    private let converter: AVAudioConverter

    init(input: AVAudioFormat) throws {
        guard input.sampleRate > 0, input.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: target) else {
            throw SpeakingAudioError("无法将麦克风音频转换为 24 kHz 单声道。")
        }
        converter.downmix = input.channelCount > 1
        self.converter = converter
    }

    func encode(_ input: AVAudioPCMBuffer) throws -> Data {
        let capacity = ceil(Double(input.frameLength) * Self.sampleRate / converter.inputFormat.sampleRate) + 32
        guard capacity < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: UInt32(capacity)) else {
            throw SpeakingAudioError("无法创建麦克风缓冲区。")
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let samples = output.int16ChannelData?[0] else {
            throw SpeakingAudioError("麦克风音频转换失败，请重新开始练习。")
        }
        return Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Int16>.size)
    }
}

// Playback callbacks can arrive before the main actor processes an interruption.
// Each response owns its counter so a callback after player.stop() cannot advance a later turn.
private final class SpeakingPlayedAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = 0
    var frames: Int { lock.withLock { completed } }
    func acknowledge(_ end: Int) { lock.withLock { completed = max(completed, end) } }
}

@MainActor final class SpeakingSessionAudio: SpeakingAudioIO {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(standardFormatWithSampleRate: SpeakingMicrophoneConverter.sampleRate, channels: 1)!
    private var tapInstalled = false
    private var continuation: AsyncThrowingStream<SpeakingMicrophoneChunk, Error>.Continuation?
    private var configurationObserver: NSObjectProtocol?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var onPlayed: (@MainActor (String) -> Void)?
    private var itemID: String?
    private var played = SpeakingPlayedAudio()
    private var queuedFrames = 0
    private var hasFinishedResponse = false

    func start(onPlayed: @escaping @MainActor (String) -> Void,
               onDeviceChange: @escaping @MainActor () -> Void) throws -> AsyncThrowingStream<SpeakingMicrophoneChunk, Error> {
        self.onPlayed = onPlayed
        let input = engine.inputNode
        guard input.inputFormat(forBus: 0).sampleRate > 0, input.inputFormat(forBus: 0).channelCount > 0,
              engine.outputNode.outputFormat(forBus: 0).sampleRate > 0,
              engine.outputNode.outputFormat(forBus: 0).channelCount > 0 else {
            throw SpeakingAudioError("请连接麦克风和音频输出设备，再开始练习。")
        }
        // Capture and playback share Apple's echo canceller so the coach does not trigger its own VAD.
        do { try input.setVoiceProcessingEnabled(true) }
        catch { throw SpeakingAudioError("无法打开语音处理，请检查系统的麦克风与输出设备。") }
        let format = input.outputFormat(forBus: 0)
        let encoder = try SpeakingMicrophoneConverter(input: format)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        let (stream, sink) = AsyncThrowingStream<SpeakingMicrophoneChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(24))
        continuation = sink
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, time in
            do {
                let data = try encoder.encode(buffer)
                guard !data.isEmpty else { return }
                let timestamp = time.isHostTimeValid ? time.hostTime : mach_absolute_time()
                if case .dropped = sink.yield(SpeakingMicrophoneChunk(pcm: data, hostTime: timestamp)) {
                    sink.finish(throwing: SpeakingAudioError("上传速度跟不上录音，练习已停止。请检查网络后重试。"))
                }
            } catch { sink.finish(throwing: error) }
        }
        tapInstalled = true
        engine.prepare()
        do { try engine.start() }
        catch { throw SpeakingAudioError("无法启动麦克风和音频输出，请检查设备后重试。") }
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                       object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in
                if self?.engine.isRunning == false { onDeviceChange() }
            }
        }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in onDeviceChange() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr {
                deviceListeners.append((address, listener))
            }
        }
        return stream
    }

    func setMuted(_ muted: Bool) {
        engine.inputNode.isVoiceProcessingInputMuted = muted
    }

    func enqueue(_ pcm: Data, itemID: String) throws {
        guard engine.isRunning else { throw SpeakingAudioError("音频设备已断开，请重新开始练习。") }
        let total = pcm.count / 2
        guard total > 0, pcm.count.isMultiple(of: 2) else { throw SpeakingAudioError("收到无效的语音片段。") }
        if self.itemID != itemID {
            guard self.itemID == nil else { throw SpeakingAudioError("教练的语音片段顺序异常，请重新开始练习。") }
            self.itemID = itemID
        }
        guard queuedFrames - played.frames + total <= Int(outputFormat.sampleRate * 120) else {
            throw SpeakingAudioError("待播放的语音过长，请重新开始练习。")
        }
        // Played-back completions include output-device latency, including Bluetooth.
        // Small buffers bound the uncertainty of the server's truncation position.
        let receipt = played
        for offset in stride(from: 0, to: total, by: 480) {
            let count = min(480, total - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: UInt32(count)),
                  let samples = buffer.floatChannelData?[0] else { throw SpeakingAudioError("无法创建播放缓冲区。") }
            buffer.frameLength = UInt32(count)
            pcm.withUnsafeBytes { bytes in
                for index in 0..<count {
                    let sample = bytes.loadUnaligned(fromByteOffset: (offset + index) * 2, as: Int16.self)
                    samples[index] = Float(Int16(littleEndian: sample)) / 32_768
                }
            }
            queuedFrames += count
            let end = queuedFrames
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
                receipt.acknowledge(end)
                Task { @MainActor in
                    guard let self, self.played === receipt else { return }
                    self.finishIfPlayed()
                }
            }
        }
        if !player.isPlaying { player.play() }
    }

    func responseFinished() {
        hasFinishedResponse = true
        finishIfPlayed()
    }

    private func finishIfPlayed() {
        guard engine.isRunning, player.isPlaying, hasFinishedResponse, let itemID,
              queuedFrames == played.frames else { return }
        clearPlayback()
        onPlayed?(itemID)
    }

    func interrupt(_ itemID: String) -> Int? {
        finishIfPlayed()
        guard self.itemID == itemID else { return nil }
        let milliseconds = played.frames * 1000 / Int(outputFormat.sampleRate)
        clearPlayback()
        return milliseconds
    }

    private func clearPlayback() {
        played = SpeakingPlayedAudio()
        if player.isPlaying { player.stop() }
        itemID = nil
        queuedFrames = 0
        hasFinishedResponse = false
    }

    func stop() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        for (var address, listener) in deviceListeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListeners.removeAll()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        continuation?.finish()
        continuation = nil
        clearPlayback()
        engine.stop()
        onPlayed = nil
    }
}
