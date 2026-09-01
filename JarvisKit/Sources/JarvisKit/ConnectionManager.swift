import Foundation

public enum ConnState: Equatable {
    case disconnected
    case connecting
    case live(via: String)
    case unreachable(hint: String)
    case pairRequired(reason: String)
}

public struct FetchedFile {
    public let status: Int
    public let name: String
    public let mime: String
    public let bytes: Data
}

// The transport ladder, v1: the paired address first (plain, token-gated),
// then a remembered remote door with every frame sealed under the pairing
// secret, then an honest state naming Telegram. Everything above sees one
// connection either way. The hole-punched rung slots in here in v2.
public final class ConnectionManager: NSObject {

    public var onState: ((ConnState) -> Void)?
    public var onEvent: (([String: Any]) -> Void)?
    public var onAudio: ((Data) -> Void)?

    private var host = ""
    private var port = 8080
    private var token = ""
    private var secret = ""
    private var remoteHost = ""
    private var remotePort = 0

    private let queue = DispatchQueue(label: "jarvis.connection")
    private var session: URLSession!
    private var socket: URLSessionWebSocketTask?
    private var ladderTask: Task<Void, Never>?
    private var wanted = false
    private var pairFailure = false

    private var via = ""
    private var sealKey: Data?
    private var sealSeenBin: ReplayGuard?
    private var assembler: Frames.Assembler?
    private var sawSealedReply = false
    private var liveNow = false

    private var readySignal: Once<Bool>?
    private var dropSignal: Once<String>?

    private var requestCounter: Int64 = 1
    private var fileWaiters: [String: Once<Frames.Whole?>] = [:]

