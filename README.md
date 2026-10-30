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
- Optional: Create Radar **plane radars** (or a radar bearing) on the same network, to see Sable ships. A plane radar covers a 90 degree cone, so 4 facing different ways cover everything.

## Settings (top of the file, or `/config.lua`)

| Setting | What it does |
|---|---|
| `CORE` | protection block position; the base is its chunk ± `BASE_RADIUS_CHUNKS` (or set it in-game: **S**, then **C**) |
| `BASE_RADIUS_CHUNKS` | 1 = 3x3, 2 = 5x5, 3 = 7x7, 4 = 9x9 chunks (also in **S**) |
| `ENGAGE_RANGE` | how far outside the base edge hostiles get shot, 0 = inside only (also in **S**) |
| `SHIP_TARGETS` | `"off"`, `"hostile"` (ships with a hostile on board), `"unknown"` (also ships with nobody seen on them) (also in **S**) |
| `SHIP_CREW_RADIUS` | players this close to a ship's centre count as on board |
| `SHIP_CLEAR` | hold fire if a shot would pass this close to one of your ships |
| `ALLOWED`, `ALLIES` | never shot; more allies can be added in-game with **F** |
| `CANNON`, `BARRELS`, `RECOIL_SPRING` | `"steel"` / `"bronze"` / `"cast_iron"`, barrel count, and whether there's a recoil spring (CBC counts it as a barrel); this sets the round speed (also in **S** > B) |
| `PIVOT_HEIGHT` | the cannon turns on the block 2 above the mount (2.5); use -1.5 for a ceiling mount |
| `FOCUS_FIRE` | `false` spreads cannons over several targets, `true` puts them all on one |
| `NO_FIRE_ZONES` | boxes shots must never fly through (your own buildings) |
| `PITCH_TRIM`, `YAW_TRIM`, `INVERT_PITCH` | fixes if the test shot lands off (pitch trim is also in **S** > H) |

## Keys

- **A**: arm / safe (arming means typing `ARM`)
- **P**: pick a target; every cannon goes for it first, even outside the engage zone (0 = back to auto)
- **S**: settings: base size, engage range, ship targets, crew radius, focus fire, mark your ships, base centre, yaw test, rescan
- **K**: track test: aims at anyone, friends included, never fires
- **T**: aim one cannon at a block and fire a short test burst
- **F**: add or remove allies

Ships with a friend on board, and ships you marked as yours (park them inside
the base, then **S** > 6), are never shot, and shots that would pass near them are held.

On the first start, each cannon turns 30° and back. That's the yaw test: cc-cbc's
yaw reading can be mirrored, so the program learns how to read it.
Bases that aren't Oil tier sleep when nobody is around, so the cannons only run
while the base is loaded.

Tests: `python test/run_sim.py` (needs `pip install lupa`); `FRIEND=1` puts an ally right next to the enemy.
