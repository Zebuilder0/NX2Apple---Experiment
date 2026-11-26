# NX2Apple Resigner

A small Mac app that renews the signature of NX2Apple on your iPhone or iPad. Connect the device, check that everything is ready,
press **Re-sign & Install**. The app on the device is updated in place and keeps its games, saves and settings.

It is not a launcher, a game builder or an emulator. It never reads an NSP, an XCI, `prod.keys` or a game dump, and it never builds a
game. It signs again the NX2Apple app (`DmShell.app`) that the NX2Apple launcher already built on this Mac, with the game frameworks
that app already holds.

- How it works and why: [ARCHITECTURE.md](ARCHITECTURE.md)
- When something fails: [TROUBLESHOOTING.md](TROUBLESHOOTING.md)

## What you need

| | |
|---|---|
| Mac | Apple silicon. The app opens on macOS 13 or later, but Xcode sets the real minimum: use the macOS your Xcode asks for. |
| Xcode | 26 or later, opened once, its license accepted, with the iOS platform downloaded. The NX2Apple shell targets iOS 26. The Xcode that built your games (README.md names 27.2) is best: another one may compile the shell again before it signs. |
| Apple ID | For the usual way (**With Xcode**): the Apple ID that signed NX2Apple, signed in to Xcode under Xcode → Settings → Apple Accounts. A free Apple ID works, its signature lasts 7 days. |
| Or a certificate and a profile | For **With profile**: an Apple Development certificate with its private key in the keychain (or a `.p12` to import), and a provisioning profile for NX2Apple's bundle ID that lists your device and that certificate. |
| iPhone or iPad | iOS or iPadOS 26 or later, Developer Mode on (Settings → Privacy & Security → Developer Mode), trusting this Mac, connected by cable and unlocked. |
| NX2Apple | Built and installed once with the NX2Apple launcher on this Mac. The launcher's shell folder (`~/Library/Application Support/NX2Apple/shell` unless you moved it) holds `shell.json`, the Xcode project and the built app. |

The Resigner checks every row of this table itself (the **Diagnostics** page) before it signs anything.

## Build it

From a checkout of this repository, on a Mac with Xcode:

```bash
frontend/tools/build_resigner.sh
```

It writes `frontend/.build/resigner/NX2Apple Resigner.app` and a zip of it. The app is signed ad hoc, like an app from `tools/try-local`.
Copied to another Mac, it opens the first time with right-click, Open.

To run it without a bundle while working on it (its executable is a small package of its own, so `swift run` in `frontend/`
still starts the launcher):

```bash
swift run --package-path frontend/resigner/app
```

Without a checkout at hand, the **build resigner** workflow in the repository's Actions (Run workflow, on your branch) builds the same
app on GitHub's Mac and attaches it to the run as `NX2Apple-Resigner-macOS-arm64`.

The tests run with the launcher's: `cd frontend && swift test` (the `ResignerCoreTests` and `ResignerModelTests` targets).

## Use it

