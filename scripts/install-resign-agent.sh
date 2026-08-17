#!/bin/bash
# Installs (or removes) the launchd agent that keeps MacLink signed on the iPhone.
#
#   ./scripts/install-resign-agent.sh            install and start
#   ./scripts/install-resign-agent.sh status     show whether it is loaded, and the log
#   ./scripts/install-resign-agent.sh uninstall  remove it
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="africa.myladder.maclink.resign"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Application Support/MacLink/auto-resign.log"
ACTION="${1:-install}"

case "$ACTION" in
uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
    rm -f "$PLIST"
    echo "Removed. MacLink will no longer re-sign itself."
    exit 0
    ;;
status)
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        echo "Agent is loaded."
    else
        echo "Agent is NOT loaded."
    fi
    [ -f "$LOG" ] && { echo; echo "Recent activity:"; tail -12 "$LOG"; }
    exit 0
    ;;
esac

mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Application Support/MacLink"

# Runs daily at 04:00. The agent itself decides whether anything needs doing, so a daily tick is
# cheap and gives several chances to catch a night when the phone is plugged in. launchd runs a
# missed occurrence once the Mac wakes, so a sleeping machine does not skip a week.
cat > "$PLIST" <<PLIST_END
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$ROOT/scripts/auto-resign.sh</string>
	</array>
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key><integer>4</integer>
		<key>Minute</key><integer>0</integer>
	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Application Support/MacLink/auto-resign.err</string>
</dict>
</plist>
PLIST_END

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
if launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    echo "Installed. MacLink will re-sign itself when the signature is 5+ days old and your"
    echo "iPhone is connected. Checked daily at 04:00."
    echo
    echo "  status:    ./scripts/install-resign-agent.sh status"
    echo "  uninstall: ./scripts/install-resign-agent.sh uninstall"
else
    echo "Could not load the agent. Plist written to $PLIST — load it with:"
    echo "  launchctl bootstrap gui/$(id -u) \"$PLIST\""
    exit 1
fi
