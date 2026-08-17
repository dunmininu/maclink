#!/bin/bash
# Reports disk space and what Xcode/simulator storage can be reclaimed.
#
# Written because this machine sits at ~93% full and an iOS platform install needs roughly 9-14 GB
# of headroom. Everything here is read-only; it prints the commands rather than running them.
set -uo pipefail

echo "=== Volume ==="
df -h /System/Volumes/Data | tail -1
diskutil info /System/Volumes/Data 2>/dev/null | grep -i "Container Free Space" || true

echo
echo "=== Reclaimable, no password needed ==="
for d in \
    "$HOME/Library/Developer/Xcode/DerivedData" \
    "$HOME/Library/Developer/Xcode/Archives" \
    "$HOME/Library/Developer/Xcode/iOS DeviceSupport" \
    "$HOME/Library/Developer/CoreSimulator/Devices" \
    "$HOME/Library/Caches/com.apple.dt.Xcode"; do
    [ -e "$d" ] && printf "  %-46s %s\n" "$(basename "$d")" "$(du -sh "$d" 2>/dev/null | cut -f1)"
done

echo
echo "=== Installed simulator runtimes ==="
xcrun simctl runtime list 2>/dev/null | grep -E "^iOS|^watchOS|^tvOS|Total Disk" || echo "  none"

echo
echo "=== Stale MobileAsset storage (SIP-protected) ==="
printf "  %-46s %s\n" "AssetsV2/iOSSimulatorRuntime" \
    "$(du -sh /System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime 2>/dev/null | cut -f1 || echo n/a)"
echo "  Cannot be deleted, even with sudo - the directory carries the SIP 'restricted' flag."
echo "  macOS counts it as purgeable and reclaims it automatically when the disk fills."

cat <<'TIPS'

=== To free space ===
  Delete a runtime Xcode cannot use (biggest win; re-downloadable):
      xcrun simctl runtime list            # find the identifier
      xcrun simctl runtime delete <id>

  Drop stale simulator devices and build output:
      xcrun simctl delete unavailable
      rm -rf ~/Library/Developer/Xcode/DerivedData/*
TIPS
