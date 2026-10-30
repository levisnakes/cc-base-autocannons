"""Runs autocannons.lua in the simulated world (test/sim.lua) and checks the outcome.
FRIEND=1: the ally Bob hugs the enemy, so nothing may be fired at him. SEED=n.
TRACK=1: track test smoothness. SHIPS=unknown: empty ships are targets too.
PICK=FarGuy: pick a player outside the engage zone with [P]."""
import os, sys
from lupa import LuaRuntime

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "..", "autocannons.lua"), encoding="utf-8").read()
sim = open(os.path.join(here, "sim.lua"), encoding="utf-8").read()

lua = LuaRuntime()
lua.globals().math.randomseed(int(os.environ.get("SEED", "1")))
lua.globals().FRIEND = os.environ.get("FRIEND") == "1"
lua.globals().TRACK = os.environ.get("TRACK") == "1"
lua.globals().SHIPS = os.environ.get("SHIPS") or None
lua.globals().PICK = os.environ.get("PICK") or None
if os.environ.get("SETTINGS") == "1":
    lua.globals().SETTINGS = True
    lua.execute(sim, src, 12.0)
    saved = lua.globals().savedSettings.replace(" ", "")
    print("SAVED", saved)
    assert '["BASE_RADIUS_CHUNKS"]=4.0' not in saved, "base size saved as a float"
    for want in ('["BASE_RADIUS_CHUNKS"]=4', '["ENGAGE_RANGE"]=20', '["SHIP_TARGETS"]="unknown"'):
        assert want in saved, want
    print("SETTINGS OK")
    sys.exit(0)
if os.environ.get("TRACK") == "1":
    lua.execute(sim, src, 34.0)
    g = lua.globals()
    print("FIRED", dict(g.fired.items()))
    assert sum(g.fired.values()) == 0, "fired during track test"
    steps = list(g.yawSteps.values())
    errs = list(g.aimErrs.values())
    stops = sum(abs(s) < 0.01 for s in steps) / len(steps)
    jerk = sum(abs(b - a) for a, b in zip(steps, steps[1:])) / (len(steps) - 1)
    print(f"cm0 following a walking player: stopped {stops:.0%} of ticks, "
          f"jerk {jerk:.3f} deg/tick, mean aim error {sum(errs) / len(errs):.2f} deg, max {max(errs):.2f}")
    assert max(errs) < 3, "lost the walking player"
    assert stops < float(os.environ.get("MAX_STOPS", "0.2")), "stop-start tracking"
    print("TRACK TEST OK")
    sys.exit(0)
lua.execute(sim, src, float(os.environ.get("END", "80")))
g = lua.globals()

logs = list(g.logs.values())
hits = [(h.t, h.who, h["from"]) for h in g.hits.values()]
for line in logs:
    print("LOG", line)
print("FIRED", dict(g.fired.items()))
print("MAPS", g.yawmap, dict(g.mapOk.items()))
ship_hits = dict(g.shipHits.items())
print("SHIP HITS", ship_hits)
ys = sorted(g.missY.values())
if ys:
    print(f"HEIGHT at Mechanoo: median {ys[len(ys) // 2]:+.2f} blocks above his chest ({len(ys)} rounds)")
    if not os.environ.get("PICK"):  # with a pick, rounds near Mechanoo are strays
        assert abs(ys[len(ys) // 2]) < 0.6, "rounds pass Mechanoo too high/low"
by = {}
for t, who, frm in hits:
    by.setdefault((who, frm), []).append(round(t, 1))
for k, v in sorted(by.items()):
    print("HITS", k, len(v), "first", v[0])

errors = [l for l in logs if "FATAL" in l or "PRINTERROR" in l]
assert not errors, errors
assert all(g.mapOk.values()), "yaw map wrong"
assert all(h[1] not in ("Bob", "levisnakes") for h in hits), "FRIENDLY FIRE"
if os.environ.get("PICK") != "FarGuy":
    assert not any(h[1] == "FarGuy" for h in hits), "shot someone outside the engage range"
assert ship_hits.get("home", 0) == 0, "shot our own ship"
assert not any(h[0] < 20 for h in hits), "fired before being armed"
if os.environ.get("FRIEND") == "1":
    late = [h for h in hits if h[1] == "Mechanoo" and h[0] > 40.5]
    assert not late, f"fired at an enemy hugging an ally: {late[:3]}"
    print("FRIEND HOLD OK")
    sys.exit(0)
if os.environ.get("PICK") == "FarGuy":
    n = sum(1 for h in hits if h[1] == "FarGuy")
    assert n >= 5, f"picked target FarGuy only hit {n} times"
    print("PICK OK")
    sys.exit(0)
if os.environ.get("SHIPS") == "unknown":
    assert ship_hits.get("drone", 0) >= 3, "empty drone not engaged in unknown mode"
else:
    assert ship_hits.get("drone", 0) == 0, "shot an empty ship in hostile mode"
assert ship_hits.get("raider", 0) + sum(h[1] == "Pilot" for h in hits) >= 5, "hostile ship not engaged"
# cannons spread over the hostiles (Mechanoo and the raider's Pilot), so each one
# must hit somebody hostile, and Mechanoo must get hit
for m in ("cm0", "cm1", "cm2"):
    n = sum(1 for h in hits if h[1] in ("Mechanoo", "Pilot") and h[2] == m)
    assert n >= 5, f"{m} only hit hostiles {n} times"
assert sum(h[1] == "Mechanoo" for h in hits) >= 10, "Mechanoo barely hit"
print("OK")
