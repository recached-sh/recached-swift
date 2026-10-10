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
}
