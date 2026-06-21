// AudioOutput.swift — streamed playback of the sidecar's int16-LE mono 24 kHz PCM via
// AVAudioEngine + a player node. enqueue() is called with chunks as they arrive; stop() halts
// instantly for barge-in.
import AVFoundation
import GinexusCore

@MainActor
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: VoiceClient.sampleRate, channels: 1, interleaved: false)!
    private var started = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    func start() {
        guard !started else { return }
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            started = false
        }
    }

    /// Append a chunk of int16-LE mono 24 kHz PCM to the playback queue.
    func enqueue(pcm16le: Data) {
        let frames = pcm16le.count / 2
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let out = buf.floatChannelData?[0] else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        pcm16le.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                out[i] = Float(Int16(littleEndian: s[i])) / 32768.0
            }
        }
        start()
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Stop playback immediately and drop any queued audio (barge-in).
    func stop() {
        guard started else { return }
        player.stop()
        player.reset()
        player.play()   // keep the node ready for the next reply
    }

    func shutdown() {
        player.stop()
        engine.stop()
        started = false
    }
}
