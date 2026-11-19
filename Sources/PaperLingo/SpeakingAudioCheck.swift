import AVFoundation

@MainActor enum SpeakingAudioCheck {
    private enum Event {
        case input(frames: Int)
        case played
        case deviceChanged
        case inputEnded
        case inputFailed(String)
        case timedOut
    }

    static func run() async -> Int32 {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let authorized = status == .notDetermined ? await AVCaptureDevice.requestAccess(for: .audio) : status == .authorized
        guard authorized else {
            print("FAIL microphone authorization status=\(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            return 1
        }

        let audio = SpeakingSessionAudio()
        let (events, sink) = AsyncStream<Event>.makeStream()
        defer {
            sink.finish()
            audio.stop()
        }

        let itemID = "local-silent-playback"
        let playbackFrames = 2_400
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(6))
        do {
            let input = try audio.start(onPlayed: { item in
                if item == itemID { sink.yield(.played) }
            }, onDeviceChange: { sink.yield(.deviceChanged) })
            let inputTask = Task {
                var reported = false
                do {
                    for try await chunk in input {
                        if !reported {
                            let count = chunk.pcm.count
                            guard count > 0, count.isMultiple(of: MemoryLayout<Int16>.size) else {
                                sink.yield(.inputFailed("invalid PCM16 buffer length"))
                                return
                            }
                            sink.yield(.input(frames: count / MemoryLayout<Int16>.size))
                            reported = true
                        }
                    }
                    sink.yield(.inputEnded)
                } catch { sink.yield(.inputFailed(error.localizedDescription)) }
            }
            let timer = Task {
                try await clock.sleep(until: deadline)
                sink.yield(.timedOut)
            }
            defer {
                inputTask.cancel()
                timer.cancel()
            }
            try audio.enqueue(Data(count: playbackFrames * MemoryLayout<Int16>.size), itemID: itemID)
            audio.responseFinished()

            var firstFrames = 0
            var played = false
            for await event in events {
                switch event {
                case .input(let frames): firstFrames = frames
                case .played: played = true
                case .deviceChanged: throw SpeakingAudioError("audio route changed")
                case .inputEnded: throw SpeakingAudioError("microphone stream ended")
                case .inputFailed(let reason): throw SpeakingAudioError(reason)
                case .timedOut: throw SpeakingAudioError("timed out (inputFrames=\(firstFrames), playbackCompleted=\(played))")
                }
                if firstFrames > 0 && played {
                    let mode = audio.usesVoiceProcessing ? "voiceProcessing" : "standard"
                    print("PASS mode=\(mode) sampleRate=\(Int(SpeakingMicrophoneConverter.sampleRate)) firstInputFrames=\(firstFrames) silentPlaybackFrames=\(playbackFrames)")
                    return 0
                }
            }
            throw SpeakingAudioError("audio check ended")
        } catch {
            print("FAIL \(error.localizedDescription)")
            return 1
        }
    }
}
