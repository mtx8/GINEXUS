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
    private var ttsTask: Task<Void, Never>?
    private var bargeInArmAt = Date.distantFuture   // ignore self-echo right after speaking starts
    private var languageID = "en"
    private var voiceRef: String?

    init?(app: AppModel, audioBase: String) {
        guard let c = VoiceClient(base: audioBase) else { return nil }
        self.app = app
        self.client = c
    }

    // MARK: lifecycle

    func start() async {
        guard state == .idle else { return }
        let granted = await Self.requestMic()
        guard granted else { errorText = "Microphone access denied. Enable it in System Settings › Privacy."; return }
        await client.warmup()

        input.onLevel = { [weak self] in self?.level = $0 }
        input.onSpeechStart = { [weak self] in self?.handleSpeechStart() }
        input.onUtterance = { [weak self] wav in self?.handleUtterance(wav) }

        // Speak finished agent replies (set the hook only while voice is live).
        app?.onTurnComplete = { [weak self] text in self?.speak(text) }

        do {
            try input.start()
        } catch {
            errorText = "Couldn't start the microphone: \(error.localizedDescription)"
            return
        }
        beginListening()
    }

    func stop() {
        ttsTask?.cancel()
        ttsTask = nil
        input.stop()
        output.shutdown()
        if app?.onTurnComplete != nil { app?.onTurnComplete = nil }
        state = .idle
        level = 0
    }

    // MARK: state transitions

    private func beginListening() {
        state = .listening
        input.arm()
    }

    private func handleSpeechStart() {
        // Barge-in: only meaningful while GINEXUS is speaking, and only after a short guard so its
        // own audio (despite AEC) can't interrupt itself.
        guard state == .speaking, Date() >= bargeInArmAt else { return }
        ttsTask?.cancel()
        ttsTask = nil
        output.stop()
        // Stay armed; the in-progress utterance will arrive via onUtterance as the next turn.
        state = .listening
    }

    private func handleUtterance(_ wav: Data) {
        guard state == .listening else { return }   // ignore mic while transcribing/thinking
        input.disarm()
        state = .transcribing
        Task {
            do {
                let text = try await client.transcribe(wav: wav)
                guard active else { return }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    beginListening()
                    return
                }
                lastTranscript = trimmed
                state = .thinking
                app?.send(trimmed)   // streams the reply; onTurnComplete → speak()
            } catch {
                errorText = "Transcription failed: \(error.localizedDescription)"
                beginListening()
            }
        }
    }

    private func speak(_ text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard active, !clean.isEmpty else { if active { beginListening() }; return }
        state = .speaking
        input.arm()                                   // listen for barge-in while speaking
        bargeInArmAt = Date().addingTimeInterval(0.4) // ignore self-echo at the very start
        let stream = client.synthesizeStream(text: clean, languageID: languageID, voiceRef: voiceRef)
        ttsTask = Task {
            do {
                for try await chunk in stream {
                    if Task.isCancelled { break }
                    output.enqueue(pcm16le: chunk)
                }
            } catch {
                // playback failed/cancelled — fall through to listening
            }
            if !Task.isCancelled, self.state == .speaking {
                // Let the tail of the queued audio play, then return to listening.
                try? await Task.sleep(nanoseconds: 300_000_000)
                if self.state == .speaking { self.beginListening() }
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
