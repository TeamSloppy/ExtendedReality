import XCTest
@testable import ExtendReality

@MainActor
final class BrowserWindowSessionTests: XCTestCase {
    func testBrowserStartsWithOneActiveTab() {
        let browser = makeBrowser(initialURL: "https://www.apple.com")

        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.activeTabID, browser.tabs[0].id)
        XCTAssertEqual(browser.activeSession.address, "https://www.apple.com")
        XCTAssertTrue(browser.canCreateTab)
    }

    func testTabsKeepIndependentAddressDrafts() throws {
        let browser = makeBrowser(initialURL: "https://first.example")
        let firstID = browser.activeTabID
        browser.activeSession.address = "first search"

        let focusRequest = browser.addressFocusRequest
        let secondID = try XCTUnwrap(browser.addTab())
        XCTAssertNotEqual(browser.addressFocusRequest, focusRequest)
        XCTAssertEqual(browser.activeSession.address, "")
        browser.activeSession.address = "second search"

        browser.selectTab(firstID)
        XCTAssertEqual(browser.activeSession.address, "first search")
        browser.selectTab(secondID)
        XCTAssertEqual(browser.activeSession.address, "second search")
    }

    func testClosingActiveTabSelectsRightThenLeftNeighbor() throws {
        let browser = makeBrowser()
        let firstID = browser.activeTabID
        let secondID = try XCTUnwrap(browser.addTab())
        let thirdID = try XCTUnwrap(browser.addTab())

        browser.selectTab(secondID)
        browser.closeTab(secondID)
        XCTAssertEqual(browser.activeTabID, thirdID)

        browser.closeTab(thirdID)
        XCTAssertEqual(browser.activeTabID, firstID)

        browser.closeTab(firstID)
        XCTAssertEqual(browser.tabs.count, 1)
        XCTAssertEqual(browser.activeTabID, firstID)
    }

    func testBrowserEnforcesEightTabLimit() {
        let browser = makeBrowser()
        for _ in 1 ..< BrowserWindowSession.maximumTabCount {
            XCTAssertNotNil(browser.addTab())
        }

        XCTAssertEqual(browser.tabs.count, 8)
        XCTAssertEqual(browser.tabCountLabel, "8/8")
        XCTAssertFalse(browser.canCreateTab)
        XCTAssertNil(browser.addTab())
        XCTAssertEqual(browser.tabs.count, 8)
    }

    func testSpatialNewTabControlCreatesAndSelectsTab() {
        var focusRequestCount = 0
        let browser = makeBrowser {
            focusRequestCount += 1
        }
        browser.updateSpatialSurfaceSize(CGSize(width: 1_000, height: 600))
        let newTabPosition = CGPoint(x: 0.98, y: 0.03)

        browser.handle(.pointerDown(normalizedPosition: newTabPosition))
        browser.handle(.pointerUp(normalizedPosition: newTabPosition))

        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.activeTabID, browser.tabs.last?.id)
        XCTAssertEqual(focusRequestCount, 1)
    }

    func testSpatialAddressControlFocusesKeyboardAndRoutesSubmittedText() {
        var focusRequestCount = 0
        let browser = makeBrowser {
            focusRequestCount += 1
        }
        browser.updateSpatialSurfaceSize(CGSize(width: 1_000, height: 600))
        let addressPosition = CGPoint(x: 0.50, y: 0.10)

        browser.handle(.pointerDown(normalizedPosition: addressPosition))
        browser.handle(.pointerUp(normalizedPosition: addressPosition))
        browser.handle(.insertText("spatial browser"))

        XCTAssertEqual(focusRequestCount, 1)
        XCTAssertEqual(
            browser.activeSession.address,
            "https://www.google.com/search?q=spatial%20browser"
        )
    }

    func testNewWindowRequestOpensTabAndFallsBackToActiveAtLimit() throws {
        let browser = makeBrowser()
        let firstRequest = URLRequest(url: try XCTUnwrap(URL(string: "about:blank#first")))

        browser.activeSession.newWindowHandler?(firstRequest)
        XCTAssertEqual(browser.tabs.count, 2)
        XCTAssertEqual(browser.activeSession.address, "about:blank#first")

        while browser.canCreateTab {
            _ = browser.addTab(requestsAddressFocus: false)
        }
        let overflowRequest = URLRequest(url: try XCTUnwrap(URL(string: "about:blank#overflow")))
        browser.activeSession.newWindowHandler?(overflowRequest)

        XCTAssertEqual(browser.tabs.count, 8)
        XCTAssertEqual(browser.activeSession.address, "about:blank#overflow")
    }

    func testLoadingActiveTabDoesNotChangeBackgroundTab() throws {
        let browser = makeBrowser(initialURL: "")
        let firstID = browser.activeTabID
        let secondID = try XCTUnwrap(browser.addTab())
        let request = URLRequest(url: try XCTUnwrap(URL(string: "about:blank#active")))

        browser.activeSession.load(request)
        browser.reloadActive()
        XCTAssertTrue(browser.activeSession.hasLoadedRequest)

        browser.selectTab(firstID)
        XCTAssertFalse(browser.activeSession.hasLoadedRequest)
        XCTAssertEqual(browser.activeSession.address, "")
        browser.selectTab(secondID)
        XCTAssertEqual(browser.activeSession.address, "about:blank#active")
    }

    private func makeBrowser(
        initialURL: String = "https://example.com",
        textInputFocusHandler: @escaping () -> Void = {}
    ) -> BrowserWindowSession {
        BrowserWindowSession(
            initialURL: initialURL,
            loadsContent: false,
            textInputFocusHandler: textInputFocusHandler,
            sessionFactory: { initialURL, _ in
                BrowserSession(initialURL: initialURL, loadsContent: false)
            }
        )
    }
}

