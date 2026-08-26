#!/bin/bash
# Run UI tests against a simulator that is known-good at launch.
#
# CoreSimulator wedges roughly every other run on this machine, and it fails
# the same way each time: the runner will not start and xcodebuild reports
#   The request was denied by service delegate (SBMainWorkspace) for reason:
#   Busy ("Application failed preflight checks").
# That is indistinguishable from a real test failure in the log, so a wedged
# simulator reads as a red test until you go looking for the reason.
#
# Shutting down and erasing first costs about fifteen seconds and removes the
# failure mode. NEVER `killall CoreSimulatorService` to clear this: it unmounts
# the runtime cryptex and only a reboot brings the runtimes back.
#
# Usage: Tools/uitest.sh [device-name] [-only-testing:...]
set -uo pipefail
cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
shift || true

xcrun simctl shutdown all >/dev/null 2>&1
xcrun simctl erase "$DEVICE" >/dev/null 2>&1

xcodebuild test -project BOFFIN.xcodeproj -scheme BOFFIN \
    -destination "platform=iOS Simulator,name=$DEVICE" "$@" 2>&1 | tee /tmp/boffin-uitest.log \
    | grep -E "Test Case .* (passed|failed)|TEST (SUCCEEDED|FAILED)|error:"

# The preflight wedge is not a test result. Say so explicitly rather than
# letting it be counted as one.
if grep -q "Application failed preflight checks" /tmp/boffin-uitest.log; then
    echo "NOTE: the simulator wedged despite the erase; this is not a test failure."
    exit 2
fi
grep -q "TEST SUCCEEDED" /tmp/boffin-uitest.log
