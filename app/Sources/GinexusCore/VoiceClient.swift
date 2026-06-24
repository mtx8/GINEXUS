// VoiceClient.swift — thin async client for the local audio sidecar (loopback only).
// The realtime conversation loop calls this directly (lowest latency); the Rust core's `speak`
// tool is a separate, file-based path for agent-initiated speech in typed chats.
//
// Audio contract with the sidecar:
//   /transcribe  POST  raw WAV bytes            → {"text": ...}
//   /synthesize  POST  {text, language_id, ...} → streamed int16 LE mono PCM @ 24 kHz
import Foundation

public enum VoiceError: Error, Sendable { case badStatus(Int), badResponse }

public struct VoiceClient: Sendable {
    public let base: URL
    /// Native sample rate of the sidecar's TTS output (Chatterbox/S3Gen). Playback must match.
    public static let sampleRate: Double = 24000

    public init?(base: String) {
        guard let u = URL(string: base) else { return nil }
        self.base = u
    }

    /// Load both models on the sidecar (long-running on first call). Best-effort.
    public func warmup() async {
        var req = URLRequest(url: base.appendingPathComponent("warmup"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Transcribe a WAV clip (any sample rate; the sidecar resamples).
    public func transcribe(wav: Data) async throws -> String {
        var req = URLRequest(url: base.appendingPathComponent("transcribe"))
        req.httpMethod = "POST"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        req.httpBody = wav
        req.timeoutInterval = 120
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VoiceError.badResponse }
        guard http.statusCode == 200 else { throw VoiceError.badStatus(http.statusCode) }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Stream synthesized speech as int16-LE-mono-24 kHz PCM, delivered as it generates so playback
    /// can start before the whole reply is done. Uses a URLSession DATA delegate to receive Data
    /// chunks — NOT `AsyncBytes`, which yields one UInt8 at a time and added ~30 s of per-byte async
    /// overhead for a few hundred KB of PCM (that was the real cause of the audio stutter/lag).
    public func synthesizeStream(text: String, languageID: String = "en",
                                 voiceRef: String? = nil) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            var req = URLRequest(url: base.appendingPathComponent("synthesize"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = ["text": text, "language_id": languageID]
            if let voiceRef, !voiceRef.isEmpty { body["voice_ref"] = voiceRef }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 180

            let delegate = PCMStreamDelegate(continuation: continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: req)
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
            task.resume()
        }
    }
}

/// Receives the /synthesize response as Data chunks and forwards them to the AsyncThrowingStream.
private final class PCMStreamDelegate: NSObject, URLSessionDataDelegate {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            continuation.finish(throwing: VoiceError.badStatus(http.statusCode))
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }
}
