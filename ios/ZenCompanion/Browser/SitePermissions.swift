import CryptoKit
import Foundation
import Observation
import UIKit
import WebKit

/// What a site can ask for. The browser asks first; the system's own question
/// only follows once the reader has allowed the site.
enum SitePermission: String, CaseIterable, Codable, Identifiable {
    case camera
    case microphone
    case location

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .camera: "camera"
        case .microphone: "mic"
        case .location: "location"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .camera: "site_permission.camera"
        case .microphone: "site_permission.microphone"
        case .location: "site_permission.location"
        }
    }
}

/// A remembered answer for one site. No entry means the browser asks.
enum SitePermissionChoice: String, Codable {
    case allow
    case block
}

enum SitePermissionDecision: Equatable {
    case grant
    case deny
    case ask
}

/// The browser's answers per site, on this phone only: never synced and left
/// out of device backups.
///
/// Android port: `SitePermissionStore` in `data/SitePermissions.kt`.
@MainActor
@Observable
final class SitePermissionStore {
    static let shared = SitePermissionStore()

    private(set) var choices: [String: SitePermissionChoice]
    @ObservationIgnored private let fileURL: URL

    init(fileURL: URL = SitePermissionStore.defaultFileURL) {
        self.fileURL = fileURL
        let saved = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: SitePermissionChoice].self, from: $0) }
        choices = saved ?? [:]
    }

    /// One blocked kind blocks the whole request, and every kind must be
    /// allowed for it to pass without asking.
    func decision(for kinds: [SitePermission], host: String) -> SitePermissionDecision {
        let answers = kinds.map { choice(for: $0, host: host) }
        if answers.contains(.block) { return .deny }
        if !answers.isEmpty, answers.allSatisfy({ $0 == .allow }) { return .grant }
        return .ask
    }

    func choice(for kind: SitePermission, host: String) -> SitePermissionChoice? {
        choices[Self.key(kind, host: host)]
    }

    func set(_ choice: SitePermissionChoice?, for kinds: [SitePermission], host: String) {
        for kind in kinds {
            choices[Self.key(kind, host: host)] = choice
        }
        save()
    }

    func removeAll() {
        choices = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(choices) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = fileURL
        try? url.setResourceValues(values)
    }

    private static func key(_ kind: SitePermission, host: String) -> String {
        "\(host.lowercased())|\(kind.rawValue)"
    }

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("site-permissions.json")
    }
}

/// What the browser keeps for websites. Open pages and history are the
/// reader's own and stay.
enum BrowserWebsiteData {
    // WebKit keeps named stores weakly. If the last tab releases its store,
    // the network session (including session cookies) can end. Tabs may sleep
    // or close without ending the user's browsing session, so keep each
    // container's store alive for the lifetime of the app.
    @MainActor private static var containerStores: [UUID: WKWebsiteDataStore] = [:]
    @MainActor private static var cookieSessions: [String: BrowserCookieSession] = [:]
    @MainActor private static var clearing: Task<Void, Never>?

    @MainActor
    static func dataStore(id: UUID?) -> WKWebsiteDataStore {
        let store: WKWebsiteDataStore
        if let id {
            store = containerStores[id] ?? WKWebsiteDataStore(forIdentifier: id)
            containerStores[id] = store
        } else { store = .default() }
        _ = cookieSession(for: store)
        Task { await prepare(store: store) }
        return store
    }

    @MainActor
    private static func cookieSession(for store: WKWebsiteDataStore) -> BrowserCookieSession {
        let key = store.identifier?.uuidString.lowercased() ?? "default"
        if let session = cookieSessions[key] { return session }
        let session = BrowserCookieSession(store: store, persistence: KeychainBrowserCookiePersistence(storeKey: key))
        cookieSessions[key] = session
        return session
    }

    @MainActor
    static func prepare(store: WKWebsiteDataStore) async {
        guard store.isPersistent else { return }
        // If iOS stopped a previous clear halfway through, finish clearing
        // WebKit as well as the checkpoint before allowing any page to load.
        if clearing == nil, KeychainBrowserCookiePersistence.clearIsPending { clearAll() }
        if let clearing { await clearing.value }
        await cookieSession(for: store).prepare()
    }

    @MainActor
    static func checkpoint(store: WKWebsiteDataStore) async {
        guard store.isPersistent, clearing == nil else { return }
        await prepare(store: store)
        await cookieSession(for: store).checkpoint()
    }

    @MainActor
    static func saveForBackground() {
        var identifier = UIBackgroundTaskIdentifier.invalid
        let finish = {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Save browser sign-ins", expirationHandler: finish)
        Task { @MainActor in
            if clearing == nil {
                for session in Array(cookieSessions.values) { await session.checkpoint() }
            }
            finish()
        }
    }

    /// The same container shares cookies across spaces within one Mozilla account.
    /// Keep the identifier stable when a space is renamed or a page is restored.
    static func storeID(accountID: String, container: String?) -> UUID? {
        guard let container, !container.isEmpty else { return nil }
        var bytes = Array(SHA256.hash(data: Data("z-sync.web-store:\(accountID):\(container)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    @MainActor
    static func clearAll() {
        guard clearing == nil else { return }
        KeychainBrowserCookiePersistence.beginClearAll()
        clearing = Task { @MainActor in
            _ = dataStore(id: nil)
            let identifiers: [UUID] = await withCheckedContinuation { continuation in
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
            }
            for identifier in identifiers { _ = dataStore(id: identifier) }
            for session in Array(cookieSessions.values) { await session.clear() }
            KeychainBrowserCookiePersistence.finishClearAll()
            clearing = nil
        }
        SitePermissionStore.shared.removeAll()
    }
}
