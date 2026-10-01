import Foundation
import Testing
@testable import Familiar

/// What a typed chat question takes from the screen: in a browser, the page's own text and controls instead of a
/// picture, unless the question is about how something looks; elsewhere, a picture as before; nothing for a general
/// question, and whatever the person's screenshot setting says.
@Suite @MainActor
struct ChatScreenEvidenceTests {
    let chrome = "com.google.Chrome", safari = "com.apple.Safari", excel = "com.microsoft.Excel"

    @Test func aQuestionAboutAPageGetsThePageNotAPicture() {
        #expect(Assistant.evidence(for: "why is this button greyed out?", mode: "auto", bundleID: chrome) == .page)
        #expect(Assistant.evidence(for: "what does this field want?", mode: "auto", bundleID: safari) == .page)
        #expect(Assistant.evidence(for: "why?", mode: "auto", bundleID: chrome) == .page)   // short questions are about the screen
    }

    @Test func howSomethingLooksStillTakesAPicture() {
        #expect(Assistant.evidence(for: "does this chart look right?", mode: "auto", bundleID: chrome) == .screenshot)
        #expect(Assistant.evidence(for: "why does the layout of this page overlap?", mode: "auto", bundleID: chrome) == .screenshot)
        #expect(Assistant.evidence(for: "what is this icon on the page?", mode: "auto", bundleID: chrome) == .screenshot)
    }

    @Test func otherAppsAndSettingsAreAsBefore() {
        #expect(Assistant.evidence(for: "why is this cell red?", mode: "auto", bundleID: excel) == .screenshot)
        #expect(Assistant.evidence(for: "why is this button greyed out?", mode: "auto", bundleID: nil) == .screenshot)
        #expect(Assistant.evidence(for: "how do I file an expense report for travel next month?", mode: "auto", bundleID: chrome) == .none)
        #expect(Assistant.evidence(for: "why is this button greyed out?", mode: "always", bundleID: chrome) == .screenshot)
        #expect(Assistant.evidence(for: "why is this button greyed out?", mode: "never", bundleID: chrome) == .none)
    }

    @Test func thePageSectionSaysWhatItIsAndHowToSeeIt() {
        let page = PageSnapshot(appName: "Chrome", bundleID: chrome, windowTitle: "Onboarding",
            documents: [PageDocument(url: "https://portal.example.test/onboarding?token=abc", frame: nil)],
            elements: [PageElement(kind: "button", role: "AXButton", label: "Request onboarding", visible: true, enabled: false, document: 0)],
            selectedText: nil, truncated: false, elapsed: 0.05)
        let section = Assistant.pageSection(page)
        #expect(section.hasPrefix("\n## The page in front (read through Accessibility, not a picture)\n"))
        #expect(section.contains("call look_at_screen to see it"))
        #expect(section.contains("[button] Request onboarding (disabled)"))
        #expect(section.contains("Address: https://portal.example.test/onboarding\n"))   // the token stays out
    }

    @Test func onlyABrowserIsReadAsAPage() {
        #expect(PageReader.read(bundleID: excel) == nil)
    }
}
