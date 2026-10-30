-- Base Autocannons - automatic autocannon defence for a CMP base.
-- One computer aims any number of Create Big Cannons autocannons (CC:CBC
-- cannon mounts) at hostile players near the base. Team and allies are never
-- shot, and fire is held when a friend is near the line of fire.
-- wget https://raw.githubusercontent.com/levisnakes/cc-base-autocannons/main/autocannons.lua startup.lua

-- Protection block position (F3). The base is its chunk +/- BASE_RADIUS_CHUNKS.
-- Base size, engage range and the ship settings can also be changed in-game with [S].
CORE = { x = 0, y = 64, z = 0 }
BASE_RADIUS_CHUNKS = 3        -- 3 = 7x7 chunks (1 = 3x3, 2 = 5x5, 4 = 9x9)
ENGAGE_RANGE = 48             -- shoot hostiles up to this far outside the base edge (0 = inside only)
DETECT_RANGE = 300            -- player detector range (server max 512)

-- Sable ships seen by Create Radar (plane radars or radar bearings on the network).
-- "off", "hostile" = ships with a hostile on board and no friends,
-- "unknown" = also ships with nobody seen on them (mark your own ships with [S])
SHIP_TARGETS = "hostile"
SHIP_CREW_RADIUS = 16         -- players this close to a ship's centre count as on board
SHIP_CLEAR = 6                -- hold fire if a shot would pass this close to a ship of yours

ALLOWED = {}                  -- your team: never shot
ALLIES = {}                   -- never shot (more can be added with [F])

ARMED = false                 -- first boot only; after that [A] on the computer decides
FOCUS_FIRE = false            -- true: every cannon shoots the same target. false: spread over targets
FRIENDLY_SAFE = 6             -- hold fire if a friend is this close to the target or the shot
MIN_RANGE = 8                 -- never fire at anything closer than this to a cannon
NO_FIRE_ZONES = {}            -- boxes shots must not fly through: { {x1, y1, z1, x2, y2, z2}, ... }

-- Autocannon build. CANNON = "steel", "bronze" or "cast_iron"; BARRELS = barrel blocks.
CANNON = "steel"
BARRELS = 3
SHOT_SPEED = nil              -- blocks/tick; nil = worked out from CANNON and BARRELS
PITCH_TRIM = 0                -- degrees added to every shot's pitch (+ = higher)
YAW_TRIM = 0                  -- degrees added to every shot's yaw
INVERT_PITCH = false          -- true if the test shot tilts the barrel down instead of up
-- Per-cannon overrides by peripheral name, e.g.
-- TURRETS = { cannon_mount_2 = { barrels = 4, pitchTrim = 0.5 } }
TURRETS = {}
AUTO_UPDATE = true

