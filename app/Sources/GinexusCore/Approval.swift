// Approval.swift (SP5/SP2-tail) — mint single-use approval tokens for irreversible/OS actions,
// byte-for-byte compatible with the Rust core's `ginexus_security::approval`. The signed app
// computes this AFTER biometric auth; the core verifies (constant-time HMAC, single-use nonce,
// bounded TTL, boot-id bound). Parity is locked by the cross-language golden vectors in tests.
import Foundation
import CryptoKit

public enum Approval {
    public static let canonVersion = 1
    /// Default token TTL the app mints with (must stay <= the core's DEFAULT_MAX_TTL_MS = 120s).
    public static let defaultTTLms: Int64 = 90_000

    /// Canonical serialization — must match serde_json with sorted keys + compact separators
    /// (`json.dumps(sort_keys=True, separators=(",",":"))`). JSONSerialization(.sortedKeys)
    /// produces sorted keys (recursively) with no whitespace, matching the Rust BTreeMap output.
    public static func canonicalPayload(
        action: String, args: [String: Any], target: String, nonce: String,
        expiryMs: Int64, bootId: String
    ) -> Data? {
        let obj: [String: Any] = [
            "v": canonVersion,
            "action": action,
            "args": args,
            "target": target,
            "nonce": nonce,
            "expiry_ms": expiryMs,
            "boot_id": bootId,
        ]
        guard JSONSerialization.isValidJSONObject(obj) else { return nil }
        return try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    /// HMAC-SHA256(raw key bytes, canonical payload) → lowercase hex. `approvalKeyHex` is the
    /// 64-char hex the app minted + injected as GINEXUS_APPROVAL_KEY (decoded to its 32 raw bytes,
    /// which is exactly the key the core's ApprovalVerifier holds).
    public static func mint(
        approvalKeyHex: String, action: String, args: [String: Any], target: String,
        nonce: String, expiryMs: Int64, bootId: String
    ) -> String? {
        guard let key = hexDecode(approvalKeyHex), key.count >= 32,
              let payload = canonicalPayload(action: action, args: args, target: target,
                                             nonce: nonce, expiryMs: expiryMs, bootId: bootId)
        else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// `target_of` from the agent loop: args["name"] ?? args["target"] ?? "tool:<name>".
    public static func target(forTool name: String, args: [String: Any]) -> String {
        if let n = args["name"] as? String { return n }
        if let t = args["target"] as? String { return t }
        return "tool:\(name)"
    }

    /// 32 bytes of OS entropy → hex (single-use nonce).
    public static func freshNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public static func hexDecode(_ s: String) -> Data? {
        guard s.count % 2 == 0 else { return nil }
        var data = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
            data.append(b)
            i = j
        }
        return data
    }
}
