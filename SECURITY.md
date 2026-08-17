# Security

What MacLink can do, what protects it, and what it costs you. Written to be read before you decide
to keep it running, not after.

## What was installed on this Mac during development

Only one thing, and it is Apple's:

| Item | What it is | Reversible |
| --- | --- | --- |
| iOS 26.5 Simulator runtime | Official Apple platform download via `xcodebuild -downloadPlatform`, from Apple's CDN | `xcrun simctl runtime delete <id>` |
| `MacLink Host.app` | Built from this repo, lives in DerivedData | Delete the `.app` |

Nothing else. An attempt to `brew install xcodegen` **failed** (no network to `ghcr.io`) and installed
nothing — the Xcode project is hand-written instead. The iOS 18.6 simulator runtime that was already
on the disk was deleted to free space.

**Zero third-party code.** `Packages/MacLinkKit/Package.swift` declares no external dependencies. Both
apps link only Apple frameworks — Network, CryptoKit, Security, AppKit/UIKit, CoreAudio, IOKit. There
is no supply chain here to compromise, no analytics SDK, and no telemetry.

## What the Mac app can do

**Accessibility permission is the significant one.** It lets the app synthesise input — move the
pointer, click, type — anywhere in the system. This is the same permission Raycast, Rectangle and
Karabiner require, and it is unavoidable for a remote trackpad: it *is* the feature.

What it deliberately does **not** have:

- **No Screen Recording.** The app never sees your screen. It cannot screenshot, read windows, or
  observe what you are doing. (`screencapture` failed during testing precisely because this
  permission was never requested.)
- **No keystroke logging.** Input flows one way: phone → Mac. The Mac never reads your typing and the
  phone's keyboard field stores nothing — each keystroke is forwarded and discarded.
- **No Full Disk Access, no Contacts, Calendar, Photos, Camera, Microphone, or Location.**
- **No login items or background daemons** unless you switch on "Start at login" yourself.

**Clipboard** is read only when the phone explicitly asks, or when you turn on "Share clipboard
automatically" — which is **off by default** precisely because continuous clipboard sharing is a
privacy decision, not a convenience default.

**The app is not sandboxed.** It cannot be: a sandboxed app cannot post CGEvents. This is a genuine
reduction in containment versus a Mac App Store app, and you should weigh it. What limits the blast
radius is that the code is small, dependency-free, and in this repo where you can read all of it.

## Network exposure

- Listens on **one TCP port on the local link only**. No port forwarding, no UPnP, no relay server,
  no cloud account, no iCloud.
- `prohibitedInterfaceTypes = [.cellular]` means the OS cannot route the connection over the
  internet, even if it wanted to.
- Peer-to-peer (AWDL) is enabled so the phone can reach the Mac when they are near each other. AWDL
  is a **proximity radio link, not the internet** — it widens how two nearby devices reach each
  other, it does not open a path from anywhere else.
- A Mac in another building is unreachable. There is no code path that would let it be reached.

**Who can see it:** anyone on your Wi-Fi can see the Bonjour advertisement (your Mac's name) and
open a TCP connection to the port. That is the same exposure as AirPlay or file sharing. What they
cannot do is get past the handshake.

## How the link is protected

- **Pairing needs a human at the Mac.** An unknown device triggers a 6-digit code displayed on the
  Mac. Without it, the handshake fails and no token is issued.
- **Every session runs a fresh X25519 exchange**, authenticated by HMAC over a transcript hash of
  both sides' handshake fields. Tampering with any field — including the Mac's name — breaks the MAC.
- **After pairing, the credential is a random 32-byte token**, sealed under the session key in
  transit and kept in the Keychain on both ends. The 6-digit code is exposed exactly once, ever.
- **All traffic is ChaChaPoly**, keyed per direction with counter nonces. Replaying a captured record
  fails authentication.
- **Forward secrecy:** session keys come from ephemeral keys, so recording traffic today does not
  decrypt it later even if the stored token leaks.
- **Revocation:** *Settings → Devices → Revoke* drops the token and kills the live session
  immediately. The device must pair again with a fresh code.

These properties are covered by tests, including `LoopbackTests` rejecting a wrong code, a revoked
token, and a declined pairing over a real socket.

## Honest limitations

- **The 6-digit code is low entropy.** An attacker who is on your network *at the exact moment you
  pair* and captures that one handshake could brute-force it offline. The window is seconds, once.
- **No rate limiting on connection attempts.** Someone on your LAN could repeatedly trigger pairing
  prompts as a nuisance. Mitigation: turn off "Allow new devices to pair" once your phone is paired —
  the app then refuses unknown devices outright.
- **Not sandboxed** (see above).
- **Not audited.** This is a personal tool written for you, not a reviewed security product. I would
  not leave the host running on untrusted public Wi-Fi.

## The debug pairing-code file

Automated end-to-end testing cannot read a code off the screen, so debug builds can write the current
pairing code to a temp file. It is **doubly gated**: compiled out of release builds entirely, and even
in a debug build it does nothing unless explicitly switched on:

```bash
defaults write africa.myladder.maclink.host EnablePairingCodeFile -bool true
```

It is **off** on this machine — it was enabled for one verification run and turned off again, and the
file was deleted. Verify with:

```bash
defaults read africa.myladder.maclink.host EnablePairingCodeFile
```

`does not exist` is the answer you want.

## On the iPhone

- **One permission: Local Network.** Nothing else — no contacts, photos, location, camera, or
  microphone.
- The pairing token lives in the Keychain (`kSecAttrAccessibleAfterFirstUnlock`).
- No account, no analytics, no network access beyond the local link.
- What you type in the Keys tab is forwarded and discarded; it is never stored or logged.

## Why permissions keep resetting

Ad-hoc signing means the app's code signature changes on **every rebuild**, and macOS keys both
Accessibility and Local Network permission to that signature. After a rebuild the switch still looks
on in System Settings while the app is silently blocked.

The fix is a stable signing identity: set a Team on the `MacLinkHost` target. This is not a security
compromise — it is the opposite, it gives the app a stable verifiable identity instead of an
anonymous one.

## Removing everything

```bash
# 1. Quit and delete the app
pkill -f "MacLink Host"
rm -rf ~/Library/Developer/Xcode/DerivedData/MacLink-*

# 2. Forget the paired devices and host identity (Keychain)
security delete-generic-password -s africa.myladder.maclink.host 2>/dev/null

# 3. Forget preferences
defaults delete africa.myladder.maclink.host 2>/dev/null

# 4. Reclaim the simulator runtime, if you no longer want it
xcrun simctl runtime list
xcrun simctl runtime delete <identifier>
```

Then remove **MacLink Host** from *System Settings → Privacy & Security → Accessibility* and
*→ Local Network*. On the phone, delete the app; its Keychain token goes with it.
