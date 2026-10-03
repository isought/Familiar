import Foundation
import Testing
@testable import Familiar

/// A watch's files as people meet them: a watch.json written by hand is read leniently and, when it can't be, says what
/// is wrong in plain words; folder names come from watch names; latest.json keeps exactly what was found.
@Suite @MainActor
struct WatchListFilesTests {
    private let created = Date(timeIntervalSince1970: 1_790_000_000)

    @Test func aHandWrittenWatchJsonNeedsOnlyItsItems() throws {
        let json = """
        {"items": ["123", 456, {"key": "https://shop.example.com/item/789", "expect": {"price": 19.99}}, "123", "  "],
         "every_minutes": "1000", "fields": ["price", " badges ", "price"], "args": {"zip": "10001", "item": "x"},
         "requires": ["SHOP_TOKEN"], "check": " shop__watch_item ", "owner": "Pricing team"}
        """
        let (definition, hadID) = try WatchListFiles.parseDefinition(Data(json.utf8), folder: "weekend", created: created)
        #expect(!hadID && definition.id == WatchListFiles.derivedID(folder: "weekend"))
        #expect(definition.name == "weekend" && definition.check == "shop__watch_item")
        #expect(definition.items == [.init(key: "123"), .init(key: "456"),
                                     .init(key: "https://shop.example.com/item/789", expect: ["price": .number(19.99)])])
        #expect(definition.everyMinutes == 240 && !definition.paused && definition.createdAt == created)
        #expect(definition.fields == ["price", "badges"] && definition.args == ["zip": .text("10001")])
        #expect(definition.requires == ["SHOP_TOKEN"])
        #expect(definition.other == #"{"owner":"Pricing team"}"#)
        #expect(WatchListFiles.definitionText(definition).contains("  \"owner\": \"Pricing team\"\n}"))   // kept, at the end
    }

    @Test func aWatchJsonThatCantBeReadSaysWhyInPlainWords() {
        func problem(_ json: String) -> String? {
            do { _ = try WatchListFiles.parseDefinition(Data(json.utf8), folder: "f", created: created); return nil }
            catch { return WatchListStore.reason(error) }
        }
        #expect(problem("[1, 2]") == "it must be one JSON object: { … }.")
        #expect(problem("{\"name\": \"x\"}") == "it needs items: a list of item ids or page addresses.")
        #expect(problem("{\"items\": \"123\"}") == "items must be a list of item ids or page addresses, [ … ].")
        #expect(problem("{\"items\": [true]}") == "item 1 must be an id or page address in quotes, or an object with a key: { \"key\": … }.")
        #expect(problem("{\"items\": [\"1\"], \"every_minutes\": \"often\"}") == "every_minutes must be a number of minutes, 5 to 240.")
        #expect(problem("{\"items\": [\"1\"], \"paused\": \"maybe\"}") == "paused must be true or false.")
        #expect(problem("{\"items\": [\"1\"], \"expect\": [1]}") == "expect must be an object of field → value, { … }.")
        #expect(problem("{\"items\": [\"1\"], \"fields\": [1]}") == "fields must be a list of field names in quotes.")
        #expect(problem("{\"items\": [\"1\"], \"name\": 3}") == "name must be text in quotes.")
        #expect(problem("{\"items\": [" + (1...201).map { "\"\($0)\"" }.joined(separator: ",") + "]}") == "it lists 201 items, and a watch holds up to 200.")
        #expect(problem("{\"items\": [\"1\"")?.hasPrefix("it isn't valid JSON (") == true)
    }

    @Test func folderNamesComeFromWatchNames() {
        #expect(WatchListFiles.slug("Sale items", taken: []) == "sale-items")
        #expect(WatchListFiles.slug("  Crème brûlée / weekend!! ", taken: []) == "creme-brulee-weekend")
        #expect(WatchListFiles.slug("Sale items", taken: ["Sale-Items", "sale-items-2"]) == "sale-items-3")
        #expect(WatchListFiles.slug("…", taken: []) == "watch")
        #expect(WatchListFiles.slug(String(repeating: "long name ", count: 10), taken: []).count <= 40)
        #expect(WatchListFiles.derivedID(folder: "weekend") == WatchListFiles.derivedID(folder: "weekend"))
        #expect(WatchListFiles.derivedID(folder: "weekend") != WatchListFiles.derivedID(folder: "weekend copy"))
    }

    @Test func latestJsonKeepsExactlyWhatWasFound() throws {
        var item = WatchListItem(key: "123")
        item.title = "Blue kettle"
        item.captured = ["price": .number(12.33), "badges": .list(["Deal"]), "note": .none]
        item.expected = ["price": .number(12.33)]
        item.state = ["price": .number(13.95), "badges": .list([]), "in_stock": .flag(false)]
        item.facts = #"{"offers":[{"price":13.95,"seller":"Acme"}]}"#
        item.why = ["The page shows 13.95; the list says 12.33."]
        item.checkedAt = Date(timeIntervalSince1970: 1_790_000_123.456789)
        item.status = .notAsExpected([WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))])
        item.notified = .asExpected
        var text = WatchListItem(key: "456")
        text.facts = "\"just words\""   // facts that are no object or list keep their text
        text.status = .couldNotCheck("Signed out")
        text.failures = 3
        text.notifiedCouldNotCheck = true
        let watch = WatchListWatch(name: "Sale items", check: "c", items: [item, text], createdAt: created,
                                   lastRunAt: Date(timeIntervalSince1970: 1_790_000_100.5))

        let written = WatchListFiles.resultsText(watch)
        #expect(written.contains("\"facts\": {\n        \"offers\": [\n"))   // readable, not a string of JSON
        var read = WatchListWatch(id: watch.id, name: "Sale items", check: "c", items: [WatchListItem(key: "123"), WatchListItem(key: "456")],
                                  createdAt: created)
        try WatchListFiles.readResults(Data(written.utf8), into: &read)
        #expect(read == watch)
    }

    @Test func numbersAreWrittenAsPeopleWriteThem() {
        #expect(WatchListJSON.pretty(["price": 19.99, "count": 3, "whole": 15.0, "flag": true, "none": NSNull()] as [String: Any], indent: "")
                == "{\n  \"count\": 3,\n  \"flag\": true,\n  \"none\": null,\n  \"price\": 19.99,\n  \"whole\": 15\n}")
        #expect(WatchListJSON.pretty([String](), indent: "") == "[]")
        #expect(WatchListJSON.pretty(["https://shop.example.com/a"], indent: "") == "[\"https://shop.example.com/a\"]")
    }
}
