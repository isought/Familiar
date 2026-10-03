import Foundation
import Testing
@testable import Familiar

/// Where watches are kept: one folder each, `watch.json` (what to watch, which people may edit) apart from `latest.json`
/// (what the last run found). Hand edits are taken in, a watch.json that can't be read is never written over, a stopped
/// watch's folder goes to the Trash, and the earlier single `watch-list.json` moves into folders once.
@Suite @MainActor
struct WatchListStoreTests {
    @Test func aWatchIsAFolderWithWhatToWatchApartFromWhatWasFound() throws {
        let place = Place()
        defer { place.remove() }
        let watch = checkedWatch()
        let store = place.store()
        try store.add(watch)

        let folder = place.watches.appendingPathComponent("sale-items")
        #expect(store.folder(for: watch.id)?.standardizedFileURL == folder.standardizedFileURL)
        for file in ["watch.json", "latest.json"] {
            #expect(try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(file).path)[.posixPermissions] as? Int == 0o600)
        }
        #expect(try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["latest.json", "watch.json"])   // no leftovers

        let definition = try String(contentsOf: folder.appendingPathComponent("watch.json"), encoding: .utf8)
        #expect(!definition.contains("state") && !definition.contains("last_told"))   // what was found stays out of it
        let results = try String(contentsOf: folder.appendingPathComponent("latest.json"), encoding: .utf8)
        #expect(results.contains("\"last_told\"") && results.contains("\"price\": 13.95") && results.contains("\"offers\": []"))

        let reopened = place.store()
        #expect(reopened.watches == [watch])
        #expect(reopened.problems.isEmpty && reopened.unreadable.isEmpty)
    }

