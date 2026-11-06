import SwiftUI
import NXCore

// "Update the launcher when a device connects" (Settings, AutoResign in NXCore): every two minutes, the shared app on a device that
// is connected by cable and whose profile runs out within two days is signed and installed again, as the hero's Re-sign does
// (resign(_:)). One device per tick, never while a build or an install runs, and only while the switch is on (the default).

extension LauncherView {
    static let autoResignTimer = Timer.publish(every: 120, on: .main, in: .common).autoconnect()

    func autoResignTick() {
        guard UserDefaults.standard.object(forKey: AutoResign.defaultsKey) as? Bool ?? true, !m.running else { return }
        let games = library.games.filter(\.onDevice)
        guard !games.isEmpty else { return }
        let expiry = signatureExpiry
        Task { @MainActor in
            await devices.refresh().value
            guard !m.running else { return }
            let wired = Set(devices.devices.filter { $0.reachable && $0.wired }.map(\.id))
            let candidates = games.map { AutoResign.Candidate(id: $0.id, device: $0.installedDevice, expiry: expiry[$0.id]) }
            guard let pick = AutoResign.next(candidates, wired: wired),
                  let game = games.first(where: { $0.id == pick.id }) else { return }
            resign(game)
        }
    }
}
