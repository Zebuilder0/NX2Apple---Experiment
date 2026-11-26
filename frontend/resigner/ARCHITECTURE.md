# NX2Apple Resigner: architecture

The Resigner is a second macOS app in the `frontend/` Swift package. It renews the signature of the NX2Apple shell (`DmShell.app`)
that the launcher already built and installs it over the copy on an iPhone or iPad. It builds no game and reads no game files.

This page records what the repository inspection found, which existing parts it reuses, and the decisions that follow from them.

## What the inspection found

### What "the NX2Apple shell" is

The app on the device is `DmShell.app` (display name NX2Apple, bundle ID `org.nxnative.shell` or the per-team variant
`org.nxnative.shell.<team>`). It is built in four steps (`frontend/Sources/NXCore/ShellInstall.swift`, `ShellExport.swift`):

1. The launcher builds each game into a framework, `DmGame<title ID>.framework`. This is the step that needs the NSP or XCI and
   `prod.keys`. The framework is mirrored into the shell root at `<root>/frameworks/`.
2. `shell.json` in the shell root (`ShellLibrary`) lists the games, the bundle ID and the team.
3. The engine's `dm/ios/tools/build_shell.sh --prepare-xcode` generates `<root>/project/DmShell.xcodeproj` with xcodegen. Its
   `Sources`, `Shell` and `tools` folders are symbolic links into the engine tree that generated it.
4. `xcodebuild ... -allowProvisioningUpdates DEVELOPMENT_TEAM=<team> PRODUCT_BUNDLE_IDENTIFIER=<id>` (`ShellInstall.buildCommand`)
   compiles, signs with automatic signing and writes `<root>/derived-data/Build/Products/Release-iphoneos/DmShell.app`.
   `devicectl device install app` (`ShellInstall.installCommand`) installs it.

The shell's library on the device is the set of game frameworks embedded in the app bundle (`frontend-ios/Sources/ShellHost/GameCatalogue.swift`
scans the embedded `<Name>.framework` folders that hold a `game.manifest.json`). The game data (`romfs.img`) and the saves are in the
app's Documents on the device, not in the bundle.

### Consequence for "no game frameworks"

A renewed shell has to contain the same game frameworks, because they are the games. A shell signed without them installs and keeps
Documents, but shows an empty library, and `build_shell.sh` refuses to generate a project with no framework (`[RED] no framework named`).
So the Resigner never builds or extracts a framework and needs no NSP, XCI, `prod.keys` or game dump, but it does need the frameworks
that are already on this Mac, inside the built `DmShell.app` and in the shell root. It signs them again as they are.

### The re-sign that already exists

`BuildStore.resignOnDevice` (`frontend/Sources/NXModel/BuildStore+Install.swift`) is the launcher's Re-sign button: it runs
`ShellInstall.buildCommand` on the cached project and derived data (Xcode reuses the compiled products and only signs again), then
`devicectl device install app` over the existing app. The Resigner's Xcode route is this command. It is not copied: the Resigner calls
`ShellInstall.buildCommand` and `ShellInstall.installCommand`.

### Other parts reused as they are

| Need | Existing code (NXCore unless noted) |
|---|---|
| Starting tools with argument arrays, never a shell | `ProcessRunner`, `ProcessLaunch`, `SystemProcessRunner` |
| Paired devices from `devicectl list devices` | `DeviceTools.devices` (the Resigner adds the fields it does not keep, see below) |
| Teams from the keychain and from Xcode's accounts | `DeviceTools.teams`, `certificateTeams`, `xcodeTeams`, `identities`, `team(fromSubject:)` |
| Profile expiry of a built app | `AppSignature.expiration(ofApp:)`, `daysLeft`, `describe` |
| The shell root, `shell.json`, the app path | `ShellLibrary.load`, `ShellLibrary.previewRoot`, `ShellInstall.appPath`, `ShellInstall.paths(ofApp:)`, `ShellRootMigration.defaultRoot` |
| Apps on the device, the shell's copies among them | `InstalledApps.listArguments`, `InstalledApps.parse`, `ShellInstall.shellApps` |
| The selected developer folder, the installed Xcode, the admin prompt | `Toolchain.developerDir`, `Toolchain.installedXcode`, `Toolchain.xcodeState`, `Toolchain.selectXcodeCmd` |
| xcodebuild's wording for two signing failures | `ShellInstall.memoryCapabilityMissing`, `BuildFailureClassifier.signingTeamTaken` |
| Interface text in every language | `Localizer` (NXModel), `frontend/l10n/*.json` |
| Colours, the Manrope face, buttons, cards, rows, dropdowns, switches, progress bar, window chrome | NXLauncher: `LauncherPalette`, `Typography`, `LauncherStyles`, `LauncherCard`, `LauncherDropdown`, `LauncherProgressBar`, `LauncherWindowChrome`, `PadFocus` |

Nothing in NXCore, NXModel or NXLauncher changes. The launcher builds and behaves as before.

### What did not exist

