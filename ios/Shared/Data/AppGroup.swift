import Foundation

// The installed Preview app uses its own sandbox, without a Share extension.
// Keep this location and the keychain identity stable across TestFlight updates.
enum AppGroup {
    static let id = "group.com.benjaminlevin.zsync.preview"
    static let defaults = UserDefaults.standard

    static var container: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
}
