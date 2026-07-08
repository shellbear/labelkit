import AppKit
import LabelKit

/// The bundle identifier LabelKit ships under (scripts/package-app.sh) —
/// used for instance discovery and the shared preferences domain.
let labelkitBundleID = "dev.shellbear.labelkit"

/// Preferences domain shared between the .app and the bare `labelkit`
/// binary (inline-UI fallback), so recents recorded in one show up in both.
func labelkitDefaults() -> UserDefaults {
    guard Bundle.main.bundleIdentifier != labelkitBundleID else { return .standard }
    return UserDefaults(suiteName: labelkitBundleID) ?? .standard
}

/// LabelKit is single-instance, like Preview: a second launch hands its
/// dataset to the running copy over a distributed notification and exits.
@MainActor
enum SingleInstance {
    static let openRequestNotification = Notification.Name("dev.shellbear.labelkit.open-request")

    /// A LabelKit.app instance other than this process, if one is running.
    static func runningInstance() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: labelkitBundleID)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    static func postOpenRequest(location: DatasetLocation, imageGlob: String?) {
        var info: [String: String] = [
            "imagesDirectory": location.imagesDirectory.path,
            "annotationsURL": location.annotationsURL.path,
        ]
        if let imageGlob { info["imageGlob"] = imageGlob }
        DistributedNotificationCenter.default().postNotificationName(
            openRequestNotification, object: nil, userInfo: info, deliverImmediately: true)
    }

    static func decodeOpenRequest(_ note: Notification) -> (location: DatasetLocation, imageGlob: String?)? {
        guard let info = note.userInfo,
              let directory = info["imagesDirectory"] as? String,
              let annotations = info["annotationsURL"] as? String else { return nil }
        let location = DatasetLocation(
            imagesDirectory: URL(fileURLWithPath: directory),
            annotationsURL: URL(fileURLWithPath: annotations),
            annotationsExists: FileManager.default.fileExists(atPath: annotations))
        return (location, info["imageGlob"] as? String)
    }

    /// Activate through LaunchServices — macOS 14+ cooperative activation
    /// denies terminal-spawned processes the right to raise other apps.
    static func activate(_ app: NSRunningApplication) {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", labelkitBundleID]
        do { try open.run() } catch { app.activate(options: [.activateAllWindows]) }
    }
}
