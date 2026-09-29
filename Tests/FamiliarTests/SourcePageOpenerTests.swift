import Foundation
import Testing
@testable import Familiar

/// A job reuses a window already showing its saved address instead of opening another tab.
@Suite
struct SourcePageOpenerTests {
    @Test func theSavedAddressMatchesHowBrowsersShowIt() {
        let inbox = "https://mail.google.com/mail/u/0/#inbox"
        #expect(SourcePageOpener.sameAddress(saved: inbox, shown: "https://mail.google.com/mail/u/0/#inbox"))
        #expect(SourcePageOpener.sameAddress(saved: inbox, shown: "mail.google.com/mail/u/0/#inbox"))      // Chrome's address bar
        #expect(SourcePageOpener.sameAddress(saved: inbox, shown: "https://mail.google.com/mail/u/0/#inbox/FMfcgzQ"))
        #expect(SourcePageOpener.sameAddress(saved: "https://www.example.com/news/", shown: "example.com/news"))
    }

    @Test func anotherPageIsNotTheSavedAddress() {
        let inbox = "https://mail.google.com/mail/u/0/#inbox"
        #expect(!SourcePageOpener.sameAddress(saved: inbox, shown: "https://mail.google.com/mail/u/0/#search/invoice"))
        #expect(!SourcePageOpener.sameAddress(saved: inbox, shown: "https://mail.google.com/mail/u/1/#inbox"))
        #expect(!SourcePageOpener.sameAddress(saved: "https://example.com/page", shown: "https://example.com/page2"))
        #expect(!SourcePageOpener.sameAddress(saved: "", shown: "https://example.com"))
    }
}
