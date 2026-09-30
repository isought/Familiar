import Foundation
import Testing
@testable import Familiar

/// The numbers come from the ledger alone. A message counts once, on the day a card step first read it; yes and no
/// are over what was shown, a miss counts on its message's first day, and "0 missed" means something only once the
/// rest was scrolled to its end. The week is measured against the pass bar set before the test began.
@Suite
struct AttentionNumbersTests {
    @Test func aMessageReadTwiceADayAndAgainTomorrowCountsOnceOnItsFirstDay() {
        // A 24-hour window read morning and evening repeats 30 messages; the next morning repeats 10 more.
        let morning = sorted(Self.at("2026-09-28", "08:00"), keys: (0..<40).map { "m\($0)" }, shown: ["m5"])
        let evening = sorted(Self.at("2026-09-28", "20:00"), keys: (10..<50).map { "m\($0)" })
        let tomorrow = sorted(Self.at("2026-09-29", "08:00"), keys: (40..<60).map { "m\($0)" }, shown: ["m45"])
        let numbers = measure([morning, evening, tomorrow], now: Self.at("2026-09-29", "09:00"))

        let monday = numbers.day("2026-09-28"), tuesday = numbers.day("2026-09-29")
        #expect(monday.read == 50 && tuesday.read == 10)
        // Shown the next day, but first read on Monday, so it is one of Monday's.
        #expect(Set(monday.shownKeys) == ["m5", "m45"] && monday.restCount == 48 && tuesday.shown == 0)
        #expect(numbers.week?.total.read == 60 && numbers.week?.total.shown == 2)
        #expect(numbers.line?.text == "Read 10 → showed 0 · you said yes to 0 · 10 in the rest")
    }

