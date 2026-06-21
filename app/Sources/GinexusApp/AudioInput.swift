// AudioInput.swift — continuous mic capture with a simple energy VAD. While "armed" it watches the
// input level; once speech starts it fires onSpeechStart (used for barge-in), and when trailing
// silence is detected it emits the captured utterance as WAV via onUtterance.
//
// All AVAudioEngine tap work happens on a realtime thread; VAD state + callbacks are hopped to the
// main actor so they're safe to touch from the controller and UI.
import AVFoundation
import GinexusCore

@MainActor
final class AudioInput {
    private let engine = AVAudioEngine()
    private var running = false
    private var inputSR = 48000.0

    // VAD tunables (frame ≈ 1024 samples ≈ 21 ms @ 48 kHz).
    var energyThreshold: Float = 0.012   // RMS above this counts as voiced
    var startFrames = 3                  // ~60 ms of voiced audio → speech start
    var endSilenceFrames = 32            // ~680 ms of silence → utterance end
    private let maxUtteranceSeconds = 30.0

    // VAD state
    private var armed = false
    private var sawSpeech = false
    private var voicedRun = 0
    private var silenceRun = 0
    private var buffer = [Float]()

    /// Fires once when speech begins after arming (good moment to cut off TTS playback).
    var onSpeechStart: (() -> Void)?
    /// Fires with a finished utterance as WAV bytes (mono 16-bit at the input sample rate).
    var onUtterance: ((Data) -> Void)?
    /// Continuous RMS level in [0, ~1] for a UI meter.
    var onLevel: ((Float) -> Void)?

    func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        // Acoustic echo cancellation + noise suppression so GINEXUS's own speech (during playback)
        // doesn't false-trigger barge-in, and background noise doesn't trip the VAD.
        try? input.setVoiceProcessingEnabled(true)
        let hwFormat = input.outputFormat(forBus: 0)
        inputSR = hwFormat.sampleRate
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buf, _ in
            guard let ch = buf.floatChannelData?[0] else { return }
            let n = Int(buf.frameLength)
            var sum: Float = 0
            for i in 0..<n { let s = ch[i]; sum += s * s }
            let rms = (n > 0) ? (sum / Float(n)).squareRoot() : 0
            let frame = Array(UnsafeBufferPointer(start: ch, count: n))
            Task { @MainActor [weak self] in self?.consume(frame: frame, rms: rms) }
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    /// Begin listening for the next utterance (resets VAD). Tap keeps running across turns.
    func arm() {
        armed = true
        resetVAD()
    }

    /// Stop emitting utterances/speech-start (e.g., while we don't want input to drive a turn).
    func disarm() {
        armed = false
        resetVAD()
    }

    private func resetVAD() {
        sawSpeech = false
        voicedRun = 0
        silenceRun = 0
        buffer.removeAll(keepingCapacity: true)
    }

    private func consume(frame: [Float], rms: Float) {
        onLevel?(rms)
        guard armed else { return }
        let voiced = rms > energyThreshold
        buffer.append(contentsOf: frame)

        if voiced {
            voicedRun += 1
            silenceRun = 0
            if !sawSpeech && voicedRun >= startFrames {
                sawSpeech = true
                onSpeechStart?()
            }
        } else {
            silenceRun += 1
            voicedRun = 0
        }

        // End of utterance: had speech, then enough trailing silence.
        if sawSpeech && silenceRun >= endSilenceFrames {
            emitUtterance()
            return
        }
        // Safety cap so a stuck VAD can't grow the buffer unbounded.
        if Double(buffer.count) / inputSR > maxUtteranceSeconds {
            if sawSpeech { emitUtterance() } else { resetVAD() }
        }
    }

    private func emitUtterance() {
        let samples = buffer
        let sr = Int(inputSR)
        resetVAD()
        guard !samples.isEmpty else { return }
        let wav = WAVUtil.wav(fromFloat: samples, sampleRate: sr)
        onUtterance?(wav)
    }
}
