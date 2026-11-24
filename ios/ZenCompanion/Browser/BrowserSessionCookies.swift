import Foundation
import Security
import WebKit
import os

/// Session cookies are memory-only in WebKit. A browser session should survive
/// iOS reclaiming the app; keep an encrypted, device-local checkpoint instead
/// of changing the cookies' expiry or copying them between containers.
protocol BrowserCookiePersistence {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

struct KeychainBrowserCookiePersistence: BrowserCookiePersistence {
    let storeKey: String
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "com.benjaminlevin.zsync.preview") + ".browser-session-cookies"
    }
    private static func generation(_ key: String) -> String {
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        return invalidate(key)
    }
    @discardableResult
    private static func invalidate(_ key: String) -> String {
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        // Only nonsecret invalidation markers live in defaults. Flush explicit
        // clears before touching Keychain, so a failed delete cannot restore
        // old logins on the next launch. A reinstall also starts a new epoch.
        UserDefaults.standard.synchronize()
        return value
    }
    private var generation: String {
        Self.generation(Self.service + ".epoch") + ":" + Self.generation(Self.service + ".generation." + storeKey)
    }
    static var clearIsPending: Bool {
        UserDefaults.standard.bool(forKey: service + ".clearPending")
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: storeKey]
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
    func read() throws -> Data? {
        guard !Self.clearIsPending else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(request as CFDictionary, &result))
        guard let data = result as? Data,
              let envelope = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              envelope["generation"] as? String == generation else { return nil }
        return envelope["cookies"] as? Data
    }
    func write(_ data: Data) throws {
        guard !Self.clearIsPending else { throw CocoaError(.userCancelled) }
        let envelope = try PropertyListSerialization.data(
            fromPropertyList: ["generation": generation, "cookies": data], format: .binary, options: 0
        )
        let attributes: [String: Any] = [
            kSecValueData as String: envelope,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
            }
        } else { try check(status) }
    }
    func delete() throws {
        Self.invalidate(Self.service + ".generation." + storeKey)
        try check(SecItemDelete(query as CFDictionary))
    }
    static func beginClearAll() {
        UserDefaults.standard.set(true, forKey: service + ".clearPending")
        UserDefaults.standard.synchronize()
        deleteAll()
    }
    static func finishClearAll() {
        deleteAll()
        UserDefaults.standard.set(false, forKey: service + ".clearPending")
        UserDefaults.standard.synchronize()
    }
    private static func deleteAll() {
        invalidate(service + ".epoch")
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }
}

enum SessionCookieArchive {
    static func encode(_ cookies: [HTTPCookie]) throws -> Data {
        // Persistent cookies remain WebKit's responsibility. Preserve every
        // property, including HttpOnly/Secure/SameSite and the exact domain.
        let properties = cookies.filter(\.isSessionOnly).compactMap { cookie -> [String: Any]? in
            guard let properties = cookie.properties else { return nil }
            return Dictionary(uniqueKeysWithValues: properties.map { key, value in
                (key.rawValue, (value as? URL)?.absoluteString ?? value)
            })
        }
        return try PropertyListSerialization.data(fromPropertyList: properties, format: .binary, options: 0)
    }

    static func decode(_ data: Data) throws -> [HTTPCookie] {
        guard let rows = try PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return rows.compactMap { row in
            HTTPCookie(properties: Dictionary(uniqueKeysWithValues: row.map { (HTTPCookiePropertyKey($0.key), $0.value) }))
        }.filter { $0.isSessionOnly && ($0.expiresDate.map { $0 > Date() } ?? true) }
    }

    static func key(_ cookie: HTTPCookie) -> String {
        "\(cookie.domain)\n\(cookie.path)\n\(cookie.name)"
    }
}

@MainActor
final class BrowserCookieSession: NSObject, WKHTTPCookieStoreObserver {
    let store: WKWebsiteDataStore
    private let persistence: BrowserCookiePersistence
    private var preparation: Task<Bool, Never>?
    private var clearing: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var needsCheckpoint = false
    private var prepared = false
    private var revision = 0

    init(store: WKWebsiteDataStore, persistence: BrowserCookiePersistence) {
        self.store = store
        self.persistence = persistence
    }

    /// All first navigations await this. Never overwrite a newer cookie that
    /// WebKit already has, and never replay the checkpoint on later reloads.
    func prepare() async {
        if let clearing { await clearing.value }
        if prepared { return }
        if let preparation { _ = await preparation.value; return }
        let task = Task { @MainActor [self] in
            do {
                if let data = try persistence.read() {
                    let saved = try SessionCookieArchive.decode(data)
                    let existing = await store.httpCookieStore.allCookies()
                    let existingKeys = Set(existing.map(SessionCookieArchive.key))
                    for cookie in saved where !existingKeys.contains(SessionCookieArchive.key(cookie)) {
                        await store.httpCookieStore.put(cookie)
                    }
                }
                prepared = true
                store.httpCookieStore.add(self)
                return true
            } catch {
                // A locked/unavailable Keychain must not erase a checkpoint.
                os_log("Browser session cookie restore unavailable", type: .error)
                return false
            }
        }
        preparation = task
        _ = await task.value
        preparation = nil
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor [weak self] in await self?.checkpoint() }
    }

    func checkpoint() async {
        guard clearing == nil else { return }
        await prepare()
        guard prepared, clearing == nil else { return }
        needsCheckpoint = true
        if let checkpointTask { await checkpointTask.value; return }
        let task = Task { @MainActor [self] in
            while needsCheckpoint, clearing == nil {
                needsCheckpoint = false
                let requested = revision
                let cookies = await store.httpCookieStore.allCookies()
                guard revision == requested, clearing == nil else { break }
                do {
                    // Replace the complete snapshot: logout cookies must
                    // disappear from disk instead of being merged back later.
                    try persistence.write(SessionCookieArchive.encode(cookies))
                } catch {
                    os_log("Browser session cookie checkpoint unavailable", type: .error)
                }
            }
            checkpointTask = nil
        }
        checkpointTask = task
        await task.value
    }

    /// Invalidate reads already in flight and finish any first-time restore
    /// before clearing WebKit, so an explicit clear cannot resurrect a login.
    func clear() async {
        if let clearing { await clearing.value; return }
        revision += 1
        needsCheckpoint = false
        let pendingPreparation = preparation
        let pendingCheckpoint = checkpointTask
        let task = Task { @MainActor [self] in
            if let pendingPreparation { _ = await pendingPreparation.value }
            if let pendingCheckpoint { await pendingCheckpoint.value }
            do { try persistence.delete() } catch {
                os_log("Browser session cookie removal unavailable", type: .error)
            }
            await withCheckedContinuation { continuation in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    continuation.resume()
                }
            }
            prepared = true
            store.httpCookieStore.add(self)
        }
        clearing = task
        await task.value
        clearing = nil
    }
}

extension WKHTTPCookieStore {
    fileprivate func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
    fileprivate func put(_ cookie: HTTPCookie) async {
        await withCheckedContinuation { continuation in
            setCookie(cookie) { continuation.resume() }
        }
    }
}
