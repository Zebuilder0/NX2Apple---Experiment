import Foundation
import NXCore

/// An iPhone or iPad as `devicectl list devices` describes it, with what the launcher's `AppleDevice` leaves out: an unpaired
/// (untrusted) device is kept, and Developer Mode, the developer disk image services and the tunnel are read.
package struct DeviceStatus: Equatable, Sendable, Identifiable {
    package var udid: String
    package var name: String
    package var model: String
    package var productType: String
    /// "iPhone", "iPad", or what devicectl says.
    package var deviceType: String
    package var osVersion: String
    package var pairingState: String
    package var transport: String
    package var tunnelState: String
    /// nil when devicectl does not say.
    package var developerMode: Bool?
    package var ddiServicesAvailable: Bool?
    package var bootState: String

    package init(udid: String, name: String, model: String = "", productType: String = "", deviceType: String = "", osVersion: String = "",
                 pairingState: String = "paired", transport: String = "", tunnelState: String = "", developerMode: Bool? = nil,
                 ddiServicesAvailable: Bool? = nil, bootState: String = "") {
        self.udid = udid; self.name = name; self.model = model; self.productType = productType; self.deviceType = deviceType
        self.osVersion = osVersion; self.pairingState = pairingState; self.transport = transport; self.tunnelState = tunnelState
        self.developerMode = developerMode; self.ddiServicesAvailable = ddiServicesAvailable; self.bootState = bootState
    }

    package var id: String { udid }
    package var paired: Bool { pairingState == "paired" }
    package var connected: Bool { !transport.isEmpty }
    package var wired: Bool { transport == "wired" }
}

package enum DeviceInventory {
    /// The physical iOS devices of the listing, connected ones first. Xcode 27.2 moved the fields into `properties` (connection,
    /// hardware, software, state) and a device may carry only that, so the old block is read and the new one fills what it lacks,
    /// as `DeviceTools.parseDevices` does.
    package static func parse(_ data: Data) -> [DeviceStatus] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any], let list = result["devices"] as? [[String: Any]] else { return [] }
        let found: [DeviceStatus] = list.compactMap { d in
            let new = d["properties"] as? [String: Any] ?? [:]
            func block(_ old: String, _ key: String) -> [String: Any] {
                (d[old] as? [String: Any] ?? [:]).merging(new[key] as? [String: Any] ?? [:]) { old, _ in old }
            }
            let hardware = block("hardwareProperties", "hardware")
            let connection = block("connectionProperties", "connection")
            let device = (d["deviceProperties"] as? [String: Any] ?? [:])
                .merging(new["state"] as? [String: Any] ?? [:]) { old, _ in old }
                .merging(new["software"] as? [String: Any] ?? [:]) { old, _ in old }
            guard hardware["reality"] as? String != "simulated", hardware["platform"] as? String == "iOS",
                  let udid = hardware["udid"] as? String, !udid.isEmpty else { return nil }
            let os = device["osVersionNumber"] as? String
                ?? (device["osVersionNumber"] as? [String: Any])?["stringValue"] as? String ?? ""
            var developerMode: Bool?
            if let status = device["developerModeStatus"] as? String { developerMode = status == "enabled" }
            else if let flag = device["developerModeStatus"] as? Bool { developerMode = flag }
            return DeviceStatus(udid: udid, name: device["name"] as? String ?? udid, model: hardware["marketingName"] as? String ?? "",
                                productType: hardware["productType"] as? String ?? "", deviceType: hardware["deviceType"] as? String ?? "",
                                osVersion: os, pairingState: connection["pairingState"] as? String ?? "unpaired",
                                transport: connection["transportType"] as? String ?? "", tunnelState: connection["tunnelState"] as? String ?? "",
                                developerMode: developerMode, ddiServicesAvailable: device["ddiServicesAvailable"] as? Bool,
                                bootState: device["bootState"] as? String ?? "")
        }
        return found.sorted { ($0.connected ? 0 : 1, $0.name) < ($1.connected ? 0 : 1, $1.name) }
    }

    /// The listing's arguments after `xcrun` (the probe writes the JSON to a temporary file).
    package static func listArguments(json: String) -> [String] { ["devicectl", "list", "devices", "--json-output", json] }
}

/// What keeps a device from taking the renewed app now.
package enum DeviceIssue: Equatable, Sendable {
    case notConnected
    case notPaired
    case developerModeOff
    case notPrepared
    case osTooOld(found: String, needed: String)

    package var text: LocalText {
        switch self {
        case .notConnected: return LocalText("resigner.device.notConnected")
        case .notPaired: return LocalText("resigner.device.notPaired")
        case .developerModeOff: return LocalText("resigner.device.developerModeOff")
        case .notPrepared: return LocalText("resigner.device.notPrepared")
        case .osTooOld(let found, let needed): return LocalText("resigner.device.osTooOld", found, needed)
        }
    }

    /// The developer disk image services come up once Xcode has prepared a connected, unlocked device: a hint, not a stop.
    package var blocking: Bool { self != .notPrepared }
}

package enum DeviceReadiness {
    /// The shell's deployment target (project-shell.yml `deploymentTarget: iOS: "26.0"`), used when the built app says nothing.
    package static let shellMinimumOS = "26.0"

    package static func issues(_ device: DeviceStatus, minimumOS: String = shellMinimumOS) -> [DeviceIssue] {
        var out: [DeviceIssue] = []
        if !device.paired { out.append(.notPaired) }
        if !device.connected { out.append(.notConnected) }
        if device.developerMode == false { out.append(.developerModeOff) }
        if device.connected, device.paired, device.ddiServicesAvailable == false { out.append(.notPrepared) }
        if let found = VersionNumber(device.osVersion), let needed = VersionNumber(minimumOS.isEmpty ? shellMinimumOS : minimumOS), found < needed {
            out.append(.osTooOld(found: device.osVersion, needed: minimumOS.isEmpty ? shellMinimumOS : minimumOS))
        }
        return out
    }
}

/// What the device's apps say about the install about to happen.
package enum InstallTargetCheck: Equatable {
    /// NX2Apple is on the device under this bundle ID: the install is an upgrade, its data stays.
    case upgrade(InstalledApp)
    /// No NX2Apple on the device: a first install, with no data to keep.
    case firstInstall
    /// NX2Apple is on the device, but only under other bundle IDs: installing under this one would add a second, empty app.
    case otherBundleOnly([InstalledApp])

    package static func decide(bundleID: String, apps: [InstalledApp]) -> InstallTargetCheck {
        if let same = apps.first(where: { $0.bundle == bundleID }) { return .upgrade(same) }
        let shells = ShellInstall.shellApps(in: apps)
        return shells.isEmpty ? .firstInstall : .otherBundleOnly(shells)
    }
}
