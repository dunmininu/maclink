#!/bin/bash
# Builds and tests everything that can be verified on this machine.
#
# Note the iOS app is compiled through the Mac Catalyst variant rather than the iOS SDK. That is a
# workaround for a missing iOS platform install, not the real thing — see README, "Verifying the
# iOS app". Once `xcodebuild -showdestinations -scheme MacLink` lists a Simulator, replace the
# Catalyst step with a real simulator build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "==> MacLinkKit tests"
(cd Packages/MacLinkKit && swift test)

echo
echo "==> macOS host build"
xcodebuild -project "$ROOT/MacLink.xcodeproj" \
    -scheme MacLinkHost \
    -destination 'platform=macOS' \
    -configuration Debug \
    build | grep -E "^\*\* BUILD|error:"

echo
echo "==> iOS app compile check"
if xcodebuild -project "$ROOT/MacLink.xcodeproj" -scheme MacLink -showdestinations 2>/dev/null \
    | grep -q "platform:iOS Simulator"; then
    DEST=$(xcodebuild -project "$ROOT/MacLink.xcodeproj" -scheme MacLink -showdestinations 2>/dev/null \
        | grep "platform:iOS Simulator" | head -1 | sed -E 's/.*id:([0-9A-Fa-f-]+).*/\1/')
    echo "    (iOS Simulator available: $DEST)"
    xcodebuild -project "$ROOT/MacLink.xcodeproj" \
        -scheme MacLink \
        -destination "id=$DEST" \
        -configuration Debug \
        build | grep -E "^\*\* BUILD|error:"
else
    echo "    (no iOS Simulator installed — falling back to a Mac Catalyst compile check)"
    xcodebuild -project "$ROOT/MacLink.xcodeproj" \
        -scheme MacLink \
        -destination 'platform=macOS,variant=Mac Catalyst' \
        CODE_SIGNING_ALLOWED=NO \
        build | grep -E "^\*\* BUILD|error:"
fi

echo
echo "All checks passed."
