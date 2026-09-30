import SwiftUI

/// The attention test's two screens in the pack: a day's rest, one tap from the daily line, and the week measured
/// against the pass bar. Neither is in the ⋯ menu; the daily line is the way in.
enum AttentionScreen: Equatable {
    /// What a day read and did not show. The route names its day, so a read that lands while it is open never turns
    /// it into another day's rest.
    case rest(day: String)
    case week

    var heading: String {
        switch self {
        case .rest: return "The rest"
        case .week: return "This week"
        }
    }
}

/// One line on the folders screen: what the latest read came to, and the way into its rest. It shows nothing when no
/// script source was read in the last seven days, so nothing changes for anyone without a mail job, unless the test
/// can't be saved: then a job that reads mail through a script says so here, even before its first line.
struct AttentionDailyLine: View {
    @ObservedObject var ledger: AttentionLedger
    /// Whether a job reads mail through a script, asked each time the line is drawn.
    var readsScript: () -> Bool = { false }
    /// Opens the rest of a day.
    let open: (String) -> Void

    var line: AttentionNumbers.Line? { ledger.numbers.line }

    /// A failed write, said wherever the test runs; the card action behind it went through.
    var error: String? {
        guard let error = ledger.error, line != nil || readsScript() else { return nil }
        return error
    }

    var body: some View {
        let line = line, error = error
        if line != nil || error != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let line {
                    Button { tap() } label: {
                        HStack(spacing: 5) {
                            Text(line.text).fixedSize(horizontal: false, vertical: true)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        }.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help(line.help)
                    .accessibilityHint("Shows everything this read, and what it left out")
                }
                if let error { Text(error).foregroundStyle(Pad.redInk).textSelection(.enabled) }
            }.font(.system(size: 12)).foregroundStyle(Pad.inkSoft)
        }
    }

    /// Opens the rest of the day the line is about.
    func tap() { if let line { open(line.day) } }
}

/// The screen a route to the attention test shows.
struct AttentionScreenView: View {
    @ObservedObject var ledger: AttentionLedger
    @ObservedObject var store: MorningStore
    @ObservedObject var navigation: MorningNavigation
    let screen: AttentionScreen

    var body: some View {
        switch screen {
        case .rest(let day):
            // Each day's rest is its own visit, so reaching one day's end never checks another.
            AttentionRestView(ledger: ledger, store: store, navigation: navigation, day: day).id(day)
        case .week:
            AttentionWeekView(ledger: ledger, navigation: navigation)
        }
    }
}

/// Everything one day read: first what it showed, where guesses can be fixed after acting, then the rest, likeliest
/// misses first, with lists and promotions under a quiet divider. The rest is never collapsed, so every miss is one
/// tap away. Scrolling to the end line is what checks the day.
struct AttentionRestView: View {
    @ObservedObject var ledger: AttentionLedger
    @ObservedObject var store: MorningStore
    @ObservedObject var navigation: MorningNavigation
    /// "yyyy-MM-dd".
    let day: String
    @State private var appeared: Date?
    @State private var reachedTheEnd = false

