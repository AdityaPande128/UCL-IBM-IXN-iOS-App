import Foundation
import CryptoKit

// Mirror of the daemon's directCrypto and the Android port: HKDF-SHA256 from
// the camera-carried secret, AES-256-GCM envelopes over raw-deflated JSON,
// sender name as AAD. The formats are pinned against Node-generated vectors
// in the unit tests; a byte of drift here is silent total failure.
public enum DirectCrypto {

    public static let windowMs: Int64 = 120_000

    static func hmac(_ key: Data, _ data: Data) -> Data {
        let k = key.isEmpty ? Data(count: 32) : key
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: k)))
    }

    // RFC 5869 with an absent salt (zero-filled key; HMAC pads identically).
    public static func derive(secretHex: String, info: String, bytes: Int) throws -> Data {
        guard let secret = Data(hex: secretHex), secret.count == 32 else {
            throw JarvisError.badSecret
        }
        let prk = hmac(Data(count: 32), secret)
        var block = Data()
        var out = Data()
        var counter: UInt8 = 1
        while out.count < bytes {
            block = hmac(prk, block + Data(info.utf8) + Data([counter]))
            out.append(block.prefix(bytes - out.count))
            counter += 1
        }
        return out
    }

    public static func topicFor(secretHex: String) throws -> String {
        "jarvis-" + (try derive(secretHex: secretHex, info: "jarvis-direct/topic", bytes: 16)).hexString
    }

    public static func keyFor(secretHex: String) throws -> Data {
        try derive(secretHex: secretHex, info: "jarvis-direct/signal", bytes: 32)
    }

    // The remote door's key: the same secret, a different corridor.
    public static func remoteKeyFor(secretHex: String) throws -> Data {
        try derive(secretHex: secretHex, info: "jarvis-remote/ws", bytes: 32)
    }

    // MARK: - Text envelopes: {v, from, ts, n, c}

    public static func seal(key: Data, from: String, payload: [String: Any],
                            nonce: Data? = nil, ts: Int64? = nil) -> String? {
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let deflated = body.deflatedRaw() else { return nil }
        let n = nonce ?? Data.randomNonce()
        let at = ts ?? Int64(Date().timeIntervalSince1970 * 1000)
        guard let box = try? AES.GCM.seal(deflated, using: SymmetricKey(data: key),
                                          nonce: AES.GCM.Nonce(data: n),
                                          authenticating: Data(from.utf8)) else { return nil }
        let envelope: [String: Any] = [
            "v": 1, "from": from, "ts": at,
            "n": n.base64EncodedString(),
            "c": (box.ciphertext + box.tag).base64EncodedString(),
        ]
        guard let raw = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    // A nonce that already opened inside the window never opens twice.
    public static func open(key: Data, selfName: String, raw: String,
                            seen: ReplayGuard = ReplayGuard.sharedText,
                            now: Int64? = nil) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (envelope["v"] as? NSNumber)?.intValue == 1,
              let from = envelope["from"] as? String, from != selfName,
              let ts = (envelope["ts"] as? NSNumber)?.int64Value,
              let nonceB64 = envelope["n"] as? String,
              let cipherB64 = envelope["c"] as? String,
              let nonce = Data(base64Encoded: nonceB64),
              let sealed = Data(base64Encoded: cipherB64), sealed.count >= 16
        else { return nil }
        let wall = now ?? Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(wall - ts) <= windowMs, !seen.contains(nonceB64) else { return nil }
        guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                               ciphertext: sealed.dropLast(16),
                                               tag: sealed.suffix(16)),
              let packed = try? AES.GCM.open(box, using: SymmetricKey(data: key),
                                             authenticating: Data(from.utf8)),
              let inflated = packed.inflatedRaw(),
              let parsed = (try? JSONSerialization.jsonObject(with: inflated)) as? [String: Any]
        else { return nil }
        seen.record(nonceB64, at: ts, wall: wall, window: windowMs)
        return parsed
    }

    // MARK: - Binary envelopes: [1][12B nonce][8B BE ts ms][ct+tag], AAD = from + ts

    public static func sealBinary(key: Data, from: String, data: Data,
                                  nonce: Data? = nil, ts: Int64? = nil) -> Data? {
        let n = nonce ?? Data.randomNonce()
        let at = ts ?? Int64(Date().timeIntervalSince1970 * 1000)
        var tsBytes = at.bigEndian
        let tsData = Data(bytes: &tsBytes, count: 8)
        guard let box = try? AES.GCM.seal(data, using: SymmetricKey(data: key),
                                          nonce: AES.GCM.Nonce(data: n),
                                          authenticating: Data(from.utf8) + tsData)
        else { return nil }
        return Data([1]) + n + tsData + box.ciphertext + box.tag
    }

    public static func openBinary(key: Data, from: String, buf: Data,
                                  seen: ReplayGuard? = nil,
                                  now: Int64? = nil) -> Data? {
        guard buf.count >= 1 + 12 + 8 + 16, buf.first == 1 else { return nil }
        let bytes = Data(buf)  // rebase indices
        let nonce = bytes.subdata(in: 1..<13)
        let tsData = bytes.subdata(in: 13..<21)
        let ts = tsData.withUnsafeBytes { $0.loadUnaligned(as: Int64.self).bigEndian }
        let wall = now ?? Int64(Date().timeIntervalSince1970 * 1000)
        guard abs(wall - ts) <= windowMs else { return nil }
        let marker = nonce.base64EncodedString()
        if let seen, seen.contains(marker) { return nil }
        let sealed = bytes.subdata(in: 21..<bytes.count)
        guard let box = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce),
                                               ciphertext: sealed.dropLast(16),
                                               tag: sealed.suffix(16)),
              let clear = try? AES.GCM.open(box, using: SymmetricKey(data: key),
                                            authenticating: Data(from.utf8) + tsData)
        else { return nil }
        seen?.record(marker, at: wall, wall: wall, window: windowMs)
        return clear
    }
}

public enum JarvisError: Error {
    case badSecret
}

// Window-pruned nonce dedup, shared by both envelope shapes. A lock, not an
// actor: callers sit on URLSession queues and must not suspend.
public final class ReplayGuard {
    public static let sharedText = ReplayGuard()
    private var marks: [String: Int64] = [:]
    private let lock = NSLock()

    public init() {}

    func contains(_ marker: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return marks[marker] != nil
    }

    func record(_ marker: String, at ts: Int64, wall: Int64, window: Int64) {
        lock.lock(); defer { lock.unlock() }
        marks[marker] = ts
        let cutoff = wall - window
        marks = marks.filter { $0.value >= cutoff }
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    public var hexString: String { map { String(format: "%02x", $0) }.joined() }

    static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 12)
        _ = SecRandomCopyBytes(kSecRandomDefault, 12, &bytes)
        return Data(bytes)
    }

    // Raw DEFLATE, no zlib header: Apple's .zlib algorithm is exactly that,
    // matching Node's deflateRawSync and Android's Deflater(nowrap = true).
    func deflatedRaw() -> Data? {
        try? (self as NSData).compressed(using: .zlib) as Data
    }

    func inflatedRaw() -> Data? {
        try? (self as NSData).decompressed(using: .zlib) as Data
    }
}
