import Foundation
import XCTest

@testable import Recached

/// End to end against a real recached-server, as an app on two devices would
/// see it: the four things the first release promises, plus recovering from
/// the server going away.
final class LiveTests: XCTestCase {
    private var server: LiveServer!
    private let phone = TempDB()
    private let tablet = TempDB()

    override func setUp() async throws {
        server = try LiveServer()
        try await server.start()
        #if os(Linux)
            if let reason = await webSocketsUnsupported(server.url) { throw XCTSkip(reason) }
        #endif
    }

    override func tearDown() {
        server = nil
    }

    private func connect(_ db: TempDB) throws -> Recached {
        try db.open(RecachedConfig(url: server.url))
    }

    private func connected(_ cache: Recached) async {
        await eventually("a connection") { cache.connectionState == .connected }
    }

    func testAWriteOnOneDeviceUpdatesAnObserverOnAnother() async throws {
        let a = try connect(phone)
        let b = try connect(tablet)
        a.watch("note:*")
        await connected(a)
        await connected(b)
        let seen = Recorder(a.observeString("note:1"))

        try b.set("note:1", "from the tablet")
        await eventually("the change to reach the phone") { seen.values.last == "from the tablet" }
        await eventually("the write to be acknowledged") { b.pendingWrites == 0 }
    }

    func testWritesMadeOfflineReachTheServerOnConnect() async throws {
        do {
            let offline = try phone.open()
            try offline.set("draft", "written in airplane mode")
            XCTAssertEqual(offline.pendingWrites, 1)
        }
        let a = try connect(phone)
        await eventually("the queued write to be acknowledged") { a.pendingWrites == 0 }

        let b = try connect(tablet)
        b.watch("draft")
        try await eventually("the write to reach another device") {
            try b.getString("draft") == "written in airplane mode"
        }
    }

    func testAKeyDeletedWhileOfflineIsGoneAfterReconnectAndOnDisk() async throws {
        let b = try connect(tablet)
        try b.set("cart:keep", "1")
        try b.set("cart:gone", "2")
        await eventually { b.pendingWrites == 0 }

        do {
            let a = try connect(phone)
            a.watch("cart:*")
            await eventually("the snapshot") { a.exists("cart:gone") }
            a.close()
        }
        try b.delete("cart:gone")  // while the phone is away
        await eventually { b.pendingWrites == 0 }

        do {
            let a = try connect(phone)
            XCTAssertTrue(a.exists("cart:gone"), "before reconnecting, the device still has it")
            let seen = Recorder(a.observe("cart:gone"))
            a.watch("cart:*")
            await eventually("observers to hear of the deletion") { seen.values.last == .some(nil) }
            a.close()
        }
        let coldStart = try phone.open()
        XCTAssertFalse(coldStart.exists("cart:gone"))
        XCTAssertEqual(try coldStart.getString("cart:keep"), "1")
    }

    func testAColdStartOfflineShowsTheLastSyncedServerState() async throws {
        let b = try connect(tablet)
        try b.setJSON("profile", #"{"name":"Ana"}"#)
        await eventually { b.pendingWrites == 0 }
        do {
            let a = try connect(phone)
            a.watch("profile")
            await eventually("the snapshot") { a.exists("profile") }
            a.close()
        }
        let offline = try phone.open()
        XCTAssertEqual(offline.getJSON("profile"), #"{"name":"Ana"}"#)
    }

    func testRecoversWhenTheServerGoesAwayAndComesBack() async throws {
        let a = try connect(phone)
        a.watch("status")
        await connected(a)

        server.stop()
        await eventually("the drop to be noticed") { a.connectionState == .waiting }
        try a.set("status", "written during the outage")
        XCTAssertEqual(a.pendingWrites, 1)

        try await server.start()
        await connected(a)
        await eventually("the queued write to be acknowledged") { a.pendingWrites == 0 }

        let b = try connect(tablet)
        b.watch("status")
        try await eventually("the write to reach another device") {
            try b.getString("status") == "written during the outage"
        }
    }

    func testAWriteTheServerRefusesIsReportedAndLeavesTheQueue() async throws {
        let a = try connect(phone)
        try a.set("count", "not a number")
        await eventually { a.pendingWrites == 0 }

        // The tablet does not watch "count", so its local copy increments
        // from nothing; the server's copy is text and refuses the increment.
        let b = try connect(tablet)
        let refusals = Recorder(b.refusedWrites())
        await connected(b)
        try b.incr("count")
        await eventually("the refusal to be reported") { !refusals.values.isEmpty }
        XCTAssertEqual(refusals.values.first?.keys, ["count"])
        XCTAssertEqual(b.pendingWrites, 0, "replaying it would be refused again")
    }

    func testAnExpiringKeyKeepsItsExpiryWhenTheServerCopyArrives() async throws {
        let a = try connect(phone)
        a.watch("session:*")
        await connected(a)
        try a.set("session:1", "token", ttl: 600)
        await eventually { a.pendingWrites == 0 }
        try await Task.sleep(nanoseconds: 300_000_000)  // the write's own echo
        XCTAssert((590...600).contains(a.ttl("session:1")), "ttl \(a.ttl("session:1"))")

        let b = try connect(tablet)
        b.watch("session:*")
        try await eventually("the snapshot") { try b.getString("session:1") == "token" }
        XCTAssert((590...600).contains(b.ttl("session:1")), "ttl \(b.ttl("session:1"))")
    }

    func testTheStatusIsReadyOnlyAfterReplayAndHydration() async throws {
        do {
            let offline = try phone.open()
            try offline.set("queued:1", "v")
        }
        let a = try connect(phone)
        a.watch("queued:*")
        let phases = Recorder(a.syncStatuses())
        await eventually("ready") { a.syncStatus.phase == .ready }
        XCTAssertEqual(a.pendingWrites, 0)
        let seen = phases.values.map(\.phase)
        if let replaying = seen.firstIndex(of: .replaying), let ready = seen.firstIndex(of: .ready) {
            XCTAssertLessThan(replaying, ready, "\(seen)")
        }
        XCTAssertNotNil(a.syncStatus.lastSyncedAt)
        // watch() may run before or after the socket opens; either way the
        // pattern ends current.
        await eventually("the pattern's snapshot") { a.subscriptionStates["queued:*"] == .current }
        XCTAssertEqual(try a.getString("queued:1"), "v")
    }

    func testAPatternWatchedLaterHydratesWhileTheConnectionStaysReady() async throws {
        let b = try connect(tablet)
        try b.set("late:1", "x")
        await eventually("acknowledged") { b.pendingWrites == 0 }
        let a = try connect(phone)
        a.watch("early:*")
        await eventually("ready") { a.syncStatus.phase == .ready }
        a.watch("late:*")
        await eventually("the late pattern's snapshot") { a.subscriptionStates["late:*"] == .current }
        XCTAssertEqual(a.syncStatus.phase, .ready)
        XCTAssertEqual(try a.getString("late:1"), "x")
    }
}
