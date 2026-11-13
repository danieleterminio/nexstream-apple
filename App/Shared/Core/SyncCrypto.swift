import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The cryptography of the sync protocol (docs/sync-protocol.md): SHA-256, HMAC-SHA256 and AES-256-GCM, the same
/// bytes the Android app produces.
enum SyncCrypto {
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    #if canImport(CryptoKit)
    static func sha256(_ s: String) -> Data { Data(SHA256.hash(data: Data(s.utf8))) }

    /// The record's name on the server: HMAC of its plain name, first 40 hex characters.
    static func kid(_ key: Data, _ plainKey: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(plainKey.utf8), using: SymmetricKey(data: key))
        return String(hex(Data(mac)).prefix(40))
    }

    /// base64( nonce || ciphertext || tag )
    static func seal(_ key: Data, _ plain: Data) -> String? {
        guard let box = try? AES.GCM.seal(plain, using: SymmetricKey(data: key)), let all = box.combined else { return nil }
        return all.base64EncodedString()
    }

    static func open(_ key: Data, _ b64: String) -> Data? {
        guard let all = Data(base64Encoded: b64), let box = try? AES.GCM.SealedBox(combined: all) else { return nil }
        return try? AES.GCM.open(box, using: SymmetricKey(data: key))
    }
    #else
    // the Windows type-check has no CryptoKit: these are never run
    static func sha256(_ s: String) -> Data { Data(s.utf8) }
    static func kid(_ key: Data, _ plainKey: String) -> String { plainKey }
    static func seal(_ key: Data, _ plain: Data) -> String? { nil }
    static func open(_ key: Data, _ b64: String) -> Data? { nil }
    #endif

    static func accountId(user: String, pass: String) -> String {
        hex(sha256("nexstream/sync/1/id\n" + user.trimmed.lowercased() + "\n" + pass.trimmed))
    }
    static func key(user: String, pass: String) -> Data {
        sha256("nexstream/sync/1/key\n" + user.trimmed.lowercased() + "\n" + pass.trimmed)
    }
}
