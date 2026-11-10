"""Prints the UDID of the simulator called <name> on the newest installed runtime of <platform> (iOS | tvOS).
usage: xcrun simctl list devices available -j | python3 scripts/pick_sim.py "iPhone 17 Pro" iOS"""
import json, re, sys

devices = json.load(sys.stdin)['devices']
want, plat = sys.argv[1], sys.argv[2]
best = None
for runtime, devs in devices.items():
    m = re.search(plat + r'-(\d+)-(\d+)', runtime)
    if not m:
        continue
    v = (int(m.group(1)), int(m.group(2)))
    for d in devs:
        if d['name'] == want and (best is None or v > best[0]):
            best = (v, d['udid'])
print(best[1] if best else '')
