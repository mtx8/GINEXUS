// WAVUtil.swift — build a canonical 16-bit PCM mono WAV from float samples. Pure + testable; used
// by mic capture before POSTing a clip to the sidecar's /transcribe.
import Foundation

public enum WAVUtil {
    /// Encode float samples in [-1, 1] as a mono 16-bit PCM WAV at `sampleRate`.
    public static func wav(fromFloat samples: [Float], sampleRate: Int) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            var v = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        return wav(fromPCM16: pcm, sampleRate: sampleRate, channels: 1)
    }

    /// Wrap raw int16-LE PCM bytes in a WAV container.
    public static func wav(fromPCM16 pcm: Data, sampleRate: Int, channels: Int) -> Data {
        let byteRate = sampleRate * channels * 2
        let blockAlign = channels * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                       // PCM fmt chunk size
        u16(1)                        // PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(16)                       // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
