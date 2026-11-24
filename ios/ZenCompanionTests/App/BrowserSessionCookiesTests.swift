import Foundation
import Security
import WebKit
import XCTest

@testable import ZenCompanion

@MainActor
final class BrowserSessionCookiesTests: XCTestCase {
    /// Stands in for device-local Keychain data, outliving each WebKit session.
    private final class MemoryPersistence: BrowserCookiePersistence {
        var data: Data?

        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func delete() throws { data = nil }
    }

    private func cookie(name: String, value: String, persistent: Bool = false) throws -> HTTPCookie {
        var header = "\(name)=\(value); Domain=session-regression.invalid; Path=/account; Secure; HttpOnly; SameSite=Strict"
        if persistent { header += "; Max-Age=3600" }
        return try XCTUnwrap(HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": header],
            for: URL(string: "https://session-regression.invalid/account")!
        ).first)
    }

    private func put(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private func remove(_ cookie: HTTPCookie, from store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.delete(cookie) { continuation.resume() }
        }
    }

    private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    func testColdRestorePreservesSessionCookieAttributesAndExcludesPersistentCookies() async throws {
        let persistence = MemoryPersistence()
        let originalStore = WKWebsiteDataStore.nonPersistent()
        let originalSession = BrowserCookieSession(store: originalStore, persistence: persistence)
        await originalSession.prepare()
        let login = try cookie(name: "login", value: "session-secret")
        let persistent = try cookie(name: "persistent", value: "webkit-owned", persistent: true)
        XCTAssertTrue(login.isSessionOnly)
        XCTAssertFalse(persistent.isSessionOnly)
        await put(login, in: originalStore)
        await put(persistent, in: originalStore)
        await originalSession.checkpoint()

        let archived = try SessionCookieArchive.decode(XCTUnwrap(persistence.data))
        XCTAssertEqual(archived.map(\.name), [login.name])
        // A fresh empty store models WebKit losing its in-memory state.
        let freshStore = WKWebsiteDataStore.nonPersistent()
        let restoredSession = BrowserCookieSession(store: freshStore, persistence: persistence)
        await restoredSession.prepare()
        let restoredCookies = await cookies(in: freshStore)
        let restored = try XCTUnwrap(restoredCookies.first { $0.name == login.name })
        XCTAssertEqual(restoredCookies.count, 1)
        XCTAssertEqual(restored.value, login.value)
        XCTAssertEqual(restored.domain, login.domain)
        XCTAssertEqual(restored.path, login.path)
        XCTAssertTrue(restored.isHTTPOnly)
        XCTAssertTrue(restored.isSecure)
        XCTAssertTrue(restored.isSessionOnly)
        XCTAssertNil(restored.expiresDate)
    }

    func testLogoutCookieDeletionIsNotResurrectedOnColdRestore() async throws {
        let persistence = MemoryPersistence()
        let store = WKWebsiteDataStore.nonPersistent()
        let session = BrowserCookieSession(store: store, persistence: persistence)
        await session.prepare()
        let login = try cookie(name: "login", value: "old-session")
        await put(login, in: store)
        await session.checkpoint()
        XCTAssertFalse(try SessionCookieArchive.decode(XCTUnwrap(persistence.data)).isEmpty)

        await remove(login, from: store)
        await session.checkpoint()
        let freshStore = WKWebsiteDataStore.nonPersistent()
        let freshSession = BrowserCookieSession(store: freshStore, persistence: persistence)
        await freshSession.prepare()
        let restoredCookies = await cookies(in: freshStore)
        XCTAssertTrue(restoredCookies.isEmpty)
    }

    func testExplicitClearRemovesStoredLoginBeforeAnotherSessionRestores() async throws {
        let persistence = MemoryPersistence()
        let store = WKWebsiteDataStore.nonPersistent()
        let session = BrowserCookieSession(store: store, persistence: persistence)
        await session.prepare()
        await put(try cookie(name: "login", value: "old-session"), in: store)
        await session.checkpoint()

        await session.clear()
        let clearedCookies = await cookies(in: store)
        XCTAssertTrue(clearedCookies.isEmpty)
        // An observer may checkpoint an empty jar after clearing; either form
        // must contain no login that could return on the next launch.
        if let data = persistence.data {
            XCTAssertTrue(try SessionCookieArchive.decode(data).isEmpty)
        }
        let freshStore = WKWebsiteDataStore.nonPersistent()
        let freshSession = BrowserCookieSession(store: freshStore, persistence: persistence)
        await freshSession.prepare()
        let restoredCookies = await cookies(in: freshStore)
        XCTAssertTrue(restoredCookies.isEmpty)
    }

    func testContainerCheckpointsRemainIsolatedOnColdRestore() async throws {
        let firstPersistence = MemoryPersistence()
        let secondPersistence = MemoryPersistence()
        let firstStore = WKWebsiteDataStore.nonPersistent()
        let secondStore = WKWebsiteDataStore.nonPersistent()
        let firstSession = BrowserCookieSession(store: firstStore, persistence: firstPersistence)
        let secondSession = BrowserCookieSession(store: secondStore, persistence: secondPersistence)
        await firstSession.prepare()
        await secondSession.prepare()
        await put(try cookie(name: "login", value: "personal-account"), in: firstStore)
        await put(try cookie(name: "login", value: "work-account"), in: secondStore)
        await firstSession.checkpoint()
        await secondSession.checkpoint()

        let freshFirstStore = WKWebsiteDataStore.nonPersistent()
        let freshSecondStore = WKWebsiteDataStore.nonPersistent()
        let freshFirstSession = BrowserCookieSession(store: freshFirstStore, persistence: firstPersistence)
        let freshSecondSession = BrowserCookieSession(store: freshSecondStore, persistence: secondPersistence)
        await freshFirstSession.prepare()
        await freshSecondSession.prepare()
        let firstCookies = await cookies(in: freshFirstStore)
        let secondCookies = await cookies(in: freshSecondStore)
        XCTAssertEqual(firstCookies.first { $0.name == "login" }?.value, "personal-account")
        XCTAssertEqual(secondCookies.first { $0.name == "login" }?.value, "work-account")
    }

    func testExistingNewerCookieWinsOverSavedValue() async throws {
        let persistence = MemoryPersistence()
        persistence.data = try SessionCookieArchive.encode([cookie(name: "login", value: "stale-session")])
        let store = WKWebsiteDataStore.nonPersistent()
        await put(try cookie(name: "login", value: "new-session"), in: store)
        let session = BrowserCookieSession(store: store, persistence: persistence)

        await session.prepare()
        let restoredCookies = await cookies(in: store)
        XCTAssertEqual(restoredCookies.first { $0.name == "login" }?.value, "new-session")
        await session.checkpoint()
        XCTAssertEqual(try SessionCookieArchive.decode(XCTUnwrap(persistence.data)).first?.value, "new-session")
    }

    func testClearedKeychainGenerationRejectsAStaleRecordLeftByFailedDeletion() throws {
        let storeKey = "cookie-regression-\(UUID().uuidString)"
        let service = (Bundle.main.bundleIdentifier ?? "com.benjaminlevin.zsync.preview")
            + ".browser-session-cookies"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: storeKey,
        ]
        defer {
            // Restrict cleanup to this randomly named test record. Never clear
            // the shared service or its installation epoch.
            SecItemDelete(query as CFDictionary)
            UserDefaults.standard.removeObject(forKey: service + ".generation." + storeKey)
        }
        let persistence = KeychainBrowserCookiePersistence(storeKey: storeKey)
        let archive = try SessionCookieArchive.encode([cookie(name: "login", value: "old-session")])
        try persistence.write(archive)
        XCTAssertEqual(try persistence.read(), archive)

        var readQuery = query
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var rawRecord: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(readQuery as CFDictionary, &rawRecord), errSecSuccess)
        let oldEnvelope = try XCTUnwrap(rawRecord as? Data)

        try persistence.delete()
        XCTAssertNil(try persistence.read())
        // Emulate the old encrypted record surviving a failed Keychain delete.
        // It carries the pre-clear generation, so restoring it must be ignored.
        var staleItem = query
        staleItem[kSecValueData as String] = oldEnvelope
        staleItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(SecItemAdd(staleItem as CFDictionary, nil), errSecSuccess)
        XCTAssertNil(try persistence.read())

        let newArchive = try SessionCookieArchive.encode([cookie(name: "login", value: "new-session")])
        try persistence.write(newArchive)
        XCTAssertEqual(try persistence.read(), newArchive)
    }
}
