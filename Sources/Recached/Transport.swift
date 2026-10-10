import Foundation
import RecachedCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Owns the WebSocket and drives the core through it: opens the socket, hands
/// the core a sink on open, feeds it every frame, and reconnects after a drop
/// with the backoff the core computes.
///
/// The current socket is `task`. Every call into the core that depends on
/// which socket is current runs under `lock` and checks the calling task
/// against it, so a late callback from a socket already replaced or closed
/// changes nothing. The lock order is always this lock, then the core's: the
/// core never calls back into this class.
final class Transport: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let client: RecachedClient
    private let url: URL
    private let state: StateCell<ConnectionState>
    /// Keys a server frame changed; called outside `lock`.
    private let onChanged: @Sendable ([String]) -> Void
    /// A frame changed something that could not be saved, so its keys are unknown.
    private let onUnknownChange: @Sendable () -> Void
    /// The pending-write count may have moved.
    private let onAcknowledged: @Sendable () -> Void

    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var retry: Task<Void, Never>?
    private var ping: Task<Void, Never>?
    private var closed = false

    /// Pings notice a socket the network dropped without a close, and keep NAT
    /// mappings alive; otherwise a phone that changed networks can sit on a
    /// dead connection until TCP gives up.
    private static let pingInterval: UInt64 = 20_000_000_000

    init(
        client: RecachedClient,
        url: URL,
        configuration: URLSessionConfiguration,
        state: StateCell<ConnectionState>,
        onChanged: @escaping @Sendable ([String]) -> Void,
        onUnknownChange: @escaping @Sendable () -> Void,
        onAcknowledged: @escaping @Sendable () -> Void
    ) {
        self.client = client
        self.url = url
        self.state = state
        self.onChanged = onChanged
        self.onUnknownChange = onUnknownChange
        self.onAcknowledged = onAcknowledged
        super.init()
        // A serial delegate queue: socket callbacks arrive one at a time.
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Connect now unless a socket is already open or opening.
    func connect() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, task == nil else { return }
        retry?.cancel()
        retry = nil
        let socket = session.webSocketTask(with: url)
        task = socket
        state.set(.connecting)
        socket.resume()
        receive(on: socket)
    }

    /// Close the socket for good; no further attempts are made.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        retry?.cancel()
        ping?.cancel()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        _ = client.connectionClosed()  // no reconnect follows, so the backoff is moot
        state.set(.offline)
        // The session holds its delegate (this object) until invalidated.
        session.invalidateAndCancel()
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrent(webSocketTask) else { return }
        // Sends the session and every queued write through the sink.
        client.connectionOpened(sink: Sink(webSocketTask))
        state.set(.connected)
        ping = Task { [weak webSocketTask] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pingInterval)
                guard !Task.isCancelled, let socket = webSocketTask else { return }
                socket.sendPing { error in
                    if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        dropped(webSocketTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        dropped(task)
    }

    // MARK: Frames

    private func receive(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.received(message, on: socket)
            case .failure:
                self.dropped(socket)
            }
        }
    }

    private func received(_ message: URLSessionWebSocketTask.Message, on socket: URLSessionWebSocketTask) {
        let frame: Data
        switch message {
        case .string(let text): frame = Data(text.utf8)
        case .data(let data): frame = data
        @unknown default: frame = Data()
        }

        lock.lock()
        guard isCurrent(socket) else {
            lock.unlock()
            return
        }
        let outcome = try? client.frameReceived(frame: frame)
        lock.unlock()

        if let outcome {
            onChanged(outcome.changedKeys)
            // Reply matching can no longer be trusted; the reconnect rebuilds
            // it and the outbox replays.
            if outcome.reconnect {
                socket.cancel(with: .protocolError, reason: nil)
                return
            }
        } else {
            // Applied in memory but not saved, and its keys are lost with the
            // error: let every observer re-read.
            onUnknownChange()
        }
        onAcknowledged()
        receive(on: socket)
    }

    private func dropped(_ socket: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        guard isCurrent(socket) else { return }
        task = nil
        ping?.cancel()
        ping = nil
        let wait = UInt64(client.connectionClosed())
        state.set(.waiting)
        retry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: wait * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }

    private func isCurrent(_ socket: URLSessionTask) -> Bool {
        !closed && task === socket
    }
}

/// Where the core sends frames. Called under the core's lock, so it must only
/// queue — `send(_:completionHandler:)` does, in call order. Text when the
/// frame is valid UTF-8, binary otherwise, as the server expects.
private final class Sink: FrameSink, @unchecked Sendable {
    private let socket: URLSessionWebSocketTask

    init(_ socket: URLSessionWebSocketTask) {
        self.socket = socket
    }

    func send(frame: Data) {
        let message: URLSessionWebSocketTask.Message =
            String(data: frame, encoding: .utf8).map { .string($0) } ?? .data(frame)
        // A failed send surfaces as the socket failing, which reconnects and
        // replays the outbox; nothing to do here.
        socket.send(message) { _ in }
    }
}
