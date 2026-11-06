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

1. **Certificate checks are on for the anisette server.** On Windows Impactor gets Apple's device headers
   ("anisette") from a remote server (`mac-ani.jkcoxson.com`, run by an Impactor and SideStore developer), and it
   accepted that server's TLS certificate without checking it. Anyone on the network could stand in for the
   server. It is now checked against the system's roots. Apple's own provisioning hosts (used only with a local
   Apple library, which Windows does not have) are checked against the system's roots plus Apple's root, as
   Impactor's main client does.
2. **The password prompt is hidden.** `plumesign account login` showed the password as it was typed.
3. **No debug log by default.** The debug level printed the developer services' replies (team, devices,
   certificates). The launcher also runs it with `RUST_LOG=info` and removes Apple IDs, device IDs and team IDs
   from its own log and from Copy diagnostics (`nspb_qt/win/signer.py` `redact`).

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
