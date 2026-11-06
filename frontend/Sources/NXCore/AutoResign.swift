import Foundation

/// "Update the launcher when a device connects" (Settings): the shared app on a device that is connected by cable is signed and
/// installed again, as the hero's Re-sign does, once its provisioning profile runs out within `window`. A free Apple ID's profile
/// lasts 7 days, so that is when it is 5 days old. The Windows launcher does the same with its own signing tool
/// (frontend-qt/nspb_qt/win/install.py). LauncherView+AutoResign.swift asks `next` every two minutes.
package enum AutoResign {
    package static let defaultsKey = "autoUpdateLauncher"
    package static let window: TimeInterval = 2 * 24 * 3600

    /// A game whose app is on a device: the device's UDID and the app's profile expiry (nil when it could not be read).
    package struct Candidate: Equatable {
        package let id: UUID
        package let device: String
        package let expiry: Date?

        package init(id: UUID, device: String, expiry: Date?) { self.id = id; self.device = device; self.expiry = expiry }
    }

    /// Whether a profile that runs out at `expiry` is due. An unknown expiry never is, so an app whose profile cannot be read
    /// is not signed again at every tick.
    package static func due(expiry: Date?, now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry.timeIntervalSince(now) < window
    }

    /// The first game whose app is due on a device connected by cable now, nil when there is none.
    package static func next(_ games: [Candidate], wired: Set<String>, now: Date = Date()) -> Candidate? {
        games.first { !$0.device.isEmpty && wired.contains($0.device) && due(expiry: $0.expiry, now: now) }
    }
}
