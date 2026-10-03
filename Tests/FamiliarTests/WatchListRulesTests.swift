import Foundation
import Testing
@testable import Familiar

/// How a watch decides whether an item is as it should be right now, and what it tells the person: what counts as
/// right, how values compare, when an alert goes out, what a check's answer means, and when a watch is due.
@Suite
struct WatchListRulesTests {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)
    private let shown: [String: WatchListValue] = ["seller": .text("Acme"), "price": .number(12.33), "strikethrough": .number(13.95),
                                                   "badges": .list(["Deal", "Overall pick"]), "in_stock": .flag(true)]

    // MARK: what counts as right

    @Test func theFirstCheckThatWorksSetsWhatCountsAsRight() {
        #expect(WatchListRules.expectations(from: shown, fields: nil, expect: [:]) == shown)
        #expect(WatchListRules.expectations(from: shown, fields: ["price", "badges", "rating"], expect: [:])
                == ["price": .number(12.33), "badges": .list(["Deal", "Overall pick"])])
    }

    @Test func whatThePersonSaysOverridesTheFirstCheckAndCanAddAField() {
        let expected = WatchListRules.expectations(from: shown, fields: ["price"], expect: ["price": .number(11.99), "seller": .text("Acme Direct")])
        #expect(expected == ["price": .number(11.99), "seller": .text("Acme Direct")])

        var item = WatchListItem(key: "123")
        let kind = WatchListRules.apply(.checked(reading(shown)), to: &item, fields: nil, expect: ["price": .number(11.99)], at: start)
        #expect(kind == nil)   // the first check never notifies, even when it isn't as expected
        #expect(item.expected?["price"] == .number(11.99))
        #expect(item.expected?["seller"] == .text("Acme"))
        #expect(item.status == .notAsExpected([WatchListDifference(field: "price", now: .number(12.33), expected: .number(11.99))]))
    }

    @Test func anItemWhoseFirstCheckFailedGetsItsExpectationsFromItsFirstSuccess() {
        var item = WatchListItem(key: "123")
        #expect(WatchListRules.apply(.failed("It took longer than 60 seconds."), to: &item, fields: nil, expect: [:], at: start) == nil)
        #expect(item.expected == nil && item.status == .couldNotCheck("It took longer than 60 seconds.") && item.failures == 1)

        let kind = WatchListRules.apply(.checked(reading(["price": .number(12.33)], title: "Blue kettle")), to: &item, fields: nil, expect: [:],
                                        at: start + 900)
        #expect(kind == nil)
        #expect(item.expected == ["price": .number(12.33)])
        #expect(item.status == .asExpected && item.failures == 0 && item.title == "Blue kettle")
    }

    @Test func expectationsAreCapturedOnceNotFromEveryCheck() {
        var item = WatchListItem(key: "123")
        _ = WatchListRules.apply(.checked(reading(["price": .number(12.33)])), to: &item, fields: nil, expect: [:], at: start)
        _ = WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start + 900)
        #expect(item.expected == ["price": .number(12.33)])
        #expect(item.state == ["price": .number(13.95)])
    }

    @Test func changingWhatCountsAsRightComparesWithTheLastCheckAndTellsNothing() {
        var item = WatchListItem(key: "123")
        _ = WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start)
        WatchListRules.reexpect(&item, with: ["price": .number(12.33)])
        let difference = WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))
        #expect(item.status == .notAsExpected([difference]))
        #expect(item.notified == .notAsExpected([difference]))   // the chat showed it
        // The next check that finds the same says nothing more.
        #expect(WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start + 900) == nil)

        var failing = WatchListItem(key: "456")
        _ = WatchListRules.apply(.checked(reading(["price": .number(1)])), to: &failing, fields: nil, expect: [:], at: start)
        _ = WatchListRules.apply(.failed("Offline"), to: &failing, fields: nil, expect: [:], at: start + 900)
        WatchListRules.reexpect(&failing, with: ["price": .number(2)])
        #expect(failing.status == .couldNotCheck("Offline"))   // nothing known now: an earlier check doesn't stand in for it
        #expect(failing.expected == ["price": .number(2)])
    }

    // MARK: comparing

    @Test func numbersAreTheSameWithinHalfACent() {
        #expect(WatchListRules.same(.number(12.33), .number(12.33)))
        #expect(WatchListRules.same(.number(12.33), .number(12.334)))
        #expect(WatchListRules.same(.number(0.1 + 0.2), .number(0.3)))
        #expect(!WatchListRules.same(.number(12.33), .number(12.34)))
        #expect(!WatchListRules.same(.number(13.95), .number(12.33)))
        // As a person or the model may write them.
        #expect(WatchListRules.same(.number(12.33), .text("12.33")))
        #expect(WatchListRules.same(.text("$12.33"), .number(12.33)))
        #expect(WatchListRules.same(.number(1299), .text("1,299.00")))
        #expect(!WatchListRules.same(.number(12.33), .text("cheap")))
    }

    @Test func textIsTrimmedThenExact() {
        #expect(WatchListRules.same(.text("  Acme \n"), .text("Acme")))
        #expect(!WatchListRules.same(.text("acme"), .text("Acme")))
        #expect(!WatchListRules.same(.text(""), .none))
    }

    @Test func listsAreSetsWhereOrderDoesNotMatter() {
        #expect(WatchListRules.same(.list(["Overall pick", "Deal"]), .list(["Deal", "Overall pick"])))
        #expect(WatchListRules.same(.list(["Deal", "Deal "]), .list(["Deal"])))
        #expect(!WatchListRules.same(.list(["Overall pick"]), .list(["Deal", "Overall pick"])))
        #expect(!WatchListRules.same(.list(["Deal", "Overall pick"]), .list(["Deal"])))
        #expect(WatchListRules.same(.list(["Deal"]), .text("Deal")))
    }

    @Test func yesAndNo() {
        #expect(WatchListRules.same(.flag(true), .flag(true)))
        #expect(!WatchListRules.same(.flag(true), .flag(false)))
        #expect(WatchListRules.same(.flag(false), .text("no")))
        #expect(!WatchListRules.same(.flag(true), .number(1)))
    }

    @Test func noneIsARealValueAndAMissingFieldIsOnlyNotReported() {
        #expect(WatchListRules.same(.none, .none))
        #expect(WatchListRules.same(.list([]), .none))   // an empty list is none
        #expect(!WatchListRules.same(.none, .number(13.95)))

        let expected: [String: WatchListValue] = ["price": .number(12.33), "strikethrough": .none, "seller": .text("Acme")]
        let status = WatchListRules.compare(["price": .number(12.33), "strikethrough": .number(13.95)], with: expected)
        #expect(status == .notAsExpected([WatchListDifference(field: "strikethrough", now: .number(13.95), expected: .none)]))
        #expect(WatchListRules.compare(["price": .number(12.33), "strikethrough": .none], with: expected) == .asExpected)

        var item = WatchListItem(key: "123")
        item.expected = expected
        item.state = ["price": .number(12.33), "strikethrough": .none]
        #expect(item.unreported == ["seller"])
    }

    // MARK: alerts

    @Test func notAsExpectedIsToldOnceAndAgainOnlyWhenItChanges() {
        var item = firstChecked(["price": .number(12.33), "badges": .list(["Deal", "Overall pick"])])

        let worse = WatchListRules.apply(.checked(reading(["price": .number(12.33), "badges": .list(["Overall pick"])])), to: &item,
                                         fields: nil, expect: [:], at: start + 900)
        let lostDeal = WatchListDifference(field: "badges", now: .list(["Overall pick"]), expected: .list(["Deal", "Overall pick"]))
        #expect(worse == .notAsExpected([lostDeal]))

        // The same differences 15 minutes later: nothing new to say.
        #expect(WatchListRules.apply(.checked(reading(["price": .number(12.33), "badges": .list(["Overall pick"])])), to: &item,
                                     fields: nil, expect: [:], at: start + 1_800) == nil)

        // Not as expected in another way: told again.
        let other = WatchListRules.apply(.checked(reading(["price": .number(13.95), "badges": .list(["Overall pick"])])), to: &item,
                                         fields: nil, expect: [:], at: start + 2_700)
        #expect(other == .notAsExpected([lostDeal, WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))]))

        // Back to what was expected.
        let back = WatchListRules.apply(.checked(reading(["price": .number(12.33), "badges": .list(["Overall pick", "Deal"])])), to: &item,
                                        fields: nil, expect: [:], at: start + 3_600)
        #expect(back == .backToExpected)
        #expect(WatchListRules.apply(.checked(reading(["price": .number(12.33), "badges": .list(["Deal", "Overall pick"])])), to: &item,
                                     fields: nil, expect: [:], at: start + 4_500) == nil)
    }

    @Test func couldNotCheckIsToldOnTheSecondFailureInARowOnlyOnceUntilItRecovers() {
        var item = firstChecked(["price": .number(12.33)])
        #expect(WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 900) == nil)
        #expect(WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 1_800) == .couldNotCheck("Offline"))
        #expect(WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 2_700) == nil)
        #expect(item.failures == 3)

        // Working again, and as it was last told (as expected): nothing new to say.
        #expect(WatchListRules.apply(.checked(reading(["price": .number(12.33)])), to: &item, fields: nil, expect: [:], at: start + 3_600) == nil)
        #expect(item.failures == 0 && !item.notifiedCouldNotCheck)

        // A new run of failures is told again; working again but not as expected is news.
        _ = WatchListRules.apply(.failed("Signed out"), to: &item, fields: nil, expect: [:], at: start + 4_500)
        #expect(WatchListRules.apply(.failed("Signed out"), to: &item, fields: nil, expect: [:], at: start + 5_400) == .couldNotCheck("Signed out"))
        let price = WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))
        #expect(WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start + 6_300)
                == .notAsExpected([price]))

        // Not as expected, then failures, then the same differences: they were told already.
        _ = WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 7_200)
        _ = WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 8_100)
        #expect(WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start + 9_000) == nil)
        #expect(WatchListRules.apply(.checked(reading(["price": .number(12.33)])), to: &item, fields: nil, expect: [:], at: start + 9_900)
                == .backToExpected)
    }

    @Test func manyItemsThatCouldNotBeCheckedForOneReasonAreOneAlert() {
        let id = UUID()
        func alert(_ key: String, _ kind: WatchListAlert.Kind) -> WatchListAlert {
            WatchListAlert(watchID: id, watchName: "Sale items", itemKey: key, title: "Item \(key)", kind: kind)
        }
        let signedOut = (1...4).map { alert("\($0)", .couldNotCheck("Signed out")) }
        let slow = [alert("5", .couldNotCheck("It took longer than 60 seconds.")), alert("6", .couldNotCheck("It took longer than 60 seconds."))]

        let grouped = WatchListRules.grouped(signedOut + slow)

        #expect(grouped == [WatchListAlert(watchID: id, watchName: "Sale items", itemKey: "", title: "Sale items",
                                           kind: .couldNotCheckItems(4, "Signed out"))] + slow)
        #expect(grouped.first?.body == "Couldn't check 4 items: Signed out")
        #expect(WatchListRules.grouped(Array(signedOut.prefix(2))) == Array(signedOut.prefix(2)))
    }

    @Test func aSingleFailureBetweenGoodChecksSaysNothing() {
        var item = firstChecked(["price": .number(12.33)])
        #expect(WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 900) == nil)
        #expect(WatchListRules.apply(.checked(reading(["price": .number(12.33)])), to: &item, fields: nil, expect: [:], at: start + 1_800) == nil)
    }

    @Test func aResultTheChatShowsIsWhatThePersonWasTold() {
        var item = firstChecked(["price": .number(12.33)])
        let difference = WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))
        #expect(WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start + 900,
                                     quiet: true) == nil)
        #expect(item.notified == .notAsExpected([difference]))
        #expect(WatchListRules.apply(.checked(reading(["price": .number(13.95)])), to: &item, fields: nil, expect: [:], at: start + 1_800) == nil)

        _ = WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 2_700)
        #expect(WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 3_600, quiet: true) == nil)
        #expect(item.notifiedCouldNotCheck)
        #expect(WatchListRules.apply(.failed("Offline"), to: &item, fields: nil, expect: [:], at: start + 4_500) == nil)
    }

    @Test func alertsSayItInPlainWords() {
        let id = UUID()
        func alert(_ kind: WatchListAlert.Kind) -> WatchListAlert {
            WatchListAlert(watchID: id, watchName: "Sale items", itemKey: "123", title: "Blue kettle", kind: kind)
        }
        let badges = WatchListDifference(field: "badges", now: .list(["Overall pick"]), expected: .list(["Deal", "Overall pick"]))
        let price = WatchListDifference(field: "price", now: .number(13.95), expected: .number(12.33))
        #expect(alert(.notAsExpected([badges])).body == "Badges: Overall pick — expected Deal, Overall pick")
        #expect(alert(.notAsExpected([badges, price])).body == "Badges: Overall pick — expected Deal, Overall pick\nPrice: 13.95 — expected 12.33")
        #expect(alert(.backToExpected).body == "Back to what you expected")
        #expect(alert(.couldNotCheck("Signed out")).body == "Couldn't check: Signed out")
        #expect(WatchListDifference(field: "in_stock", now: .flag(false), expected: .flag(true)).words == "In stock: no — expected yes")
        #expect(WatchListDifference(field: "strikethrough", now: .none, expected: .number(13.9)).words == "Strikethrough: none — expected 13.90")
        #expect(WatchListNotifier.identifier(alert(.backToExpected)) == WatchListNotifier.identifier(alert(.couldNotCheck("x"))))
    }

    @Test func fieldNamesReadAsWords() {
        #expect(WatchListRules.label("in_stock") == "In stock")
        #expect(WatchListRules.label("strikeThrough") == "Strike through")
        #expect(WatchListRules.label("SKU") == "SKU")
        #expect(WatchListRules.label("price") == "Price")
    }

    // MARK: what a check returns

    @Test func aCheckAnswerBecomesTitleAddressStateAndFacts() throws {
        let outcome = WatchListReading.parse([
            "title": "Blue kettle", "url": "https://shop.example.com/item/123",
            "state": ["seller": "Acme", "price": 12.33, "badges": ["Deal", 2, NSNull()], "in_stock": true, "strikethrough": NSNull(),
                      "dimensions": ["w": 10, "h": 20]],
            "facts": ["offers": [["seller": "Acme", "price": 12.33]], "note": "Deal ends at 6 PM"],
        ] as [String: Any])
        guard case .checked(let reading) = outcome else { Issue.record("expected a reading, got \(outcome)"); return }
        #expect(reading.title == "Blue kettle")
        #expect(reading.url == "https://shop.example.com/item/123")
        #expect(reading.state["seller"] == .text("Acme"))
        #expect(reading.state["price"] == .number(12.33))
        #expect(reading.state["badges"] == .list(["Deal", "2"]))
        #expect(reading.state["in_stock"] == .flag(true))
        #expect(reading.state["strikethrough"] == WatchListValue.none)
        #expect(reading.state["dimensions"] == .text(#"{"h":20,"w":10}"#))   // not flat: compared as its JSON text
        #expect(reading.facts == #"{"note":"Deal ends at 6 PM","offers":[{"price":12.33,"seller":"Acme"}]}"#)
    }

    @Test func anErrorOrNoStateMeansItCouldNotCheck() {
        #expect(WatchListReading.parse(["error": "Signed out of the shop"]) == .failed("Signed out of the shop"))
        #expect(WatchListReading.parse(["error": NSNull(), "title": "x", "state": [String: Any]()]) == .checked(WatchListReading(title: "x", url: nil, state: [:], facts: nil)))
        #expect(WatchListReading.parse(["title": "x"]) == .failed("The check didn't say what it found (no state)."))
        #expect(WatchListReading.parse("just text") == .failed("The check didn't return what it found."))
        #expect(WatchListReading.parse(nil) == .failed("The check didn't return what it found."))
    }

    @Test func aScriptFailureReadsAsItsOwnWords() {
        let error = "watch_item.py failed: ValueError: item 9 isn't on the shop\nTraceback (most recent call last):\n  File …"
        #expect(WatchListRules.reason(error) == "item 9 isn't on the shop")
        #expect(WatchListRules.reason("check.py produced no result. stderr: boom") == "check.py produced no result. stderr: boom")
        #expect(WatchListRules.reason("\n") == "The check failed without saying why.")
    }

    @Test func valuesComeFromJSONAndGoBackAsJSON() {
        #expect(WatchListValue(json: 3 as NSNumber) == .number(3))
        #expect(WatchListValue(json: true) == .flag(true))
        #expect(WatchListValue(json: "Deal") == .text("Deal"))
        #expect(WatchListValue(json: nil) == WatchListValue.none)
        #expect(WatchListValue.number(3).json as? Int == 3)
        #expect(WatchListValue.number(12.5).json as? Double == 12.5)
        #expect(WatchListValue.none.json is NSNull)
        #expect(WatchListValue.number(12.5).words == "12.50")
        #expect(WatchListValue.number(1299).words == "1299")
        #expect(WatchListValue.list([]).words == "none")
        #expect(WatchListValue.text(" ").words == "empty")
    }

    // MARK: when

    @Test func aWatchIsDueWhenItsIntervalHasPassed() {
        var watch = WatchListWatch(name: "Sale items", check: "shop__watch_item", items: [WatchListItem(key: "123")], everyMinutes: 15)
        #expect(WatchListSchedule.isDue(watch, at: start))   // never checked
        watch.lastRunAt = start
        #expect(!WatchListSchedule.isDue(watch, at: start + 10 * 60))
        #expect(!WatchListSchedule.isDue(watch, at: start + 14 * 60))
        #expect(WatchListSchedule.isDue(watch, at: start + 15 * 60 - 2))   // a tick a moment early still counts
        #expect(WatchListSchedule.isDue(watch, at: start + 40 * 60))
        #expect(WatchListSchedule.isDue(watch, at: start - 3_600))         // the clock went back an hour
        #expect(WatchListSchedule.next(watch, after: start + 60) == start + 15 * 60)

        watch.paused = true
        #expect(!WatchListSchedule.isDue(watch, at: start + 40 * 60))
        #expect(WatchListSchedule.next(watch, after: start) == nil)
        watch.paused = false
        watch.items = []
        #expect(!WatchListSchedule.isDue(watch, at: start + 40 * 60))
    }

    @Test func howOftenIsHeldBetweenFiveMinutesAndFourHours() {
        #expect(WatchListWatch(name: "a", check: "c", items: [], everyMinutes: 1).everyMinutes == 5)
        #expect(WatchListWatch(name: "a", check: "c", items: [], everyMinutes: 1_000).everyMinutes == 240)
        #expect(WatchListWatch(name: "a", check: "c", items: []).everyMinutes == 15)
        #expect(WatchListWatch(name: "a", check: "c", items: [], everyMinutes: 60).everyWords == "every hour")
        #expect(WatchListWatch(name: "a", check: "c", items: [], everyMinutes: 120).everyWords == "every 2 hours")
        #expect(WatchListWatch(name: "a", check: "c", items: [], everyMinutes: 45).everyWords == "every 45 minutes")
    }

    // MARK: helpers

    private func reading(_ state: [String: WatchListValue], title: String? = "Blue kettle") -> WatchListReading {
        WatchListReading(title: title, url: "https://shop.example.com/item/123", state: state, facts: nil)
    }

    /// An item after the watch's first check, which says nothing: the chat shows it.
    private func firstChecked(_ state: [String: WatchListValue]) -> WatchListItem {
        var item = WatchListItem(key: "123")
        let kind = WatchListRules.apply(.checked(reading(state)), to: &item, fields: nil, expect: [:], at: start)
        #expect(kind == nil)
        return item
    }
}
