# The Windows launcher's signing tool

The Windows launcher installs the shared app on an iPhone or iPad without a sideloader the player has to run. It
signs the app with the player's Apple ID through **plumesign**, the command-line tool of
[Impactor](https://github.com/claration/impactor) (formerly PlumeImpactor). The launcher never sees the Apple ID
password: the player signs in once in plumesign's own console window, and Impactor keeps the session.

`build-qt.yml` builds `plumesign.exe` from source and puts it in the zip as `NX2Apple/tools/plumesign.exe`.
It does not download Impactor's release binary, which is not signed and has no published checksum.

| File | What it is |
|---|---|
| `pin` | The Impactor repository, version and commit the tool is built from. The workflow checks the commit. |
| `hardening.patch` | The changes made to that commit, below. |
| `LICENSE-impactor.txt` | Impactor's licence (MIT). Parts of it (`crates/plume_core`, `3rdparty/omnisette`, `3rdparty/apple-codesign-*`) are MPL-2.0: the source of the files changed here is this patch, and the rest is at the pinned commit. |

## What the patch changes, and why

These came out of a review of Impactor 2.7.2 before it went into the launcher (what it sends where, what it
stores, what it logs):

1. **Certificate checks are on for the anisette client.** On Windows Impactor gets Apple's device headers
   ("anisette") from a remote server (`mac-ani.jkcoxson.com`, run by an Impactor and SideStore developer), and
   the same client then provisions with Apple (`gsa.apple.com`). It accepted every certificate without checking
   it, so anyone on the network could stand in for either. It now checks them against the system's roots plus
   Apple Root CA (Impactor's own `crates/plume_core/src/apple_root.der`), as Impactor's main client does: Apple's
   hosts chain to Apple Root CA, which Windows does not trust by default. (The first version of this patch left
   Apple's root out, and sign-in stopped with "a root certificate which is not trusted by the trust provider".)
   In this build every HTTP client uses Windows' own TLS (SChannel, through native-tls: `plume_core` turns that
   feature on for the one reqwest all crates share), which accepts a chain that ends in a root passed this way.
   Apple's provisioning client for a local Apple library, which Windows does not have, gets the same roots.
2. **The password prompt is hidden.** `plumesign account login` showed the password as it was typed.
3. **No debug log by default.** The debug level printed the developer services' replies (team, devices,
   certificates). The launcher also runs it with `RUST_LOG=info` and removes Apple IDs, device IDs and team IDs
   from its own log and from Copy diagnostics (`nspb_qt/win/signer.py` `redact`).

And three that make the sign-in window work as the launcher opens it (`plumesign account login`, no options):

4. **`account login` alone asks.** It printed its help page when given no option, so the window showed the usage and
   closed.
5. **The Apple ID and two-factor prompts are prompts.** They were log lines followed by a bare read, and a log
   level above info hid them.
6. **The team is chosen at sign-in.** An Apple ID with several developer teams asked which one at every signing,
   which the launcher (no window) cannot answer. The sign-in window asks once and keeps the choice, and signing
   uses it.

What stays as Impactor has it, and the launcher says so in the Apple ID row:

- The password is never sent (Apple's SRP login) and never stored.
- The session token and the signing key are in `%APPDATA%\PlumeImpactor`, not encrypted, like most sideloading
  tools. **Sign out** in the launcher removes the session.
- The anisette server sees a device identifier and a provisioning blob, never the password or the tokens.

## Updating

1. Read the changes between the pinned commit and the new one, the way the review above did: hosts contacted,
   what is written to disk, what is logged.
2. Put the new commit and version in `pin`, and make the patch apply again (`git apply --3way`).
3. Run `build-qt.yml` (workflow_dispatch) and try a sign-in, an install and Sign out on a device.
