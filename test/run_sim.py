"""Runs autocannons.lua in the simulated world (test/sim.lua) and checks the outcome.
FRIEND=1: the ally Bob hugs the enemy, so nothing may be fired at him. SEED=n."""
import os, sys
from lupa import LuaRuntime

here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, "..", "autocannons.lua"), encoding="utf-8").read()
sim = open(os.path.join(here, "sim.lua"), encoding="utf-8").read()

lua = LuaRuntime()
lua.globals().math.randomseed(int(os.environ.get("SEED", "1")))
lua.globals().FRIEND = os.environ.get("FRIEND") == "1"
lua.execute(sim, src, float(os.environ.get("END", "80")))
g = lua.globals()

logs = list(g.logs.values())
hits = [(h.t, h.who, h["from"]) for h in g.hits.values()]
for line in logs:
    print("LOG", line)
print("FIRED", dict(g.fired.items()))
print("MAPS", g.yawmap, dict(g.mapOk.items()))
by = {}
for t, who, frm in hits:
    by.setdefault((who, frm), []).append(round(t, 1))
for k, v in sorted(by.items()):
    print("HITS", k, len(v), "first", v[0])

errors = [l for l in logs if "FATAL" in l or "PRINTERROR" in l]
assert not errors, errors
assert all(g.mapOk.values()), "yaw map wrong"
assert all(h[1] not in ("Bob", "levisnakes") for h in hits), "FRIENDLY FIRE"
assert not any(h[1] == "FarGuy" for h in hits), "shot someone outside the engage range"
assert not any(h[0] < 20 for h in hits), "fired before being armed"
if os.environ.get("FRIEND") == "1":
    late = [h for h in hits if h[1] == "Mechanoo" and h[0] > 40.5]
    assert not late, f"fired at an enemy hugging an ally: {late[:3]}"
    print("FRIEND HOLD OK")
    sys.exit(0)
for m in ("cm0", "cm1", "cm2"):
    n = sum(1 for h in hits if h[1] == "Mechanoo" and h[2] == m)
    assert n >= 5, f"{m} only hit Mechanoo {n} times"
print("OK")