final class BrowserURLResolverTests: XCTestCase {
    func testPreservesFullHTTPURL() {
        XCTAssertEqual(
            BrowserURLResolver.resolve("https://example.com/path?q=1")?.absoluteString,
            "https://example.com/path?q=1"
        )
    }

    func testAddsHTTPSForDomain() {
        XCTAssertEqual(
            BrowserURLResolver.resolve("example.com/docs")?.absoluteString,
            "https://example.com/docs"
        )
    }

    func testBuildsEncodedGoogleSearchURL() throws {
        let url = try XCTUnwrap(BrowserURLResolver.resolve("очки & spatial web"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "www.google.com")
        XCTAssertEqual(components.path, "/search")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: "очки & spatial web")])
    }

    func testRejectsUnsupportedExplicitScheme() {
        XCTAssertNil(BrowserURLResolver.resolve("ftp://example.com/file"))
    }
}

final class BrowserChromeLayoutTests: XCTestCase {
    private let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    func testHitTestsTabsAndControls() {
        let layout = BrowserChromeLayout(
            size: CGSize(width: 1_000, height: 600),
            tabIDs: [firstID, secondID]
        )

        XCTAssertEqual(layout.target(at: CGPoint(x: 0.10, y: 0.03)), .tab(firstID))
        XCTAssertEqual(layout.target(at: CGPoint(x: 0.44, y: 0.03)), .closeTab(firstID))
        XCTAssertNil(layout.target(at: CGPoint(x: 0.93, y: 0.03)))
        XCTAssertEqual(layout.target(at: CGPoint(x: 0.98, y: 0.03)), .newTab)
        XCTAssertEqual(layout.target(at: CGPoint(x: 0.02, y: 0.10)), .back)
        XCTAssertEqual(layout.target(at: CGPoint(x: 0.06, y: 0.10)), .forward)
        XCTAssertEqual(layout.target(at: CGPoint(x: 0.50, y: 0.10)), .address)
        XCTAssertEqual(layout.target(at: CGPoint(x: 0.98, y: 0.10)), .reload)
    }

    func testMapsSurfacePositionIntoWebContent() throws {
        let layout = BrowserChromeLayout(
            size: CGSize(width: 1_000, height: 600),
            tabIDs: [firstID]
        )
        let chromeHeight = BrowserChromeLayout.chromeHeight
        let surfaceY = (chromeHeight + (600 - chromeHeight) * 0.5) / 600
        let target = try XCTUnwrap(layout.target(at: CGPoint(x: 0.25, y: surfaceY)))
        guard case .content(let position) = target else {
            return XCTFail("Expected a web-content hit target")
        }

        XCTAssertEqual(position.x, 0.25, accuracy: 0.000_1)
        XCTAssertEqual(position.y, 0.5, accuracy: 0.000_1)
    }
}
