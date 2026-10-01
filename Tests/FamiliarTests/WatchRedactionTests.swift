import Testing
@testable import Familiar

/// What Watch Me writes down when someone types or clicks during a recording: PRIVACY.md promises that passwords,
/// secret-looking fields, terminals and document text are never recorded, and that the rule fails closed.
@Suite @MainActor
struct WatchRedactionTests {
    private func field(bundle: String = "com.google.Chrome", role: String = "AXTextField", subrole: String? = nil,
                       title: String? = nil, description: String? = nil, placeholder: String? = nil,
                       parentTitle: String? = nil) -> WatchRecorder.Field {
        WatchRecorder.field(bundle: bundle, role: role, subrole: subrole, title: title, description: description,
                            placeholder: placeholder, parentTitle: parentTitle)
    }

    @Test func aNamedFormFieldIsRecordedUnderItsName() {
        #expect(field(title: "Cost Center") == .text(label: "text field “Cost Center”"))
        #expect(field(role: "AXSearchField", placeholder: "Search catalog") == .text(label: "search field “Search catalog”"))
        #expect(field(role: "AXComboBox", parentTitle: "Region") == .text(label: "combo box “Region”"))
        #expect(field(role: "AXTextArea", description: "Business justification") == .text(label: "text area “Business justification”"))
    }

    @Test(arguments: ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp", "com.mitchellh.ghostty"])
    func nothingTypedInATerminalIsRecorded(bundle: String) {
        #expect(field(bundle: bundle, title: "Name") == .hidden(why: "terminal"))
    }

    @Test func aSecureFieldIsHiddenWhateverItIsCalled() {
        #expect(field(subrole: "AXSecureTextField", title: "Name") == .hidden(why: "password field"))
        #expect(field(subrole: "AXSecureTextField") == .hidden(why: "password field"))
    }

    @Test(arguments: ["Password", "Passcode", "API key", "One-time code (OTP)", "PIN", "CVV", "Recovery tokens", "Client secret", "SSN"])
    func aFieldNamedLikeASecretIsHidden(name: String) {
        #expect(field(title: name) == .hidden(why: "password field"))
        #expect(field(description: name) == .hidden(why: "password field"))
        #expect(field(placeholder: name) == .hidden(why: "password field"))
        #expect(field(parentTitle: name) == .hidden(why: "password field"))   // an unnamed field takes its parent's name
    }

    @Test func aSecretNameAnywhereWinsOverAnInnocentOne() {
        #expect(field(title: "Login", placeholder: "Enter your password") == .hidden(why: "password field"))
    }

    @Test func documentsAndUnknownElementsAreHidden() {
        #expect(field(bundle: "com.apple.Notes", role: "AXTextArea", title: "Body") == .hidden(why: "text area"))
        #expect(field(bundle: "com.tinyspeck.slackmacgap", role: "AXTextArea") == .hidden(why: "text area"))
        #expect(field(role: "AXWebArea") == .hidden(why: "web area"))
        #expect(field(role: "") == .hidden(why: "unknown field"))
    }

    @Test func aClickedControlsValueIsHiddenWhenItCouldBeASecretOrADocument() {
        let button = AXElementInfo(role: "AXButton", title: "Submit", value: "Ready")
        #expect(WatchRecorder.safeValue(button, bundle: "com.google.Chrome") == "Ready")
        #expect(WatchRecorder.safeValue(button, bundle: "com.apple.Terminal") == nil)
        #expect(WatchRecorder.safeValue(AXElementInfo(role: "AXTextField", value: "hunter2", subrole: "AXSecureTextField"), bundle: nil) == nil)
        #expect(WatchRecorder.safeValue(AXElementInfo(role: "AXTextField", title: "API key", value: "sk-123"), bundle: nil) == nil)
        #expect(WatchRecorder.safeValue(AXElementInfo(role: "AXTextField", value: "x", placeholder: "Token"), bundle: nil) == nil)
        for role in ["AXTextArea", "AXWebArea", "AXScrollArea"] {
            #expect(WatchRecorder.safeValue(AXElementInfo(role: role, value: "A whole document"), bundle: nil) == nil)
        }
        let long = AXElementInfo(role: "AXPopUpButton", value: String(repeating: "a", count: 200))
        #expect(WatchRecorder.safeValue(long, bundle: nil) == String(repeating: "a", count: 120) + "…")
    }
}