    var body: some View {
        let numbers = ledger.numbers
        let counts = numbers.day(day), rest = numbers.restItems(on: day)
        ScrollView {
            // Lazy, so the end line appears only once it is scrolled to.
            LazyVStack(alignment: .leading, spacing: 6) {
                chips(numbers).padding(.bottom, 10)
                Text(summary(counts, numbers)).font(.system(size: 13)).foregroundStyle(Pad.inkSoft)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 12)
                if let error = ledger.error {
                    Text(error).font(.system(size: 12)).foregroundStyle(Pad.redInk).textSelection(.enabled).padding(.bottom, 8)
                }
                if counts.wasRead {
                    section("Shown · \(counts.shown)")
                    ForEach(counts.shownKeys, id: \.self) { shownRow($0) }
                    if counts.shown == 0 { Text("No card came from this read.").font(.system(size: 12)).foregroundStyle(Pad.inkSoft) }
                    section("The rest · \(counts.restCount)").padding(.top, 14)
                    ForEach(rest.items, id: \.key) { row($0, numbers) }
                    if !rest.lists.isEmpty {
                        HStack(spacing: 10) {
                            Text("Lists and promotions · \(rest.lists.count)").font(.system(size: 11, weight: .medium)).fixedSize()
                            Rectangle().fill(Pad.tabEdge.opacity(0.5)).frame(height: 1)
                        }.foregroundStyle(Pad.inkSoft).padding(.vertical, 8)
                        ForEach(rest.lists, id: \.key) { row($0, numbers) }
                    }
                    Text("That’s all \(counts.shownKeys.count + rest.items.count + rest.lists.count) read \(name(day, numbers)).")
                        .font(.system(size: 12)).foregroundStyle(Pad.inkSoft).padding(.top, 12)
                        .onAppear { reachedEnd() }
                }
            }.padding(22)
        }
        .onAppear { appeared = ledger.clock() }
        .onDisappear { left() }
    }

    /// The days read this week, newest first, and the one on screen.
    func days(_ numbers: AttentionNumbers) -> [String] {
        let read = (numbers.week?.days ?? []).filter(\.wasRead).map(\.day).reversed()
        return read.contains(day) ? Array(read) : [day] + read
    }

    func open(_ day: String) { navigation.route = .attention(.rest(day: day)) }

    func openWeek() { navigation.route = .attention(.week) }

    /// The end line came on screen: the day's rest was looked through, once per visit.
    func reachedEnd() {
        reachedTheEnd = true
        ledger.restViewed(day: day, count: ledger.numbers.day(day).restCount, reachedEnd: true, seconds: seconds)
    }

    /// Leaving before the end is recorded too, but never checks the day. A look that began on an earlier day is not:
    /// the pack stood open overnight, and whatever moves it on now, such as chat, is no look at the rest today.
    func left() {
        let counts = ledger.numbers.day(day), zone = ledger.timeZone
        guard !reachedTheEnd, counts.wasRead, let appeared,
              AttentionTime.day(of: appeared, in: zone) == AttentionTime.day(of: ledger.clock(), in: zone) else { return }
        ledger.restViewed(day: day, count: counts.restCount, reachedEnd: false, seconds: seconds)
    }

    /// The row the screen shows for a shown message: its card, or its subject once the card is gone.
    func shownRow(_ key: String) -> AttentionShownRow {
        AttentionShownRow(ledger: ledger, key: key, card: store.cards.first { $0.tracking?.key == key }) { navigation.route = .card($0) }
    }

    /// The row the screen shows for a message in the rest.
    func row(_ item: AttentionItem, _ numbers: AttentionNumbers) -> AttentionRestRow {
        let when = item.received ?? item.readAt
        var parts = [item.fromName ?? item.address ?? item.from ?? item.sourceName]
        if let tab = item.tab, !tab.isEmpty { parts.append(tab.prefix(1).uppercased() + tab.dropFirst()) }
        // Mail from the evening before is named by its day.
        parts.append(numbers.format(when, AttentionTime.day(of: when, in: numbers.timeZone) == day ? "H:mm" : "EEE H:mm"))
        if item.important == true { parts.append("important") }
        if item.bulk == true { parts.append("list") }
        return AttentionRestRow(ledger: ledger, item: item, details: parts.joined(separator: " · "))
    }

    private var seconds: TimeInterval {
        guard let appeared else { return 0 }
        return (ledger.clock().timeIntervalSince(appeared) * 10).rounded() / 10
    }

    private func chips(_ numbers: AttentionNumbers) -> some View {
        HStack(spacing: 6) {
            ForEach(days(numbers), id: \.self) { chip in
                let on = chip == day
                Button { open(chip) } label: {
                    Text(chip == numbers.today ? "Today" : numbers.format(chip, "EEE d"))
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 5)
                        .foregroundStyle(on ? Color.white : Pad.ink)
                        .background(on ? Pad.penInk : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? Color.clear : Pad.tabEdge.opacity(0.6)))
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer(minLength: 8)
            Button { openWeek() } label: {
                HStack(spacing: 4) { Text("This week"); Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)) }
            }.buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Pad.penInk)
        }
    }

    private func summary(_ counts: AttentionNumbers.Day, _ numbers: AttentionNumbers) -> String {
        guard counts.wasRead else { return "Nothing was read \(name(day, numbers))." }
        var text = "Read \(counts.read) → showed \(counts.shown). "
        switch counts.restCount {
        case 0: text += "Nothing else came in."
        case 1: text += "This one stayed out of your way."
        default: text += "These \(counts.restCount) stayed out of your way."
        }
        if counts.cutOff > 0 { text += " \(counts.cutOff) more were past the script’s limit and weren’t read." }
        return text
    }

    /// "today", "yesterday" or "on Mon".
    private func name(_ day: String, _ numbers: AttentionNumbers) -> String {
        day == numbers.today ? "today" : day == numbers.day(numbers.today, plus: -1) ? "yesterday" : "on " + numbers.format(day, "EEE")
    }

    private func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Pad.inkSoft).padding(.bottom, 2)
    }
}

