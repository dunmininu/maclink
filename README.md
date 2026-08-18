# MacLink

Turn your iPhone into a trackpad, keyboard and control surface for your Mac — over your local
network only.

Two apps in one Xcode project:

| Target | Product | What it is |
| --- | --- | --- |
| `MacLink` | `MacLink.app` (iOS 17+) | The phone app: trackpad, keyboard, media, system controls |
| `MacLinkHost` | `MacLink Host.app` (macOS 14+) | A menu bar app on the Mac that receives events and replays them as real input |

Shared protocol, discovery, and crypto live in `Packages/MacLinkKit`, a local Swift package both
targets depend on.

---

## Local only, the way Continuity is

MacLink reaches a Mac that is *next to you*, and nothing else. That is not a policy check bolted on
top — it falls out of how the link is built, in three places:

1. **Discovery is Bonjour/mDNS** (`_maclink._tcp`). mDNS is link-local by design: it does not cross
   routers, so a Mac somewhere else on the internet is never even visible.
2. **Peer-to-peer is on.** `NWParameters.includePeerToPeer = true` on both ends lets Network.framework
   use AWDL — the same direct Wi-Fi radio link AirDrop rides on. So the phone and the Mac find each
   other when they are near each other, even with no shared Wi-Fi, no router, and no infrastructure
   at all. This is the bit that makes it feel like the rest of the Apple ecosystem.
3. **Cellular is prohibited.** `prohibitedInterfaceTypes = [.cellular]` is what keeps it local.

The distinction between 2 and 3 is the whole design, and it is worth being precise about: **AWDL is a
proximity radio link, not the internet.** Turning peer-to-peer on widens *how* two nearby devices
reach each other; it does not open a path from anywhere else. Excluding cellular means the OS can
never route this connection off the local link. So there is still no relay server, no account, no
iCloud, and no route from the outside world to your Mac — a Mac in another building is unreachable
whatever an attacker does.

[`TransportParameterTests`](Packages/MacLinkKit/Tests/MacLinkKitTests/TransportParameterTests.swift)
asserts all of this, so a future change cannot quietly undo it.

## Security

Anyone else on your café Wi-Fi can see the Bonjour advertisement too, so the link is authenticated
and encrypted:

- **Pairing.** The first time a phone connects, the Mac shows a random 6-digit code in a floating
  window. You type it on the phone. Nothing else gets in — the Mac's owner has to physically approve.
- **Key exchange.** Every session runs a fresh X25519 ECDH. The exchange is authenticated by HMAC
  over a transcript hash of both sides' handshake fields, keyed by the shared credential. Tampering
  with any field — including the Mac's name — breaks the MAC.
- **Tokens.** On successful pairing the Mac mints a random 32-byte token, seals it under the session
  key, and the phone keeps it in the Keychain. Later sessions authenticate with that token instead
  of a code, so the 6-digit code is only ever exposed once.
- **Records.** Everything after the handshake is ChaChaPoly, keyed per direction, with a counter
  nonce. Replaying a captured record fails authentication.
- **Forward secrecy.** Session keys come from ephemeral keys, so a recorded session cannot be
  decrypted later even if the stored token leaks.
- **Revocation.** *Settings › Devices › Revoke* on the Mac drops the token and kills the live
  session. The phone then has to pair again with a fresh code.

Honest limits: the 6-digit code is low entropy, so an attacker who is on your network *at the moment
you pair* and who captures that one handshake could brute-force it offline. That window is a few
seconds, once. After pairing, the credential is a full 32-byte token. This is a hobby-grade LAN
remote, not a hardened remote-access product — I would not leave the host running on untrusted
public Wi-Fi.

---

## Getting it running

### 1. The Mac app

```bash
xcodebuild -scheme MacLinkHost -destination 'platform=macOS' -configuration Debug build
```

Then launch the built app:

```bash
open ~/Library/Developer/Xcode/DerivedData/MacLink-*/Build/Products/Debug/"MacLink Host.app"
```

Or just open `MacLink.xcodeproj` and press ⌘R with the `MacLinkHost` scheme selected.