- A dependency check for signing (the launcher's `DependencyCheck` is about building games: Python, dotnet, the Metal toolchain).
- Reading identities without `-v`, so an invalid one is reported with its reason, and a certificate whose private key is missing.
- Reading and matching provisioning profiles (team, bundle ID, certificate, device, entitlements, expiry).
- Signing a built app with `codesign` and a chosen profile.
- Device readiness beyond paired and reachable: Developer Mode, the developer disk image services, an unpaired (untrusted) device.
- Checks after the install, a redacted log and a diagnostics export.

## Decisions

### Layers

Three targets in the frontend package, the same rules as the launcher's (`frontend/ARCHITECTURE.md`), and an executable of its own:

| Target | Holds | May import |
|---|---|---|
| `ResignerCore` | pure logic and services: the checks, the parsers, the matcher, the signing and install pipeline, the redaction | Foundation, NXCore |
| `ResignerModel` | `@MainActor` stores | Foundation, Combine, NXCore, NXModel, ResignerCore |
| `ResignerUI` (library) | the app: wiring, views, the `.p12` import (Security framework), the panels. Its one public name is `ResignerMain.run()` | all but NX2Apple, NXLauncher for the styles |
| `NX2AppleResigner` (package `frontend/resigner/app`) | `@main`, which calls `ResignerMain.run()` | ResignerUI |

Why the executable is a package of its own: a second executable in the frontend package would make a plain `swift run` there fail
("multiple executable products"), and `frontend/README.md`, `Onboarding.md` and `Console.md` start the launcher that way. In the
frontend package the Resigner still reaches the launcher's `package` types, which another package could not.

`ResignerCore` imports no SwiftUI, AppKit or Combine, and most of it builds on Linux too, which is how its tests were first run.
`ResignerModelTests` has a test that reads the imports, as `LayerImportsTests` does for the launcher.

### Two signing routes

1. **Xcode route** (automatic signing). `ShellInstall.buildCommand` on the launcher's cached project. Xcode creates or renews the
   provisioning profile (`-allowProvisioningUpdates`), which is the only supported way for a free Apple ID to get a new one. It needs
   the project, the mirrored frameworks the project names, the engine files its links point at, and the Apple ID signed in to Xcode.
2. **Profile route** (manual signing). The built `DmShell.app` is copied to a private temporary folder, the chosen profile is embedded,
   every embedded framework and then the app are signed with `codesign` and the chosen identity, and the copy is installed. It needs no
   Xcode project and no engine, only the built app, an identity and a profile that is valid for the bundle ID, the certificate and the
   device. It cannot make a profile. For a free Apple ID it works only while a profile Xcode made earlier is still valid.

"Automatic" (the default) takes the Xcode route when the project is usable and the profile route otherwise.

### Data on the device

- The Resigner never uninstalls. No command it can run removes an app (a test checks every command of the pipeline).
- It installs under the bundle ID the device already has. Installing an app with the same bundle ID over an installed one is an
  upgrade, and iOS keeps the app's data container (Documents, Library). This is how the launcher's install and re-sign have always
  worked. It is Apple's documented install behaviour, not something this branch verified on hardware.
- iOS refuses an upgrade whose `application-identifier` (`<team>.<bundle ID>`) differs from the installed app's. So the team must be
  the one the device's copy was signed with. When that team is known (`shell.json`, the last re-sign) and differs, the Resigner stops
  before installing. When devicectl reports the refusal, it explains it and stops. It never falls back to another bundle ID: the
  launcher's team variant would install a second, empty app, which is the opposite of a renewal.
- Before the install it lists the apps on the device. With no NX2Apple there, it asks for confirmation, because there is no data to
  keep and this is a first install. With NX2Apple there under another bundle ID only, it stops and says which ID to choose.

### Entitlements

The shell asks for `com.apple.developer.kernel.increased-memory-limit` unless the launcher generated it without (a team that cannot
carry it). The Resigner keeps every entitlement the app has. When the profile or the team cannot grant one, it stops and names it.
For the Increased Memory Limit only, it offers to sign without it after saying what that means (a large game may run out of memory).
That choice is per run and is written to the log. Nothing is stripped silently.

### Dependency check

`EnvironmentFacts` is what the probe read (tool output, files, exit codes). `DependencyEvaluator` turns the facts into rows, as a pure
function, so every case (Xcode missing, the Command Line Tools selected, the license not accepted, an invalid identity, an expired
profile, no device) is a test with made-up facts. The check runs when the app opens, when asked, before every re-sign (never from the
cache) and after a failure that names a dependency. It never installs or changes anything. A fix that changes the system (switching
the developer folder) is a button that asks for an administrator's password through macOS.

### Processes and secrets

- Every tool starts through `ProcessRunner` with an argument array. Nothing goes through `/bin/sh -c`.
- A `.p12` is imported with `SecItemImport` into the login keychain. Its password goes from the secure field to the Security framework and
  is never written to a log, a file, the defaults or a command line.
- The log is redacted as it is written: the home folder, the user name, email addresses, device UDIDs (all but the last four characters)
  and certificate holders' names. The diagnostics export is that log plus the dependency rows. It holds no key, certificate, profile
  or password.
- The profile route's copy and the trial signature's file are in folders of their own (mode 0700) in the user's temporary folder, named
  with a UUID, and removed when the run ends, failed or not. The Xcode route signs the launcher's own build in place, as the launcher's
  Re-sign does, and writes nothing else.

## Limits

- This branch was written and tested without a Mac or a device: the Core tests ran on Linux, the package built and its tests ran on
  the repository's macOS CI (Xcode 27.2). No signing with a real identity and no install on a real device has been run. See
  [README.md](README.md#what-was-tested).
- A free Apple ID's profile lasts 7 days. Renewing it needs Xcode and the Apple ID, which is the Xcode route. The profile route cannot
  renew a free profile.
- The Resigner reads the launcher's settings (`org.nxnative.NSPortBuilder`: `shellRoot`, `installDevice`, `signingTeam`) to start with
  the same folder, device and team. It never writes them.
