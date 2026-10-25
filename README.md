# Base Autocannons

Automatic autocannon defence for a CMP base. One CC computer aims any number of
Create Big Cannons autocannons (through CC:CBC cannon mounts) at hostile players
near the base. Your team and allies are never shot.

```
wget https://raw.githubusercontent.com/levisnakes/cc-base-autocannons/main/autocannons.lua startup.lua
```

## Build

- Each autocannon sits on a full **Cannon Mount** (not the compact one) with rotation in **both** the yaw and pitch shafts. Faster shafts make the cannon turn faster.
- Put a **wired modem** on every mount and on a **Player Detector**, and cable them all to the computer.
- Keep each autocannon loaded with ammo.

## Settings (top of the file, or `/config.lua`)

| Setting | What it does |
|---|---|
| `CORE` | protection block position; the base is its chunk ± `BASE_RADIUS_CHUNKS` |
| `ENGAGE_RANGE` | how far outside the base edge hostiles get shot (0 = inside only) |
| `ALLOWED`, `ALLIES` | never shot; more allies can be added in-game with **F** |
| `CANNON`, `BARRELS` | `"steel"` / `"bronze"` / `"cast_iron"` and barrel count; this sets the round speed |
| `FOCUS_FIRE` | `false` spreads cannons over several targets, `true` puts them all on one |
| `NO_FIRE_ZONES` | boxes shots must never fly through (your own buildings) |
| `PITCH_TRIM`, `YAW_TRIM`, `INVERT_PITCH` | fixes if the test shot lands off |

## Keys

- **A**: arm / safe (arming means typing `ARM`)
- **T**: aim one cannon at a block and fire a short test burst
- **F**: add or remove allies
- **Y**: redo a cannon's yaw test
- **R**: rescan peripherals

On the first start, each cannon turns 30° and back. That's the yaw test: cc-cbc's
yaw reading can be mirrored, so the program learns how to read it.
Bases that aren't Oil tier sleep when nobody is around, so the cannons only run
while the base is loaded.

Tests: `python test/run_sim.py` (needs `pip install lupa`); `FRIEND=1` puts an ally right next to the enemy.