    @Test func watchJsonIsWrittenForPeopleToRead() throws {
        let place = Place()
        defer { place.remove() }
        let store = place.store()
        let id = UUID(uuidString: "6F1C2A3B-4D5E-4F60-8A7B-9C0D1E2F3A4B")!
        try store.add(WatchListWatch(id: id, name: "Sale items", check: "shop__watch_item",
                                     items: [WatchListItem(key: "123"), WatchListItem(key: "https://shop.example.com/item/456", expect: ["price": .number(19.99)])],
                                     args: ["zip": .text("10001")], fields: ["price", "badges"], expect: ["badges": .list(["Deal"])],
                                     createdAt: Date(timeIntervalSince1970: 1_790_000_000.7)))
        let text = try String(contentsOf: place.watches.appendingPathComponent("sale-items/watch.json"), encoding: .utf8)
        #expect(text == """
        {
          "id": "6F1C2A3B-4D5E-4F60-8A7B-9C0D1E2F3A4B",
          "name": "Sale items",
          "check": "shop__watch_item",
          "items": [
            "123",
            {
              "expect": {
                "price": 19.99
              },
              "key": "https://shop.example.com/item/456"
            }
          ],
          "fields": ["price", "badges"],
          "expect": {
            "badges": ["Deal"]
          },
          "args": {
            "zip": "10001"
          },
          "every_minutes": 15,
          "paused": false,
          "created_at": "2026-09-21T14:13:20Z"
        }

        """)
    }

    @Test func theEarlierWatchListMovesIntoFoldersWithWhatWasFoundAndWhatThePersonWasTold() throws {
        let place = Place()
        defer { place.remove() }
        var told = WatchListItem(key: "123")
        told.title = "Blue kettle"
        told.url = "https://shop.example.com/item/123"
        told.expected = ["price": .number(12.33), "badges": .list(["Deal"])]
        told.state = ["price": .number(13.95), "badges": .list(["Deal"])]
        told.facts = #"{"seller":"Acme"}"#
        told.checkedAt = Date(timeIntervalSince1970: 1_790_000_900.25)
        let difference = WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))
        told.status = .notAsExpected([difference])
        told.notified = .notAsExpected([difference])
        var failing = WatchListItem(key: "456")
        failing.status = .couldNotCheck("Signed out")
        failing.failures = 2
        failing.notifiedCouldNotCheck = true
        let first = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [told, failing], fields: ["price", "badges"],
                                   everyMinutes: 30, paused: true, createdAt: Date(timeIntervalSince1970: 1_790_000_000),
                                   lastRunAt: Date(timeIntervalSince1970: 1_790_000_900.5))
        let second = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [WatchListItem(key: "789")],
                                    createdAt: Date(timeIntervalSince1970: 1_790_000_060))
        try FileManager.default.createDirectory(at: place.root, withIntermediateDirectories: true)
        try SourceRunJSON.encoder().encode(LegacyWatchList(watches: [first, second])).write(to: place.legacy)   // as the earlier version wrote it

        let store = place.store()

        #expect(store.watches.map(\.name) == ["Sale items", "Sale items"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: place.watches.path).sorted() == ["sale-items", "sale-items-2"])
        let moved = try #require(store.watch(id: first.id))
        #expect(moved.everyMinutes == 30 && moved.paused && moved.fields == ["price", "badges"])
        #expect(moved.lastRunAt == first.lastRunAt)
        let item = try #require(moved.item("123"))
        #expect(item.captured == ["price": .number(12.33), "badges": .list(["Deal"])])   // what counted as right is where it starts
        #expect(item.expected == ["price": .number(12.33), "badges": .list(["Deal"])])
        #expect(item.status == .notAsExpected([difference]) && item.notified == .notAsExpected([difference]))
        #expect(item.title == "Blue kettle" && item.facts == #"{"seller":"Acme"}"# && item.checkedAt == told.checkedAt)
        let stillFailing = try #require(moved.item("456"))
        #expect(stillFailing.failures == 2 && stillFailing.notifiedCouldNotCheck && stillFailing.status == .couldNotCheck("Signed out"))

        let names = try FileManager.default.contentsOfDirectory(atPath: place.root.path)
        #expect(!names.contains("watch-list.json"))
        #expect(names.contains { $0.hasPrefix("watch-list.json.moved-") })
        #expect(!names.contains { $0.hasPrefix(".watches-moving-") })

        // The same results come back on the next launch, and nothing is moved twice.
        try SourceRunJSON.encoder().encode(LegacyWatchList(watches: [first])).write(to: place.legacy)
        let again = place.store()
        #expect(again.watches.count == 2 && again.watch(id: first.id)?.item("123")?.notified == .notAsExpected([difference]))
        #expect(FileManager.default.fileExists(atPath: place.legacy.path))   // left alone: there is a watches folder now
    }

    @Test func anEarlierWatchListThatCantBeReadIsLeftAsItWas() throws {
        let place = Place()
        defer { place.remove() }
        try FileManager.default.createDirectory(at: place.root, withIntermediateDirectories: true)
        try "{ not json".write(to: place.legacy, atomically: true, encoding: .utf8)
        let store = place.store()
        #expect(store.watches.isEmpty)
        #expect(store.notice?.hasPrefix("Your earlier watch list couldn't be moved into the watches folder, so it was left as watch-list.json") == true)
        #expect(try String(contentsOf: place.legacy, encoding: .utf8) == "{ not json")
        #expect(!FileManager.default.fileExists(atPath: place.watches.path))
    }

    @Test func aHandEditIsTakenInAtTheNextLook() throws {
        let place = Place()
        defer { place.remove() }
        let store = place.store()
        let watch = checkedWatch()
        try store.add(watch)
        #expect(store.refresh() == WatchListChanges())   // its own writes are no hand edits

        try place.edit("sale-items") { json in
            json["items"] = ["https://shop.example.com/item/123", "456", "789"]
            json["expect"] = ["badges": ["Deal"], "price": 11.99]
            json["paused"] = false
            json["every_minutes"] = 60
            json["note"] = "Ask the pricing team before changing this"
        }
        let changes = store.refresh()

        #expect(changes.newItems == [watch.id: ["789"]])
        let edited = try #require(store.watch(id: watch.id))
        #expect(edited.items.map(\.key) == ["https://shop.example.com/item/123", "456", "789"])
        #expect(!edited.paused && edited.everyMinutes == 60)
        let item = try #require(edited.item("https://shop.example.com/item/123"))
        #expect(item.expected == ["price": .number(11.99), "badges": .list(["Deal"])])
        #expect(item.status == .notAsExpected([WatchListDifference(field: "price", now: .number(13.95), expected: .number(11.99))]))
        #expect(item.notified == watch.items[0].notified)   // the next check tells them, not the edit
        #expect(item.state == watch.items[0].state)         // what was found stays with its item
        #expect(edited.item("789")?.status == nil)

        // A change from Noteling keeps the key it doesn't use, and isn't a hand edit.
        try store.change(watch.id) { $0.paused = true }
        let text = try String(contentsOf: place.watches.appendingPathComponent("sale-items/watch.json"), encoding: .utf8)
        #expect(text.contains("\"note\": \"Ask the pricing team before changing this\"") && text.contains("\"paused\": true"))
        #expect(store.refresh() == WatchListChanges())

        // An item taken out by hand goes, with what was found about it.
        try place.edit("sale-items") { $0["items"] = ["789"] }
        store.refresh()
        #expect(store.watch(id: watch.id)?.items.map(\.key) == ["789"])
        try store.save(watch.id)
        let results = try String(contentsOf: place.watches.appendingPathComponent("sale-items/latest.json"), encoding: .utf8)
        #expect(!results.contains("item/123"))
    }

    @Test func aWatchJsonThatCantBeReadIsKeptAndReportedAndTheLastGoodOneIsUsed() throws {
        let place = Place()
        defer { place.remove() }
        let store = place.store()
        let watch = checkedWatch()
        try store.add(watch)
        let file = place.watches.appendingPathComponent("sale-items/watch.json")
        let broken = "{\n  \"name\": \"Sale items\",\n  \"items\": [\"123\",\n}\n"
        try place.write(broken, to: file)

        store.refresh()
        let problem = try #require(store.problems[watch.id])
        #expect(problem.hasPrefix("Can't read watch.json: it isn't valid JSON (invalid value around line 4"))
        #expect(store.watch(id: watch.id) == watch)   // the last good definition

        // Nothing writes over it: not a change, not a run's results.
        #expect(throws: WatchListError.self) { try store.change(watch.id) { $0.paused = false } }
        try store.change(watch.id, persist: false) { $0.lastRunAt = Date() }
        try store.save(watch.id)
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
        #expect(place.store().watches.isEmpty)   // and it stays unread, never set aside, at the next launch
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)

        try place.write("{\"name\": \"Sale items\", \"items\": [\"123\"], \"id\": \"\(watch.id.uuidString)\"}", to: file)
        store.refresh()
        #expect(store.problems.isEmpty)
        #expect(store.watch(id: watch.id)?.items.map(\.key) == ["123"])
    }

    @Test func stoppingAWatchMovesItsFolderToTheTrash() throws {
        let place = Place()
        defer { place.remove() }
        let trash = place.root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var trashed: [String] = []
        let store = place.store(trash: { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        })
        let keep = WatchListWatch(name: "Keep", check: "c", items: [WatchListItem(key: "1")])
        let stop = WatchListWatch(name: "Sale items", check: "c", items: [WatchListItem(key: "2")])
        try store.add(keep)
        try store.add(stop)

        try store.remove(stop.id)

        #expect(trashed == ["sale-items"])
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("sale-items/watch.json").path))
        #expect(store.watches.map(\.name) == ["Keep"])
        #expect(place.store().watches.map(\.name) == ["Keep"])

        let stuck = place.store(trash: { _ in throw CocoaError(.fileWriteNoPermission) })
        #expect(throws: WatchListError.self) { try stuck.remove(keep.id) }
        #expect(stuck.watches.map(\.name) == ["Keep"])   // still watched when the Trash can't take it
    }

    @Test func aFolderSomeonePutsThereIsWatchedAndOneTheyTakeAwayIsNot() throws {
        let place = Place()
        defer { place.remove() }
        let store = place.store()
        let original = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [WatchListItem(key: "1")])
        try store.add(original)

        // A teammate's folder with only what matters in it.
        let handed = place.watches.appendingPathComponent("weekend")
        try FileManager.default.createDirectory(at: handed, withIntermediateDirectories: true)
        try place.write("{\"items\": [\"7\", 8], \"expect\": {\"in_stock\": true}}", to: handed.appendingPathComponent("watch.json"))
        // A copy of a folder, id and all.
        try FileManager.default.copyItem(at: place.watches.appendingPathComponent("sale-items"), to: place.watches.appendingPathComponent("sale-items copy"))
        // A folder with something else in it.
        try FileManager.default.createDirectory(at: place.watches.appendingPathComponent("notes"), withIntermediateDirectories: true)

        let changes = store.refresh()

        #expect(changes.added.count == 2)
        let weekend = try #require(store.watches.first { $0.name == "weekend" })
        #expect(weekend.items.map(\.key) == ["7", "8"] && weekend.expect == ["in_stock": .flag(true)] && weekend.everyMinutes == 15)
        #expect(weekend.id == WatchListFiles.derivedID(folder: "weekend"))
        let written = try String(contentsOf: handed.appendingPathComponent("watch.json"), encoding: .utf8)
        #expect(written.contains(weekend.id.uuidString))   // its id is written down, so it stays
        let copy = try #require(store.watches.first { $0.id != original.id && $0.name == "Sale items" })
        #expect(copy.id == WatchListFiles.derivedID(folder: "sale-items copy"))
        #expect(store.unreadable == ["notes": "Can't read watch.json: it isn't in the folder."])

        // Renamed: the same watch. Deleted: no longer watched.
        try FileManager.default.moveItem(at: handed, to: place.watches.appendingPathComponent("weekend-picks"))
        try FileManager.default.removeItem(at: place.watches.appendingPathComponent("sale-items copy"))
        let later = store.refresh()
        #expect(later.removed == [copy.id] && later.added.isEmpty)
        #expect(store.folder(for: weekend.id)?.lastPathComponent == "weekend-picks")
        #expect(Set(store.watches.map(\.id)) == [original.id, weekend.id])
    }

    @Test func twentyWatchesOf200ItemsAtMost() throws {
        let place = Place()
        defer { place.remove() }
        let store = place.store()
        let many = (1...200).map { WatchListItem(key: "\($0)") }
        #expect(throws: WatchListError.self) {
            try store.add(WatchListWatch(name: "Too many", check: "c", items: many + [WatchListItem(key: "201")]))
        }
        for n in 1...20 { try store.add(WatchListWatch(name: "Watch \(n)", check: "c", items: n == 1 ? many : [WatchListItem(key: "1")])) }
        #expect(throws: WatchListError.self) { try store.add(WatchListWatch(name: "Watch 21", check: "c", items: [WatchListItem(key: "1")])) }
        #expect(store.watches.count == 20)

        let full = store.watches[0]
        #expect(throws: WatchListError.self) { try store.change(full.id) { $0.items.append(WatchListItem(key: "201")) } }
        #expect(store.watch(id: full.id)?.items.count == 200)

        let extra = place.watches.appendingPathComponent("one-more")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try place.write("{\"name\": \"One more\", \"items\": [\"1\"]}", to: extra.appendingPathComponent("watch.json"))
        store.refresh()
        #expect(store.unreadable["one-more"] == "Not watched: Noteling watches up to 20 lists. Stop one to watch this one.")
        #expect(place.store().watches.count == 20)

        try store.remove(store.watches[5].id)   // a place frees up: it is watched at the next look
        store.refresh()
        #expect(store.unreadable.isEmpty && store.watches.contains { $0.name == "One more" })
    }

    // MARK: helpers

    /// A watch whose first item was checked once and then found not as expected, so it has everything a run leaves.
    private func checkedWatch() -> WatchListWatch {
        var item = WatchListItem(key: "https://shop.example.com/item/123")
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        _ = WatchListRules.apply(.checked(WatchListReading(title: "Blue kettle", url: "https://shop.example.com/item/123",
                                                           state: ["price": .number(12.33), "badges": .list(["Deal"]), "seller": .text("Acme")],
                                                           facts: #"{"offers":[]}"#, why: ["Priced by the shop's own list"])),
                                 to: &item, fields: ["price", "badges"], expect: ["badges": .list(["Deal"])], at: start)
        _ = WatchListRules.apply(.checked(WatchListReading(title: "Blue kettle", url: "https://shop.example.com/item/123",
                                                           state: ["price": .number(13.95), "badges": .list(["Deal"]), "seller": .text("Acme")],
                                                           facts: #"{"offers":[]}"#, why: ["The page shows 13.95; the list says 12.33"])),
                                 to: &item, fields: ["price", "badges"], expect: ["badges": .list(["Deal"])], at: start + 900.5)
        var failing = WatchListItem(key: "456")
        _ = WatchListRules.apply(.failed("Signed out"), to: &failing, fields: nil, expect: [:], at: start)
        _ = WatchListRules.apply(.failed("Signed out"), to: &failing, fields: nil, expect: [:], at: start + 900)
        return WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [item, failing], args: ["zip": .text("10001")],
                              fields: ["price", "badges"], expect: ["badges": .list(["Deal"])], everyMinutes: 30, paused: true,
                              createdAt: start, lastRunAt: start + 900.25)
    }
}

/// A Noteling folder of its own for one test: `watches/` and the earlier `watch-list.json`, never the real ones.
@MainActor
struct Place {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("watch-place-\(UUID().uuidString)")
    var watches: URL { root.appendingPathComponent("watches") }
    var legacy: URL { root.appendingPathComponent("watch-list.json") }

    /// Stopped watches' folders go to a Trash folder of the test's own, never the real Trash.
    func store(trash: ((URL) throws -> Void)? = nil) -> WatchListStore {
        let bin = root.appendingPathComponent("Trash")
        return WatchListStore(directory: watches, legacyFile: legacy, trash: trash ?? { url in
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: bin.appendingPathComponent(UUID().uuidString))
        })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    /// Writes a file as a person's editor would, with a later modification date than any before it.
    func write(_ text: String, to file: URL) throws {
        let earlier = WatchListFiles.modified(file) ?? Date()
        try text.write(to: file, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: earlier.addingTimeInterval(2)], ofItemAtPath: file.path)
    }

    /// Edits a watch's watch.json by hand.
    func edit(_ folder: String, _ change: (inout [String: Any]) -> Void) throws {
        let file = watches.appendingPathComponent(folder).appendingPathComponent("watch.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        change(&json)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try write(String(decoding: data, as: UTF8.self), to: file)
    }
}
