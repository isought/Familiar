import Foundation
import Testing
@testable import Familiar

@Suite
struct IrreversibleGuardTests {
    typealias G = IrreversibleGuard

    // MARK: keys

    @Test
    func forbiddenCombosInAnySpellingAndOrder() {
        let forbidden = ["cmd+q", "Cmd+Q", "command+q", "super+q", "meta+q", "⌘+q",
                         "cmd+w", "cmd+shift+w", "shift+cmd+w", "Shift+Command+W", "command + shift + w",
                         "cmd+option+w", "alt+cmd+w", "opt+command+w", "option+meta+W",
                         "cmd+h", "command+H", "cmd+m", "super+m"]
        for combo in forbidden {
            guard case .forbidden(let reason) = G.classifyKey(combo) else {
                Issue.record("\(combo) should be forbidden"); continue
            }
            #expect(!reason.isEmpty)
        }
    }

    @Test
    func everyOtherComboIsSafe() {
        let safe = ["cmd+s", "cmd+c", "cmd+v", "cmd+z", "cmd+shift+z", "cmd+a", "cmd+enter", "cmd+return", "cmd+f",
                    "ctrl+w", "control+q", "option+w", "shift+w", "q", "w", "h", "m",
                    "cmd+ctrl+q", "cmd+shift+q", "cmd+shift+h", "cmd+shift+m", "cmd+option+h", "cmd+option+m",
                    "cmd+ctrl+w", "cmd+shift+option+w", "hyper+w", "cmd+", "", "+"]
        for combo in safe {
            #expect(G.classifyKey(combo) == .safe, "\(combo)")
        }
    }

    // MARK: presses

    private func el(role: String? = "AXButton", subrole: String? = nil, title: String? = nil, description: String? = nil,
                    domID: String? = nil, value: String? = nil, isDefaultButton: Bool = false, isSecure: Bool = false) -> G.ElementInfo {
        G.ElementInfo(role: role, subrole: subrole, title: title, description: description, domID: domID, value: value,
                      isDefaultButton: isDefaultButton, isSecure: isSecure)
    }

    private func press(_ e: G.ElementInfo, inSheet: Bool = false, declared: [String] = [], warnings: [String] = []) -> G.Classification {
        G.classifyPress(e, inSheet: inSheet, declared: declared, warningNoteLabels: warnings)
    }

    @Test
    func labelFallsThroughToFirstNonEmptySource() {
        #expect(el(title: "Save").label == "Save")
        #expect(el(title: "", description: "Send message").label == "Send message")
        #expect(el(description: "", domID: "submit-btn").label == "submit-btn")
        #expect(el().label == "")
    }

