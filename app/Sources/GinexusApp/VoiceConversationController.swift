// VoiceConversationController.swift — the hands-free loop. Ties mic capture (+VAD) → sidecar STT →
// the normal agent turn (AppModel.send, so the voice turn shows up in the transcript) → streamed
// sidecar TTS → playback, with barge-in: talking over GINEXUS cuts off its reply and starts a new
// turn. Acoustic echo cancellation (input voice-processing) keeps the assistant's own audio from
// false-triggering barge-in.
import Foundation
import AVFoundation
import GinexusCore

@MainActor
final class VoiceConversationController: ObservableObject {
    enum State: String { case idle, listening, transcribing, thinking, speaking }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Float = 0          // mic RMS, for the UI meter
    @Published private(set) var lastTranscript = ""
    @Published var errorText: String?

    var active: Bool { state != .idle }

    private weak var app: AppModel?
    private let client: VoiceClient
    private let input = AudioInput()
    private let output = AudioOutput()
    private var languageID = "en"
    private var voiceRef: String?

    // Streaming-TTS pipeline: speak each sentence as soon as it completes in the reply stream, so
    // audio starts long before the full text answer is done.
    private var consumedLen = 0            // chars of the reply already turned into speech chunks
    private var speechQueue: [String] = [] // pending sentence chunks to synthesize, in order
    private var pumpRunning = false        // a synth/play pump is active
    private var pumpTask: Task<Void, Never>?
    private var replyFinal = false         // the LLM reply finished streaming

    init?(app: AppModel, audioBase: String) {
        guard let c = VoiceClient(base: audioBase) else { return nil }
        self.app = app
        self.client = c
    }

    // MARK: lifecycle

    func start() async {
        guard state == .idle else { return }
        VoiceLog.log("start() called; audioBase=\(client.base.absoluteString)")
        let granted = await Self.requestMic()
        VoiceLog.log("mic permission granted=\(granted)")
        guard granted else { errorText = "Microphone access denied. Enable it in System Settings › Privacy."; return }
        VoiceLog.log("warming sidecar…")
        await client.warmup()
        VoiceLog.log("warmup done")

        input.onLevel = { [weak self] in self?.level = $0 }
        input.onSpeechStart = { [weak self] in self?.handleSpeechStart() }
        input.onUtterance = { [weak self] wav in self?.handleUtterance(wav) }

        // Stream the reply to speech sentence-by-sentence (set the hook only while voice is live).
        app?.onAssistantText = { [weak self] text, final in self?.onReplyText(text, final: final) }

        do {
            try input.start()
            VoiceLog.log("AudioInput.start() ok")
        } catch {
            VoiceLog.log("AudioInput.start() FAILED: \(error)")
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        beginListening()
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        speechQueue.removeAll()
        input.stop()
        output.shutdown()
        app?.onAssistantText = nil
        state = .idle
        level = 0
    }

    // MARK: state transitions

    private func beginListening() {
        state = .listening
        input.arm()
    }

    private func handleSpeechStart() {
        // Barge-in is disabled in half-duplex (mic is off while speaking), so this is inert.
    }

    private func handleUtterance(_ wav: Data) {
        VoiceLog.log("utterance received: \(wav.count) bytes, state=\(state.rawValue)")
        guard state == .listening else { return }   // ignore mic while transcribing/thinking/speaking
        input.disarm()
        state = .transcribing
        Task {
            do {
                let text = try await client.transcribe(wav: wav)
                VoiceLog.log("transcribed: \(text.prefix(80))")
                guard active else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    beginListening()
                    return
                }
                lastTranscript = trimmed
                state = .thinking
                // Reset the streaming-TTS pipeline for this turn, then fire the agent. The reply
                // streams back via onReplyText and is spoken sentence-by-sentence.
                consumedLen = 0
                replyFinal = false
                speechQueue.removeAll()
                app?.send(trimmed)
            } catch {
                errorText = "Transcription failed: \(error.localizedDescription)"
                beginListening()
            }
        }
    }

    // MARK: streaming TTS — speak each sentence the moment it completes

    private static let enders: Set<Character> = [".", "!", "?", "\n", "…", "。", "！", "？"]

    /// Called with the growing reply text (final=false) and once at the end (final=true). Extracts
    /// newly-completed sentences and queues them for synthesis immediately.
    private func onReplyText(_ text: String, final: Bool) {
        guard active else { return }
        let chars = Array(text)
        if consumedLen > chars.count { consumedLen = 0 }   // reply text was reset (e.g. tool preamble)
        var lastBoundary = consumedLen
        var i = consumedLen
        while i < chars.count {
            if Self.enders.contains(chars[i]) { lastBoundary = i + 1 }
            i += 1
        }
        let end = final ? chars.count : lastBoundary
        if end > consumedLen {
            let chunk = String(chars[consumedLen..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            consumedLen = end
            if !chunk.isEmpty { enqueueSpeech(chunk) }
        }
        if final {
            replyFinal = true
            if state == .thinking {            // nothing was spoken (empty reply) → resume listening
                beginListening()
            } else {
                maybeFinishSpeaking()
            }
        }
    }

    private func enqueueSpeech(_ s: String) {
        // HALF-DUPLEX: as soon as we begin speaking, the mic stays disarmed so GINEXUS never hears
        // itself; it re-arms only after the whole reply has been spoken and playback has drained.
        if state != .speaking { state = .speaking; input.disarm() }
        speechQueue.append(s)
        pumpSpeech()
    }

    /// Serial pump: synthesize queued sentences in order, streaming each into the player. Synthesis
    /// (RTF < 1) runs ahead of playback, so speech is continuous.
    private func pumpSpeech() {
        guard !pumpRunning else { return }
        pumpRunning = true
        pumpTask = Task { @MainActor in
            while !speechQueue.isEmpty {
                let s = speechQueue.removeFirst()
                if Task.isCancelled { break }
                VoiceLog.log("synth chunk: \(s.prefix(48))")
                do {
                    for try await chunk in client.synthesizeStream(text: s, languageID: languageID, voiceRef: voiceRef) {
                        if Task.isCancelled || !self.active { break }
                        self.output.enqueue(pcm16le: chunk)
                    }
                } catch { /* skip this chunk */ }
            }
            pumpRunning = false
            maybeFinishSpeaking()
        }
    }

    /// Re-open the mic only once the reply is fully received, all chunks synthesized, and playback
    /// has actually drained (+ a short room-tail guard).
    private func maybeFinishSpeaking() {
        guard replyFinal, !pumpRunning, speechQueue.isEmpty, state == .speaking else { return }
        output.whenDrained { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard let self, self.state == .speaking, self.speechQueue.isEmpty, !self.pumpRunning else { return }
                VoiceLog.log("reply done + drained → listening")
                self.beginListening()
            }
        }
    }

    private static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default: return false
        }
    }
}