    @Test func theDailyLineReadsLikeTheFounderWroteIt() {
        let wednesday = Self.at("2026-09-30", "08:00")
        let keys = (0..<42).map { "k\($0)" }
        var events = [sorted(wednesday, keys: keys, shown: Set(keys.prefix(6)))]
        events += [label("k0", .yes, at: wednesday), label("k1", .yes, at: wednesday), label("k1", .strongYes, at: wednesday),
                   implicit("k2", .mine, at: wednesday), implicit("k3", .optionTapped, at: wednesday), label("k4", .no, at: wednesday)]
        let now = Self.at("2026-09-30", "09:00")
        #expect(measure(events, now: now).line == .init(day: "2026-09-30", text: "Read 42 → showed 6 · you said yes to 4 · 36 in the rest",
                                                       help: "4 yes: 2 you tapped, 2 guessed from what you did"))
        let day = measure(events, now: now).day("2026-09-30")
        #expect(day.yesTapped == 2 && day.yesGuessed == 2 && day.no == 1 && day.leftAlone == 1 && day.strong == 1)

        // Once the rest has been scrolled to its end, the line says what was missed.
        events.append(restViewed("2026-09-30", reachedEnd: true, at: wednesday))
        #expect(measure(events, now: now).line?.text == "Read 42 → showed 6 · you said yes to 4 · 0 missed")
        events.append(miss("k40", at: wednesday))
        #expect(measure(events, now: now).line?.text == "Read 42 → showed 6 · you said yes to 4 · 1 missed")
        events.append(miss("k40", retract: true, at: wednesday))
        #expect(measure(events, now: now).line?.text == "Read 42 → showed 6 · you said yes to 4 · 0 missed")

        // With nothing read today, the latest day read in the last seven, named.
        #expect(measure(events, now: Self.at("2026-10-01", "09:00")).line?.text == "Yesterday: Read 42 → showed 6 · you said yes to 4 · 0 missed")
        #expect(measure(events, now: Self.at("2026-10-06", "09:00")).line?.text == "Wed: Read 42 → showed 6 · you said yes to 4 · 0 missed")
        #expect(measure(events, now: Self.at("2026-10-07", "09:00")).line == nil)
        #expect(measure([], now: now).line == nil)

        // Messages past the script's limit are cut off, not read. Reads that don't say where their windows start may
        // cut off the same ones, so of a day's only the most counts.
        events.append(sorted(Self.at("2026-09-30", "08:30"), keys: [], arrived: 202, returned: 42, truncated: true))
        events.append(sorted(Self.at("2026-09-30", "20:00"), keys: [], arrived: 150, returned: 42, truncated: true))
        #expect(measure(events, now: now.addingTimeInterval(12 * 3_600)).line?.text
                == "Read 42 → showed 6 · you said yes to 4 · 0 missed · 160 cut off")
    }

    /// The script returns the newest 200 of what arrived in its window, so what it leaves out is the oldest, which is
    /// where the window reaches back over an earlier read. Those were read then and are not cut off.
    @Test func aReadCutsOffOnlyWhatNoEarlierReadReturned() {
        var inbox = Inbox()
        // 180 arrive from 18:00 to 08:00 and are all read at 08:00; 60 more by 18:00. A 24-hour read at 18:00 sees
        // 240 and returns the newest 200. Every message was read.
        inbox.arrive(180, from: Self.at("2026-09-29", "18:00"), to: Self.at("2026-09-30", "08:00"))
        var events = [inbox.read(at: Self.at("2026-09-30", "08:00"), hours: 24)]
        inbox.arrive(60, from: Self.at("2026-09-30", "08:00"), to: Self.at("2026-09-30", "18:00"))
        events.append(inbox.read(at: Self.at("2026-09-30", "18:00"), hours: 24))
        #expect(inbox.counts.last == .init(arrived: 240, returned: 200))
        let evening = measure(events, now: Self.at("2026-09-30", "18:30"))
        #expect(evening.day("2026-09-30").read == 240 && evening.day("2026-09-30").cutOff == 0)
        #expect(evening.line?.text == "Read 240 → showed 0 · you said yes to 0 · 240 in the rest")   // was "· 40 cut off"
        #expect(evening.week?.labels == "0 tapped (0 strong, 0 explained) · 0 guessed · 0 cut off")

        // The next morning's 24-hour read reaches back to 08:00 and leaves out 20 of the 60, read the evening before.
        inbox.arrive(160, from: Self.at("2026-09-30", "18:00"), to: Self.at("2026-10-01", "08:00"))
        events.append(inbox.read(at: Self.at("2026-10-01", "08:00"), hours: 24))
        #expect(inbox.counts.last == .init(arrived: 220, returned: 200))
        let tomorrow = measure(events, now: Self.at("2026-10-01", "08:30"))
        #expect(tomorrow.day("2026-10-01").cutOff == 0 && tomorrow.day("2026-10-01").read == 160 && tomorrow.week?.total.cutOff == 0)
    }

    @Test func aDayReadTwiceWithinADayCountsOnlyMailNoReadReturned() {
        // 50 arrive from 08:00 to 20:00, 130 overnight, 150 the next day. The 20:00 read's 24-hour window holds 280 and
        // it leaves out 80, all returned at 08:00.
        var inbox = Inbox()
        inbox.arrive(50, from: Self.at("2026-09-29", "08:00"), to: Self.at("2026-09-29", "20:00"))
        inbox.arrive(130, from: Self.at("2026-09-29", "20:00"), to: Self.at("2026-09-30", "08:00"))
        var events = [inbox.read(at: Self.at("2026-09-30", "08:00"), hours: 24)]
        inbox.arrive(150, from: Self.at("2026-09-30", "08:00"), to: Self.at("2026-09-30", "20:00"))
        events.append(inbox.read(at: Self.at("2026-09-30", "20:00"), hours: 24))
        #expect(inbox.counts == [.init(arrived: 180, returned: 180), .init(arrived: 280, returned: 200)])
        #expect(measure(events, now: Self.at("2026-09-30", "21:00")).day("2026-09-30").cutOff == 0)   // was 80

        // 220 arrive in the 24 hours before 08:00, when the newest 200 are read and 20 are cut off; 100 more by 16:00.
        // The 16:00 read's 24-hour window holds 250 and it leaves out 50, all among the 200 returned at 08:00.
        var busy = Inbox()
        busy.arrive(70, from: Self.at("2026-09-29", "08:00"), to: Self.at("2026-09-29", "16:00"))
        busy.arrive(150, from: Self.at("2026-09-29", "16:00"), to: Self.at("2026-09-30", "08:00"))
        var reads = [busy.read(at: Self.at("2026-09-30", "08:00"), hours: 24)]
        busy.arrive(100, from: Self.at("2026-09-30", "08:00"), to: Self.at("2026-09-30", "16:00"))
        reads.append(busy.read(at: Self.at("2026-09-30", "16:00"), hours: 24))
        #expect(busy.counts == [.init(arrived: 220, returned: 200), .init(arrived: 250, returned: 200)])
        let numbers = measure(reads, now: Self.at("2026-09-30", "17:00"))
        #expect(numbers.day("2026-09-30").cutOff == 20 && numbers.day("2026-09-30").read == 300)   // was 50
        #expect(numbers.line?.text.hasSuffix("· 300 in the rest · 20 cut off") == true)

        // A read soon after whose window starts where the 08:00 one's did, as when it ran before the later reads were
        // sorted, leaves out 121: the same 20, and 101 returned at 08:00. Nothing more was cut off.
        busy.arrive(1, from: Self.at("2026-09-30", "16:00"), to: Self.at("2026-09-30", "16:05"))
        reads.append(busy.read(at: Self.at("2026-09-30", "16:05"), since: Self.at("2026-09-29", "08:00")))
        #expect(busy.counts.last == .init(arrived: 321, returned: 200))
        #expect(measure(reads, now: Self.at("2026-09-30", "17:00")).day("2026-09-30").cutOff == 20)
    }

    @Test func mailPastTheLimitThatNoReadReturnedIsStillCutOff() {
        // Read at 08:00; the 18:00 read goes back to 07:00, an hour before it. 10 of the 250 in its window were read at
        // 08:00, and it leaves out 50: those 10, and 40 that arrived after 08:00 and were never read.
        var inbox = Inbox()
        inbox.arrive(90, from: Self.at("2026-09-29", "08:00"), to: Self.at("2026-09-30", "07:00"))
        inbox.arrive(10, from: Self.at("2026-09-30", "07:00"), to: Self.at("2026-09-30", "08:00"))
        var events = [inbox.read(at: Self.at("2026-09-30", "08:00"), hours: 24)]
        inbox.arrive(240, from: Self.at("2026-09-30", "08:00"), to: Self.at("2026-09-30", "18:00"))
        events.append(inbox.read(at: Self.at("2026-09-30", "18:00"), hours: ScriptReadWindow.hours(lastRead: Self.at("2026-09-30", "08:00"),
                                                                                                   now: Self.at("2026-09-30", "18:00"))))
        #expect(inbox.counts == [.init(arrived: 100, returned: 100), .init(arrived: 250, returned: 200)])
        let numbers = measure(events, now: Self.at("2026-09-30", "18:30"))
        #expect(numbers.day("2026-09-30").cutOff == 40 && numbers.day("2026-09-30").read == 300)
        #expect(numbers.line?.text == "Read 300 → showed 0 · you said yes to 0 · 300 in the rest · 40 cut off")
        #expect(numbers.week?.labels.hasSuffix("· 40 cut off") == true)
    }

    /// A message read before and archived since is no longer in the mailbox, so the script no longer counts it as
    /// arrived. Told when the last sorted read was, the script counts what it cut off that arrived after it, which stays
    /// exact. Without that count, as from an older copy of the script, the estimate takes away the archived ones too.
    @Test func theScriptsOwnCountStaysExactWhenMailReadBeforeWasArchived() {
        let morning = Self.at("2026-09-30", "08:00"), evening = Self.at("2026-09-30", "18:00")
        var inbox = Inbox()
        inbox.arrive(90, from: Self.at("2026-09-29", "08:00"), to: Self.at("2026-09-30", "07:00"))
        inbox.arrive(30, from: Self.at("2026-09-30", "07:00"), to: morning)
        let first = inbox.read(at: morning, hours: 24)
        // The person archives 20 of those read at 08:00 that arrived after 07:00, and 260 more arrive by 18:00. The
        // 18:00 read goes back to 07:00 and returns the newest 200: 60 of the 260 were never read.
        inbox.archive(20, from: Self.at("2026-09-30", "07:00"), to: morning)
        inbox.arrive(260, from: morning, to: evening)
        let hours = ScriptReadWindow.hours(lastRead: morning, now: evening)
        var told = inbox, untold = inbox
        let counted = told.read(at: evening, hours: hours, lastRead: morning)
        #expect(told.counts.last == .init(arrived: 270, returned: 200))
        let numbers = measure([first, counted], now: Self.at("2026-09-30", "18:30"))
        #expect(numbers.day("2026-09-30").cutOff == 60 && numbers.line?.text.hasSuffix("· 60 cut off") == true)
        #expect(numbers.week?.labels.hasSuffix("· 60 cut off") == true)
        // The estimate takes away all 30 read at 08:00 from its window, though only 10 are still there.
        let estimated = untold.read(at: evening, hours: hours)
        #expect(measure([first, estimated], now: Self.at("2026-09-30", "18:30")).day("2026-09-30").cutOff == 40)
    }

    @Test func openingTheRestWithoutReachingTheEndIsNotAChecked() {
        let read = sorted(Self.at("2026-09-29"), keys: ["a", "b", "c"], shown: ["a"])
        let glanced = restViewed("2026-09-29", reachedEnd: false, at: Self.at("2026-09-29", "10:00"))
        let anotherDay = restViewed("2026-09-28", reachedEnd: true, at: Self.at("2026-09-29", "10:05"))
        let numbers = measure([read, glanced, anotherDay], now: Self.at("2026-09-29", "12:00"))
        #expect(!numbers.day("2026-09-29").restChecked)
        #expect(numbers.line?.text == "Read 3 → showed 1 · you said yes to 0 · 2 in the rest")
        // Looking at the rest is still using the pack that day.
        #expect(numbers.day("2026-09-29").firstOpen == Self.at("2026-09-29", "10:00"))

        // A day whose every message was shown has nothing left to check.
        let allShown = sorted(Self.at("2026-09-29"), keys: ["a"], shown: ["a"])
        #expect(measure([allShown], now: Self.at("2026-09-29", "12:00")).day("2026-09-29").restChecked)
    }

    @Test func aReadAfterTheRestWasCheckedLeavesItToCheckAgain() {
        let keys = (0..<42).map { "k\($0)" }
        var events = [sorted(Self.at("2026-09-30", "08:00"), keys: keys, shown: Set(keys.prefix(6))),
                      restViewed("2026-09-30", reachedEnd: true, at: Self.at("2026-09-30", "09:00"))]
        let evening = Self.at("2026-09-30", "21:00")
        #expect(measure(events, now: evening).line?.text == "Read 42 → showed 6 · you said yes to 0 · 0 missed")

        // Messages read again, and new ones that got a card, add nothing to the rest.
        events.append(sorted(Self.at("2026-09-30", "14:00"), keys: keys + ["n0"], shown: ["n0"]))
        #expect(measure(events, now: evening).day("2026-09-30").restChecked)

        // An evening read that adds 15 to the rest leaves it to check again, until it is scrolled to its end again.
        events.append(sorted(Self.at("2026-09-30", "20:00"), keys: (0..<15).map { "e\($0)" }))
        #expect(!measure(events, now: evening).day("2026-09-30").restChecked)
        #expect(measure(events, now: evening).line?.text == "Read 58 → showed 7 · you said yes to 0 · 51 in the rest")
        #expect(measure(events, now: evening).week?.missed.verdict == .notMeasured
                && measure(events, now: evening).week?.total.daysChecked == 0)
        events.append(restViewed("2026-09-30", reachedEnd: true, at: Self.at("2026-09-30", "20:30")))
        #expect(measure(events, now: evening).line?.text == "Read 58 → showed 7 · you said yes to 0 · 0 missed")

        // A receipt backfilled after the look carries its own earlier time, but its messages were not on screen then.
        events.append(sorted(Self.at("2026-09-30", "12:00"), keys: ["b0", "b1"]))
        #expect(!measure(events, now: evening).day("2026-09-30").restChecked)
        #expect(measure(events, now: evening).day("2026-09-30").restCount == 53)
    }

    @Test func aMissCountsOnTheDayTheItemWasFirstRead() {
        let thursday = sorted(Self.at("2026-09-24"), keys: ["lease", "promo"])
        let saturday = sorted(Self.at("2026-09-26"), keys: ["parcel"])
        let tapped = miss("lease", at: Self.at("2026-09-26", "18:00"))
        let numbers = measure([thursday, saturday, tapped], now: Self.at("2026-09-26", "20:00"))
        #expect(numbers.day("2026-09-24").missed == 1 && numbers.day("2026-09-26").missed == 0)
        #expect(numbers.week?.total.missed == 1)
        #expect(numbers.day("2026-09-26").firstOpen == Self.at("2026-09-26", "18:00") && numbers.day("2026-09-24").firstOpen == nil)
    }

    @Test func aRestItemThatLaterGetsACardCountsAsShown() {
        let monday = sorted(Self.at("2026-09-28"), keys: ["lease", "promo"])
        let missed = miss("lease", at: Self.at("2026-09-28", "12:00"))
        let tuesday = sorted(Self.at("2026-09-29"), keys: ["lease"], shown: ["lease"])
        let before = measure([monday, missed], now: Self.at("2026-09-28", "13:00")).day("2026-09-28")
        #expect(before.restKeys == ["lease", "promo"] && before.missed == 1)

        let after = measure([monday, missed, tuesday], now: Self.at("2026-09-29", "13:00"))
        #expect(after.day("2026-09-28").shownKeys == ["lease"] && after.day("2026-09-28").restKeys == ["promo"])
        #expect(after.day("2026-09-28").missed == 0 && after.day("2026-09-29").read == 0)
        #expect(after.restItems(on: "2026-09-28").items.map(\.key) == ["promo"])
    }

    @Test func passBar() {
        // 290 read, 38 shown, 25 yes (7 by a thumb, one of them strong), 3 no, every rest checked, opened on 5 days.
        let final = Self.at("2026-09-30", "22:00")
        let week = measure(fixtureWeek(), now: final).week
        #expect(week?.title == "Day 7 of 7 · started Thu Sep 24" && week?.dayNumber == 7 && week?.startDay == "2026-09-24")
        #expect(week?.days.map(\.day) == Self.days)
        #expect(week?.total == .init(read: 290, shown: 38, yesTapped: 7, yesGuessed: 18, no: 3, missed: 0, cutOff: 0,
            tapped: 8, guessed: 20, strong: 1, explained: 1, daysSoFar: 7, daysRead: 7, daysChecked: 7, daysOpened: 5))
        #expect(week?.showed == .init(verdict: .pass, text: "Showed 13% of what was read", bar: "at most 20%"))
        #expect(week?.missed == .init(verdict: .pass, text: "Missed 0 of 25 worth-it", bar: "under 1%"))
        #expect(week?.opened == .init(verdict: .pass, text: "Opened on 5 days", bar: "5 of 7"))
        #expect(week?.overall == "PASS")
        #expect(week?.power == "0 of 25 can't rule out a true miss rate up to 12% (95%)")
        #expect(week?.labels == "8 tapped (1 strong, 1 explained) · 20 guessed · 0 cut off")
        #expect(week?.days.map { $0.firstOpen != nil } == [true, true, false, true, false, true, true])

        // One miss in a normal week fails, whichever day it was tapped.
        let missed = measure(fixtureWeek() + [miss("d1m38", at: Self.at("2026-09-30", "21:30"))], now: final).week
        #expect(missed?.missed == .init(verdict: .fail, text: "Missed 1 of 26 worth-it", bar: "under 1%"))
        #expect(missed?.overall == "FAIL" && missed?.power == nil && missed?.days[1].missed == 1)

        // A day whose rest nobody looked through leaves the bar pending.
        let unchecked = measure(fixtureWeek().filter { !Self.isRestView($0, of: "2026-09-28") }, now: final).week
        #expect(unchecked?.missed == .init(verdict: .pending("check the rest for Mon"),
                                           text: "Missed 0 of 25 worth-it · check the rest for Mon", bar: "under 1%"))
        #expect(unchecked?.overall == "Day 7 of 7" && unchecked?.total.daysChecked == 6)

        // Four days opened fail on the last day.
        let fourDays: [String: AttentionOpenTrigger] = ["2026-09-24": .launcher, "2026-09-25": .launcher, "2026-09-27": .launcher, "2026-09-30": .menu]
        let four = measure(fixtureWeek(opens: fourDays), now: final).week
        #expect(four?.opened == .init(verdict: .fail, text: "Opened on 4 days", bar: "5 of 7") && four?.overall == "FAIL")

        // Chat, Who's Who and a run opening the pack are not the person opening it; opening a card in it is.
        let monday = Self.at("2026-09-28", "12:00")
        let passing = [AttentionOpenTrigger.chat, .people, .run].map { event(.opened(.init(trigger: $0, route: "folders", desk: 3)), at: monday) }
        #expect(measure(fixtureWeek(opens: fourDays) + passing, now: final).week?.opened.verdict == .fail)
        let cardOpened = event(.engaged(.init(key: "d4m0", what: .cardOpened, card: Self.card)), at: monday)
        let five = measure(fixtureWeek(opens: fourDays) + passing + [cardOpened], now: final).week
        #expect(five?.opened.verdict == .pass && five?.days[4].firstOpen == monday && five?.overall == "PASS")

        // Day 7 is not final before its read, so a pass given at midnight is not taken back at 08:00.
        let openedEarly: [String: AttentionOpenTrigger] = ["2026-09-24": .launcher, "2026-09-25": .launcher, "2026-09-27": .launcher,
                                                           "2026-09-28": .menu, "2026-09-29": .menu]
        let beforeRead = measure(fixtureWeek(opens: openedEarly), now: Self.at("2026-09-30", "07:00")).week
        #expect(beforeRead?.showed.verdict == .onTrack && beforeRead?.missed.verdict == .onTrack && beforeRead?.opened.verdict == .pass)
        #expect(beforeRead?.overall == "Day 7 of 7")
        #expect(measure(fixtureWeek(opens: openedEarly), now: final).week?.overall == "PASS")

        // Day 3 is on track, not a pass; Saturday's rest is looked through on Sunday, so it is still pending.
        let saturday = Self.at("2026-09-26", "22:00")
        let third = measure(fixtureWeek(), now: saturday).week
        #expect(third?.title == "Day 3 of 7 · started Thu Sep 24" && third?.overall == "Day 3 of 7")
        #expect(third?.showed.verdict == .onTrack && third?.opened.verdict == .onTrack)
        #expect(third?.missed.verdict == .pending("check the rest for Sat"))
        #expect(third?.total.daysSoFar == 3 && third?.days[3].read == 0)   // days to come are empty
        let checked = measure(fixtureWeek() + [restViewed("2026-09-26", reachedEnd: true, at: Self.at("2026-09-26", "21:00"))], now: saturday)
        #expect(checked.week?.missed.verdict == .onTrack && checked.week?.overall == "Day 3 of 7")

        // Opening fails as soon as 5 days can no longer be reached: 0 opened with 5 days left is on track, with 4 it fails.
        #expect(measure(fixtureWeek(opens: [:]), now: saturday).week?.opened.verdict == .onTrack)
        #expect(measure(fixtureWeek(opens: [:]), now: Self.at("2026-09-27", "22:00")).week?.opened
                == .init(verdict: .fail, text: "Opened on 0 days", bar: "5 of 7"))

        // Too much shown is off track before day 7 and fails on it, once day 7 is read.
        let crowded = [sorted(Self.at("2026-09-24"), keys: (0..<10).map { "c\($0)" }, shown: ["c0", "c1", "c2"])]
        #expect(measure(crowded, now: Self.at("2026-09-25")).week?.showed == .init(verdict: .offTrack, text: "Showed 30% of what was read", bar: "at most 20%"))
        #expect(measure(crowded, now: final).week?.showed.verdict == .offTrack)
        #expect(measure(crowded + [sorted(Self.at("2026-09-30"), keys: [])], now: final).week?.showed.verdict == .fail)

        // Nothing read and nothing worth it are not measured.
        let empty = measure([sorted(Self.at("2026-09-30"), keys: [])], now: final)
        #expect(empty.week?.showed == .init(verdict: .notMeasured, text: "Nothing read yet", bar: "at most 20%"))
        #expect(empty.week?.missed == .init(verdict: .notMeasured, text: "Missed 0 of 0 worth-it", bar: "under 1%"))
        #expect(empty.week?.power == nil && empty.week?.overall == "Day 1 of 7")
        #expect(empty.line?.text == "Read 0 → showed 0 · you said yes to 0 · 0 missed")
        #expect(measure([], now: final).week == nil)
    }

    @Test func windowRollsAfterSevenDays() {
        let reads = (0..<9).map { offset in
            sorted(Self.at("2026-09-22").addingTimeInterval(Double(offset) * 86_400), keys: ["r\(offset)a", "r\(offset)b"])
        }
        let ninth = measure(reads, now: Self.at("2026-09-30", "12:00")).week
        #expect(ninth?.title == "Last 7 days" && ninth?.dayNumber == 9 && ninth?.startDay == "2026-09-22")
        #expect(ninth?.days.map(\.day) == Self.days && ninth?.total.read == 14)

        let seventh = measure(reads, now: Self.at("2026-09-28", "12:00")).week
        #expect(seventh?.title == "Day 7 of 7 · started Tue Sep 22" && seventh?.days.first?.day == "2026-09-22")
        #expect(seventh?.days.last?.day == "2026-09-28" && seventh?.total.read == 14)
    }

    @Test func restOrdering() {
        let at = Self.at("2026-09-29", "12:00")
        func received(_ time: String) -> Date { Self.at("2026-09-29", time) }
        let items = [
            item("a", at: at, received: received("07:00"), tab: "updates", bulk: false, important: true),
            item("b", at: at, received: received("08:00"), tab: "primary", bulk: false, important: false),
            item("c", at: at, received: received("09:00"), tab: "primary", bulk: false, important: false),
            item("d", at: received("10:00")),   // no mail facts: sorted by when it was read
            item("e", at: at, received: received("06:00"), tab: "updates", bulk: false, important: false),
            item("f", at: at, received: received("11:00"), tab: "promotions", bulk: true, important: false),
            item("g", at: at, received: received("05:00"), tab: "updates", bulk: true, important: true),
            item("s", at: at, received: received("11:30"), tab: "primary", bulk: false, important: true, shown: true),
        ]
        let numbers = measure([event(.sorted(.init(runIDs: [UUID()], backfilled: false, sources: [source(at)], items: items)), at: at)],
                              now: at)
        let rest = numbers.restItems(on: "2026-09-29")
        #expect(rest.items.map(\.key) == ["a", "c", "b", "d", "e"])
        #expect(rest.lists.map(\.key) == ["g", "f"])
        #expect(numbers.day("2026-09-29").restKeys == ["f", "d", "c", "b", "a", "e", "g"])   // newest first, by arrival or read
        #expect(numbers.day("2026-09-29").shownKeys == ["s"])
    }

    @Test func gapsAndPowerFootnote() {
        // Saturday's read ended at 08:10; Monday's 24-hour window started Sunday 07:50.
        let saturday = Self.at("2026-09-26", "08:10"), monday = Self.at("2026-09-28", "07:50")
        let keys = (0..<22).map { "y\($0)" }
        var events = [sorted(saturday, keys: ["s0"], since: saturday.addingTimeInterval(-86_400)),
                      sorted(monday, keys: keys, shown: Set(keys), since: monday.addingTimeInterval(-86_400))]
        events += keys.map { implicit($0, .mine, at: monday) }
        events.append(restViewed("2026-09-26", reachedEnd: true, at: monday))
        let week = measure(events, now: Self.at("2026-09-28", "09:00")).week
        #expect(week?.gaps == ["Not read: Sat 26 08:10 → Sun 27 07:50"])
        #expect(week?.power == "0 of 22 can't rule out a true miss rate up to 14% (95%)")

        // A read that starts within ten minutes of the last one's end leaves no gap; a day without a read says so.
        events.append(sorted(Self.at("2026-09-28", "20:00"), keys: [], since: monday.addingTimeInterval(9 * 60)))
        #expect(measure(events, now: Self.at("2026-09-29", "21:00")).week?.gaps == ["Not read: Sat 26 08:10 → Sun 27 07:50"])
        #expect(measure(events, now: Self.at("2026-09-29", "22:01")).week?.gaps
                == ["Not read: Sat 26 08:10 → Sun 27 07:50", "No read since Mon 28 20:00"])

        // A source last read before the window, such as a mail job removed and set up again, is left out, unless
        // nothing was read in the window at all.
        let removed = sorted(Self.at("2026-09-20"), keys: [], source: UUID(), name: "Old mail")
        let rolled = measure([removed] + events, now: Self.at("2026-09-29", "21:00")).week
        #expect(rolled?.title == "Last 7 days" && rolled?.gaps == ["Not read: Sat 26 08:10 → Sun 27 07:50"])
        #expect(measure([removed], now: Self.at("2026-09-29", "21:00")).week?.gaps == ["No read since Sun 20 08:00"])

        // With two sources, each gap names its source, as it was last called.
        let work = UUID()
        events.append(sorted(Self.at("2026-09-28", "09:00"), keys: [], source: work, name: "Work"))
        events.append(sorted(Self.at("2026-09-29", "09:00"), keys: [], source: work, name: "Work mail", since: Self.at("2026-09-28", "12:00")))
        #expect(measure(events, now: Self.at("2026-09-29", "21:00")).week?.gaps
                == ["Not read from Example Gmail: Sat 26 08:10 → Sun 27 07:50", "Not read from Work mail: Mon 28 09:00 → Mon 28 12:00"])

        // Below 3 worth it, the rule of three bounds nothing, and says so without going past 100%.
        let one = [sorted(Self.at("2026-09-29"), keys: ["x"], shown: ["x"]), implicit("x", .mine, at: Self.at("2026-09-29", "09:00"))]
        #expect(measure(one, now: Self.at("2026-09-29", "10:00")).week?.power == "0 of 1 can't rule out a true miss rate up to 100% (95%)")
    }

    /// A mail job read from the screen beside the script can take a message's card, and the message then counts as left
    /// out. One quiet line says on which days that could happen, names each job as last read, and suggests removing
    /// only the ones still in Manage sources.
    @Test func screenReadMailJobsAreNamedByTheDaysTheyRan() {
        let gmail = UUID(), apple = UUID()
        let screen = { (id: UUID, name: String) in AttentionEvent.Sorted.ScreenRead(sourceID: id, sourceName: name) }
        var events = [sorted(Self.at("2026-09-27"), keys: ["a"]),
                      sorted(Self.at("2026-09-28"), keys: ["b"], screenRead: [screen(gmail, "Gmail inbox")]),
                      sorted(Self.at("2026-09-29"), keys: ["c"], screenRead: [screen(gmail, "Gmail inbox – today’s unread")]),
                      sorted(Self.at("2026-09-30"), keys: ["d"])]
        let now = Self.at("2026-09-30", "09:00"), week = Self.days
        var numbers = measure(events, now: now)
        #expect(numbers.screenRead(on: week) == "Your screen-read mail job “Gmail inbox – today’s unread” also ran on 2 days. If it reads"
            + " the same inbox, a message shown on its card can land in the rest here, and removing it in Manage sources keeps the numbers clean.")
        // A rest names its own day, and a day without one says nothing.
        #expect(numbers.screenRead(on: ["2026-09-29"])?.hasPrefix("Your screen-read mail job “Gmail inbox – today’s unread” also ran yesterday.") == true)
        #expect(numbers.screenRead(on: ["2026-09-28"])?.hasPrefix("Your screen-read mail job “Gmail inbox” also ran on Mon.") == true)
        #expect(numbers.screenRead(on: ["2026-09-30"]) == nil && numbers.screenRead(on: ["2026-09-27"]) == nil)
        #expect(measure(events, now: Self.at("2026-09-29", "09:00")).screenRead(on: ["2026-09-29"])?.contains(" also ran today.") == true)
        // On Monday the week so far holds only Monday's, named as today.
        #expect(measure(events, now: Self.at("2026-09-28", "09:00")).screenRead(on: week)?.contains("“Gmail inbox” also ran today.") == true)

        // Two jobs are named together, and only the one still in Manage sources is suggested for removal.
        events.append(sorted(Self.at("2026-09-30", "10:00"), keys: [], screenRead: [screen(apple, "Mail inbox"), screen(gmail, "Gmail inbox – today’s unread")]))
        numbers = measure(events, now: Self.at("2026-09-30", "11:00"))
        #expect(numbers.screenRead(on: week) == "Your screen-read mail jobs “Gmail inbox – today’s unread” and “Mail inbox” also ran on"
            + " 3 days. If they read the same inbox, a message shown on one of their cards can land in the rest here, and removing them"
            + " in Manage sources keeps the numbers clean.")
        #expect(numbers.screenRead(on: week, active: [apple])?.hasSuffix("can land in the rest here, and removing “Mail inbox” in Manage sources"
            + " keeps the numbers clean.") == true)
        #expect(numbers.screenRead(on: week, active: [])?.hasSuffix("also ran on 3 days. If they read the same inbox, a message shown on"
            + " one of their cards can land in the rest here.") == true)
        #expect(measure([sorted(Self.at("2026-09-30"), keys: ["x"])], now: now).screenRead(on: week) == nil)
    }

    @Test @MainActor func theLedgerGivesItsNumbersInItsOwnZone() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-numbers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        // 22:30 in New York is already the next day in UTC.
        let ledger = AttentionLedger(directory: root, clock: { Self.at("2026-09-30", "22:30") }, timeZone: Self.zone)
        #expect(ledger.numbers.today == "2026-09-30" && ledger.numbers.line == nil && ledger.numbers.week == nil)
    }

    @Test func onlyTheDaysAScreenCanShowAreSortedAhead() {
        // Two months read every morning, 30 new messages a day, one of them shown.
        let reads = (0..<60).map { offset in
            sorted(Self.at("2026-08-01").addingTimeInterval(Double(offset) * 86_400), keys: (0..<30).map { "d\(offset)m\($0)" },
                   shown: ["d\(offset)m0"])
        }
        let numbers = measure(reads, now: Self.at("2026-09-29", "12:00"))
        // The daily line looks back six days and the week at most six either side of today; nothing after today was read.
        #expect(numbers.shownDays.keys.sorted() == (23...29).map { "2026-09-\($0)" })
        #expect(numbers.line?.text == "Read 30 → showed 1 · you said yes to 0 · 29 in the rest" && numbers.week?.total.read == 7 * 30)
        // Any other day is worked out when it is asked for, the same as a day shown.
        let august = numbers.day("2026-08-10"), september = numbers.day("2026-09-28")
        #expect(august.read == 30 && august.shownKeys == ["d9m0"] && august.wasRead && !august.restChecked)
        #expect(september == measure(reads, now: Self.at("2026-10-20", "12:00")).day("2026-09-28"))
    }

    @Test @MainActor func theLedgerWorksItsNumbersOutOncePerWriteAndDay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attention-numbers-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try AttentionLogFile(url: root.appendingPathComponent("signals.jsonl")).append([
            event(.started, at: Self.at("2026-09-28", "07:00")), sorted(Self.at("2026-09-28"), keys: ["a", "b"], shown: ["a"])])
        var now = Self.at("2026-09-29", "09:00")
        let ledger = AttentionLedger(directory: root, clock: { now }, timeZone: Self.zone)
        #expect(ledger.numbers.line?.text == "Yesterday: Read 2 → showed 1 · you said yes to 0 · 1 in the rest")
        #expect(ledger.numbers.week?.gaps == [])

        // Nothing is written by 11:00, so the days are not worked out again, but the time moves on: 27 hours after
        // the last read, the week says so.
        now = Self.at("2026-09-29", "11:00")
        #expect(ledger.numbers.now == now && ledger.numbers.week?.gaps == ["No read since Mon 28 08:00"])
        // A write works them out again, and so does a new day.
        ledger.recordOpened(.menu, route: .folders, desk: 1, wasOpen: false)
        #expect(ledger.numbers.day("2026-09-29").firstOpen == now)
        now = Self.at("2026-09-30", "09:00")
        #expect(ledger.numbers.today == "2026-09-30" && ledger.numbers.line?.text.hasPrefix("Mon: ") == true)
    }

    // MARK: - Fixtures

    /// A mailbox the mail script reads as it does: what arrived since the window's start, the newest `limit` returned,
    /// and, told the last read, how many left out arrived after it; each read written as a card step writes it,
    /// messages read before by key alone.
    private struct Inbox {
        struct Counts: Equatable {
            var arrived: Int
            var returned: Int
        }

        var arrivals: [(key: String, at: Date)] = []
        var known: Set<String> = []
        var counts: [Counts] = []

        /// `count` messages spread evenly from `from` to `to`.
        mutating func arrive(_ count: Int, from: Date, to: Date) {
            let step = to.timeIntervalSince(from) / Double(count), first = arrivals.count
            arrivals += (0..<count).map { ("mail\(first + $0)", from.addingTimeInterval(step * (Double($0) + 0.5))) }
        }

        /// The first `count` that arrived from `from` to `to` leave the inbox.
        mutating func archive(_ count: Int, from: Date, to: Date) {
            let gone = Set(arrivals.filter { $0.at >= from && $0.at <= to }.prefix(count).map(\.key))
            arrivals.removeAll { gone.contains($0.key) }
        }

        mutating func read(at: Date, hours: Int, lastRead: Date? = nil) -> AttentionEvent {
            read(at: at, since: at.addingTimeInterval(-Double(hours) * 3_600), lastRead: lastRead)
        }

        mutating func read(at: Date, since: Date, limit: Int = 200, lastRead: Date? = nil) -> AttentionEvent {
            let arrived = arrivals.filter { $0.at >= since && $0.at <= at }
            let returned = arrived.sorted { $0.at > $1.at }.prefix(limit)
            let kept = Set(returned.map(\.key))
            let runID = UUID(), sourceID = AttentionNumbersTests.inboxID
            let items = returned.filter { !known.contains($0.key) }.map {
                AttentionItem(key: $0.key, sourceID: sourceID, sourceName: "Example Gmail", kind: "mail", script: "imap-mail__today",
                              runID: runID, itemID: $0.key, readAt: at, subject: "Subject \($0.key)", received: $0.at, preview: "", shown: false)
            }
            let seen = returned.filter { known.contains($0.key) }.map { AttentionEvent.Sorted.Seen(key: $0.key, shown: false) }
            known.formUnion(returned.map(\.key))
            counts.append(.init(arrived: arrived.count, returned: returned.count))
            let source = AttentionEvent.Sorted.Source(sourceID: sourceID, sourceName: "Example Gmail", script: "imap-mail__today",
                runID: runID, collectedAt: at, since: since, arrived: arrived.count, returned: returned.count,
                truncated: arrived.count > returned.count,
                cutOffSinceLastRead: lastRead.map { last in arrived.filter { $0.at >= last && !kept.contains($0.key) }.count })
            return AttentionEvent(.sorted(.init(runIDs: [runID], backfilled: false, sources: [source], items: items,
                                                seen: seen.isEmpty ? nil : seen)), at: at, timeZone: AttentionNumbersTests.zone, app: "0.5.4")
        }
    }

    private static let inboxID = UUID()

    private static let zone = TimeZone(identifier: "America/New_York")!
    /// Thursday, September 24 to Wednesday, September 30.
    private static let days = (24...30).map { "2026-09-\($0)" }
    private static let card = AttentionCardContext(cardID: UUID(), disposition: .unreviewed, displayDisposition: .unreviewed,
        optionCount: 1, optionModes: [.prepare], cardAgeHours: 1, userEdited: false, hasPersonalContext: false, createdByRun: nil)
    private let sourceID = UUID()

    /// A time on a local day in New York, four hours behind UTC in September.
    private static func at(_ day: String, _ time: String = "08:00") -> Date { AttentionTime.date("\(day)T\(time):00.000-04:00")! }

    private static func isRestView(_ event: AttentionEvent, of day: String) -> Bool {
        if case .restViewed(let viewed) = event.payload { return viewed.restDay == day }
        return false
    }

    /// The numbers from what had been written by `now`.
    private func measure(_ events: [AttentionEvent], now: Date) -> AttentionNumbers {
        let written = events.filter { $0.at <= now }
        return AttentionNumbers(index: AttentionIndex(written, now: now, timeZone: Self.zone), now: now, timeZone: Self.zone)
    }

    /// A week read every day at 08:00. Each day's first shown message gets a thumb up (Thursday's a strong one) and
    /// the next few are guessed yes from what the person did; Thursday to Saturday each have one no, and Thursday's
    /// thumb is explained. Thumbs and looks through the rest happen on the first day from then on that the pack is opened.
    private func fixtureWeek(opens: [String: AttentionOpenTrigger] = ["2026-09-24": .launcher, "2026-09-25": .launcher,
                                 "2026-09-27": .launcher, "2026-09-29": .menu, "2026-09-30": .menu]) -> [AttentionEvent] {
        let reads = [48, 39, 30, 61, 51, 44, 17], shown = [7, 5, 4, 6, 8, 5, 3], yes = [5, 4, 3, 4, 4, 3, 2]
        var events: [AttentionEvent] = []
        for (index, day) in Self.days.enumerated() {
            let keys = (0..<reads[index]).map { "d\(index)m\($0)" }
            events.append(sorted(Self.at(day), keys: keys, shown: Set(keys.prefix(shown[index]))))
            if let trigger = opens[day] { events.append(event(.opened(.init(trigger: trigger, route: "folders", desk: 4)), at: Self.at(day, "08:30"))) }
            let acted = Self.days.first { $0 >= day && opens[$0] != nil } ?? Self.days[6]
            events.append(label(keys[0], index == 0 ? .strongYes : .yes, at: Self.at(acted, "09:00")))
            if index == 0 { events.append(label(keys[0], .explain, text: "Rent is due.", at: Self.at(acted, "09:05"))) }
            events += keys[1..<yes[index]].enumerated().map { implicit($1, $0 % 2 == 0 ? .mine : .optionTapped, at: Self.at(day, "09:00")) }
            if index < 3 {
                events.append(index == 0 ? label(keys[yes[index]], .no, at: Self.at(acted, "09:00")) : implicit(keys[yes[index]], .ignored, at: Self.at(day, "09:00")))
            }
            events.append(restViewed(day, reachedEnd: true, at: Self.at(acted, "21:00")))
        }
        return events.sorted { $0.at < $1.at }
    }

    private func event(_ payload: AttentionEvent.Payload, at: Date) -> AttentionEvent {
        AttentionEvent(payload, at: at, timeZone: Self.zone, app: "0.5.4")
    }

    private func item(_ key: String, at: Date, received: Date? = nil, tab: String? = nil, bulk: Bool? = nil, important: Bool? = nil,
                      shown: Bool = false) -> AttentionItem {
        AttentionItem(key: key, sourceID: sourceID, sourceName: "Example Gmail", kind: "mail", script: "imap-mail__today", runID: UUID(),
            itemID: key, readAt: at, subject: "Subject \(key)", tab: tab, bulk: bulk, important: important, received: received,
            preview: "", shown: shown)
    }

    private func source(_ at: Date, id: UUID? = nil, name: String = "Example Gmail", since: Date? = nil, count: Int = 0,
                        arrived: Int? = nil, returned: Int? = nil, truncated: Bool = false) -> AttentionEvent.Sorted.Source {
        .init(sourceID: id ?? sourceID, sourceName: name, script: "imap-mail__today", runID: UUID(), collectedAt: at, since: since,
              arrived: arrived ?? count, returned: returned ?? count, truncated: truncated)
    }

    /// One card step's read at `at`, returning `keys` and showing `shown`.
    private func sorted(_ at: Date, keys: [String], shown: Set<String> = [], source id: UUID? = nil, name: String = "Example Gmail",
                        since: Date? = nil, arrived: Int? = nil, returned: Int? = nil, truncated: Bool = false,
                        screenRead: [AttentionEvent.Sorted.ScreenRead]? = nil) -> AttentionEvent {
        let items = keys.map { item($0, at: at, shown: shown.contains($0)) }
        let read = source(at, id: id, name: name, since: since, count: keys.count, arrived: arrived, returned: returned, truncated: truncated)
        return event(.sorted(.init(runIDs: [read.runID], backfilled: false, sources: [read], items: items, screenRead: screenRead)), at: at)
    }

    private func label(_ key: String, _ value: AttentionLabelValue, text: String? = nil, at: Date) -> AttentionEvent {
        event(.label(.init(key: key, value: value, weight: AttentionLabels.weight(value), prior: .notSet, text: text, via: .card,
                           item: item(key, at: at), card: Self.card)), at: at)
    }

    private func implicit(_ key: String, _ signal: AttentionSignal, at: Date) -> AttentionEvent {
        event(.implicit(.init(key: key, signal: signal, item: item(key, at: at), card: Self.card)), at: at)
    }

    private func miss(_ key: String, retract: Bool = false, at: Date) -> AttentionEvent {
        event(.miss(.init(key: key, retract: retract, item: item(key, at: at))), at: at)
    }

    private func restViewed(_ day: String, reachedEnd: Bool, at: Date) -> AttentionEvent {
        event(.restViewed(.init(restDay: day, count: 36, reachedEnd: reachedEnd, seconds: 30)), at: at)
    }
}
