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
        // NOTE: voice-processing (AEC) is intentionally OFF — on multi-channel input devices it can
        // deliver all-zero audio. Barge-in instead relies on disarming the VAD while speaking.
        let hwFormat = input.outputFormat(forBus: 0)
        inputSR = hwFormat.sampleRate
        // The tap fires on a realtime audio thread. It MUST be @Sendable (non-isolated) — if it
        // inherits this @MainActor class's isolation, Swift's runtime asserts the wrong executor and
        // crashes (EXC_BREAKPOINT). Do only thread-safe local work here, then hop to the main actor.
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { @Sendable [weak self] buf, _ in
            guard let chans = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            let chCount = max(1, Int(buf.format.channelCount))
            // Scan EVERY channel and keep the loudest — on a multi-channel / aggregate device the live
            // mic may not be channel 0. Use that channel's samples for transcription.
            var bestRMS: Float = 0
            var bestCh = 0
            for c in 0..<chCount {
                let ch = chans[c]
                var sum: Float = 0
                for i in 0..<n { let s = ch[i]; sum += s * s }
                let rms = (n > 0) ? (sum / Float(n)).squareRoot() : 0
                if rms > bestRMS { bestRMS = rms; bestCh = c }
            }
            let frame = Array(UnsafeBufferPointer(start: chans[bestCh], count: n))
            let rms = bestRMS
            Task { @MainActor [weak self] in self?.consume(frame: frame, rms: rms, channels: chCount) }
        }
        engine.prepare()
        try engine.start()
        running = true
        VoiceLog.log("mic engine started: inputSR=\(inputSR), tapFormat=\(hwFormat)")
    }

    // Diagnostics: track peak level between throttled log lines so we can see if audio is arriving.
    private var diagPeak: Float = 0
    private var diagCount = 0

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

    private func consume(frame: [Float], rms: Float, channels: Int = 1) {
        onLevel?(rms)
        // Throttled diagnostics (~ every 2s at 21ms/frame): peak level + channel count so we can tell
        // "no audio reaching mic" from "audio present but below VAD threshold".
        diagPeak = max(diagPeak, rms); diagCount += 1
        if diagCount >= 96 {
            VoiceLog.log(String(format: "mic level: peak=%.4f thresh=%.4f ch=%d armed=%@ sawSpeech=%@",
                                diagPeak, energyThreshold, channels, armed ? "Y" : "N", sawSpeech ? "Y" : "N"))
            diagPeak = 0; diagCount = 0
        }
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
        VoiceLog.log("emitUtterance: \(samples.count) samples @ \(sr)Hz -> \(wav.count) bytes")
        onUtterance?(wav)
    }
}
