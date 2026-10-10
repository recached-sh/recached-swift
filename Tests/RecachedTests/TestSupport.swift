import Foundation
import XCTest

@testable import Recached

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// A fresh database file in a temporary directory.
final class TempDB {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("recached-\(UUID().uuidString)")
    var file: URL { directory.appendingPathComponent("cache.db") }

    func open(_ config: RecachedConfig = RecachedConfig()) throws -> Recached {
        try Recached.open(at: file, config: config)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Poll `condition` until it holds, failing the test after `timeout` seconds.
/// Runs on the caller's actor, so a main-actor test can poll main-actor state.
func eventually(
    isolation: isolated (any Actor)? = #isolation,
    _ message: String = "condition",
    timeout: TimeInterval = 10,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () throws -> Bool
) async rethrows {
    let deadline = Date().addingTimeInterval(timeout)
    while try !condition() {
        if Date() > deadline {
            XCTFail("timed out waiting for \(message)", file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Collects everything a stream yields, in the background.
final class Recorder<Element: Sendable>: @unchecked Sendable {
    private let collected = Locked<[Element]>([])
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Element>) {
        task = Task { [collected] in
            for await element in stream { collected.withLock { $0.append(element) } }
        }
    }

    var values: [Element] { collected.withLock { $0 } }

    deinit {
        task?.cancel()
    }
}

#if os(macOS) || os(Linux)
    /// A real recached-server, from the binary scripts/build-engine.sh staged, on
    /// free loopback ports in a temporary directory so it never touches anyone's
    /// data. `stop()` and `start()` keep the ports, to test reconnecting.
    final class LiveServer {
        let url: URL
        private let tcpPort = freePort()
        private let wsPort: Int
        private let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "recached-server-\(UUID().uuidString)")
        private let binary: URL
        private var process: Process?

        init() throws {
            let staged = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("engine/host/recached-server")
            binary = ProcessInfo.processInfo.environment["RECACHED_SERVER"].map(URL.init(fileURLWithPath:)) ?? staged
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw XCTSkip("no recached-server at \(binary.path); run scripts/build-engine.sh")
            }
            wsPort = freePort()
            url = URL(string: "ws://127.0.0.1:\(wsPort)")!
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        }

        func start() async throws {
            let process = Process()
            process.executableURL = binary
            process.currentDirectoryURL = workDirectory
            process.environment = [
                // The server binds every interface by default; a test server has
                // no business on the LAN.
                "RECACHED_BIND": "127.0.0.1",
                "RECACHED_PORT": "\(tcpPort)",
                "RECACHED_WS_PORT": "\(wsPort)",
                "RECACHED_METRICS_PORT": "0",
                "RECACHED_SAVE_INTERVAL": "0",
            ]
            let log = workDirectory.appendingPathComponent("server.log")
            _ = FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            try handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            self.process = process
            let port = wsPort
            await eventually("recached-server to listen on \(port)") {
                precondition(process.isRunning, "recached-server exited; see \(log.path)")
                return canConnect(port)
            }
        }

        /// SIGKILL, not `terminate()`: on Linux, Foundation's `Process` hands the
        /// child its spawning thread's signal mask, which can block SIGTERM for
        /// good. An abrupt stop is also the harder case for the client.
        func stop() {
            guard let process else { return }
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            self.process = nil
        }

        deinit {
            stop()
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }
#else
    /// iOS and its simulator cannot start processes: the live tests run on
    /// macOS and Linux.
    final class LiveServer {
        var url: URL { fatalError("unreachable") }
        init() throws { throw XCTSkip("live tests need a recached-server subprocess (macOS and Linux only)") }
        func start() async throws {}
        func stop() {}
    }
#endif

#if os(Linux)
    /// Why this platform cannot run the live tests, or `nil` when it can.
    ///
    /// On Linux, `URLSessionWebSocketTask` goes through the system libcurl, and
    /// Ubuntu 24.04's (8.5) is built without WebSocket support: every socket
    /// fails with "WebSockets not supported by libcurl". Newer distributions'
    /// libcurl has it. The live tests run on macOS regardless.
    func webSocketsUnsupported(_ url: URL) async -> String? {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let socket = session.webSocketTask(with: url)
        socket.resume()
        let failure: String? = await withCheckedContinuation { continuation in
            socket.send(.string(resp("PING"))) { error in continuation.resume(returning: error.map { "\($0)" }) }
        }
        socket.cancel(with: .normalClosure, reason: nil)
        guard let failure, failure.contains("WebSockets not supported") else { return nil }
        return "this platform's libcurl was built without WebSocket support"
    }
#endif

/// RESP array frame, as the server sends it.
func resp(_ parts: String...) -> String {
    parts.reduce("*\(parts.count)\r\n") { $0 + "$\($1.utf8.count)\r\n\($1)\r\n" }
}

// MARK: Sockets

#if os(Linux)
    private let streamSocket = Int32(SOCK_STREAM.rawValue)
#else
    private let streamSocket = SOCK_STREAM
#endif

private func loopback(port: Int) -> sockaddr_in {
    var address = sockaddr_in()
    #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    return address
}

/// A port the OS reports free right now.
private func freePort() -> Int {
    let fd = socket(AF_INET, streamSocket, 0)
    defer { close(fd) }
    var address = loopback(port: 0)
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
    }
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return Int(UInt16(bigEndian: address.sin_port))
}

private func canConnect(_ port: Int) -> Bool {
    let fd = socket(AF_INET, streamSocket, 0)
    defer { close(fd) }
    var address = loopback(port: port)
    return withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}
