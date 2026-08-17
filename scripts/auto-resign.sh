#!/bin/bash
# Keeps MacLink alive on the iPhone without anyone thinking about it.
#
# A free Apple ID signs an app for 7 days. This runs daily from a launchd agent and re-signs when the
# signature is getting old and the phone happens to be attached — so plugging in once a week is
# enough, and there is nothing to remember.
#
# Deliberately quiet. It exits without a sound in the ordinary cases (too soon, phone not here) and
# only speaks up when a human actually needs to act: the signature is nearly expired and the phone
# has not been seen.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="$HOME/Library/Application Support/MacLink"
STAMP="$STATE_DIR/last-resign"
LOG="$STATE_DIR/auto-resign.log"

# Re-sign once the signature is this old. Two days of slack before the 7-day cliff, so a couple of
# missed nights still get caught.
RESIGN_AFTER_DAYS=${RESIGN_AFTER_DAYS:-5}
# Past this, start telling the user to plug the phone in.
NAG_AFTER_DAYS=${NAG_AFTER_DAYS:-6}

mkdir -p "$STATE_DIR"
say() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG"; }

notify() {
    /usr/bin/osascript -e "display notification \"$1\" with title \"MacLink\"" >/dev/null 2>&1 || true
}

age_days() {
    [ -f "$STAMP" ] || { echo 999; return; }
    local then now
    then=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
    now=$(date +%s)
    echo $(( (now - then) / 86400 ))
}

AGE=$(age_days)

if [ "$AGE" -lt "$RESIGN_AFTER_DAYS" ]; then
    say "signature is ${AGE}d old, nothing to do"
    exit 0
fi

# The platform can go missing — deleting the simulator runtime to reclaim disk also removes it.
if ! xcrun simctl runtime list 2>/dev/null | grep -q "iOS"; then
    say "iOS platform missing, cannot build"
    if [ "$AGE" -ge "$NAG_AFTER_DAYS" ]; then
        notify "Can't re-sign: the iOS platform is missing. Run scripts/download-ios-platform.sh."
    fi
    exit 1
fi

# Is the phone here? Not being here is normal, not an error.
if ! xcodebuild -project "$ROOT/MacLink.xcodeproj" -scheme MacLink -showdestinations 2>/dev/null \
        | grep "platform:iOS," | grep -qv "Simulator"; then
    say "signature is ${AGE}d old but no iPhone attached"
    if [ "$AGE" -ge "$NAG_AFTER_DAYS" ]; then
        notify "Plug in your iPhone to keep MacLink working — its signature expires in about a day."
    fi
    exit 0
fi

say "signature is ${AGE}d old and the phone is here — re-signing"
if "$ROOT/scripts/install-on-iphone.sh" >> "$LOG" 2>&1; then
    touch "$STAMP"
    say "re-signed successfully"
    notify "MacLink re-signed — good for another 7 days."
    exit 0
fi

say "re-sign FAILED (see above)"
notify "MacLink could not be re-signed. Open Terminal and run scripts/install-on-iphone.sh."
exit 1