-- Settings in /config.lua override the ones above. Use it for anything you
-- don't want to retype: it survives reinstalls and updates, and one file can
-- be shared by every computer (each program ignores settings it doesn't use).
do
  local path = "/config.lua"
  if fs.exists(path) then
    local fn, err = loadfile(path, "t", _ENV)
    if fn then
      local ok, runErr = pcall(fn)
      if not ok then printError("config.lua: " .. tostring(runErr)) sleep(3) end
    else
      printError("config.lua: " .. tostring(err))
      sleep(3)
    end
  end
end

-- ============================================================ helpers
local VERSION = "1.4.0"
local DIR = "/autocannons"
local LATENCY = 0.05          -- seconds between a new aim reaching the mount and the round leaving
local CMD_AHEAD = 0.05        -- a new aim reaches the mount one tick after it's sent
local LEARN_TURN = 30         -- degrees the yaw test turns
local atan2 = math.atan2 or math.atan
local sqrt, floor, abs, max, min = math.sqrt, math.floor, math.abs, math.max, math.min
local rad, deg, sin, cos = math.rad, math.deg, math.sin, math.cos

-- CBC 5.11.7 autocannon data: speed = base + inc * min(barrels, maxInc)
local MATERIALS = {
  steel = { base = 3, inc = 1.5, maxInc = 4, life = 60 },
  bronze = { base = 3, inc = 1.5, maxInc = 3, life = 25 },
  cast_iron = { base = 5, inc = 2, maxInc = 2, life = 11 },
}

local U = {}
function U.lowerSet(...)
  local s = {}
  for _, list in ipairs({ ... }) do
    if type(list) == "table" then
      for _, n in ipairs(list) do s[string.lower(n)] = true end
    end
  end
  return s
end
function U.read(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  if not f then return nil end
  local t = f.readAll()
  f.close()
  return t
end
function U.write(path, text)
  local f = fs.open(path, "w")
  if f then f.write(text) f.close() end
end
function U.load(path)
  local t = U.read(path)
  if not t then return nil end
  return textutils.unserialize(t)
end
function U.save(path, v) U.write(path, textutils.serialize(v)) end
function U.m(n) return string.format("%.0fm", n) end
-- 0 = north, 90 = east
function U.compass(dx, dz)
  if dx * dx + dz * dz < 1 then return "-" end
  local a = deg(atan2(dx, -dz)) % 360
  local names = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
  return names[floor((a + 22.5) / 45) % 8 + 1]
end
function U.angDiff(a, b) return (a - b + 180) % 360 - 180 end
function U.all(fns)
  if #fns > 0 then parallel.waitForAll(table.unpack(fns)) end
end

fs.makeDir(DIR)

-- [S] on the computer saves these; they win over the settings at the top
local SAVED_KEYS = { "BASE_RADIUS_CHUNKS", "ENGAGE_RANGE", "SHIP_TARGETS", "SHIP_CREW_RADIUS", "FOCUS_FIRE" }
do
  local saved = U.load(DIR .. "/settings") or {}
  for _, k in ipairs(SAVED_KEYS) do
    if saved[k] ~= nil then _ENV[k] = saved[k] end
  end
end
local function saveSettings()
  local out = {}
  for _, k in ipairs(SAVED_KEYS) do out[k] = _ENV[k] end
  U.save(DIR .. "/settings", out)
end

local friends
local savedAllies = U.load(DIR .. "/allies") or {}
local function rebuildLists() friends = U.lowerSet(ALLOWED, ALLIES, savedAllies) end
rebuildLists()

-- ============================================================ base area
-- [C] on the computer saves a centre that wins over CORE
local B = {}
function B.set(x, z)
  local cx, cz = floor(x / 16), floor(z / 16)
  B.x, B.z = x, z
  B.minX = (cx - BASE_RADIUS_CHUNKS) * 16
  B.maxX = (cx + BASE_RADIUS_CHUNKS + 1) * 16
  B.minZ = (cz - BASE_RADIUS_CHUNKS) * 16
  B.maxZ = (cz + BASE_RADIUS_CHUNKS + 1) * 16
  B.cx, B.cz = (B.minX + B.maxX) / 2, (B.minZ + B.maxZ) / 2
  B.chunks = BASE_RADIUS_CHUNKS * 2 + 1
end
do
  local c = U.load(DIR .. "/core") or CORE
  B.set(c.x, c.z)
  B.unset = c.x == 0 and c.z == 0
end
-- distance outside the base edge (0 inside)
function B.edge(x, z)
  local dx = max(B.minX - x, 0, x - B.maxX)
  local dz = max(B.minZ - z, 0, z - B.maxZ)
  return sqrt(dx * dx + dz * dz)
end

-- ============================================================ peripherals
local P = { det = nil, mounts = {}, radars = {} }
function P.has(name, method)
  local ok, ms = pcall(peripheral.getMethods, name)
  if not ok or not ms then return false end
  for _, m in ipairs(ms) do if m == method then return true end end
  return false
end
function P.scan()
  P.det, P.mounts, P.radars = nil, {}, {}
  local seen = {}
  local names = peripheral.getNames()
  table.sort(names)
  for _, n in ipairs(names) do
    if not seen[n] then
      seen[n] = true
      if peripheral.hasType(n, "player_detector") then P.det = P.det or n
      elseif peripheral.hasType(n, "cannon_mount") then P.mounts[#P.mounts + 1] = n
      -- radar bearings and plane radars; the radar monitor also has getTracks
      elseif P.has(n, "getTracks") and not P.has(n, "getSelectedTrackId") then P.radars[#P.radars + 1] = n
      end
    end
  end
end
function P.call(name, method, ...)
  if not name then return false end
  local r = table.pack(pcall(peripheral.call, name, method, ...))
  if not r[1] then return false, r[2] end
  return true, table.unpack(r, 2, r.n)
end

-- ============================================================ players
-- S.players[lname] = { name, friend, x, y, z, vx, vy, vz, edge, hist }
-- S.ships[id] = { id, name, x, y, z, vx, vy, vz, edge, hist, friends, foes, mine }
local S = { players = {}, ships = {}, mine = U.load(DIR .. "/myships") or {} }

-- velocity = least-squares slope over the last 0.6 s, so one jumpy reading
-- doesn't swing the aim
local function pushHist(e, x, y, z, t)
  local h = e.hist
  h[#h + 1] = { t = t, x = x, y = y, z = z }
  while #h > 24 or (#h > 3 and t - h[1].t > 0.6) do table.remove(h, 1) end
  e.vx, e.vy, e.vz = e.vx or 0, e.vy or 0, e.vz or 0
  if #h < 3 or t - h[1].t < 0.15 then return end
  local n, st, sx, sy, sz = #h, 0, 0, 0, 0
  for _, s in ipairs(h) do st, sx, sy, sz = st + s.t, sx + s.x, sy + s.y, sz + s.z end
  st, sx, sy, sz = st / n, sx / n, sy / n, sz / n
  local stt, stx, sty, stz = 0, 0, 0, 0
  for _, s in ipairs(h) do
    local dt = s.t - st
    stt, stx, sty, stz = stt + dt * dt, stx + dt * (s.x - sx), sty + dt * (s.y - sy), stz + dt * (s.z - sz)
  end
  if stt > 0 then e.vx, e.vy, e.vz = stx / stt, sty / stt, stz / stt end
end

-- reads every player in names (one game tick for all of them)
function S.scan(names)
  local got, fns = {}, {}
  for _, name in ipairs(names) do
    fns[#fns + 1] = function()
      local okp, p = P.call(P.det, "getPlayer", name)
      if okp and type(p) == "table" and p.x then got[name] = p end
    end
  end
  U.all(fns)
  local now = os.clock()
  for name, p in pairs(got) do
    local l = string.lower(name)
    local e = S.players[l]
    if not e then
      e = { name = name, hist = {} }
      S.players[l] = e
    end
    e.friend = friends[l] or false
    e.x, e.y, e.z = p.x, p.y, p.z
    e.seen = now
    pushHist(e, p.x, p.y, p.z, now)
    e.edge = B.edge(p.x, p.z)
  end
  for l, e in pairs(S.players) do
    if now - e.seen > 1.5 then S.players[l] = nil end
  end
end

-- the player list is refreshed once a second; positions every tick
function S.loop()
  local names, listedAt = {}, -1e9
  while true do
    local t0 = os.clock()
    if P.det and t0 - listedAt >= 1 then
      listedAt = t0
      local ok, n = P.call(P.det, "getPlayersInRange", DETECT_RANGE)
      if ok and type(n) == "table" then names = n end
    end
    if P.det then S.scan(names) end
    if os.clock() - t0 < 0.04 then sleep(0.05) end
  end
end

-- Sable ship tracks from every radar. Track positions are the ship's centre.
-- A radar bearing only refreshes a ship when its dish sweeps past, so a
-- reading counts as new only when the ship moved (or every 0.5 s if it's still).
function S.scanRadars()
  local lists, fns = {}, {}
  for i, r in ipairs(P.radars) do
    fns[#fns + 1] = function()
      local ok, t = P.call(r, "getTracks")
      if ok and type(t) == "table" then lists[i] = t end
    end
  end
  U.all(fns)
  local now = os.clock()
  for _, list in pairs(lists) do
    for _, t in pairs(list) do
      local pos = t.position
      if tostring(t.category) == "SABLE" and type(pos) == "table" and pos.x then
        local id = tostring(t.id)
        local e = S.ships[id]
        if not e then
          e = { id = id, name = "ship " .. id:sub(1, 4), hist = {}, aimY = 0, seen = now }
          S.ships[id] = e
        end
        local moved = not e.x or (pos.x - e.x) ^ 2 + (pos.y - e.y) ^ 2 + (pos.z - e.z) ^ 2 > 1e-6
        if moved or now - e.seen >= 0.5 then
          e.x, e.y, e.z = pos.x, pos.y, pos.z
          e.seen = now
          pushHist(e, pos.x, pos.y, pos.z, now)
          e.edge = B.edge(pos.x, pos.z)
        end
        e.scanned = now
      end
    end
  end
  for id, e in pairs(S.ships) do
    if now - e.scanned > 4 then S.ships[id] = nil end
  end
  S.crew()
end

-- who is on each ship
function S.crew()
  local r2 = SHIP_CREW_RADIUS * SHIP_CREW_RADIUS
  for id, e in pairs(S.ships) do
    e.friends, e.foes = 0, 0
    e.mine = S.mine[id] or false
    for _, p in pairs(S.players) do
      if (p.x - e.x) ^ 2 + (p.y - e.y) ^ 2 + (p.z - e.z) ^ 2 < r2 then
        if p.friend then e.friends = e.friends + 1 else e.foes = e.foes + 1 end
      end
    end
  end
end

-- ships to keep shots away from: yours, and any with a friend on board
function S.friendlyShip(e) return e.mine or (e.friends or 0) > 0 end

function S.shipIsTarget(e)
  if S.friendlyShip(e) or e.edge > ENGAGE_RANGE then return false end
  if SHIP_TARGETS == "hostile" then return (e.foes or 0) > 0 end
  return SHIP_TARGETS == "unknown"
end

function S.radarLoop()
  while true do
    local t0 = os.clock()
    if #P.radars > 0 then S.scanRadars() end
    if os.clock() - t0 < 0.04 then sleep(#P.radars > 0 and 0.05 or 1) end
  end
end

-- where e will be `ahead` seconds after its last reading
function S.predict(e, ahead)
  local dt = os.clock() - e.seen + ahead
  return { name = e.name, x = e.x + e.vx * dt, y = e.y + e.vy * dt, z = e.z + e.vz * dt,
    vx = e.vx, vy = e.vy, vz = e.vz, aimY = e.aimY, shipId = e.id }
end

-- ============================================================ ballistics
-- MC yaw: 0 = south (+z), 90 = west (-x), 180 = north, 270 = east. Pitch + = up.
-- CBC projectile step: F = -drag * v + gravity; pos += v + F / 2; v += F
local DRAG, GRAVITY = 0.01, 0.025
local Bal = {}
function Bal.dir(yaw, pitch)
  local cp = cos(rad(pitch))
  return -sin(rad(yaw)) * cp, sin(rad(pitch)), cos(rad(yaw)) * cp
end
function Bal.yawTo(dx, dz) return deg(atan2(-dx, dz)) % 360 end

-- height (relative to the pivot) where the round crosses horizontal distance D, and when
function Bal.heightAt(c, pitch, D)
  local cp, sp = cos(rad(pitch)), sin(rad(pitch))
  local h, y = c.barrel * cp, c.barrel * sp
  if h >= D then return D * sp / max(cp, 1e-3), 0 end
  local vh, vy = c.speed * cp, c.speed * sp
  for t = 1, c.life do
    local fh, fy = -DRAG * vh, -DRAG * vy - GRAVITY
    local nh, ny = h + vh + fh / 2, y + vy + fy / 2
    if nh >= D then
      local f = (D - h) / (nh - h)
      return y + (ny - y) * f, t - 1 + f
    end
    h, y = nh, ny
    vh, vy = vh + fh, vy + fy
  end
  return nil
end

-- low-arc pitch that hits (D, dy), plus the flight time in ticks
function Bal.solve(c, D, dy, hint)
  local function f(p)
    local y, t = Bal.heightAt(c, p, D)
    if not y then return nil end
    return y - dy, t
  end
  local lo, hi
  if hint then
    local a, b = max(c.minPitch, hint - 3), min(c.maxPitch, hint + 3)
    local fa, fb = f(a), f(b)
    if fa and fb and fa < 0 and fb >= 0 then lo, hi = a, b end
  end
  if not lo then
    local prev = nil
    local p = c.minPitch
    while p <= c.maxPitch do
      local v = f(p)
      if v then
        if v >= 0 then
          if prev then lo, hi = prev, p end
          break
        end
        prev = p
      else
        prev = nil
      end
      p = p + 2
    end
    if not lo then return nil end
  end
  for _ = 1, 16 do
    local mid = (lo + hi) / 2
    local v = f(mid)
    if v and v < 0 then lo = mid else hi = mid end
  end
  local _, t = f(hi)
  if not t then return nil end
  return hi, t
end

-- yaw/pitch (world) to hit e from the pivot, leading its velocity
function Bal.aim(c, px, py, pz, e, hint)
  local aimY = e.aimY or 1.0
  local ax, ay, az = e.x, e.y + aimY, e.z
  local yaw, pitch, ticks
  for _ = 1, 4 do
    local dx, dy, dz = ax - px, ay - py, az - pz
    local D = sqrt(dx * dx + dz * dz)
    if D < 1 then return nil end
    pitch, ticks = Bal.solve(c, D, dy, hint or pitch)
    if not pitch then return nil end
    yaw = Bal.yawTo(dx, dz)
    local tf = ticks / 20 + LATENCY
    ax = e.x + (e.vx or 0) * tf
    ay = e.y + aimY + max(-1, min(1, e.vy or 0)) * tf * 0.5
    az = e.z + (e.vz or 0) * tf
  end
  return yaw, pitch, ticks, ax, ay, az
end

-- points along the flight path, starting at the muzzle, a bit past the target
function Bal.path(c, px, py, pz, yaw, pitch, ticks)
  local dx, dy, dz = Bal.dir(yaw, pitch)
  local x, y, z = px + dx * c.barrel, py + dy * c.barrel, pz + dz * c.barrel
  local vx, vy, vz = dx * c.speed, dy * c.speed, dz * c.speed
  local pts = { { x, y, z } }
  for _ = 1, min(c.life, floor(ticks) + 20) do
    local fx, fy, fz = -DRAG * vx, -DRAG * vy - GRAVITY, -DRAG * vz
    x, y, z = x + vx + fx / 2, y + vy + fy / 2, z + vz + fz / 2
    vx, vy, vz = vx + fx, vy + fy, vz + fz
    pts[#pts + 1] = { x, y, z }
  end
  return pts
end

-- nil if safe, else why not. Friends are checked where they are now and
-- where they'll be when the round gets there (they may be running with the target).
function Bal.unsafe(pts, ticks, ax, ay, az, e)
  local r2 = FRIENDLY_SAFE * FRIENDLY_SAFE
  for _, p in pairs(S.players) do
    if p.friend then
      local fy = p.y + 0.9
      local vx, vy, vz = p.vx or 0, p.vy or 0, p.vz or 0
      local tf = ticks / 20 + LATENCY
      if (p.x - ax) ^ 2 + (fy - ay) ^ 2 + (p.z - az) ^ 2 < r2
        or (p.x + vx * tf - ax) ^ 2 + (fy + vy * tf - ay) ^ 2 + (p.z + vz * tf - az) ^ 2 < r2
        or (p.x - e.x) ^ 2 + (p.y - e.y) ^ 2 + (p.z - e.z) ^ 2 < r2 then
        return "friend near target: " .. p.name
      end
      for i = 1, #pts do
        local q = pts[i]
        local t = (i - 1) / 20 + LATENCY
        if (p.x - q[1]) ^ 2 + (fy - q[2]) ^ 2 + (p.z - q[3]) ^ 2 < 9
          or (p.x + vx * t - q[1]) ^ 2 + (fy + vy * t - q[2]) ^ 2 + (p.z + vz * t - q[3]) ^ 2 < 9 then
          return "friend in line: " .. p.name
        end
      end
    end
  end
  local c2 = SHIP_CLEAR * SHIP_CLEAR
  for id, sh in pairs(S.ships) do
    if id ~= e.shipId and S.friendlyShip(sh) then
      for i = 1, min(#pts, floor(ticks) + 2) do
        local q = pts[i]
        if (sh.x - q[1]) ^ 2 + (sh.y - q[2]) ^ 2 + (sh.z - q[3]) ^ 2 < c2 then
          return "own ship in line: " .. sh.name
        end
      end
    end
  end
  for _, b in ipairs(NO_FIRE_ZONES) do
    local x1, x2 = min(b[1], b[4]), max(b[1], b[4])
    local y1, y2 = min(b[2], b[5]), max(b[2], b[5])
    local z1, z2 = min(b[3], b[6]), max(b[3], b[6])
    for i = 1, min(#pts, floor(ticks) + 2) do
      local q = pts[i]
      if q[1] >= x1 and q[1] <= x2 + 1 and q[2] >= y1 and q[2] <= y2 + 1 and q[3] >= z1 and q[3] <= z2 + 1 then
        return "no-fire zone"
      end
    end
  end
  return nil
end

-- ============================================================ turrets
-- cc-cbc setTargetAngles and getInfo().targetYaw use the barrel's real MC yaw,
-- but getInfo().yaw can be mirrored or offset. T.yawMap[name] = { sign, off }
-- turns that reading back into the real yaw; it's learned with a short test turn.
local T = { list = {}, yawMap = U.load(DIR .. "/yawmap") or {}, armed = ARMED, busy = nil }
do
  local a = U.load(DIR .. "/armed")
  if a ~= nil then T.armed = a end
end

function T.cfg(name)
  local o = TURRETS[name] or {}
  local mat = MATERIALS[o.cannon or CANNON] or MATERIALS.steel
  local barrels = o.barrels or BARRELS
  local speed = o.speed or SHOT_SPEED or (mat.base + mat.inc * min(barrels, mat.maxInc))
  return { speed = speed, life = o.life or mat.life, barrel = barrels + 0.5,
    minPitch = o.minPitch or -30, maxPitch = o.maxPitch or 60,
    pitchTrim = o.pitchTrim or PITCH_TRIM, yawTrim = o.yawTrim or YAW_TRIM }
end

function T.sync()
  local keep = {}
  for _, t in ipairs(T.list) do keep[t.name] = t end
  T.list = {}
  for _, n in ipairs(P.mounts) do
    local t = keep[n] or { name = n, state = "starting", firing = false }
    t.c = T.cfg(n)
    T.list[#T.list + 1] = t
  end
end

function T.setArmed(v)
  T.armed = v
  U.save(DIR .. "/armed", v)
end

local function setFire(t, on)
  if t.firing ~= on then
    P.call(t.name, "fire", on)
    t.firing = on
  end
end

function T.allOff()
  for _, t in ipairs(T.list) do pcall(peripheral.call, t.name, "fire", false) t.firing = false end
end

function T.realYaw(t, info)
  local map = T.yawMap[t.name]
  if not map or not info.yaw then return nil end
  return (map[1] * (info.yaw - map[2])) % 360
end

-- wait until the yaw reading stops changing; returns the last info
local function settle(t, timeout)
  local stopAt = os.clock() + timeout
  local last, still, info = nil, 0, nil
  while os.clock() < stopAt do
    sleep(0.1)
    local ok, i = P.call(t.name, "getInfo")
    if ok and type(i) == "table" and i.yaw then
      info = i
      if last and abs(U.angDiff(i.yaw, last)) < 0.02 then still = still + 1 else still = 0 end
      last = i.yaw
      if still >= 5 then return info, true end
    end
  end
  return info, false
end

-- turn LEARN_TURN degrees and back, and see which way the yaw reading moved
function T.learn(t)
  setFire(t, false)
  t.state = "yaw test: turning " .. LEARN_TURN .. " deg"
  -- turning computer control off and on copies the real angles into the target
  P.call(t.name, "setComputerControl", false)
  P.call(t.name, "setComputerControl", true)
  local ok, i1 = P.call(t.name, "getInfo")
  if not ok or type(i1) ~= "table" or not i1.targetYaw then t.state = "no reply" return false end
  local yaw1, read1 = i1.targetYaw, i1.yaw
  P.call(t.name, "setTargetAngles", (yaw1 + LEARN_TURN) % 360, i1.targetPitch or 0)
  local i2, stopped = settle(t, 20)
  P.call(t.name, "setTargetAngles", yaw1, i1.targetPitch or 0)
  if not i2 or not stopped then t.state = "yaw test: mount didn't stop" return false end
  local d = U.angDiff(i2.yaw, read1)
  if abs(d) < 2 then t.state = "no yaw rotation - check the yaw shaft" return false end
  if abs(abs(d) - LEARN_TURN) > 2 then
    t.state = string.format("yaw test: turned %.1f, not %d", d, LEARN_TURN)
    return false
  end
  local sign = d > 0 and 1 or -1
  T.yawMap[t.name] = { sign, (read1 - sign * yaw1) % 360 }
  U.save(DIR .. "/yawmap", T.yawMap)
  settle(t, 20)
  t.state = "ready"
  return true
end

-- [P] picks one target (a player name in lowercase, or "ship:<id>") that every
-- cannon goes for first. It's dropped after PICK_FORGET seconds out of sight.
T.pick, T.pickLost = nil, nil
local PICK_FORGET = 30
function T.pickedTarget()
  if not T.pick then return nil end
  local e
  if T.pick:sub(1, 5) == "ship:" then e = S.ships[T.pick:sub(6)] else e = S.players[T.pick] end
  if e and not e.friend and not (e.hist and e.id and S.friendlyShip(e)) then
    T.pickLost = nil
    return e
  end
  T.pickLost = T.pickLost or os.clock()
  if os.clock() - T.pickLost > PICK_FORGET then T.pick, T.pickLost = nil, nil end
  return nil
end

-- hostiles this turret could shoot at, best first.
-- In track test (T.test) everyone is a candidate, friends too, but nothing fires.
function T.candidates(t, px, py, pz)
  local out = {}
  local pick = T.pickedTarget()
  for l, p in pairs(S.players) do
    if T.test or (not p.friend and (p.edge <= ENGAGE_RANGE or pick == p)) then
      local d = sqrt((p.x - px) ^ 2 + (p.y - py) ^ 2 + (p.z - pz) ^ 2)
      if d >= (T.test and 2 or MIN_RANGE) then
        local score = p.edge + d * 0.05
        if t.target == l then score = score - 15 end
        if pick == p then score = score - 1000 end
        if not FOCUS_FIRE then
          for _, o in ipairs(T.list) do
            if o ~= t and o.target == l then score = score + 30 end
          end
        end
        out[#out + 1] = { key = l, e = p, score = score }
      end
    end
  end
  -- ships come after players: hitting the pilot ends it faster
  for id, e in pairs(S.ships) do
    if (T.test and not e.mine) or (not T.test and (S.shipIsTarget(e) or (pick == e and not S.friendlyShip(e)))) then
      local d = sqrt((e.x - px) ^ 2 + (e.y - py) ^ 2 + (e.z - pz) ^ 2)
      if d >= MIN_RANGE + 8 then
        local key = "ship:" .. id
        local score = e.edge + d * 0.05 + 20
        if t.target == key then score = score - 15 end
        if pick == e then score = score - 1000 end
        if not FOCUS_FIRE then
          for _, o in ipairs(T.list) do
            if o ~= t and o.target == key then score = score + 30 end
          end
        end
        out[#out + 1] = { key = key, e = e, score = score }
      end
    end
  end
  table.sort(out, function(a, b) return a.score < b.score end)
  return out
end

-- Works out this tick's aim from the mount's last reading, then sends the aim,
-- any trigger change and the next getInfo together, so each costs one game tick.
-- The mount turns at full shaft speed and stops once it reaches its target, so
-- a fresh target every tick is what keeps it moving smoothly.
function T.step(t, now)
  local calls = {}
  local function call(...)
    local a = table.pack(...)
    calls[#calls + 1] = function() P.call(table.unpack(a, 1, a.n)) end
  end
  local function fire(on)
    if t.firing ~= on then t.firing = on call(t.name, "fire", on) end
  end
  T.think(t, now, call, fire)
  calls[#calls + 1] = function()
    local ok, info = P.call(t.name, "getInfo")
    t.info = ok and type(info) == "table" and info or nil
  end
  U.all(calls)
end

function T.think(t, now, call, fire)
  local info = t.info
  if not info then t.state = "no reply" fire(false) return end
  if info.assembled == false then
    fire(false)
    t.state = "not assembled"
    call(t.name, "assemble", true)
    return
  end
  if not info.computerControl then
    call(t.name, "setComputerControl", true)
    t.sent = nil
  end
  t.noPower = (info.yawShaftSpeed or 0) == 0 or (info.pitchShaftSpeed or 0) == 0
  if not T.yawMap[t.name] then fire(false) t.needsLearn = true return end

  local px, py, pz = info.x + 0.5, info.y + 1.5, info.z + 0.5
  local chosen, held
  for _, cand in ipairs(T.candidates(t, px, py, pz)) do
    local e = S.predict(cand.e, CMD_AHEAD)
    local yaw, pitch, ticks, ax, ay, az = Bal.aim(t.c, px, py, pz, e, t.target == cand.key and t.pitch or nil)
    if yaw then
      local why = not T.test and Bal.unsafe(Bal.path(t.c, px, py, pz, yaw, pitch, ticks), ticks, ax, ay, az, e)
      if not why then
        chosen = { key = cand.key, e = e, yaw = yaw, pitch = pitch, ax = ax, az = az }
        break
      end
      held = held or why
    else
      held = held or ("out of reach: " .. cand.e.name)
    end
  end

  if not chosen then
    fire(false)
    t.target, t.pitch = nil, nil
    t.state = held and ("hold: " .. held) or (t.noPower and "NO ROTATION" or "watching")
    return
  end
  t.target, t.pitch = chosen.key, chosen.pitch
  local my = (chosen.yaw + t.c.yawTrim) % 360
  local mp = (chosen.pitch + t.c.pitchTrim) * (INVERT_PITCH and -1 or 1)
  if not t.sent or abs(U.angDiff(t.sent[1], my)) > 0.01 or abs(t.sent[2] - mp) > 0.01 or now - t.sent[3] > 1 then
    call(t.name, "setTargetAngles", my, mp)
    t.sent = { my, mp, now }
  end

  -- fire while the barrel is within about a body-width of the aim point
  local dist = sqrt((chosen.ax - px) ^ 2 + (chosen.az - pz) ^ 2)
  local tol = max(0.5, deg(math.atan(0.8 / max(dist, 1))))
  if t.firing then tol = tol * 1.5 end
  local cy = T.realYaw(t, info)
  local aimed = cy and info.pitch and abs(U.angDiff(cy, my)) <= tol and abs(info.pitch - mp) <= tol
  local name = chosen.e.name
  if T.test then
    fire(false)
    t.state = (aimed and "TEST: locked on " or "TEST: aiming at ") .. name
  elseif not aimed then
    fire(false)
    t.state = "aiming at " .. name .. (t.noPower and " (NO ROTATION)" or "")
  elseif not T.armed then
    fire(false)
    t.state = "on " .. name .. " (SAFE)"
  else
    fire(true)
    t.state = "FIRING on " .. name
  end
end

function T.loop()
  while true do
    local now = os.clock()
    local fns = {}
    for _, t in ipairs(T.list) do
      if T.busy ~= t.name and not t.learning then
        fns[#fns + 1] = function()
          local ok, err = pcall(T.step, t, now)
          if not ok then t.state = "error: " .. tostring(err) setFire(t, false) end
        end
      end
    end
    U.all(fns)
    -- the peripheral calls already wait a tick; only sleep if they didn't
    if os.clock() - now < 0.04 then sleep(0.05) end
  end
end

-- yaw tests run here so they don't hold up the cannons that are ready
function T.learnLoop()
  while true do
    local fns = {}
    for _, t in ipairs(T.list) do
      if t.needsLearn and not T.yawMap[t.name] and T.busy ~= t.name and os.clock() >= (t.nextLearn or 0) then
        fns[#fns + 1] = function()
          t.learning = true
          local ok, done = pcall(T.learn, t)
          t.learning, t.needsLearn = false, false
          if not ok then t.state = "error: " .. tostring(done) end
          if not (ok and done) then t.nextLearn = os.clock() + 30 end
        end
      end
    end
    U.all(fns)
    sleep(1)
  end
end

-- ============================================================ screen
local UI = { busy = false }

function UI.draw()
  if UI.busy then return end
  local w, h = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.orange)
  write("AUTOCANNONS ")
  term.setTextColor(colors.gray)
  write("v" .. VERSION)
  local st = T.test and " TRACK TEST - NOT FIRING " or (T.armed and " ARMED " or " SAFE ")
  term.setCursorPos(w - #st + 1, 1)
  term.setBackgroundColor(T.test and colors.blue or (T.armed and colors.red or colors.green))
  term.setTextColor(colors.white)
  write(st)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.lightGray)
  term.setCursorPos(1, 2)
  if B.unset then
    term.setTextColor(colors.red)
    write("Base centre not set! Stand on the core, press [C]")
  else
    write(string.format("%dx%d chunks at %d %d, engage %s out", B.chunks, B.chunks, floor(B.x), floor(B.z),
      U.m(ENGAGE_RANGE)))
  end

  term.setCursorPos(1, 3)
  if T.pick then
    local e = T.pickedTarget()
    term.setTextColor(colors.orange)
    write("Target: " .. (e and e.name or T.pick) .. (e and " (picked)" or " (picked, not seen)"))
  else
    term.setTextColor(colors.lightGray)
    write("Target: AUTO")
  end

  local list = {}
  for _, p in pairs(S.players) do list[#list + 1] = p end
  table.sort(list, function(a, b) return a.edge < b.edge end)
  term.setCursorPos(1, 4)
  term.setTextColor(P.det and colors.gray or colors.red)
  write(P.det and ("Players seen (" .. #list .. " within " .. DETECT_RANGE .. "m)") or "Player detector MISSING")
  local ships = {}
  for _, e in pairs(S.ships) do ships[#ships + 1] = e end
  table.sort(ships, function(a, b) return a.edge < b.edge end)
  local shipRows = #P.radars > 0 and (1 + min(#ships, 3)) or 0
  local row = 5
  local maxRows = max(1, h - 7 - #T.list - shipRows)
  for i = 1, min(#list, maxRows) do
    local p = list[i]
    term.setCursorPos(1, row)
    term.setTextColor(p.friend and colors.lime or colors.red)
    local where = p.edge <= 0 and "INSIDE" or (U.m(p.edge) .. " " .. U.compass(p.x - B.cx, p.z - B.cz))
    local tag = p.friend and "friend" or ((T.pick == string.lower(p.name) and "PICKED")
      or (p.edge <= ENGAGE_RANGE and "TARGET" or "out"))
    write(string.format("%-7s %-16s %-9s %d %d %d", tag, p.name:sub(1, 16), where, floor(p.x), floor(p.y), floor(p.z)))
    row = row + 1
  end
  if shipRows > 0 then
    term.setCursorPos(1, row)
    term.setTextColor(colors.gray)
    write("Ships (" .. #ships .. ", " .. #P.radars .. " radars, targets: " .. SHIP_TARGETS .. ")")
    row = row + 1
    for i = 1, min(#ships, 3) do
      local e = ships[i]
      local target = S.shipIsTarget(e)
      local tag = e.mine and "MINE" or ((e.friends or 0) > 0 and "friend"
        or (T.pick == "ship:" .. e.id and "PICKED") or (target and "TARGET" or "ignore"))
      term.setCursorPos(1, row)
      term.setTextColor(target and colors.red or (S.friendlyShip(e) and colors.lime or colors.lightGray))
      local where = e.edge <= 0 and "INSIDE" or (U.m(e.edge) .. " " .. U.compass(e.x - B.cx, e.z - B.cz))
      write(string.format("%-7s %-9s %-9s crew %d/%d", tag, e.name, where, e.friends or 0, e.foes or 0))
      row = row + 1
    end
  end
  row = row + 1
  term.setCursorPos(1, row)
  term.setTextColor(colors.gray)
  write("Cannons (" .. #T.list .. ")")
  for _, t in ipairs(T.list) do
    row = row + 1
    term.setCursorPos(1, row)
    term.setTextColor(t.firing and colors.red or colors.white)
    write((t.name .. " " .. (t.state or "")):sub(1, w))
  end
  if #T.list == 0 then
    row = row + 1
    term.setCursorPos(1, row)
    term.setTextColor(colors.lightGray)
    write("none - put a wired modem on each cannon mount")
  end
  term.setCursorPos(1, h)
  term.setTextColor(colors.yellow)
  write("[A]rm [P]ick [S]ettings [K]track [T]est [F]riends")
end

-- base centre = where a player is standing now (on the protection block)
function UI.setCentre()
  if not P.det then print("No player detector.") sleep(2) return end
  print("Stand on the protection block.")
  local name = UI.ask("Your name: ")
  local ok, p = P.call(P.det, "getPlayer", name)
  if not ok or type(p) ~= "table" or not p.x then print("Can't see " .. name .. ".") sleep(2) return end
  local c = { x = floor(p.x), y = floor(p.y), z = floor(p.z) }
  U.save(DIR .. "/core", c)
  B.set(c.x, c.z)
  B.unset = false
  for _, e in pairs(S.players) do e.edge = B.edge(e.x, e.z) end
  print(string.format("Base centre set to %d %d %d.", c.x, c.y, c.z))
  sleep(2)
end

function UI.ask(prompt)
  term.setTextColor(colors.yellow)
  write(prompt)
  term.setTextColor(colors.white)
  return read() or ""
end

function UI.begin()
  UI.busy = true
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
end

function UI.pickTurret()
  if #T.list == 0 then print("No cannon mounts found.") sleep(2) return nil end
  for i, t in ipairs(T.list) do print(i .. ") " .. t.name .. (T.yawMap[t.name] and "" or "  (yaw not tested)")) end
  local n = tonumber(UI.ask("Cannon #: "))
  return n and T.list[n]
end

-- aim one cannon at a block and optionally fire a short burst
function UI.testShot()
  local t = UI.pickTurret()
  if not t then return end
  if not T.yawMap[t.name] or not t.info then print("Wait for its yaw test first.") sleep(2) return end
  local x, y, z = UI.ask("Target x y z: "):match("(%-?[%d%.]+)%s+(%-?[%d%.]+)%s+(%-?[%d%.]+)")
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  if not z then print("Need three numbers.") sleep(2) return end
  T.busy = t.name
  setFire(t, false)
  local i = t.info
  local px, py, pz = i.x + 0.5, i.y + 1.5, i.z + 0.5
  local yaw, pitch, ticks = Bal.aim(t.c, px, py, pz, { x = x + 0.5, y = y, z = z + 0.5, aimY = 0.5 })
  if not yaw then
    print("Out of reach for this cannon.")
    sleep(2)
  else
    print(string.format("yaw %.1f pitch %.1f, flight %.2fs", yaw, pitch, ticks / 20))
    P.call(t.name, "setTargetAngles", (yaw + t.c.yawTrim) % 360, (pitch + t.c.pitchTrim) * (INVERT_PITCH and -1 or 1))
    t.sent = nil
    settle(t, 15)
    if UI.ask("Fire a short burst? (y/n): "):lower() == "y" then
      P.call(t.name, "fire", true)
      sleep(0.6)
      P.call(t.name, "fire", false)
      print("Watch where it lands. Too low: raise PITCH_TRIM.")
      UI.ask("[enter]")
    end
  end
  T.busy = nil
end

function UI.yawTest()
  local t = UI.pickTurret()
  if not t then return end
  T.busy = t.name
  print("Turning " .. t.name .. " " .. LEARN_TURN .. " degrees and back...")
  T.yawMap[t.name] = nil
  local ok = T.learn(t)
  print(ok and "Done." or ("Failed: " .. tostring(t.state)))
  sleep(2)
  T.busy = nil
end

function UI.friendsMenu()
  print("Friends are never shot. +name adds, -name removes.")
  for _, n in ipairs(ALLOWED) do print("  " .. n .. "  (team, in settings)") end
  for _, n in ipairs(ALLIES) do print("  " .. n .. "  (in settings)") end
  for _, n in ipairs(savedAllies) do print("  " .. n) end
  local a = UI.ask("> ")
  local op, name = a:match("^([%+%-])%s*(%S+)")
  if not op then return end
  for i = #savedAllies, 1, -1 do
    if string.lower(savedAllies[i]) == string.lower(name) then table.remove(savedAllies, i) end
  end
  if op == "+" then savedAllies[#savedAllies + 1] = name end
  U.save(DIR .. "/allies", savedAllies)
  rebuildLists()
  for l, p in pairs(S.players) do p.friend = friends[l] or false end
end

function UI.pickMenu()
  local opts = {}
  for l, p in pairs(S.players) do
    if not p.friend then opts[#opts + 1] = { key = l, e = p, label = p.name } end
  end
  for id, e in pairs(S.ships) do
    if not S.friendlyShip(e) then
      opts[#opts + 1] = { key = "ship:" .. id, e = e, label = e.name .. " (crew " .. (e.foes or 0) .. ")" }
    end
  end
  table.sort(opts, function(a, b) return a.e.edge < b.e.edge end)
  print("Pick a target. Every cannon goes for it first,")
  print("even outside the engage zone. Friends can't be picked.")
  print("0) AUTO (cannons choose)" .. (T.pick and "" or "  <- now"))
  local _, h = term.getSize()
  for i = 1, min(#opts, h - 5) do
    local o = opts[i]
    local where = o.e.edge <= 0 and "inside" or (U.m(o.e.edge) .. " out")
    print(i .. ") " .. o.label .. ", " .. where .. (T.pick == o.key and "  <- now" or ""))
  end
  local n = tonumber(UI.ask("> "))
  if n == 0 then T.pick, T.pickLost = nil, nil
  elseif n and opts[n] then T.pick, T.pickLost = opts[n].key, nil end
end

local SHIP_MODES = { off = "hostile", hostile = "unknown", unknown = "off" }
local SHIP_DESC = { off = "off", hostile = "ships with a hostile on board",
  unknown = "hostile ships + ships with nobody seen" }

function UI.settings()
  while true do
    term.clear()
    term.setCursorPos(1, 1)
    local mine = 0
    for _ in pairs(S.mine) do mine = mine + 1 end
    print("Settings")
    print(string.format("1) Base size: %dx%d chunks", B.chunks, B.chunks))
    print(string.format("2) Engage range: %s outside the edge", U.m(ENGAGE_RANGE)))
    print("3) Ship targets: " .. (SHIP_DESC[SHIP_TARGETS] or tostring(SHIP_TARGETS)))
    print(string.format("4) Crew radius: %s from a ship's centre", U.m(SHIP_CREW_RADIUS)))
    print("5) Focus fire: " .. (FOCUS_FIRE and "on (all on one target)" or "off (spread out)"))
    print(string.format("6) Mark ships inside the base as mine (%d marked)", mine))
    print("7) Forget my ships")
    print("8) Yaw test a cannon")
    print("9) Rescan peripherals")
    print("C) Set base centre (stand on the core)")
    print("Enter = back")
    local k = UI.ask("> ")
    if k == "" then return end
    if k == "1" then
      local n = tonumber(UI.ask("Chunks across (odd number, 1-15): "))
      if n and n >= 1 and n <= 15 and n % 2 == 1 then
        BASE_RADIUS_CHUNKS = floor((n - 1) / 2)
        B.set(B.x, B.z)
      end
    elseif k == "2" then
      local n = tonumber(UI.ask("Metres outside the base edge (0 = inside only): "))
      if n and n >= 0 then ENGAGE_RANGE = n end
    elseif k == "3" then SHIP_TARGETS = SHIP_MODES[SHIP_TARGETS] or "hostile"
    elseif k == "4" then
      local n = tonumber(UI.ask("Crew radius in metres: "))
      if n and n > 0 then SHIP_CREW_RADIUS = n end
    elseif k == "5" then FOCUS_FIRE = not FOCUS_FIRE
    elseif k == "6" then
      for id, e in pairs(S.ships) do if e.edge <= 0 then S.mine[id] = true end end
      U.save(DIR .. "/myships", S.mine)
    elseif k == "7" then
      S.mine = {}
      U.save(DIR .. "/myships", S.mine)
    elseif k == "8" then UI.yawTest()
    elseif k == "9" then
      P.scan()
      T.sync()
    elseif k:lower() == "c" then UI.setCentre()
    end
    saveSettings()
    for _, e in pairs(S.players) do e.edge = B.edge(e.x, e.z) end
    for _, e in pairs(S.ships) do e.edge = B.edge(e.x, e.z) end
    S.crew()
  end
end

function UI.loop()
  local timer = os.startTimer(0.5)
  UI.draw()
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then
      UI.draw()
      timer = os.startTimer(0.5)
    elseif ev == "char" then
      local k = string.lower(a)
      if k == "a" then
        UI.begin()
        if T.armed then
          T.setArmed(false)
        elseif UI.ask("Type ARM to let the cannons fire: ") == "ARM" then
          T.setArmed(true)
        end
      elseif k == "k" then
        T.test = not T.test
        if T.test then T.allOff() end
      elseif k == "s" then UI.begin() UI.settings()
      elseif k == "p" then UI.begin() UI.pickMenu()
      elseif k == "c" then UI.begin() UI.setCentre()
      elseif k == "t" then UI.begin() UI.testShot()
      elseif k == "f" then UI.begin() UI.friendsMenu()
      elseif k == "y" then UI.begin() UI.yawTest()
      elseif k == "r" then
        P.scan()
        T.sync()
      end
      UI.busy = false
      UI.draw()
      timer = os.startTimer(0.5)
    elseif ev == "peripheral" or ev == "peripheral_detach" then
      P.scan()
      T.sync()
    end
  end
end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-base-autocannons"
local UPDATE_FILE = "autocannons.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- don't reboot in the middle of a fight
local function readyToUpdate()
  for _, p in pairs(S.players) do
    if not p.friend and p.edge <= ENGAGE_RANGE + 32 then return false end
  end
  for _, e in pairs(S.ships) do
    if S.shipIsTarget(e) then return false end
  end
  for _, t in ipairs(T.list) do if t.firing then return false end end
  return not UI.busy and not T.busy
end

local Upd = {}
-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
function Upd.splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

function Upd.braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
function Upd.statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = Upd.braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + Upd.braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
function Upd.mergeSettings(oldSrc, newSrc)
  local oldSettings = Upd.statements((Upd.splitSettings(oldSrc)))
  local newSettings, rest = Upd.splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = Upd.braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + Upd.braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

function Upd.fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

function Upd.check(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = Upd.fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or U.read(SHA_FILE) == sha then return end

  local newSrc = Upd.fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = U.read(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = Upd.mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    U.write(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  U.write(PROGRAM_PATH .. ".old", oldSrc)
  U.write(PROGRAM_PATH, merged)
  U.write(SHA_FILE, sha)
  T.allOff()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

function Upd.loop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(Upd.check)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
function Upd.boot()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(Upd.check, true)
end

-- ============================================================ start
Upd.boot()
P.scan()
T.sync()
T.allOff()

local ok, err = pcall(parallel.waitForAny, S.loop, S.radarLoop, T.loop, T.learnLoop, UI.loop, Upd.loop)
T.allOff()
if not ok then
  if tostring(err):find("Terminated") then
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)
    print("Autocannons stopped. Cannons set to hold fire.")
    return
  end
  printError(err)
  print("Restarting in 5s...")
  sleep(5)
  os.reboot()
end
