import Foundation
import WebKit
import XCTest

@testable import ZenCompanion

@MainActor
final class BrowserWebsiteDataTests: XCTestCase {
    private func pages() -> OpenPagesStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let preferences = FakePreferences()
        return OpenPagesStore(
            directory: directory,
            preferences: preferences,
            makeModel: { MiniBrowserModel(initialURL: $0, preferences: preferences) }
        )
    }

    private func sessionCookie() throws -> HTTPCookie {
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .domain: "session-regression.invalid",
            .path: "/",
            .name: "login-\(UUID().uuidString)",
            .value: "test-session",
            .secure: "TRUE",
            .discard: "TRUE",
        ]))
        XCTAssertTrue(cookie.isSessionOnly)
        XCTAssertNil(cookie.expiresDate)
        return cookie
    }

    private func set(_ cookie: HTTPCookie, in model: MiniBrowserModel) async throws {
        let store = try XCTUnwrap(model.webView?.configuration.websiteDataStore)
        await withCheckedContinuation { continuation in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func cookies(in model: MiniBrowserModel) async throws -> [HTTPCookie] {
        let store = try XCTUnwrap(model.webView?.configuration.websiteDataStore)
        return await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func delete(_ cookie: HTTPCookie, from model: MiniBrowserModel) async throws {
        let store = try XCTUnwrap(model.webView?.configuration.websiteDataStore)
        await withCheckedContinuation { continuation in
            store.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }

    func testContainerSessionCookieSurvivesClosingEveryWebViewAndReopening() async throws {
        let pages = pages()
        let containerID = UUID()
        // A blank page creates WebKit without requesting any website.
        let first = autoreleasepool { pages.open(url: nil, websiteDataStoreID: containerID) }
        let cookie = try sessionCookie()
        try await set(cookie, in: first.model)
        weak var originalStore = first.model.webView?.configuration.websiteDataStore
        weak var originalWebView = first.model.webView

        autoreleasepool { pages.endBrowserSession() }
        XCTAssertNil(first.model.webView)
        XCTAssertTrue(pages.pages.isEmpty)
        // WebKit can finish releasing a web view on a later run-loop turn.
        for _ in 0..<80 where originalWebView != nil {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertNil(originalWebView, "The test must release the last container web view")
        XCTAssertNotNil(originalStore, "Closing pages must not end the container's cookie session")

        let reopened = pages.open(url: nil, websiteDataStoreID: containerID)
        XCTAssertTrue(reopened.model.webView?.configuration.websiteDataStore === originalStore)
        let restoredCookies = try await cookies(in: reopened.model)
        XCTAssertEqual(restoredCookies.first { $0.name == cookie.name }?.value, cookie.value)
        try await delete(cookie, from: reopened.model)
        pages.closeAll()
    }

    func testRetainedContainerCookieDoesNotLeakToOtherContainersOrDefaultBrowsing() async throws {
        let pages = pages()
        let firstID = UUID()
        let first = pages.open(url: nil, websiteDataStoreID: firstID)
        let cookie = try sessionCookie()
        try await set(cookie, in: first.model)
        pages.endBrowserSession()

        let otherContainer = pages.open(url: nil, websiteDataStoreID: UUID())
        let otherCookies = try await cookies(in: otherContainer.model)
        XCTAssertFalse(otherCookies.contains { $0.name == cookie.name })
        let defaultPage = pages.open(url: nil)
        let defaultCookies = try await cookies(in: defaultPage.model)
        XCTAssertFalse(defaultCookies.contains { $0.name == cookie.name })

        let originalContainer = pages.open(url: nil, websiteDataStoreID: firstID)
        let originalCookies = try await cookies(in: originalContainer.model)
        XCTAssertEqual(originalCookies.first { $0.name == cookie.name }?.value, cookie.value)
        try await delete(cookie, from: originalContainer.model)
        pages.closeAll()
    }
}
