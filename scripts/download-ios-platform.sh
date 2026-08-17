#!/bin/bash
# Downloads the iOS platform, with a disk-space watchdog.
#
# Xcode gates *all* iOS builds — Simulator and physical device alike — on this platform being
# installed, and it is bundled with the matching simulator runtime. Deleting the runtime to reclaim
# space (`xcrun simctl runtime delete all`) therefore also removes the ability to build for a real
# iPhone. That is not obvious, and it is how this machine lost device builds once already.
#
# This volume runs close to full, so the download is supervised: if free space falls under the floor
# the download is killed rather than allowed to fill the disk. MobileAsset downloads resume, so an
# abort costs time, not progress.
set -uo pipefail

FLOOR_GB=${FLOOR_GB:-6}
LOG="${TMPDIR:-/tmp}/maclink-ios-platform-download.log"

if xcrun simctl runtime list 2>/dev/null | grep -q "iOS"; then
    echo "An iOS runtime is already installed:"
    xcrun simctl runtime list 2>/dev/null | grep "iOS" | sed 's/^/  /'
    echo "Nothing to do."
    exit 0
fi

FREE_GB=$(($(df -k /System/Volumes/Data | tail -1 | awk '{print $4}') / 1024 / 1024))
echo "Free space: ${FREE_GB}GB. Download is ~8.5GB and peaks around 13GB during install."
if [ "$FREE_GB" -lt 15 ]; then
    echo "WARNING: under 15GB free. Run scripts/free-space.sh first if this aborts."
fi

echo "Downloading (arm64 only — half the size of the universal variant)…"
xcodebuild -downloadPlatform iOS -architectureVariant arm64 > "$LOG" 2>&1 &
DL_PID=$!

while kill -0 "$DL_PID" 2>/dev/null; do
    FREE_GB=$(($(df -k /System/Volumes/Data | tail -1 | awk '{print $4}') / 1024 / 1024))
    if [ "$FREE_GB" -lt "$FLOOR_GB" ]; then
        echo "ABORT: free space fell to ${FREE_GB}GB (floor ${FLOOR_GB}GB). Killing the download."
        kill -TERM "$DL_PID" 2>/dev/null; sleep 3; kill -9 "$DL_PID" 2>/dev/null
        echo "Reclaim space and re-run — the download resumes where it stopped."
        exit 2
    fi
    printf "\r  %s  |  %sGB free   " "$(tail -c 200 "$LOG" | tr '\r' '\n' | tail -1 | cut -c1-60)" "$FREE_GB"
    sleep 20
done
echo

wait "$DL_PID"; STATUS=$?
if [ $STATUS -ne 0 ]; then
    tail -5 "$LOG"
    echo "Download failed (status $STATUS). Full log: $LOG"
    exit $STATUS
fi

echo "Installed:"
xcrun simctl runtime list 2>/dev/null | grep "iOS" | sed 's/^/  /'
df -h /System/Volumes/Data | tail -1
