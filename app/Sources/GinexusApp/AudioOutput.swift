// AudioOutput.swift — streamed playback of the sidecar's int16-LE mono 24 kHz PCM.
//
// NOT @MainActor: PCM int16→float conversion and buffer scheduling run on a dedicated serial queue,
// so they never compete with the main thread (SwiftUI animation, mic-level @Published updates). That
// main-actor contention was a source of audio micro-stutter. AVAudioPlayerNode.scheduleBuffer is
// thread-safe. A small jitter buffer (~280 ms) is accumulated before playback starts so brief
// upstream gaps don't underrun into audible silence. enqueue() is called with chunks as they arrive;
// stop() halts instantly.
import AVFoundation
import GinexusCore

final class AudioOutput: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: VoiceClient.sampleRate, channels: 1, interleaved: false)!
    private let q = DispatchQueue(label: "ginexus.audio.output")

    // All of the following are touched only on `q`.
    private var engineStarted = false
    private var playing = false
    private var pending = 0                 // buffers scheduled but not yet played
    private var queuedFrames = 0            // frames currently buffered ahead (jitter cushion)
    private var drainHandler: (() -> Void)?
    private var residual = Data()           // a trailing odd byte carried to the next chunk (alignment)
    private let prebufferFrames = Int(VoiceClient.sampleRate * 0.28)   // ~280 ms cushion before play()

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    private func ensureEngineLocked() {
        guard !engineStarted else { return }
        do { try engine.start(); engineStarted = true }
        catch { engineStarted = false; VoiceLog.log("AudioOutput engine start failed: \(error)") }
    }

    /// Append a chunk of int16-LE mono 24 kHz PCM. Conversion + scheduling happen off the main thread.
    func enqueue(pcm16le: Data) {
        q.async { [self] in
            // HTTP chunks are arbitrary-sized — an odd byte count would shift every following sample
            // by one byte (= static). Carry the trailing odd byte to the next chunk so conversion is
            // always 16-bit aligned, and read each sample little-endian byte-by-byte (no alignment risk).
            var data = residual
            data.append(pcm16le)
            let usable = data.count - (data.count % 2)
            residual = usable < data.count ? data.suffix(from: usable) : Data()
            let frames = usable / 2
            guard frames > 0,
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
                  let out = buf.floatChannelData?[0] else { return }
            buf.frameLength = AVAudioFrameCount(frames)
            data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                for i in 0..<frames {
                    let lo = UInt16(raw[i * 2])
                    let hi = UInt16(raw[i * 2 + 1])
                    out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
                }
            }
            ensureEngineLocked()
            guard engineStarted else { return }
            pending += 1
            queuedFrames += frames
            player.scheduleBuffer(buf, completionHandler: { [weak self] in
                self?.q.async { self?.bufferCompletedLocked(frames) }
            })
            if !playing && queuedFrames >= prebufferFrames {   // start once a cushion is buffered
                player.play(); playing = true
            }
        }
    }

    /// Force playback even if still under the prebuffer threshold (e.g. a short final reply).
    func flush() {
        q.async { [self] in
            ensureEngineLocked()
            if engineStarted && !playing && pending > 0 { player.play(); playing = true }
        }
    }

    private func bufferCompletedLocked(_ frames: Int) {
        pending = max(0, pending - 1)
        queuedFrames = max(0, queuedFrames - frames)
        if pending == 0, let h = drainHandler { drainHandler = nil; h() }
    }

    /// Fire `completion` once all currently-queued audio has finished playing. Call AFTER the last
    /// chunk is enqueued; forces playback so a tiny final chunk still drains.
    func whenDrained(_ completion: @escaping () -> Void) {
        q.async { [self] in
            ensureEngineLocked()
            if engineStarted && !playing && pending > 0 { player.play(); playing = true }
            if pending == 0 { completion() } else { drainHandler = completion }
        }
    }

    /// Stop playback immediately and drop any queued audio.
    func stop() {
        q.async { [self] in
            guard engineStarted else { return }
            player.stop(); player.reset()
            playing = false; pending = 0; queuedFrames = 0; drainHandler = nil; residual = Data()
        }
    }

    func shutdown() {
        q.async { [self] in
            player.stop(); engine.stop()
            engineStarted = false; playing = false; pending = 0; queuedFrames = 0; drainHandler = nil; residual = Data()
        }
    }
}
