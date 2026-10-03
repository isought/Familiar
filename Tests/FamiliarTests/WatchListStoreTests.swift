import Foundation
import Testing
@testable import Familiar

/// Where watches are kept: `watch-list.json`, owner-only, written whole; 20 watches of up to 50 items; a file that can't
/// be read is set aside, never overwritten.
@Suite @MainActor
struct WatchListStoreTests {
    @Test func aWatchComesBackExactlyAsItWasSaved() throws {
        let folder = temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watch-list.json")
        var item = WatchListItem(key: "https://shop.example.com/item/123")
        item.title = "Blue kettle"
        item.url = "https://shop.example.com/item/123"
        item.expected = ["price": .number(12.33), "badges": .list(["Deal"]), "in_stock": .flag(true), "strikethrough": .none, "seller": .text("Acme")]
        item.state = ["price": .number(13.95), "badges": .list([]), "in_stock": .flag(false), "strikethrough": .number(1), "seller": .text("1")]
        item.facts = #"{"offers":[]}"#
        item.checkedAt = Date(timeIntervalSince1970: 1_790_000_123.456)
        item.status = .notAsExpected([WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))])
        item.notified = .asExpected
        item.failures = 0
        var failing = WatchListItem(key: "456")
        failing.status = .couldNotCheck("Signed out")
        failing.failures = 2
        failing.notifiedCouldNotCheck = true
        let watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [item, failing], args: ["zip": .text("10001")],
                                   fields: ["price", "badges"], expect: ["badges": .list(["Deal"])], everyMinutes: 30, paused: true,
                                   createdAt: Date(timeIntervalSince1970: 1_790_000_000), lastRunAt: Date(timeIntervalSince1970: 1_790_000_100))

        let store = WatchListStore(file: file)
        try store.add(watch)
        let reopened = WatchListStore(file: file)

        #expect(reopened.watches == [watch])
        #expect(reopened.notice == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func aFileWithOnlyTheEssentialFieldsStillOpens() throws {
        let folder = temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watch-list.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let id = UUID()
        try #"{"version": 1, "watches": [{"id": "\#(id.uuidString)", "name": "Sale items", "check": "shop__watch_item", "items": [{"key": "123"}], "everyMinutes": 2}]}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let store = WatchListStore(file: file)

        let watch = try #require(store.watches.first)
        #expect(watch.id == id && watch.items.map(\.key) == ["123"] && watch.everyMinutes == 5 && !watch.paused)
        #expect(watch.items[0].failures == 0 && watch.items[0].status == nil)
    }

    @Test func aFileThatCantBeReadIsSetAsideNotOverwritten() throws {
        let folder = temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("watch-list.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)

        let store = WatchListStore(file: file)
        #expect(store.watches.isEmpty)
        #expect(store.notice?.hasPrefix("An earlier watch list couldn't be read, so it was set aside as watch-list.unreadable-") == true)
        try store.add(WatchListWatch(name: "New", check: "shop__watch_item", items: [WatchListItem(key: "1")]))

        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("unreadable") }
        #expect(aside.count == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent(aside[0]), encoding: .utf8) == "{ not json")
        #expect(WatchListStore(file: file).watches.map(\.name) == ["New"])
    }

    @Test func twentyWatchesOfFiftyItemsAtMost() throws {
        let folder = temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WatchListStore(file: folder.appendingPathComponent("watch-list.json"))
        let fifty = (1...50).map { WatchListItem(key: "\($0)") }
        #expect(throws: WatchListError.self) {
            try store.add(WatchListWatch(name: "Too many", check: "c", items: fifty + [WatchListItem(key: "51")]))
        }
        for n in 1...20 { try store.add(WatchListWatch(name: "Watch \(n)", check: "c", items: n == 1 ? fifty : [WatchListItem(key: "1")])) }
        #expect(throws: WatchListError.self) { try store.add(WatchListWatch(name: "Watch 21", check: "c", items: [WatchListItem(key: "1")])) }
        #expect(store.watches.count == 20)

        // A change that would go past 50 items changes nothing.
        let full = store.watches[0]
        #expect(throws: WatchListError.self) { try store.change(full.id) { $0.items.append(WatchListItem(key: "51")) } }
        #expect(store.watch(id: full.id)?.items.count == 50)
        #expect(WatchListStore(file: store.file).watches.count == 20)
    }

    @Test func changesAndStopsAreSavedAtOnce() throws {
        let folder = temporary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WatchListStore(file: folder.appendingPathComponent("watch-list.json"))
        let watch = WatchListWatch(name: "Sale items", check: "c", items: [WatchListItem(key: "1")])
        try store.add(watch)
        try store.change(watch.id) { $0.paused = true }
        #expect(WatchListStore(file: store.file).watch(id: watch.id)?.paused == true)

        try store.change(watch.id, persist: false) { $0.everyMinutes = 60 }   // a run's results wait for its save
        #expect(WatchListStore(file: store.file).watch(id: watch.id)?.everyMinutes == 15)
        try store.save()
        #expect(WatchListStore(file: store.file).watch(id: watch.id)?.everyMinutes == 60)

        try store.remove(watch.id)
        #expect(WatchListStore(file: store.file).watches.isEmpty)
        #expect(throws: WatchListError.self) { try store.change(watch.id) { $0.paused = false } }
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("watch-list-\(UUID().uuidString)")
    }
}