    override public init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: self,
                             delegateQueue: nil)
    }

    private let hexSecret = try! NSRegularExpression(pattern: "^[0-9a-fA-F]{64}$")

    private func secretLooksReal() -> Bool {
        hexSecret.firstMatch(in: secret, range: NSRange(secret.startIndex..., in: secret)) != nil
    }

    public func start(host: String, port: Int, token: String, secret: String,
                      remoteHost: String = "", remotePort: Int = 0) {
        queue.sync {
            let unchanged = self.host == host && self.port == port
                && self.token == token && self.secret == secret
                && self.remoteHost == remoteHost && self.remotePort == remotePort
            if wanted && unchanged && ladderTask != nil { return }
            stopLocked()
            self.host = host
            self.port = port
            self.token = token
            self.secret = secret
            self.remoteHost = remoteHost
            self.remotePort = remotePort
            wanted = true
            pairFailure = false
            ladderTask = Task { [weak self] in await self?.ladder() }
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        wanted = false
        ladderTask?.cancel()
        ladderTask = nil
        closeLinkLocked()
        onState?(.disconnected)
    }

    private func closeLinkLocked() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        via = ""
        sealKey = nil
        sealSeenBin = nil
        assembler = nil
        liveNow = false
    }

    private func ladder() async {
        while queue.sync(execute: { wanted }) {
            onState?(.connecting)
            if !host.isEmpty, await attemptWs(host: host, port: port, label: "lan") {
                await awaitDrop(); continue
            }
            if queue.sync(execute: { pairFailure || !wanted }) { return }
            if secretLooksReal(), !remoteHost.isEmpty, remotePort > 0,
               await attemptWs(host: remoteHost, port: remotePort, label: "remote") {
                await awaitDrop(); continue
            }
            if queue.sync(execute: { pairFailure || !wanted }) { return }
            onState?(.unreachable(hint: "Mac unreachable. Telegram still works."))
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func awaitDrop() async {
        _ = await dropSignal?.wait()
        queue.sync { closeLinkLocked() }
        if !queue.sync(execute: { wanted }) { return }
        onState?(.disconnected)
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    private func attemptWs(host toHost: String, port toPort: Int,
                           label: String) async -> Bool {
        guard let url = URL(string: "ws://\(toHost):\(toPort)") else { return false }
        let ready = Once<Bool>()
        let drop = Once<String>()
        let sealed = label == "remote"
        let key = sealed ? (try? DirectCrypto.remoteKeyFor(secretHex: secret)) : nil
        if sealed && key == nil { return false }
        queue.sync {
            readySignal = ready
            dropSignal = drop
            via = label
            sealKey = key
            sealSeenBin = sealed ? ReplayGuard() : nil
            assembler = sealed ? Frames.Assembler() : nil
            sawSealedReply = false
            liveNow = false
            let task = session.webSocketTask(with: url)
            socket = task
            task.resume()
            receiveLoop(on: task)
        }
        let live = await withTaskTimeout(seconds: 5) { await ready.wait() } ?? false
        if !live {
            queue.sync {
                socket?.cancel(with: .normalClosure, reason: nil)
                socket = nil
            }
        }
        return live
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard task === self.socket else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleTextLocked(text)
                    case .data(let data): self.handleBinaryLocked(data)
                    @unknown default: break
                    }
                    self.receiveLoop(on: task)
                case .failure(let error):
                    self.readySignal?.complete(false)
                    self.dropSignal?.complete(error.localizedDescription)
                }
            }
        }
    }

    // Runs on `queue`.
    private func handleTextLocked(_ text: String) {
        if let key = sealKey {
            guard let parsed = DirectCrypto.open(key: key, selfName: "phone", raw: text)
            else { return }
            sawSealedReply = true
            handleParsedLocked(parsed)
        } else if let parsed = decodeJSON(text) {
            handleParsedLocked(parsed)
        }
    }

    // Runs on `queue`.
    private func handleBinaryLocked(_ data: Data) {
        guard let key = sealKey else {
            onAudio?(data)
            return
        }
        guard let clear = DirectCrypto.openBinary(key: key, from: "mac", buf: data,
                                                  seen: sealSeenBin) else { return }
        sawSealedReply = true
        guard let whole = assembler?.accept(clear) else { return }
        switch whole.tag {
        case Frames.tagWsBinary:
            onAudio?(whole.body)
        case Frames.tagWsText:
            if let text = String(data: whole.body, encoding: .utf8),
               let parsed = decodeJSON(text) {
                handleParsedLocked(parsed)
            }
        case Frames.tagFileRes:
            if let reqId = str(whole.meta, "reqId") {
                fileWaiters.removeValue(forKey: reqId)?.complete(whole)
            }
        default:
            break
        }
    }

    // Runs on `queue`. Live only once the daemon has said "connected".
    private func handleParsedLocked(_ parsed: [String: Any]) {
        if str(parsed, "type") == "connected", !via.isEmpty {
            liveNow = true
            onState?(.live(via: via))
            readySignal?.complete(true)
        }
        onEvent?(parsed)
    }

    // Runs on `queue`, from the delegate.
    fileprivate func socketOpenedLocked(_ task: URLSessionWebSocketTask) {
        guard task === socket else { return }
        let auth = msg("auth", ["token": token])
        if let key = sealKey {
            task.send(.string("{\"type\":\"seal\",\"v\":1}")) { _ in }
            if let sealedAuth = DirectCrypto.seal(key: key, from: "phone", payload: auth) {
                task.send(.string(sealedAuth)) { _ in }
            }
        } else if let raw = encodeJSON(auth) {
            task.send(.string(raw)) { _ in }
        }
    }

    // Runs on `queue`, from the delegate. On the sealed rung a 4401 proves
    // nothing until this peer has opened at least one envelope: a stale
    // endpoint may now point at a stranger's daemon, and a stranger must not
    // be able to convince this phone its own pairing died.
    fileprivate func socketClosedLocked(_ task: URLSessionWebSocketTask,
                                        code: Int, reason: Data?) {
        guard task === socket else { return }
        if code == 4401, sealKey == nil || sawSealedReply {
            pairFailure = true
            wanted = false
            onState?(.pairRequired(reason: "The Mac refused this pairing."))
        }
        readySignal?.complete(false)
        dropSignal?.complete("closed \(code)")
    }

    // MARK: - Sending

    @discardableResult
    public func send(_ payload: [String: Any]) -> Bool {
        queue.sync {
            guard let task = socket, liveNow || str(payload, "type") == "auth"
            else { return false }
            if let key = sealKey {
                guard let sealed = DirectCrypto.seal(key: key, from: "phone",
                                                     payload: payload)
                else { return false }
                task.send(.string(sealed)) { _ in }
            } else {
                guard let raw = encodeJSON(payload) else { return false }
                task.send(.string(raw)) { _ in }
            }
            return true
        }
    }

    // MARK: - File lane (download only in v1)

    public func downloadFile(id: String, name: String) async throws -> FetchedFile {
        let (currentVia, currentHost, currentPort, currentToken) = queue.sync {
            (via, host, port, token)
        }
        if currentVia == "remote" {
            let meta: [String: Any] = ["op": "get", "id": id]
            guard let whole = await fileRoundTrip(meta: meta) else {
                throw JarvisNetError.noReply
            }
            return FetchedFile(status: int(whole.meta, "status") ?? 0, name: name,
                               mime: str(whole.meta, "mime") ?? "application/octet-stream",
                               bytes: whole.body)
        }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "http://\(currentHost):\(currentPort)/files/\(encoded)")
        else { throw JarvisNetError.badRequest }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        return FetchedFile(status: http?.statusCode ?? 0, name: name,
                           mime: http?.value(forHTTPHeaderField: "Content-Type")
                               ?? "application/octet-stream",
                           bytes: data)
    }

    private func fileRoundTrip(meta: [String: Any]) async -> Frames.Whole? {
        let waiter = Once<Frames.Whole?>()
        let dispatched: Bool = queue.sync {
            guard let key = sealKey, let task = socket, liveNow else { return false }
            requestCounter += 1
            let reqId = "r\(requestCounter)"
            var stamped = meta
            stamped["reqId"] = reqId
            stamped["sid"] = Int(requestCounter)
            fileWaiters[reqId] = waiter
            for frame in Frames.chunks(tag: Frames.tagFileReq, meta: stamped, body: Data()) {
                guard let sealed = DirectCrypto.sealBinary(key: key, from: "phone",
                                                           data: frame)
                else {
                    fileWaiters.removeValue(forKey: reqId)
                    return false
                }
                task.send(.data(sealed)) { _ in }
            }
            return true
        }
        guard dispatched else { return nil }
        return await withTaskTimeout(seconds: 60) { await waiter.wait() } ?? nil
    }
}

extension ConnectionManager: URLSessionWebSocketDelegate {
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async { self.socketOpenedLocked(webSocketTask) }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        queue.async {
            self.socketClosedLocked(webSocketTask, code: closeCode.rawValue, reason: reason)
        }
    }
}

public enum JarvisNetError: Error {
    case noReply
    case badRequest
}

// A complete-once box that many callers can await; completion from any
// thread, waiters resumed exactly once each.
public final class Once<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    private var waiters: [CheckedContinuation<Value, Never>] = []

    public init() {}

    public func complete(_ result: Value) {
        lock.lock()
        guard value == nil else {
            lock.unlock()
            return
        }
        value = result
        let resumed = waiters
        waiters = []
        lock.unlock()
        for waiter in resumed { waiter.resume(returning: result) }
    }

    public func wait() async -> Value {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

// Await a value with a deadline; nil on timeout.
public func withTaskTimeout<Value: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async -> Value
) async -> Value? {
    await withTaskGroup(of: Value?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
