#!/usr/bin/env python3
"""Pick an available simulator of a given device family.

Usage: pick-simulator.py iPhone

Prints the device name on stdout, or exits 1 if none is available.

Why this is not a grep: device names legitimately contain brackets, for
example "iPad Pro 13-inch (M5)". A regex that stops at the first "(" yields
"iPad Pro 13-inch", which is not a real device, and xcodebuild then fails with
"unable to find a device matching the destination specifier" as if no iPad
existed at all. Parse the JSON.

Apple also renames these every cycle, so CI selects by family rather than by a
pinned model name that goes stale on the next runner image bump.
"""

import json
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: pick-simulator.py <family>", file=sys.stderr)
        return 2
    family = sys.argv[1]

    result = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "-j"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"simctl failed: {result.stderr.strip()}", file=sys.stderr)
        return 1

    devices = json.loads(result.stdout).get("devices", {})
    names = [
        device["name"]
        for runtime_devices in devices.values()
        for device in runtime_devices
        if device.get("isAvailable") and device.get("name", "").startswith(family)
    ]

    if not names:
        print(f"No available {family} simulator.", file=sys.stderr)
        return 1

    print(names[0])
    return 0


if __name__ == "__main__":
    sys.exit(main())
