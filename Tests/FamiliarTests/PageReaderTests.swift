import ApplicationServices
import Foundation
import Testing
@testable import Familiar

/// The page reader: what it reads from a page's Accessibility tree (the page, not the browser around it), what it
/// keeps from each thing on it, and the key that names the page. The trees here are made up, so no browser is needed.
@Suite
struct PageReaderTests {
    // MARK: - Reading a page

    @Test func itReadsThePageNotTheBrowserAroundIt() throws {
        let result = try #require(PageWalk.read(window: Self.window(), viewport: Self.viewport))
        #expect(result.documents.map(\.url) == ["https://portal.example.test/catalog/onboarding",
                                                 "https://portal.example.test/catalog/onboarding/form"])
        #expect(!result.elements.contains { $0.label == "Back" || $0.label == "New tab" })   // the browser's own controls
        #expect(result.elements.map(\.kind) == ["heading", "text", "link", "button", "text field", "password field", "button", "text", "link"])
        #expect(!result.truncated)
    }

    @Test func eachThingKeepsWhatNamesIt() throws {
        let elements = try #require(PageWalk.read(window: Self.window(), viewport: Self.viewport)).elements
        let heading = elements[0], link = elements[2], request = elements[3], field = elements[4], password = elements[5]
        #expect(heading.label == "Onboarding to Payments" && heading.level == 1 && heading.value == nil)
        #expect(link.label == "Access guide" && link.link == "https://portal.example.test/guide")
        // A button whose name is the text inside it, with the page's own id for it.
        #expect(request.label == "Request onboarding" && request.domID == "request-btn" && !request.enabled)
        #expect(field.label == "Cost center" && field.value == "4410")
        #expect(password.label == "Password" && password.value == nil)   // never a password's value
        #expect(elements.filter { $0.label == "Request onboarding" }.count == 1)   // its inner text isn't read twice
    }

    @Test func thingsInAFrameAndOffScreenAreMarked() throws {
        let elements = try #require(PageWalk.read(window: Self.window(), viewport: Self.viewport)).elements
        let submit = try #require(elements.first { $0.label == "Submit" })
        #expect(submit.document == 1 && submit.visible)
        let footer = try #require(elements.first { $0.label == "Terms of use" })
        #expect(!footer.visible && footer.document == 0)
    }

    @Test func aLongPageStopsAtItsBudget() throws {
        var rows: [FakeNode] = []
        for index in 0..<500 { rows.append(FakeNode("AXStaticText", ["AXValue": "Row \(index)"], frame: CGRect(x: 0, y: 100 + index * 20, width: 200, height: 18))) }
        let page = FakeNode("AXWebArea", ["AXURL": "https://example.test/long"], frame: Self.viewport, rows)
        let window = FakeNode("AXWindow", [:], frame: Self.viewport, [page])
        let read = try #require(PageWalk.read(window: window, viewport: Self.viewport, budget: .init(nodes: 6_000, elements: 120)))
        #expect(read.elements.count == 120 && read.truncated)
        let whole = try #require(PageWalk.read(window: window, viewport: Self.viewport))
        #expect(whole.elements.count == 500 && !whole.truncated)
        // A clock that has run out stops the walk too.
        var tick = Date(timeIntervalSince1970: 0)
        let slow = try #require(PageWalk.read(window: window, viewport: Self.viewport, budget: .init(seconds: 1)) {
            tick = tick.addingTimeInterval(0.5)
            return tick
        })
        #expect(slow.truncated && slow.elements.count < 500)
    }

    @Test func aWindowWithoutAPageReadsNothing() {
        let window = FakeNode("AXWindow", [:], frame: Self.viewport, [FakeNode("AXButton", ["AXTitle": "OK"])])
        #expect(PageWalk.read(window: window, viewport: Self.viewport) == nil)
    }

    @Test func theTextForTheModelSaysWhatIsWhere() throws {
        let result = try #require(PageWalk.read(window: Self.window(), viewport: Self.viewport))
        let page = PageSnapshot(appName: "Browser", bundleID: "com.example.browser", windowTitle: "Onboarding", documents: result.documents,
                                elements: result.elements, selectedText: "4410", truncated: false, elapsed: 0.02)
        let text = page.text()
        #expect(text.contains("Address: https://portal.example.test/catalog/onboarding\n"))
        #expect(text.contains("Page key: portal.example.test/catalog/onboarding/form\n"))   // the form's frame fills the page
        #expect(text.contains("[heading 1] Onboarding to Payments\n"))
        #expect(text.contains("[button] Request onboarding (disabled)\n"))
        #expect(text.contains("[text field] Cost center = “4410”\n"))
        #expect(text.contains("[link] Access guide → https://portal.example.test/guide\n"))
        #expect(text.contains("[link] Terms of use → https://portal.example.test/terms ·off screen"))
        #expect(text.contains("Selected text: “4410”"))
        #expect(!text.contains("hunter2"))
    }

    @Test func theWindowsTabsAreNamed() throws {
        #expect(try #require(PageWalk.read(window: Self.window(), viewport: Self.viewport)).tabs == ["Onboarding", "Inbox (3)"])
    }

    @Test func aLinkInsideAHeadingIsStillRead() throws {
        let heading = FakeNode("AXHeading", ["AXValue": 2], frame: CGRect(x: 0, y: 100, width: 300, height: 30), [
            FakeNode("AXLink", ["AXURL": "https://desk.example.test/incident.do?sys_id=1"], frame: CGRect(x: 0, y: 100, width: 80, height: 30),
                     [FakeNode("AXStaticText", ["AXValue": "INC001"])])])
        let page = FakeNode("AXWebArea", ["AXURL": "https://desk.example.test/list"], frame: Self.viewport, [heading])
        let elements = try #require(PageWalk.read(window: FakeNode("AXWindow", [:], frame: Self.viewport, [page]), viewport: Self.viewport)).elements
        #expect(elements.map(\.kind) == ["heading", "link"])   // the link's text names both, and is not read as text
        #expect(elements.map(\.label) == ["INC001", "INC001"] && elements[1].link == "https://desk.example.test/incident.do?sys_id=1")
    }

    @Test func thePageIsTheLargestWebPageNotDeveloperToolsOrASidePanel() throws {
        let tools = FakeNode("AXWebArea", ["AXURL": "devtools://devtools/bundled/devtools_app.html"], frame: CGRect(x: 0, y: 0, width: 1_200, height: 900),
                             [FakeNode("AXButton", ["AXTitle": "Elements"])])
        let panel = FakeNode("AXWebArea", ["AXURL": "https://assistant.example.test/panel"], frame: CGRect(x: 900, y: 80, width: 300, height: 820),
                             [FakeNode("AXButton", ["AXTitle": "Ask"])])
        let page = FakeNode("AXWebArea", ["AXURL": "https://portal.example.test/"], frame: CGRect(x: 0, y: 80, width: 900, height: 820),
                            [FakeNode("AXButton", ["AXTitle": "Request"], frame: CGRect(x: 10, y: 100, width: 80, height: 20))])
        let read = try #require(PageWalk.read(window: FakeNode("AXWindow", [:], frame: Self.viewport, [tools, panel, page]), viewport: Self.viewport))
        #expect(read.documents.first?.url == "https://portal.example.test/" && read.elements.map(\.label) == ["Request"])
    }

    @Test func whatIsScrolledUnderTheToolbarIsOffScreen() throws {
        let page = FakeNode("AXWebArea", ["AXURL": "https://portal.example.test/"], frame: CGRect(x: 0, y: 80, width: 1_200, height: 820), [
            FakeNode("AXButton", ["AXTitle": "Menu"], frame: CGRect(x: 10, y: 20, width: 80, height: 30)),
            FakeNode("AXButton", ["AXTitle": "Save"], frame: CGRect(x: 10, y: 300, width: 80, height: 30))])
        let read = try #require(PageWalk.read(window: FakeNode("AXWindow", [:], frame: Self.viewport, [page]), viewport: Self.viewport))
        #expect(read.elements.map(\.visible) == [false, true])
    }

    @Test func aLongMenuStillLeavesTheFormsFrameFound() throws {
        let menu = FakeNode("AXGroup", [:], (0..<50).map { FakeNode("AXLink", ["AXTitle": "Module \($0)"], frame: CGRect(x: 0, y: 100, width: 100, height: 10)) })
        let form = FakeNode("AXWebArea", ["AXURL": "https://example.service-now.com/sc_cat_item.do?sys_id=abc123"],
                            frame: CGRect(x: 200, y: 60, width: 1_000, height: 840), [FakeNode("AXButton", ["AXTitle": "Order now"])])
        let top = FakeNode("AXWebArea", ["AXURL": "https://example.service-now.com/navpage.do"], frame: Self.viewport, [menu, form])
        let read = try #require(PageWalk.read(window: FakeNode("AXWindow", [:], frame: Self.viewport, [top]), viewport: Self.viewport,
                                              budget: .init(elements: 20)))
        #expect(read.truncated && read.elements.count == 20)
        #expect(read.documents.count == 2 && PageKey.of(read.documents)?.description == "example.service-now.com/sc_cat_item.do?sys_id=abc123")
    }

    // MARK: - Secrets

    @Test func secretsStayOffThePage() throws {
        func field(_ attributes: [String: Any]) -> FakeNode {
            FakeNode("AXTextField", attributes.merging(["AXValue": "s3cr3t-value"]) { first, _ in first }, frame: CGRect(x: 0, y: 100, width: 100, height: 20))
        }
        let page = FakeNode("AXWebArea", ["AXURL": "https://example.test/"], frame: Self.viewport, [
            FakeNode("AXStaticText", ["AXValue": "API key"], frame: CGRect(x: 0, y: 90, width: 100, height: 10)),
            field([:]),                                                        // named only by the text beside it
            field(["AXDOMIdentifier": "user_password"]),
            field(["AXDOMIdentifier": "apiKeyInput", "AXTitle": "Field"]),
            field(["AXTitle": "Verification code"]),
            field(["AXTitle": "Card number"]),
            FakeNode("AXTextField", ["AXTitle": "Notes", "AXValue": "use sk-abcdefghijklmnopqrstuv"], frame: CGRect(x: 0, y: 100, width: 100, height: 20)),
            FakeNode("AXTextField", ["AXTitle": "Reference", "AXValue": "4111 1111 1111 1111"], frame: CGRect(x: 0, y: 100, width: 100, height: 20)),
            FakeNode("AXTextField", ["AXTitle": "Order number", "AXValue": "1234 5678 9012 3456"], frame: CGRect(x: 0, y: 100, width: 100, height: 20)),
            FakeNode("AXStaticText", ["AXValue": "Your key: ghp_abcdefghijklmnopqrstuvwxyz123456"], frame: CGRect(x: 0, y: 200, width: 100, height: 10)),
        ])
        let elements = try #require(PageWalk.read(window: FakeNode("AXWindow", [:], frame: Self.viewport, [page]), viewport: Self.viewport)).elements
        #expect(elements.filter { $0.kind == "text field" }.map(\.value) == [nil, nil, nil, nil, nil, nil, nil, "1234 5678 9012 3456"])
        #expect(elements.last?.label == "(hidden: looks like a secret)")
    }

    @Test func secretLooksAndCardNumbers() {
        #expect(PageWalk.looksLikeSecretValue("AKIAABCDEFGHIJKLMNOP") && PageWalk.looksLikeSecretValue("-----BEGIN RSA PRIVATE KEY-----"))
        #expect(PageWalk.looksLikeSecretValue("card 4111-1111-1111-1111 on file") && PageWalk.luhn("4111111111111111"))
        #expect(!PageWalk.looksLikeSecretValue("Order 1234567890123456") && !PageWalk.looksLikeSecretValue("Call 555 0100"))
        #expect(!PageWalk.looksLikeSecretValue("Request onboarding"))
        #expect(ScreenText.safeValue("4410", subrole: nil, names: ["Cost center"]))
        #expect(!ScreenText.safeValue("hunter2", subrole: "AXSecureTextField", names: ["Name"]))
        #expect(!ScreenText.safeValue("abc", subrole: nil, names: ["", "One-time code"]))
    }

    @Test func addressesLoseTheirCredentials() {
        #expect(PageWalk.safeAddress("https://example.test/reset?token=abc&lang=en#step2") == "https://example.test/reset?lang=en")
        #expect(PageWalk.safeAddress("https://example.test/cb?code=xyz&state=1") == "https://example.test/cb")
        #expect(PageWalk.safeAddress("https://bucket.example.test/f.pdf?X-Amz-Signature=s&X-Amz-Credential=c&v=2") == "https://bucket.example.test/f.pdf?v=2")
        #expect(PageWalk.safeAddress("https://example.test/item?id=42") == "https://example.test/item?id=42")
    }

    // MARK: - The page key

    @Test func aPageKeyIsItsHostAndPathOnly() {
        #expect(PageKey.of("https://Portal.Example.test:8443/Catalog/Item/?utm_source=mail#top")?.description
                == "portal.example.test:8443/Catalog/Item")
        #expect(PageKey.of("https://example.test")?.description == "example.test/")
        #expect(PageKey.of("not a page") == nil && PageKey.of("file:///Users/me/notes.html") == nil)
    }

    @Test func aServiceNowFormIsTheSamePageHoweverItIsReached() {
        let direct = PageKey.of("https://example.service-now.com/sc_cat_item.do?sys_id=abc123&sysparm_view=full")
        let classic = PageKey.of("https://example.service-now.com/nav_to.do?uri=sc_cat_item.do%3Fsys_id%3Dabc123")
        let polaris = PageKey.of("https://example.service-now.com/now/nav/ui/classic/params/target/sc_cat_item.do%3Fsys_id%3Dabc123")
        #expect(direct?.description == "example.service-now.com/sc_cat_item.do?sys_id=abc123")
        #expect(classic == direct && polaris == direct)
        // The service portal names its pages by id, and the record by sys_id; the category is just how it was reached.
        #expect(PageKey.of("https://example.service-now.com/sp?id=sc_cat_item&sys_id=abc123&sysparm_category=hr")?.description
                == "example.service-now.com/sp?id=sc_cat_item&sys_id=abc123")
        // Another record is another page.
        #expect(PageKey.of("https://example.service-now.com/sc_cat_item.do?sys_id=zzz") != direct)
    }

    @Test func anAppServedFromItsRootIsKeyedByItsPageParameter() {
        #expect(PageKey.of("http://127.0.0.1:4310/?page=library&q=tax")?.description == "127.0.0.1:4310/?page=library")
        #expect(PageKey.of("http://127.0.0.1:4310/?page=library") != PageKey.of("http://127.0.0.1:4310/?page=attention"))
        #expect(PageKey.of("https://news.example.test/item?id=42")?.description == "news.example.test/item")
    }

    @Test func aServiceNowRecordOnACompanysOwnDomainKeepsItsRecord() {
        let id = "0123456789abcdef0123456789abcdef"
        #expect(PageKey.of("https://servicedesk.example.test/incident.do?sys_id=\(id)&sysparm_view=ess")?.description
                == "servicedesk.example.test/incident.do?sys_id=\(id)")
        #expect(PageKey.of("https://help.example.test/esc?id=ticket&table=incident&sys_id=\(id)")?.description
                == "help.example.test/esc?id=ticket&sys_id=\(id)&table=incident")
        // Encoded twice, the wrapped address still lands on the record.
        #expect(PageKey.of("https://example.service-now.com/nav_to.do?uri=%252Fincident.do%253Fsys_id%253Dabc")?.description
                == "example.service-now.com/incident.do?sys_id=abc")
    }

    @Test func theSamePageWrittenTwoWaysHasOneKey() {
        #expect(PageKey.of("https://example.test:443/docs/index.html") == PageKey.of("https://example.test/docs/"))
        #expect(PageKey.of("http://example.test:80/") == PageKey.of("http://example.test/"))
        #expect(PageKey.of("http://127.0.0.1:4310/")?.description == "127.0.0.1:4310/")
        // A route after "#/" is a page of its own; a place in the page, or Gmail's #inbox, is not.
        #expect(PageKey.of("https://app.example.test/#/settings/profile/?tab=2")?.description == "app.example.test/#/settings/profile")
        #expect(PageKey.of("https://mail.example.test/mail/u/0/#inbox")?.description == "mail.example.test/mail/u/0")
        #expect(PageKey.of("https://docs.example.test/guide#install") == PageKey.of("https://docs.example.test/guide"))
    }

    @Test func theMainFrameNamesThePageButAnAdDoesNot() {
        let top = PageDocument(url: "https://example.service-now.com/navpage.do", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let form = PageDocument(url: "https://example.service-now.com/sc_cat_item.do?sys_id=abc123", frame: CGRect(x: 200, y: 60, width: 800, height: 740))
        let ad = PageDocument(url: "https://ads.example.net/banner?id=1", frame: CGRect(x: 0, y: 0, width: 1_000, height: 800))
        let small = PageDocument(url: "https://example.service-now.com/widget.do", frame: CGRect(x: 0, y: 700, width: 300, height: 100))
        #expect(PageKey.of([top, form])?.description == "example.service-now.com/sc_cat_item.do?sys_id=abc123")
        #expect(PageKey.of([top, ad])?.description == "example.service-now.com/navpage.do")
        #expect(PageKey.of([top, small])?.description == "example.service-now.com/navpage.do")
        #expect(PageKey.of([]) == nil)
    }

    // MARK: - Fixtures

    static let viewport = CGRect(x: 0, y: 0, width: 1_200, height: 900)

    /// A browser window: its toolbar, then a page with a heading, an intro, a link, a disabled button whose name is
    /// its text, a field, a password field, a frame holding a form, and a footer below the fold.
    static func window() -> FakeNode {
        let toolbar = FakeNode("AXToolbar", [:], [FakeNode("AXButton", ["AXDescription": "Back"]), FakeNode("AXButton", ["AXDescription": "New tab"]),
            FakeNode("AXTextField", ["AXDescription": "Address and search bar", "AXValue": "portal.example.test/catalog/onboarding"])])
        let tabs = FakeNode("AXTabGroup", [:], [FakeNode("AXRadioButton", ["AXTitle": "Onboarding", "AXSubrole": "AXTabButton"]),
                                                FakeNode("AXRadioButton", ["AXTitle": "Inbox (3)", "AXSubrole": "AXTabButton"])])
        let frame = FakeNode("AXWebArea", ["AXURL": "https://portal.example.test/catalog/onboarding/form"],
                             frame: CGRect(x: 0, y: 80, width: 1_200, height: 800), [
            FakeNode("AXGroup", [:], [FakeNode("AXButton", ["AXTitle": "Submit"], frame: CGRect(x: 40, y: 600, width: 90, height: 30)),
                                      FakeNode("AXStaticText", ["AXValue": "Approval usually takes 2 days."], frame: CGRect(x: 40, y: 640, width: 300, height: 18))]),
        ])
        let page = FakeNode("AXWebArea", ["AXURL": "https://portal.example.test/catalog/onboarding"], frame: CGRect(x: 0, y: 80, width: 1_200, height: 820), [
            FakeNode("AXHeading", ["AXValue": 1], frame: CGRect(x: 40, y: 100, width: 500, height: 40),
                     [FakeNode("AXStaticText", ["AXValue": "Onboarding to Payments"])]),
            FakeNode("AXGroup", [:], [
                FakeNode("AXStaticText", ["AXValue": "Request access before you start."], frame: CGRect(x: 40, y: 150, width: 400, height: 18)),
                FakeNode("AXLink", ["AXURL": "https://portal.example.test/guide"], frame: CGRect(x: 40, y: 180, width: 120, height: 18),
                         [FakeNode("AXStaticText", ["AXValue": "Access guide"])]),
                FakeNode("AXButton", ["AXDOMIdentifier": "request-btn", "AXEnabled": false], frame: CGRect(x: 40, y: 220, width: 180, height: 32),
                         [FakeNode("AXStaticText", ["AXValue": "Request onboarding"])]),
                FakeNode("AXTextField", ["AXTitle": "Cost center", "AXValue": "4410"], frame: CGRect(x: 40, y: 270, width: 200, height: 24)),
                FakeNode("AXTextField", ["AXTitle": "Password", "AXSubrole": "AXSecureTextField", "AXValue": "hunter2"],
                         frame: CGRect(x: 40, y: 300, width: 200, height: 24)),
            ]),
            frame,
            FakeNode("AXGroup", [:], [FakeNode("AXLink", ["AXTitle": "Terms of use", "AXURL": "https://portal.example.test/terms"],
                                               frame: CGRect(x: 40, y: 2_400, width: 100, height: 18))]),
        ])
        return FakeNode("AXWindow", ["AXTitle": "Onboarding"], frame: viewport, [tabs, toolbar, page])
    }
}

/// A made-up Accessibility element.
struct FakeNode: PageNode {
    let role: String
    let attributes: [String: Any]
    let frame: CGRect?
    let children: [FakeNode]

    init(_ role: String, _ attributes: [String: Any], frame: CGRect? = nil, _ children: [FakeNode] = []) {
        self.role = role
        self.attributes = attributes
        self.frame = frame
        self.children = children
    }

    func string(_ attribute: String) -> String? {
        attribute == kAXRoleAttribute ? role : attributes[attribute] as? String
    }
    func number(_ attribute: String) -> Int? { attributes[attribute] as? Int }
    func flag(_ attribute: String) -> Bool? { attributes[attribute] as? Bool }
}
