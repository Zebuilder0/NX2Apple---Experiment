# NX2Apple Resigner: troubleshooting

Start with the **Diagnostics** page: each row says what was found, why it matters and what to do. This page covers the same ground in
more words, and the failures that only show while signing or installing. **Export diagnostics** writes a redacted report to attach to
a question or an issue (it holds no key, certificate, profile or password).

## Xcode and its setup

**Xcode app: Missing.** Install Xcode from the App Store or from [Apple's downloads](https://developer.apple.com/download/all/?q=Xcode),
open it once, then Check again. A beta works too.

**Xcode version: Outdated.** The NX2Apple shell targets iOS 26, so it needs Xcode 26 or later. Keep the Xcode that built your games
when you can (README.md names 27.2): another Xcode makes the Xcode route compile the shell again.

**Active developer folder: Set up wrong.** `xcode-select` points at the Command Line Tools (`/Library/Developer/CommandLineTools`),
which cannot sign or install iOS apps. Two fixes:

- **Select this Xcode** switches the whole Mac. macOS asks for an administrator's password. It runs
  `xcode-select -s <Xcode>/Contents/Developer` and Xcode's first-launch setup.
- **Use for Resigner** (Settings, Xcode to use) makes only the Resigner use that Xcode, through `DEVELOPER_DIR`. Nothing of the Mac
  changes.

**Xcode license: Needs you.** Xcode's tools refuse to run until the license is accepted. Open Xcode and accept it, or press **Accept
license** (administrator's password).

**Xcode's first launch: Needs you.** Xcode still has components to install. Open it once, or press **Finish setup**.

**iOS platform: Missing.** Since Xcode 15 the iOS platform is a separate download of several GB. Press **Get iOS platform** or use
Xcode → Settings → Components. Only the Xcode route needs it.

## Command line tools

**Command line developer tools: Missing.** `xcrun` does not run. Install Xcode, or the Command Line Tools (**Install tools** shows
Apple's installer).

**codesign or security: Missing.** Both ship with macOS in `/usr/bin`. If one is missing, the system needs repair (reinstall macOS).

**devicectl: Missing or Outdated.** It comes with Xcode 15 and later.

## Code signing

**Signing team: Needs you.** No team is chosen, or the Xcode route has no Apple ID of that team signed in to Xcode. Sign in under
Xcode → Settings → Apple Accounts, then Check again.

**Same team as the device's copy: Set up wrong.** NX2Apple on the device was signed by another team. iOS updates an app only from the
team that signed it, so this renewal would be refused, and the only way around it would be deleting the app and its data. Choose that
team in Settings.

**Signing certificate.**

- *its private key is not on this Mac*: the certificate is in the keychain, its key is not. A certificate made on another Mac brings
  its key only in a `.p12`: on that Mac, Keychain Access, the certificate, Export, Personal Information Exchange (.p12). Import it in
  Settings, Import a certificate.
- *does not trust this certificate (CSSMERR_TP_NOT_TRUSTED)*: the Apple Worldwide Developer Relations intermediate certificate is
  missing or old. Install the current one from [Apple's certificate page](https://www.apple.com/certificateauthority/).
- *expired* or *revoked*: make a new Apple Development certificate in Xcode → Settings → Apple Accounts → Manage Certificates.
- On the Xcode route a missing certificate is not a problem: Xcode makes one for a signed-in account when it signs.

**Signing check.** **Try signing** signs a small test file with the certificate (it runs by itself before every signature with a
profile).

- *codesign may not use the private key now*: the login keychain is locked, or access to the key was refused. Unlock the keychain.
  When macOS asks whether codesign may use the key, choose Always Allow.
- *the keychain has the certificate but not its private key*: see above.

## Provisioning

**Provisioning profile, on the Xcode route.** Xcode creates or renews it when it signs. The row shows the profile of the app on this
Mac and its expiry.

**Provisioning profile, on the profile route.** The profile must be for NX2Apple's bundle ID (or a wildcard that covers it), of the
chosen team, include the chosen certificate and the device, grant the app's entitlements and be valid. The row names the first thing
that does not fit. Profiles are read from `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and
`~/Library/MobileDevice/Provisioning Profiles`. A profile downloaded from the developer website goes there when you open it.

**Entitlements: the Increased Memory Limit.** The shell asks for `com.apple.developer.kernel.increased-memory-limit`. A free Apple ID
cannot carry it, nor a paid team whose account holder has not accepted Apple's latest agreement. The Resigner stops and says so. You
may then choose **Sign without it** for that one run: NX2Apple installs and runs, but a large game may run out of memory. The choice is
not remembered, and the log records it.

## Device

**No iPhone or iPad is paired with this Mac.** Connect it with a cable and unlock it. Check again.

**The device does not trust this Mac yet.** Unlock it, tap Trust and enter its passcode.

**Developer Mode is off.** Settings → Privacy & Security → Developer Mode, turn it on, restart the device, confirm.

**Xcode has not prepared the device yet.** Keep it connected and unlocked for a minute: Xcode mounts its developer disk image then.

**The device runs an older iOS than 26.** The NX2Apple shell cannot run there.

**NX2Apple on the device: none.** The device has no NX2Apple, so there is nothing to keep. The Resigner asks before installing
(**Install anyway**). With a free Apple ID, trust the developer app once on the device afterwards: Settings → General → VPN & Device
Management.

**NX2Apple on the device: under another bundle ID.** The launcher may have installed it as `org.nxnative.shell.<team>`. Choose that
bundle ID in Settings, Device and app, Bundle ID.

## NX2Apple shell

**Shell folder: Missing.** Build and install a game once with the NX2Apple launcher, or choose the right folder in Settings (the
launcher's Settings, Move cache folder, may have moved it).

**Built NX2Apple app: no game, or a game is incomplete.** The Resigner signs the games the built app holds and never builds one.
Build that game again in the launcher.

**Launcher's Xcode project: Set up wrong.** The project's links into the engine point at files that are gone, usually because the
launcher's engine was updated or moved. Use **With profile**, or install a game again from the launcher, which makes the project
again. Without its build folder (`derived-data`) the project still works, but Xcode compiles the whole shell, which takes long.

## While signing

| The Resigner says | Cause | What to do |
|---|---|---|
| Team cannot carry the Increased Memory Limit | Free Apple ID, or a paid team without the latest agreement accepted | Sign without it for this run, or add the capability to the app ID of a paid team |
| The bundle ID is registered to another team | `org.nxnative.shell` belongs to another team | Sign with that team. A different bundle ID would make a second, empty app, so the Resigner does not try one |
| Xcode has no account for team | No Apple ID of that team in Xcode | Xcode → Settings → Apple Accounts |
| The Apple ID has to sign in to Xcode again | The session expired | Sign in again in Xcode → Settings → Apple Accounts |
| A new Program License Agreement | The account holder has not accepted it | Accept it at developer.apple.com |
| The team has reached its limit of registered devices | Too many devices on the account | Remove one at developer.apple.com or use another team |
| Xcode cannot use the device now | Locked, busy or not prepared | Unlock it, keep it connected, try again |
| Xcode is missing files of the launcher's project | The engine moved or was updated | With profile, or install a game again from the launcher |
| codesign may not use the private key | Locked keychain or refused access | Unlock the keychain, choose Always Allow |
| The signature does not verify | The built app is damaged | Build a game again in the launcher |

The tool's own last line is shown under the message and is in the log.

## While installing

| The Resigner says | Cause | What to do |
|---|---|---|
| The device refused the update, another team | The copy on the device was signed by another team | Sign with that team. The app and its data on the device are unchanged |
| The profile does not include this device | A profile without the device | The Xcode route adds the device, or use a profile that lists it |
| The device is locked | Locked during the install | Unlock it and try again |
| Developer Mode is off | | Turn it on and restart the device |
| Not enough free space | The device is full | Free space on the device |
| The install reported success, but the app is not listed | The device did not keep the install | Check again, then look at the log |

## After the install

**iOS says the developer is not trusted.** Settings → General → VPN & Device Management, your Apple ID, Trust. Needed once per
developer, usually after a first install with a free Apple ID.

**The app opens but says its signature expired.** The renewal did not reach this device or another team signed it. Renew it again and
check that the dashboard's device is this one.

## Logs

The log on the dashboard is short by default: the commands, the errors and the results. Settings, Detailed log, puts every line of the
tools in it (still redacted). **Copy log** and **Export diagnostics** give it to you as text.