It appears in the menu bar as a pointer icon — there is no Dock icon or main window (`LSUIElement`).

### 2. Grant Accessibility permission

**Nothing will move until you do this.** macOS blocks synthetic input events unless the app is
trusted. The app prompts on first launch; if you miss it:

*System Settings › Privacy & Security › Accessibility* → enable **MacLink Host**.

The menu bar popover shows an orange banner and a shortcut button until this is granted, and the
phone gets an explicit error message rather than silently doing nothing.

> **Sign the Mac app with a real certificate, or this resets on every rebuild.** Accessibility trust
> is keyed to the code signature. Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) produces a different
> signature each build, so macOS silently drops the grant — and worse, System Settings still shows
> the switch as *on* while it no longer applies. Set a Team on the `MacLinkHost` target and build
> with your Development certificate; the grant then survives rebuilds.
>
> If a grant ever gets stuck — toggling does nothing — clear the stale entry rather than fighting it:
>
> ```bash
> tccutil reset Accessibility africa.myladder.maclink.host
> ```
>
> Then relaunch the app and approve the fresh prompt. Note that **a full disk also breaks this**: TCC
> cannot write its database, so the switch appears to move and nothing persists.

### 2b. Grant Automation permission

Mission Control, Spaces, App Exposé, the app switcher, screenshots and screen lock need a *second*
permission, separate from Accessibility. macOS asks the first time one is used:

*System Settings › Privacy & Security › Automation* → **MacLink Host** → enable **System Events**.

Why two permissions, when Accessibility already allows synthetic input: these particular actions are
**symbolic hotkeys**, dispatched by machinery that on macOS 26 ignores synthetic events entirely.
Measured on 26.5 — posting `⌃↑` through `CGEvent` does nothing with flags alone, nothing with genuine
modifier key events alongside it, and nothing with the keystroke spaced out in time. Driving System
Events through Apple Events does work, because the keystroke arrives as a script would deliver it
rather than being injected at the HID layer. See
[`SystemEventsBridge`](Apps/macOS/Sources/Input/SystemEventsBridge.swift).

Without this grant these commands fail *silently*, which reads as a broken feature rather than a
missing permission — so the host writes the failure into its activity log, and the menu bar tracks
the grant alongside Accessibility.

> **Launchpad is gone as of macOS 26.** Apple removed it; there is no `Launchpad.app` to open. That
> command sends F4, which is what the hardware Launchpad key sent and reaches the Applications view
> that replaced it. On older macOS it opens Launchpad proper.

### 3. The iOS app

Open `MacLink.xcodeproj`, select the `MacLink` scheme and a Simulator, and run. This works today —
the iOS 26.5 platform is installed.

> **If you ever see *"iOS 26.5 is not installed"*** and no Simulator destinations at all, the iOS
> platform is missing. Both Simulator *and* physical-device builds are gated on it. Reinstall with:
>
> ```bash
> xcodebuild -downloadPlatform iOS -architectureVariant arm64
> ```
>
> `arm64` halves the download to ~8.5 GB. Check headroom first with `scripts/free-space.sh` — an
> installed runtime costs its download plus an expanded image.