/// A message a card step showed, by its card's title, with the card's thumbs, so a guess can be fixed after acting
/// on the card put it away.
struct AttentionShownRow: View {
    @ObservedObject var ledger: AttentionLedger
    let key: String
    /// Nil once the card is gone.
    let card: MorningCard?
    let open: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let card {
                Button { open(card.id) } label: {
                    Text(card.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Open this file")
                AttentionThumbs(ledger: ledger, card: card, via: .shown)
            } else {
                Text(ledger.index.item[key]?.subject ?? "A message whose card is gone").lineLimit(1).foregroundStyle(Pad.inkSoft)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 13)).padding(.horizontal, 12).frame(minHeight: 32)
        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// A message the card step read and left out. "Should have shown me" marks it missed, which never makes a card;
/// right-click explains it.
struct AttentionRestRow: View {
    @ObservedObject var ledger: AttentionLedger
    let item: AttentionItem
    /// "Dana Ruiz · Primary · 8:12 · important · list".
    let details: String

    var isMissed: Bool { ledger.index.missedKeys.contains(item.key) }
    var isExplaining: Bool { ledger.explaining == item.key }

    var body: some View {
        let explanation = ledger.explanation(for: item.key)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.subject.isEmpty ? "No subject" : item.subject).font(.system(size: 13)).lineLimit(1)
                    Text(details).font(.system(size: 11)).foregroundStyle(Pad.inkSoft).lineLimit(1)
                }
                Spacer(minLength: 8)
                if let explanation {
                    Image(systemName: "text.bubble").font(.system(size: 10)).foregroundStyle(Pad.penInk)
                        .help(explanation).accessibilityLabel("Your explanation: \(explanation)")
                }
                Button(isMissed ? "✓ Missed · undo" : "Should have shown me") { toggleMiss() }
                    .buttonStyle(AttentionSmallButton(filled: isMissed))
                    .accessibilityHint(isMissed ? "Takes back that this should have been shown" : "Marks this as something you wanted to see")
                if let page { Link(destination: page) { Image(systemName: "arrow.up.right.square") }.foregroundStyle(Pad.penInk).help("Open original") }
            }
            if isExplaining { AttentionRowExplainField(ledger: ledger, key: item.key) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Color.white.opacity(isMissed ? 0.85 : 0.6), in: RoundedRectangle(cornerRadius: 7))
        .contextMenu {
            Button(explanation == nil ? "Let me explain…" : "Edit your explanation…") { ledger.beginExplaining(item.key) }
        }
    }

    /// Marks the message missed, or takes that back.
    func toggleMiss() { ledger.miss(key: item.key, retract: isMissed) }

    private var page: URL? {
        item.url.flatMap(URL.init(string:)).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
    }
}

/// One line under a row of the rest, only while the person explains it. The words never change a label or a miss.
struct AttentionRowExplainField: View {
    @ObservedObject var ledger: AttentionLedger
    let key: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text("Let me explain").foregroundStyle(Pad.inkSoft)
            TextField("Why is this worth your notice, or not?", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused).onSubmit { save(text) }
            Button("Save") { save(text) }.foregroundStyle(Pad.penInk)
            Button("Cancel") { ledger.cancelExplaining() }.foregroundStyle(Pad.penInk)
        }
        .buttonStyle(.plain).font(.system(size: 12))
        .onAppear {
            text = ledger.explanation(for: key) ?? ""
            focused = true
        }
        .onExitCommand { ledger.cancelExplaining() }
        .onDisappear { if ledger.explaining == key { ledger.cancelExplaining() } }
    }

    /// Saves up to 2000 characters and closes the field once they are written.
    func save(_ text: String) {
        guard ledger.explaining == key else { return }
        ledger.explain(key: key, card: nil, text: text, via: .rest)
    }
}

/// The week against the pass bar set before it began: a row a day, the totals, a verdict for each bar, and what the
/// numbers cannot say. Tapping a day opens its rest.
struct AttentionWeekView: View {
    @ObservedObject var ledger: AttentionLedger
    @ObservedObject var navigation: MorningNavigation

    private static let widths: [CGFloat] = [62, 42, 52, 84, 30, 50, 62, 52]
    private static let titles = ["", "Read", "Showed", "Yes (tapped)", "No", "Missed", "Rest", "Opened"]