1. Connect the iPhone or iPad with a cable and unlock it.
2. Open NX2Apple Resigner. It checks Xcode, the command line tools, the certificate, the profile, the device and the shell folder.
   The dashboard says **Ready to renew**, or how many things to fix first. **Diagnostics** shows each one with what was found, why it
   matters and what to do, and a button where the Resigner can start the fix (an Apple download, Xcode's setup). A fix that changes
   the Mac's settings goes through macOS's administrator prompt. Nothing is installed or changed without your click.
3. Check the device, the team and the certificate on the dashboard. The defaults come from the NX2Apple launcher.
4. Press **Re-sign & Install** (Command-Return). The steps show as they run: checking the environment, detecting the device,
   validating the credentials, preparing the shell project, signing, verifying the signature, installing, verifying the install.
   **Stop** works until the install begins.
5. When it says **Renewed**, the signature on the device lasts until the date shown (7 days for a free Apple ID). Renew again before
   then. Renewing early is fine.

## The two ways to sign

**With Xcode** (the default when it can) does what the launcher's own Re-sign button does: Xcode signs the launcher's cached project
again (`xcodebuild ... -allowProvisioningUpdates DEVELOPMENT_TEAM=<team> PRODUCT_BUNDLE_IDENTIFIER=<id>`) and creates or renews the
provisioning profile itself. It reuses the compiled app, so it is quick, unless the project's build folder is gone or another Xcode
built it. It needs the project and the engine files the project points at. If the launcher's engine was updated or moved since,
use the other way or install a game again from the launcher.

**With profile** signs a copy of the built app with `codesign`, the certificate and the profile you choose. It needs no project and no
engine. It cannot make a profile: Apple makes profiles for Xcode or on the developer website, so with a free Apple ID this works only
while a profile Xcode made earlier is still valid.

**Automatic** takes **With Xcode** when the launcher's project is usable, **With profile** otherwise.

## Your data on the device

The Resigner installs over the existing app, under the bundle ID the device already has (`org.nxnative.shell`, or the team variant the
launcher may have used). That is an update: iOS keeps the app's Documents and Library, so the games' data, the saves and the settings
stay. It never uninstalls, and no button of it does.

iOS takes the update only from the team that signed the copy on the device. When the Resigner knows that team (from `shell.json` or
its last renewal) and another one is chosen, it stops before installing. When the device refuses for that reason, it says so and the
app on the device is left as it was. It never tries another bundle ID, because that would install a second, empty NX2Apple.

When the device has no NX2Apple, the Resigner asks before installing: there is nothing to keep, so this is a first install.

Data preservation is how iOS updates an app with the same bundle ID and team, and how the launcher's install and re-sign have always
worked. It was not verified on a device for this app (see below).

## Your credentials

- Signing uses the macOS keychain and Apple's tools (`codesign`, `security`, Xcode). No key, certificate or profile leaves this Mac.
- A `.p12` is imported with the Security framework into the login keychain. Its password is used for that call and not kept anywhere.
  codesign asks once whether it may use the new key. Always Allow saves the questions that follow.
- The log takes out your home folder, user name, email addresses, team and certificate holders' names and device IDs as it is written.
  **Export diagnostics** writes that log and the dependency rows to a text file. It holds no key, certificate, profile or password.
- Every tool starts with a fixed path and an argument list, never through a shell.

## What was tested

Tested:

- `ResignerCoreTests`, 94 tests, on Linux (Swift 6.2, NXCore without its Darwin-only files) and on the repository's macOS CI (Xcode 27.2):
  every case of the dependency check (Xcode missing, installed, outdated, the Command Line Tools selected, no license, no first launch,
  no iOS platform, no xcrun, no codesign, no identity, an invalid, revoked, untrusted or expired one, a certificate without its key,
  no profile, an expired one, one for another device, team or bundle ID, the Increased Memory Limit, no device, an untrusted, a
  disconnected or an old one, NX2Apple missing on the device or under another bundle ID, no shell folder, a broken project), and the
  whole run against a scripted stand-in for Apple's tools (both ways to sign, every stop, every install failure, the checks after it).
- `ResignerModelTests` on macOS CI: the settings, the check, Stop, the two questions, the record of the last renewal, the export.
- The package builds in release mode on macOS CI, and the app bundle is built by the **build resigner** workflow.

Not tested, because neither a Mac with your Apple ID nor a device was available when this was written:

- a signature with a real Apple Development identity and a real profile, on either route
- an install on a real iPhone or iPad, and that the data on it stays (expected from how iOS updates apps, not verified here)
- the `.p12` import against a real file
- the devicectl JSON of every Xcode version: the parser reads the fields of Xcode 26 and of Xcode 27.2's newer layout, as the launcher
  does, from sample files written for the tests, not captured from a device
- the look of the pages on a screen (they were compiled, not looked at)

Run it once with a device you can afford to set up again before relying on it.