    @Test
    func windowControlsAndMenusAreForbidden() {
        for subrole in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
            guard case .forbidden = press(el(subrole: subrole, title: "Close")) else { Issue.record(Comment(rawValue: subrole)); continue }
        }
        for role in ["AXMenuBarItem", "AXMenuItem"] {
            guard case .forbidden = press(el(role: role, title: "File")) else { Issue.record(Comment(rawValue: role)); continue }
        }
        // Forbidden beats confirm: a close button titled "Discard" is still a close button.
        guard case .forbidden = press(el(subrole: "AXCloseButton", title: "Discard")) else { Issue.record("close beats confirm"); return }
    }

    @Test
    func confirmWordsMatchWholeWordsCaseInsensitively() {
        for word in G.confirmWords {
            #expect(press(el(title: word)) == .confirm(word), Comment(rawValue: word))
            #expect(press(el(title: word.uppercased())) == .confirm(word.uppercased()), Comment(rawValue: word))
            #expect(press(el(title: "Now \(word.capitalized) this")) == .confirm("Now \(word.capitalized) this"), Comment(rawValue: word))
        }
        #expect(press(el(title: "Send")) == .confirm("Send"))
        #expect(press(el(title: "Reply All")) == .confirm("Reply All"))
        #expect(press(el(title: "Reply  all")) == .confirm("Reply  all"))
        #expect(press(el(title: "Delete draft")) == .confirm("Delete draft"))
        #expect(press(el(title: "Sign in")) == .confirm("Sign in"))
        // Substrings are not words.
        for title in ["Sender", "Posted", "Resend", "Signature", "Remover", "Discarded", "Reply", "Confirmation", "Payments", "Buyer", "Approved"] {
            #expect(press(el(title: title)) == .safe, Comment(rawValue: title))
        }
        for title in ["Save", "Cancel", "Next", "OK", "Search", "Open"] {
            #expect(press(el(title: title)) == .safe, Comment(rawValue: title))
        }
    }

    @Test
    func valueAndDomIDAreCheckedToo() {
        // The value carries the confirm word: a web button whose text is exposed as value.
        #expect(press(el(title: "", value: "Submit")) == .confirm("Submit"))
        // The label is harmless but the DOM id gives it away; the payload is the label the human sees.
        #expect(press(el(title: "Go", domID: "submit-btn")) == .confirm("Go"))
        #expect(press(el(domID: "post-button")) == .confirm("post-button"))
        #expect(press(el(domID: "compose-toolbar")) == .safe)
        #expect(press(el(title: "Compose", value: "draft")) == .safe)
    }

    @Test
    func defaultButtonInSheetNeedsConfirming() {
        #expect(press(el(title: "OK", isDefaultButton: true), inSheet: true) == .confirm("OK"))
        #expect(press(el(title: "OK", isDefaultButton: true), inSheet: false) == .safe)
        #expect(press(el(title: "OK", isDefaultButton: false), inSheet: true) == .safe)
        #expect(press(el(isDefaultButton: true), inSheet: true) == .confirm("the default button"))
    }

    @Test
    func declaredAndWarningLabelsMatchNormalised() {
        #expect(press(el(title: "Archive  Project"), declared: ["archive project"]) == .confirm("Archive  Project"))
        #expect(press(el(title: "archive project"), declared: ["  Archive\tProject "]) == .confirm("archive project"))
        #expect(press(el(title: "Archive"), declared: ["archive project"]) == .safe)
        #expect(press(el(title: "Launch"), warnings: ["LAUNCH"]) == .confirm("Launch"))
        #expect(press(el(title: "Launch"), warnings: ["launch now"]) == .safe)
        #expect(press(el(), declared: [""], warnings: [""]) == .safe)
    }

    // MARK: typing

    @Test
    func typingIntoSecureFieldsIsForbidden() {
        #expect(G.classifyType(into: el(role: "AXTextField", isSecure: true)) == .forbidden("a password field"))
        #expect(G.classifyType(into: el(role: "AXTextField")) == .safe)
        #expect(G.classifyType(into: el(role: "AXTextField", title: "Delete")) == .safe)
    }

    // MARK: confirmations

    @Test
    func consumeMatchesNormalisedLabelAndCountsDown() {
        let now = Date()
        var c: G.Confirmation? = G.Confirmation(label: "Submit", expires: now.addingTimeInterval(60), usesLeft: 2)
        #expect(!G.consume(&c, label: "Send", now: now))
        #expect(c?.usesLeft == 2)
        #expect(G.consume(&c, label: "  submit ", now: now))
        #expect(c?.usesLeft == 1)
        #expect(G.consume(&c, label: "SUBMIT", now: now.addingTimeInterval(30)))
        #expect(c == nil)
        #expect(!G.consume(&c, label: "Submit", now: now))
    }

    @Test
    func consumeRejectsExpiredAndExhausted() {
        let now = Date()
        var expired: G.Confirmation? = G.Confirmation(label: "Send", expires: now, usesLeft: 1)
        #expect(!G.consume(&expired, label: "Send", now: now))
        #expect(expired == nil)
        var exhausted: G.Confirmation? = G.Confirmation(label: "Send", expires: now.addingTimeInterval(60), usesLeft: 0)
        #expect(!G.consume(&exhausted, label: "Send", now: now))
        #expect(exhausted == nil)
        var none: G.Confirmation? = nil
        #expect(!G.consume(&none, label: "Send", now: now))
        var blank: G.Confirmation? = G.Confirmation(label: "", expires: now.addingTimeInterval(60), usesLeft: 1)
        #expect(!G.consume(&blank, label: "", now: now))
    }

    @Test
    func confirmMessageNamesTheButton() {
        #expect(G.confirmMessage(label: "Submit") ==
                "This looks irreversible (button “Submit”). Ask the user and end your reply with `Suggestions: Submit it | Don't`")
    }
}