To run on your actual iPhone you need a signing team — see [Signing](#signing). Note that the
Simulator is a poor test for this app specifically: it has no multi-touch, so scroll, right-click and
pinch cannot be exercised there. The trackpad really needs a physical phone.

### 4. Pair

There is a setup wizard on both ends, so this is close to automatic:

1. **On the Mac**, MacLink Host opens a welcome window on first launch. It walks you through the one
   permission it needs and flips to "granted" by itself once you switch it on — no coming back to
   confirm. Reopen it any time from the menu bar with *Setup Guide…*.
2. **On the phone**, MacLink opens its wizard. It watches for your Mac and moves on the moment it
   appears. If there is exactly one Mac, it connects without asking.
3. Type the 6-digit code the Mac shows. That is the only thing you have to do by hand, and it exists
   precisely to prove a person is standing at the Mac.
4. If the Mac still needs Accessibility, the wizard says so and finishes on its own once granted.

Future launches reconnect silently — the wizard never appears again.

---

## What the phone can do

**Trackpad tab**
- Drag to move the cursor, with speed-sensitive acceleration
- Tap to click · two-finger tap to right-click · three-finger tap for middle-click
- Tap-then-hold-and-drag to drag things (the button stays down)
- Two fingers to scroll, with proper scroll phases so Safari rubber-bands like a real trackpad
- Pinch to zoom
- Three-finger swipes: up = Mission Control, down = App Exposé, left/right = switch Spaces
- Physical left/middle/right buttons underneath for press-and-hold drag selection

**Keys tab**
- A real text field that forwards every keystroke, including backspace and return, and stores
  nothing on the phone. Autocorrect and smart quotes are off so typing into a terminal or editor is
  not silently rewritten.
- Sticky ⌘ ⇧ ⌥ ⌃ fn modifiers that apply to the next key
- esc, tab, delete, forward delete, return, arrows, home/end, page up/down
- One-tap ⌘C ⌘V ⌘X ⌘A ⌘Z ⇧⌘Z ⌘S ⌘F ⌘T ⌘W ⌘Q ⌘Space

**Media tab**
- Play/pause, next, previous
- Volume slider (sets the real output volume via CoreAudio), plus up/down/mute keys
- Screen and keyboard backlight brightness

**More tab**
- Presentation mode: big previous/next buttons, black screen, start, exit
- Mission Control, App Windows, Launchpad, Show Desktop, Spaces, app switching, close window, quit
- Screenshot (full and region), Lock Screen, Sleep Display, Sleep Mac
- Clipboard: pull the Mac's clipboard to the phone, or push the phone's to the Mac
- Settings: pointer speed, scroll speed, natural scrolling, tap-to-click, haptics, keep-awake

**Status, always visible**
- Which Mac you are driving, its frontmost app, and its battery level

## Getting it onto your iPhone

The Simulator is enough to check layout and the connection, but not the trackpad — it has no
multi-touch, so scroll, right-click and pinch are unreachable there. Here is the path to a real
phone.

### 0. Install the iOS platform (required — no way around it)

Building for a **physical iPhone needs the same platform download as the Simulator**. Both
destinations are gated on it:

```
{ platform:iOS, name:Any iOS Device, error:iOS 26.5 is not installed. }
```

So going device-only does not skip the download. Install it once:

```bash
xcodebuild -downloadPlatform iOS -architectureVariant arm64
```

`-architectureVariant arm64` skips the Intel slices and roughly halves the size (8.5 GB instead of
~15 GB) — correct for any Apple Silicon Mac. Or use *Xcode → Settings → Components*.

> **Disk space.** This machine runs at ~93% full. An installed runtime costs its 8.5 GB asset plus
> an expanded image, so check you have headroom before starting. `scripts/free-space.sh` reports
> what is reclaimable.

### 1. Add your Apple ID to Xcode

*Xcode → Settings → Accounts → + → Apple ID.* A **free** Apple ID is enough — it gives you a
"Personal Team" that can sign apps for your own devices. You do not need the $99/year Developer
Program, though see the 7-day limit below.

### 2. Set the team on the iOS target

Open `MacLink.xcodeproj` → select the project → **MacLink** target → *Signing & Capabilities*:

- Tick **Automatically manage signing**
- Set **Team** to your Personal Team

If Xcode complains the bundle identifier is unavailable, change it — it must be globally unique.
`africa.myladder.maclink` should be fine since it is your own domain, but anything like
`com.yourname.maclink` works:

```
PRODUCT_BUNDLE_IDENTIFIER = com.yourname.maclink
```

### 3. Plug in the phone and run

1. Connect the iPhone by USB. On the phone, tap **Trust This Computer** and enter your passcode.
2. In Xcode, pick your iPhone from the destination menu (top bar, next to the scheme).
3. Press ⌘R.

The first build will fail to launch with *"Untrusted Developer"*. On the phone go to
**Settings → General → VPN & Device Management → Developer App**, tap your Apple ID, and
**Trust**. Then hit ⌘R again.

After the first successful run you can enable *Xcode → Window → Devices and Simulators → Connect via
network* and drop the cable.

### 4. First launch on the phone

iOS will ask **"MacLink would like to find and connect to devices on your local network."** You must
allow this — it is the whole app. If you dismiss it by accident, re-enable it under
*Settings → MacLink → Local Network*.

### Keeping it signed automatically

A free Apple ID signs an app for 7 days. Rather than remembering that, install the agent:

```bash
./scripts/install-resign-agent.sh
```

It checks daily at 04:00 and re-signs when the signature is 5+ days old *and* your iPhone happens to
be connected — so plugging in overnight once a week is enough. Reinstalling over the same bundle id
keeps the app's data and its pairing token, so nothing resets.

It stays quiet in the normal cases (too soon, phone not attached) and only notifies when a person
actually has to do something: the signature is nearly out and the phone has not been seen, or a
re-sign failed.

```bash
./scripts/install-resign-agent.sh status      # is it loaded, and what has it done
./scripts/install-resign-agent.sh uninstall   # stop it
```

State and log live in `~/Library/Application Support/MacLink/`.

> **Careful with `xcrun simctl runtime delete all`.** Xcode gates *all* iOS builds — Simulator and
> physical device alike — on the iOS platform being installed, and the platform is bundled with its
> simulator runtime. Deleting the runtime to reclaim disk therefore also removes the ability to build
> for a real iPhone, and the auto-resign agent will report that it cannot build. Restore it with
> `./scripts/download-ios-platform.sh`.

### What to expect from a free account

| | Free Apple ID | Developer Program ($99/yr) |
| --- | --- | --- |
| App lifetime on device | **7 days**, then it refuses to launch | 1 year |
| Renewing | Automatic, via `install-resign-agent.sh` | Automatic, once a year |
| Devices | 3 apps at a time, limited registrations | 100 devices |
| TestFlight / App Store | No | Yes |

Note an iCloud subscription is unrelated — that is storage. Signing comes from the Apple Developer
Program, a separate paid product. Neither tier is permanent: the paid one just moves re-signing from
weekly to yearly. With the agent installed the free tier is unattended anyway, so the paid account is
only worth it for TestFlight or putting this on other people's phones.

### Also worth doing: sign the Mac app properly

While you are in there, do the same for the **MacLinkHost** target — set *Team* and switch the
signing certificate from ad-hoc (`-`) to your Development certificate. Accessibility trust is keyed
to the code signature, so with ad-hoc signing macOS forgets the permission on **every rebuild**. A
stable certificate makes the grant stick.

## Signing summary

Out of the box, with no identities configured:

- The Mac app ad-hoc signs and runs locally (re-granting Accessibility after each rebuild).
- The iOS app cannot build for the Simulator *or* a device until the iOS platform is installed
  (step 0 above), and cannot install on a physical iPhone until a team is set.

## Layout

```
MacLink.xcodeproj
Packages/MacLinkKit/          shared: wire protocol, framing, crypto, discovery, transport
  Sources/MacLinkKit/
    Protocol.swift            every message both ends can send
    Crypto.swift              X25519 + HKDF key schedule, ChaChaPoly record cipher
    Handshake.swift           the pair/resume state machine, both roles
    LinkChannel.swift         length-prefixed framing over NWConnection
    HostServer.swift          NWListener + Bonjour advertisement (Mac side)
    ClientLink.swift          NWBrowser + connection (phone side)
    SecretStore.swift         Keychain-backed JSON store
  Tests/MacLinkKitTests/      crypto unit tests + loopback end-to-end tests
Apps/iOS/Sources/             the phone app (SwiftUI + a UIKit multi-touch surface)
Apps/macOS/Sources/           the menu bar host (SwiftUI + CGEvent synthesis)
```

## Tests

```bash
./scripts/verify.sh
```

Runs the package tests, builds the Mac app, and compile-checks the iOS app.

The 20 package tests (`cd Packages/MacLinkKit && swift test`) cover the key schedule, MAC
verification, record encryption (including replay and tamper rejection), message coding, and — in
`LoopbackTests` — a real `HostServer` and `ClientLink` talking over a real TCP socket: pairing with
a code, resuming with a stored token, ordered delivery of every message type over the encrypted
channel, and rejection of a wrong code, a revoked token, and a declined pairing.

## What has actually been verified

Run end to end on 2026-08-16, iOS app in the Simulator driving the real Mac host:

**Verified working**
- 24 package tests, including the full loopback handshake and encrypted message round trip.
- The Mac host builds, launches, and advertises `_maclink._tcp` on every active interface.
- The iOS app builds against the real iOS SDK, launches, and renders.
- The phone **discovers the Mac over Bonjour** and connects.
- The link carries **live status**: host name, frontmost app, battery, volume, Accessibility state.
- **The pointer actually moves.** Measured on a two-display setup: a 150 pt horizontal swipe moved
  the cursor 148 px, a 170 pt vertical swipe moved it 181 px, each axis independent, and motion
  clamps correctly at the edge of the display union.
- Reconnecting is automatic — relaunching the app goes straight to the trackpad with no interaction.

**Still unverified**
- Multi-touch gestures: scroll, right-click (two-finger tap), pinch-to-zoom and three-finger swipes.
  The Simulator injects one finger at a time, so these cannot be exercised there at all. They need a
  real phone.
- Gesture *feel* — pointer acceleration constants and haptics are still tuned by judgement, not use.

### Two bugs this found

Worth recording, because both were invisible to the tests:

1. **The UI never left the host list even though the link was connected.** `RemoteSession.isConnected`
   read `link.isConnected`, and `ClientLink` is a plain class — Observation cannot see through it, so
   SwiftUI never invalidated the view. It now derives from the `linkState` stored property. A
   protocol-level test could never have caught this; only running the app did.
2. **A peer-to-peer browser does not reliably return ordinary Wi-Fi results**, and finds nothing at
   all in the Simulator. `HostDiscovery` now runs one browser of each kind and merges them.

## Tuning the feel

Three things were wrong on first real-device use, and the fixes are worth knowing about:

- **Pointer speed scales to your desktop.** The host reports the size of its display union, and the
  phone multiplies motion by `desktop width / trackpad width`. A full-width swipe crosses roughly the
  whole desktop whether the Mac is a laptop screen or driving an external monitor. The *Speed* slider
  in Settings is a multiplier on top of that, so `1.0` is neutral — raise it if you still want more.
- **Tap-to-click measures displacement, not path length.** A fingertip jitters a point or two per
  sample; at 120 Hz a perfectly still 150 ms tap accumulates 20+ points of "movement". Summing that
  made taps fail intermittently. Net displacement from the touch-down point does not grow with the
  sample rate.
- **Modifier keys are pressed, not just flagged.** Ordinary apps accept `CGEventFlags` on a keystroke,
  but the system's own shortcuts — Mission Control, App Exposé, Spaces — are dispatched by the
  symbolic-hotkey machinery, which watches for genuine modifier key events. Three-finger swipes did
  nothing until the modifiers were posted as real key-downs around the keystroke.

Landscape is supported: turn the phone sideways for a wider pad. The status bar and hint text drop
away in landscape so the trackpad gets nearly the whole screen.

## Notes on a few implementation choices

- **Pinch is ⌘-scroll.** True `NSEventTypeMagnify` events cannot be synthesised through public API.
  ⌘-scroll is the zoom gesture Safari, Preview, Maps, Finder and Xcode all already understand.
- **Shortcuts use US-ANSI key positions.** macOS defines ⌘Z by physical key position, so a fixed
  table is correct. Free text typing goes through `keyboardSetUnicodeString` and stays
  layout-independent.
- **Motion is coalesced onto the display refresh.** Touch samples accumulate and flush once per
  frame via `CADisplayLink`, so a fast drag sends ~120 small packets a second instead of one per
  sample, and `TCP_NODELAY` keeps Nagle from batching them into a visible lag.
- **JSON on the wire.** At a few dozen bytes per event and ~120 events a second this is roughly
  7 KB/s — nothing on a LAN — and being able to read a packet dump was worth more than the bytes.
- **Sleep Mac uses System Events** and will trigger a one-time Automation permission prompt. Every
  other action goes through CGEvent and needs only Accessibility.
