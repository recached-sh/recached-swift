import Foundation
import XCTest

@testable import Recached

/// Everything that works with no server at all.
final class LocalTests: XCTestCase {
    private let db = TempDB()

    func testReadsReturnWhatWasWritten() throws {
        let cache = try db.open()
        try cache.set("text", "hello")
        try cache.set("bytes", Data([0, 1, 2]))
        XCTAssertEqual(try cache.getString("text"), "hello")
        XCTAssertEqual(cache.get("bytes"), Data([0, 1, 2]))
        XCTAssertTrue(cache.exists("text"))
        XCTAssertNil(cache.get("missing"))
        XCTAssertEqual(cache.ttl("missing"), -2)
    }

    func testCountersAndJSON() throws {
        let cache = try db.open()
        XCTAssertEqual(try cache.incr("n"), 1)
        XCTAssertEqual(try cache.incr("n", by: 5), 6)
        try cache.setJSON("doc", #"{"title":"a","draft":true}"#)
        try cache.mergeJSON("doc", #"{"draft":null}"#)
        XCTAssertEqual(cache.getJSON("doc"), #"{"title":"a"}"#)
    }

    func testDeleteReportsWhetherTheKeyExisted() throws {
        let cache = try db.open()
        try cache.set("k", "v")
        XCTAssertTrue(try cache.delete("k"))
        XCTAssertFalse(try cache.delete("k"))
    }

    func testAValueWithATTLExpires() throws {
        let cache = try db.open()
        try cache.set("session", "token", ttl: 120)
        XCTAssertTrue((1...120).contains(cache.ttl("session")))
    }

    func testWritesAndTheirQueueSurviveReopening() throws {
        do {
            let cache = try db.open()
            try cache.set("a", "1")
            try cache.incr("n", by: 2)
            XCTAssertEqual(cache.pendingWrites, 2)
        }
        let cache = try db.open()
        XCTAssertEqual(try cache.getString("a"), "1")
        XCTAssertEqual(try cache.getString("n"), "2")
        XCTAssertEqual(cache.pendingWrites, 2)
    }

    func testGetMatchingIsSortedByKey() throws {
        let cache = try db.open()
        try cache.set("p:2", "b")
        try cache.set("p:1", "a")
        try cache.set("q:1", "c")
        XCTAssertEqual(cache.getMatching("p:*").map(\.key), ["p:1", "p:2"])
        XCTAssertEqual(cache.getMatching("p:*").first?.string, "a")
    }

    func testARefusedCommandThrowsAndQueuesNothing() throws {
        let cache = try db.open()
        try cache.set("text", "abc")
        XCTAssertThrowsError(try cache.incr("text")) { error in
            guard case RecachedError.command = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(cache.pendingWrites, 1)
    }

    func testABinaryValueHasNoStringForm() throws {
        let cache = try db.open()
        try cache.set("bin", Data([0xff, 0]))
        XCTAssertThrowsError(try cache.getString("bin")) { error in
            XCTAssertEqual(error as? RecachedError, .notUTF8(key: "bin"))
        }
    }

    func testWithoutAURLTheCacheStaysOffline() throws {
        let cache = try db.open()
        XCTAssertEqual(cache.connectionState, .offline)
        cache.reconnectNow()  // a no-op, not an error
    }

    func testAFullOutboxRefusesTheWriteAndChangesNothing() throws {
        do {
            let cache = try db.open(RecachedConfig(maxPendingWrites: 2))
            try cache.set("a", "1")
            try cache.set("b", "1")
            XCTAssertThrowsError(try cache.set("a", "changed")) { error in
                XCTAssertEqual(error as? RecachedError, .outboxFull(pending: 2, capacity: 2))
            }
            XCTAssertEqual(try cache.getString("a"), "1")
            XCTAssertEqual(cache.pendingWrites, 2)
        }
        let reopened = try db.open(RecachedConfig(maxPendingWrites: 2))
        XCTAssertEqual(reopened.pendingWrites, 2, "the queued writes are intact on disk")
    }

    func testWithoutAURLTheStatusStaysDisconnected() throws {
        let cache = try db.open()
        XCTAssertEqual(cache.syncStatus.phase, .disconnected)
        XCTAssertNil(cache.syncStatus.lastSyncedAt)
    }

    func testTheConfigNeverPrintsItsCredentials() {
        let text = RecachedConfig(url: URL(string: "wss://x"), password: "hunter2", syncToken: "secret").description
        XCTAssertFalse(text.contains("hunter2") || text.contains("secret"), text)
    }
}

final class ChangeBusTests: XCTestCase {
    private let calls = Locked<[String]>([])
    private lazy var bus = ChangeBus { pattern, keys in
        keys.contains { $0.hasPrefix(pattern.replacingOccurrences(of: "*", with: "")) }
    }

    private func record(_ name: String) -> @Sendable () -> Void {
        { [calls] in calls.withLock { $0.append(name) } }
    }

    func testAKeyListenerHearsOnlyItsKey() {
        _ = bus.onKey("a", record("a"))
        bus.publish(["b"])
        XCTAssertEqual(calls.withLock { $0 }, [])
        bus.publish(["b", "a"])
        XCTAssertEqual(calls.withLock { $0 }, ["a"])
    }

    func testAPatternListenerHearsOncePerChangeSet() {
        _ = bus.onPattern("cart:*", record("cart"))
        bus.publish(["cart:1", "cart:2", "user:1"])
        bus.publish(["user:2"])
        XCTAssertEqual(calls.withLock { $0 }, ["cart"])
    }

    func testCancellingARegistrationStopsIt() {
        let a = bus.onKey("k", record("a"))
        _ = bus.onKey("k", record("b"))
        a.cancel()
        a.cancel()  // idempotent
        bus.publish(["k"])
        XCTAssertEqual(calls.withLock { $0 }, ["b"])
    }

    func testInvalidateAllReachesEveryone() {
        _ = bus.onKey("k", record("k"))
        _ = bus.onPattern("p:*", record("p"))
        bus.invalidateAll()
        XCTAssertEqual(calls.withLock { $0 }.sorted(), ["k", "p"])
    }
}

final class BroadcastTests: XCTestCase {
    func testEveryStreamGetsWhatIsSentAfterItStarts() async {
        let broadcast = Broadcast<Int>(buffer: 8)
        broadcast.send(0)  // before any stream: nobody hears it
        let first = Recorder(broadcast.stream())
        let second = Recorder(broadcast.stream())
        broadcast.send(1)
        broadcast.send(2)
        await eventually { first.values == [1, 2] && second.values == [1, 2] }
    }
}
