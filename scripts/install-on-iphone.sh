#!/bin/bash
# Builds, signs, installs and launches MacLink on a connected iPhone.
#
# Everything here is automatic except one thing that cannot be: adding your Apple ID to Xcode.
# That is your credential, so you do it once in the UI, and this script picks it up from there.
#
#   Xcode → Settings → Accounts → + → Apple ID     (a free account is enough)
#
# Then plug the phone in and run this.
set -uo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
BUNDLE_ID="africa.myladder.maclink"

fail() { echo "✗ $1" >&2; exit 1; }
step() { echo; echo "==> $1"; }

# ---------------------------------------------------------------- iOS platform
step "Checking the iOS platform is installed"
if ! xcodebuild -showsdks 2>/dev/null | grep -q "iphoneos"; then
    fail "No iOS SDK. Install it with: xcodebuild -downloadPlatform iOS -architectureVariant arm64"
fi
echo "    iOS SDK present"

# ---------------------------------------------------------------- signing team
step "Looking for a signing identity"
if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "Apple Develop"; then
    cat >&2 <<'MSG'
✗ No Apple Development certificate found.

   This is the one step that cannot be automated — it needs your Apple ID.

   1. Open Xcode → Settings → Accounts
   2. Click + and sign in with your Apple ID (free is fine)
   3. Open MacLink.xcodeproj → MacLink target → Signing & Capabilities
      → tick "Automatically manage signing" and pick your Team
   4. Re-run this script

MSG
    exit 1
fi

# The team id is the OU field of the development certificate.
TEAM=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject -nameopt multiline 2>/dev/null \
    | awk -F'= ' '/organizationalUnitName/ {print $2; exit}')
[ -n "${TEAM:-}" ] || fail "Found a certificate but could not read its team id. Set the Team in Xcode instead."
echo "    Team: $TEAM"

# ---------------------------------------------------------------- device
step "Looking for a connected iPhone"

# Ask xcodebuild, not devicectl: the two use different identifier forms, and only xcodebuild's is
# accepted by `-destination`. Its listing also carries the reason a device is ineligible.
DESTINATIONS=$(xcodebuild -project "$ROOT/MacLink.xcodeproj" -scheme MacLink -showdestinations 2>/dev/null \
    | grep "platform:iOS," | grep -v "Simulator" || true)

if [ -z "$DESTINATIONS" ]; then
    fail "No iPhone found. Plug it in, unlock it, and tap Trust This Computer."
fi

UDID=$(echo "$DESTINATIONS" | sed -E 's/.*id:([0-9A-Fa-f-]+).*/\1/' | head -1)
[ -n "${UDID:-}" ] || fail "iPhone found but not usable:
$DESTINATIONS"
DEVICE_NAME=$(echo "$DESTINATIONS" | sed -E 's/.*name:([^,}]+).*/\1/' | head -1)
echo "    Device: ${DEVICE_NAME:-unknown} ($UDID)"

# Explains the two failures every first-time device build hits. Neither is visible from
# `-showdestinations` — they only surface once a build actually probes the phone.
explain_build_failure() {
    local log="$1"
    if grep -q "Developer Mode disabled" "$log"; then
        cat >&2 <<MSG

✗ Developer Mode is turned off on "${DEVICE_NAME}".

   Every iPhone ships with it off, and it blocks all development builds. Turn it on once:

   1. On the phone: Settings → Privacy & Security → Developer Mode
   2. Switch it on, then tap Restart when prompted
   3. After it reboots, unlock the phone and confirm the prompt
   4. Re-run this script

   The Developer Mode row only appears after a Mac has tried to run an app on the phone.
   That has now happened, so it will be there.

MSG
        exit 1
    fi
    if grep -qi "provisioning profile\|no profiles for" "$log"; then
        cat >&2 <<'MSG'

✗ Provisioning failed.

   Open MacLink.xcodeproj in Xcode, select the MacLink target → Signing & Capabilities,
   and press ⌘R once so Xcode can register the device with your Personal Team. After that
   this script will work on its own.

MSG
        exit 1
    fi
    fail "Build failed — see the output above."
}

# ---------------------------------------------------------------- build
step "Building for the device"
BUILD_LOG=$(mktemp)
if ! xcodebuild -project "$ROOT/MacLink.xcodeproj" \
    -scheme MacLink \
    -destination "id=$UDID" \
    -configuration Debug \
    DEVELOPMENT_TEAM="$TEAM" \
    CODE_SIGN_STYLE=Automatic \
    -allowProvisioningUpdates \
    build > "$BUILD_LOG" 2>&1; then
    grep -E "error:|Developer Mode" "$BUILD_LOG" | head -5
    explain_build_failure "$BUILD_LOG"
fi
echo "    ** BUILD SUCCEEDED **"
rm -f "$BUILD_LOG"

APP=$(find ~/Library/Developer/Xcode/DerivedData/MacLink-*/Build/Products/Debug-iphoneos \
    -maxdepth 1 -name "MacLink.app" 2>/dev/null | head -1)
[ -n "${APP:-}" ] || fail "Built, but could not find MacLink.app."
echo "    $APP"

# ---------------------------------------------------------------- install
step "Installing on the phone"
xcrun devicectl device install app --device "$UDID" "$APP" 2>&1 | tail -3 \
    || fail "Install failed. If it mentions a provisioning profile, open the project in Xcode once and press ⌘R."

step "Launching"
xcrun devicectl device process launch --device "$UDID" "$BUNDLE_ID" 2>&1 | tail -2

cat <<'DONE'

Installed.

If the app refuses to open with "Untrusted Developer", on the phone go to
  Settings → General → VPN & Device Management → Developer App → Trust
then open MacLink again.

On first launch, allow the Local Network prompt — the app cannot find your Mac without it.
A free Apple ID signs the app for 7 days; re-run this script to renew it.
DONE