    var body: some View {
        let numbers = ledger.numbers
        if let week = numbers.week {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(week.title).font(HandFont.font(size: 22))
                        Spacer()
                        if ["PASS", "FAIL"].contains(week.overall) {
                            Text(week.overall).font(.system(size: 12, weight: .semibold)).tracking(1)
                                .foregroundStyle(week.overall == "PASS" ? Pad.penInk : Pad.redInk)
                        }
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        cells(Self.titles).font(.system(size: 11)).foregroundStyle(Pad.inkSoft).padding(.bottom, 6)
                        ForEach(week.days, id: \.day) { day in dayRow(day, numbers) }
                        Divider().overlay(Pad.tabEdge.opacity(0.5)).padding(.vertical, 4)
                        let total = week.total
                        cells(["Week", "\(total.read)", "\(total.shown)", "\(total.yes) (\(total.yesTapped))", "\(total.no)", "\(total.missed)",
                               "\(total.daysChecked)/\(total.daysRead)", "\(total.daysOpened) of \(total.daysSoFar)"])
                            .font(.system(size: 13, weight: .semibold))
                    }.monospacedDigit()
                    VStack(alignment: .leading, spacing: 8) {
                        bar(week.showed)
                        bar(week.missed)
                        bar(week.opened)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(week.gaps, id: \.self) { Text($0) }
                        if let power = week.power { Text(power) }
                        Text("Labels: " + week.labels)
                    }.font(.system(size: 11)).foregroundStyle(Pad.inkSoft).fixedSize(horizontal: false, vertical: true)
                }.padding(22)
            }
        } else {
            Text("The week starts with the first read of your mail.").font(.system(size: 14)).foregroundStyle(Pad.inkSoft).padding(24)
        }
    }

    func open(_ day: String) { navigation.route = .attention(.rest(day: day)) }

    private func dayRow(_ day: AttentionNumbers.Day, _ numbers: AttentionNumbers) -> some View {
        let later = day.day > numbers.today
        let name = numbers.format(day.day, "EEE d"), opened = day.firstOpen.map { numbers.format($0, "H:mm") } ?? "—"
        let values = later ? [name] + Array(repeating: "", count: 7)
            : !day.wasRead ? [name] + Array(repeating: "—", count: 6) + [opened]
            : [name, "\(day.read)", "\(day.shown)", "\(day.yes) (\(day.yesTapped))", "\(day.no)", "\(day.missed)",
               day.restChecked ? "✓" : "to check", opened]
        return Button { open(day.day) } label: {
            cells(values, penInk: day.wasRead && !day.restChecked ? 6 : nil).font(.system(size: 13)).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(later || !day.wasRead)
        .help(day.wasRead ? "Show what \(name) read" : "")
    }

    /// One row of the table; the first column is the day, the rest are numbers.
    private func cells(_ values: [String], penInk column: Int? = nil) -> some View {
        HStack(spacing: 10) {
            ForEach(values.indices, id: \.self) { index in
                Text(values[index]).lineLimit(1)
                    .frame(width: Self.widths[index], alignment: index == 0 ? .leading : .trailing)
                    .foregroundStyle(index == column ? Pad.penInk : Pad.ink)
            }
        }
    }

    private func bar(_ bar: AttentionNumbers.Bar) -> some View {
        let mark = Self.mark(bar.verdict)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(mark.symbol).foregroundStyle(mark.color).frame(width: 14)
            Text(bar.text + (mark.word.map { " · " + $0 } ?? ""))
            Spacer(minLength: 12)
            Text("bar: " + bar.bar).foregroundStyle(Pad.inkSoft)
        }.font(.system(size: 13))
    }

    /// Pass and fail are final. Before day 7 a bar is on or off track; pending says what to check first.
    private static func mark(_ verdict: AttentionNumbers.Verdict) -> (symbol: String, word: String?, color: Color) {
        switch verdict {
        case .pass: return ("✓", nil, Pad.penInk)
        case .fail: return ("✗", nil, Pad.redInk)
        case .onTrack: return ("…", "on track", Pad.inkSoft)
        case .offTrack: return ("✗", "off track", Pad.redInk)
        case .pending: return ("…", nil, Pad.inkSoft)
        case .notMeasured: return ("–", "not measured yet", Pad.inkSoft)
        }
    }
}

/// A smaller MorningActionButton, for a control on every row of a long list.
private struct AttentionSmallButton: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(filled ? Color.white : Pad.ink)
            .background(filled ? Pad.penInk : Color.white.opacity(0.8), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(filled ? Color.clear : Pad.tabEdge.opacity(0.7)))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
