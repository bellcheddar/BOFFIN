#!/bin/bash
# Build BOFFIN and run it on a connected iPhone.
#
#     Tools/run-on-device.sh
#
# This is the route that does not wait for TestFlight. It registers the
# connected device with the developer account if it is not already there,
# because automatic development signing fails with "Your team has no devices
# from which to generate a provisioning profile" until at least one exists --
# which is exactly what blocked the first archive attempt.
set -uo pipefail
cd "$(dirname "$0")/.."

CRED=~/.claude/skills/marcs-vibe-coding/credentials.env
set -a; . "$CRED" 2>/dev/null; set +a
export API_PRIVATE_KEYS_DIR="$(dirname "${ASC_KEY_PATH:-/nonexistent}")"

UDID=$(xcrun devicectl list devices 2>/dev/null \
       | awk '/connected|paired/ {print $(NF-1)}' | head -1)
if [ -z "$UDID" ]; then
    echo "No iPhone found. Connect it by USB, unlock it, and tap Trust."
    echo "Then run this again."
    exit 1
fi
echo "device: $UDID"

JWT=$(xcrun altool --generate-jwt --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" 2>&1 \
      | grep -oE '^ey[A-Za-z0-9_.-]+$' | head -1)
known=$(curl -s -H "Authorization: Bearer $JWT" \
    "https://api.appstoreconnect.apple.com/v1/devices?limit=200" \
    | python3 -c "import json,sys;print(' '.join(d['attributes'].get('udid','') for d in json.load(sys.stdin).get('data',[])))")
if [[ " $known " != *" $UDID "* ]]; then
    echo "registering the device with the developer account ..."
    curl -s -o /dev/null -w "  HTTP %{http_code}\n" -X POST \
        -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
        --data "{\"data\":{\"type\":\"devices\",\"attributes\":{\"name\":\"Marc's iPhone\",\"platform\":\"IOS\",\"udid\":\"$UDID\"}}}" \
        "https://api.appstoreconnect.apple.com/v1/devices"
else
    echo "device already registered"
fi

# -allowProvisioningUpdates creates the development profile now that a device
# exists for it to include.
xcodebuild -project BOFFIN.xcodeproj -scheme BOFFIN -configuration Debug \
    -destination "id=$UDID" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
    build
