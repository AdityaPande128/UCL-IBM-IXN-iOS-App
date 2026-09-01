import Foundation

// Mirror of the daemon's channelFrames: [tag][4B BE header len][header JSON]
// [payload chunk]. Ordered+reliable channel, so sequence gaps mean bugs and
// kill the stream whole; nothing is ever delivered short.
public enum Frames {
    public static let tagWsBinary = 0x01
    public static let tagFileReq = 0x02
    public static let tagFileRes = 0x03
    public static let tagWsText = 0x04
    public static let chunkBytes = 64 * 1024

    // The binary cap matches the plain websocket's frame limit; the file
    // caps clear the HTTP lane's 50 MB so no rung strands a legal file.
    static let maxBytes: [Int: Int] = [
        tagWsBinary: 32 * 1024 * 1024,
        tagFileReq: 52 * 1024 * 1024,
        tagFileRes: 52 * 1024 * 1024,
        tagWsText: 16 * 1024 * 1024,
    ]

    public static func encode(tag: Int, header: String, payload: Data,
                              from: Int, length: Int) -> Data {
        let head = Data(header.utf8)
        var out = Data(capacity: 5 + head.count + length)
        out.append(UInt8(tag))
        var headLength = UInt32(head.count).bigEndian
        out.append(Data(bytes: &headLength, count: 4))
        out.append(head)
        if length > 0 { out.append(payload.subdata(in: from..<(from + length))) }
        return out
    }

    public struct Decoded {
        public let tag: Int
        public let header: [String: Any]
        public let payload: Data
    }

    public static func decode(_ frame: Data) -> Decoded? {
        guard frame.count >= 5 else { return nil }
        let bytes = Data(frame)  // rebase indices
        let tag = Int(bytes[0])
        guard tag >= 0x01, tag <= 0x04 else { return nil }
        let headLength = bytes.subdata(in: 1..<5).withUnsafeBytes {
            Int($0.loadUnaligned(as: UInt32.self).bigEndian)
        }
        guard headLength >= 0, headLength <= 64 * 1024,
              5 + headLength <= bytes.count else { return nil }
        guard let header = (try? JSONSerialization.jsonObject(
            with: bytes.subdata(in: 5..<(5 + headLength)))) as? [String: Any]
        else { return nil }
        return Decoded(tag: tag, header: header,
                       payload: bytes.subdata(in: (5 + headLength)..<bytes.count))
    }

    public static func chunks(tag: Int, meta: [String: Any], body: Data) -> [Data] {
        let total = max(1, (body.count + chunkBytes - 1) / chunkBytes)
        let sid = (meta["sid"] as? NSNumber)?.intValue ?? 0
        return (0..<total).map { seq in
            let from = seq * chunkBytes
            let length = max(0, min(chunkBytes, body.count - from))
            var header: [String: Any] = seq == 0 ? meta : [:]
            header["sid"] = sid
            header["seq"] = seq
            header["last"] = seq == total - 1
            let head = (try? JSONSerialization.data(withJSONObject: header))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return encode(tag: tag, header: head, payload: body, from: from, length: length)
        }
    }

    public struct Whole {
        public let tag: Int
        public let meta: [String: Any]
        public let body: Data
    }

    public final class Assembler {
        private struct Stream {
            let meta: [String: Any]
            var parts: [Data] = []
            var bytes = 0
            var next = 0
        }

        // Insertion order is age order, so the eldest half-done stream can be
        // evicted; a sender never legitimately needs many open.
        private var streams: [String: Stream] = [:]
        private var order: [String] = []
        private let maxOpenStreams = 16

        public init() {}

        public func accept(_ frame: Data) -> Whole? {
            guard let decoded = Frames.decode(frame),
                  let seq = (decoded.header["seq"] as? NSNumber)?.intValue,
                  let sid = (decoded.header["sid"] as? NSNumber)?.intValue
            else { return nil }
            let key = "\(decoded.tag):\(sid)"
            if seq == 0 {
                while streams.count >= maxOpenStreams, streams[key] == nil,
                      let eldest = order.first {
                    streams.removeValue(forKey: eldest)
                    order.removeFirst()
                }
                if streams[key] == nil { order.append(key) }
                streams[key] = Stream(meta: decoded.header)
            }
            guard var stream = streams[key], seq == stream.next else {
                drop(key)
                return nil
            }
            stream.next += 1
            stream.bytes += decoded.payload.count
            if stream.bytes > (Frames.maxBytes[decoded.tag] ?? 0) {
                drop(key)
                return nil
            }
            stream.parts.append(decoded.payload)
            guard (decoded.header["last"] as? Bool) == true else {
                streams[key] = stream
                return nil
            }
            drop(key)
            var body = Data(capacity: stream.bytes)
            for part in stream.parts { body.append(part) }
            return Whole(tag: decoded.tag, meta: stream.meta, body: body)
        }

        private func drop(_ key: String) {
            streams.removeValue(forKey: key)
            order.removeAll { $0 == key }
        }
    }
}
