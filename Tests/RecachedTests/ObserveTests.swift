import Foundation
import XCTest

@testable import Recached

final class ObserveTests: XCTestCase {
    private let db = TempDB()

    func testObserveYieldsTheCurrentValueThenEachChangeOnce() async throws {
        let cache = try db.open()
        try cache.set("k", "1")
        let seen = Recorder(cache.observeString("k"))
        await eventually { seen.values == ["1"] }

        try cache.set("other", "x")
        try cache.set("k", "2")
        try cache.set("k", "2")  // unchanged: not repeated
        try cache.delete("k")
        await eventually { seen.values == ["1", "2", nil] }
    }

    func testObserveMatchingFollowsTheSetOfKeys() async throws {
        let cache = try db.open()
        try cache.set("cart:1", "apple")
        let seen = Recorder(cache.observeMatching("cart:*"))
        await eventually { seen.values.last?.map(\.key) == ["cart:1"] }

        try cache.set("user:1", "x")  // outside the pattern
        try cache.set("cart:2", "pear")
        await eventually { seen.values.last?.map(\.key) == ["cart:1", "cart:2"] }

        try cache.delete("cart:1")
        await eventually { seen.values.last?.map(\.key) == ["cart:2"] }
        XCTAssertEqual(seen.values.count, 3, "the write outside the pattern yielded nothing")
    }

    func testASlowConsumerStillEndsOnTheLatestValue() async throws {
        let cache = try db.open()
        try cache.set("n", "0")
        let last = Locked<String?>(nil)
        let consumer = Task {
            for await value in cache.observeString("n") {
                try? await Task.sleep(nanoseconds: 50_000_000)  // slower than the writes
                last.withLock { $0 = value }
            }
        }
        defer { consumer.cancel() }
        for i in 1...100 { try cache.set("n", "\(i)") }
        await eventually { last.withLock { $0 } == "100" }
    }

    func testABinaryValueObservesAsNilText() async throws {
        let cache = try db.open()
        try cache.set("bin", Data([0xff]))
        let text = Recorder(cache.observeString("bin"))
        let bytes = Recorder(cache.observe("bin"))
        await eventually { text.values == [nil] && bytes.values == [Data([0xff])] }
    }

    func testStateStreamsStartWithTheCurrentValueThenFollowChanges() async throws {
        let cache = try db.open()
        let states = Recorder(cache.connectionStates())
        let pending = Recorder(cache.pendingWriteCounts())
        await eventually("the current values") { states.values == [.offline] && pending.values == [0] }

        try cache.set("a", "1")
        // Only the last value is guaranteed: a consumer that has not caught up
        // skips to the newest one by design.
        await eventually("the change") { pending.values.last == 1 }
    }

    // The models are main-actor types, checked in main-actor helpers: a test
    // method marked @MainActor makes SwiftPM's generated Linux test runner
    // warn, which -warnings-as-errors turns fatal.

    #if canImport(Observation)
        func testObservedKeyFollowsItsKey() async throws {
            guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else { throw XCTSkip("needs Observation") }
            let cache = try db.open()
            try cache.set("title", "draft")
            try await Self.checkObservedKey(cache)
        }

        @available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
        @MainActor
        private static func checkObservedKey(_ cache: Recached) async throws {
            let model = ObservedKey(cache, "title")
            XCTAssertEqual(model.string, "draft")
            try cache.set("title", "final")
            await eventually { model.string == "final" }
        }
    #endif

    #if canImport(Combine)
        func testObservableKeyFollowsItsKey() async throws {
            let cache = try db.open()
            try cache.set("title", "draft")
            try await Self.checkObservableKey(cache)
        }

        @MainActor
        private static func checkObservableKey(_ cache: Recached) async throws {
            let model = ObservableKey(cache, "title")
            XCTAssertEqual(model.string, "draft")
            try cache.set("title", "final")
            await eventually { model.string == "final" }
        }
    #endif
}
