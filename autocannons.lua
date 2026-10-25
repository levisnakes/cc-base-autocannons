-- Base Autocannons - automatic autocannon defence for a CMP base.
-- One computer aims any number of Create Big Cannons autocannons (CC:CBC
-- cannon mounts) at hostile players near the base. Team and allies are never
-- shot, and fire is held when a friend is near the line of fire.
-- wget https://raw.githubusercontent.com/levisnakes/cc-base-autocannons/main/autocannons.lua startup.lua

-- Protection block position (F3). The base is its chunk +/- BASE_RADIUS_CHUNKS.
CORE = { x = 0, y = 64, z = 0 }
BASE_RADIUS_CHUNKS = 3        -- 3 = 7x7 chunks
ENGAGE_RANGE = 48             -- shoot hostiles up to this far outside the base edge (0 = inside only)
DETECT_RANGE = 300            -- player detector range (server max 512)

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
local VERSION = "1.0.0"
local DIR = "/autocannons"
local LATENCY = 0.15          -- seconds between reading a position and the round leaving
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

local friends
local savedAllies = U.load(DIR .. "/allies") or {}
local function rebuildLists() friends = U.lowerSet(ALLOWED, ALLIES, savedAllies) end
rebuildLists()

-- ============================================================ base area
local B = {}
do
  local cx, cz = floor(CORE.x / 16), floor(CORE.z / 16)
  B.minX = (cx - BASE_RADIUS_CHUNKS) * 16
  B.maxX = (cx + BASE_RADIUS_CHUNKS + 1) * 16
  B.minZ = (cz - BASE_RADIUS_CHUNKS) * 16
  B.maxZ = (cz + BASE_RADIUS_CHUNKS + 1) * 16
  B.cx, B.cz = (B.minX + B.maxX) / 2, (B.minZ + B.maxZ) / 2
  B.chunks = BASE_RADIUS_CHUNKS * 2 + 1
end
-- distance outside the base edge (0 inside)
function B.edge(x, z)
  local dx = max(B.minX - x, 0, x - B.maxX)
  local dz = max(B.minZ - z, 0, z - B.maxZ)
  return sqrt(dx * dx + dz * dz)
end

-- ============================================================ peripherals
local P = { det = nil, mounts = {} }
function P.scan()
  P.det, P.mounts = nil, {}
  local seen = {}
  local names = peripheral.getNames()
  table.sort(names)
  for _, n in ipairs(names) do
    if not seen[n] then
      seen[n] = true
      if peripheral.hasType(n, "player_detector") then P.det = P.det or n
      elseif peripheral.hasType(n, "cannon_mount") then P.mounts[#P.mounts + 1] = n
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
local S = { players = {} }

local function pushHist(e, x, y, z, t)
  local h = e.hist
  h[#h + 1] = { t = t, x = x, y = y, z = z }
  while #h > 12 or (#h > 2 and t - h[1].t > 1.0) do table.remove(h, 1) end
  local o = h[1]
  local dt = t - o.t
  if dt >= 0.2 then
    e.vx, e.vy, e.vz = (x - o.x) / dt, (y - o.y) / dt, (z - o.z) / dt
  elseif not e.vx then
    e.vx, e.vy, e.vz = 0, 0, 0
  end
end

function S.scan(now)
  if not P.det then return end
  local ok, names = P.call(P.det, "getPlayersInRange", DETECT_RANGE)
  if not ok or type(names) ~= "table" then return end
  local got, fns = {}, {}
  for _, name in ipairs(names) do
    fns[#fns + 1] = function()
      local okp, p = P.call(P.det, "getPlayer", name)
      if okp and type(p) == "table" and p.x then got[name] = p end
    end
  end
  U.all(fns)
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

function S.loop()
  while true do
    S.scan(os.clock())
    sleep(0.1)
  end
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

-- hostiles this turret could shoot at, best first
function T.candidates(t, px, py, pz)
  local out = {}
  for l, p in pairs(S.players) do
    if not p.friend and p.edge <= ENGAGE_RANGE then
      local d = sqrt((p.x - px) ^ 2 + (p.y - py) ^ 2 + (p.z - pz) ^ 2)
      if d >= MIN_RANGE then
        local score = p.edge + d * 0.05
        if t.target == l then score = score - 15 end
        if not FOCUS_FIRE then
          for _, o in ipairs(T.list) do
            if o ~= t and o.target == l then score = score + 30 end
          end
        end
        out[#out + 1] = { key = l, e = p, score = score }
      end
    end
  end
  table.sort(out, function(a, b) return a.score < b.score end)
  return out
end

function T.step(t, now)
  local ok, info = P.call(t.name, "getInfo")
  if not ok or type(info) ~= "table" then t.state = "no reply" setFire(t, false) return end
  t.info = info
  if info.assembled == false then
    setFire(t, false)
    t.state = "not assembled"
    P.call(t.name, "assemble", true)
    return
  end
  if not info.computerControl then P.call(t.name, "setComputerControl", true) end
  t.noPower = (info.yawShaftSpeed or 0) == 0 or (info.pitchShaftSpeed or 0) == 0
  if not T.yawMap[t.name] then setFire(t, false) t.needsLearn = true return end

  local px, py, pz = info.x + 0.5, info.y + 1.5, info.z + 0.5
  local chosen, held
  for _, cand in ipairs(T.candidates(t, px, py, pz)) do
    local yaw, pitch, ticks, ax, ay, az = Bal.aim(t.c, px, py, pz, cand.e, t.target == cand.key and t.pitch or nil)
    if yaw then
      local why = Bal.unsafe(Bal.path(t.c, px, py, pz, yaw, pitch, ticks), ticks, ax, ay, az, cand.e)
      if not why then
        chosen = { key = cand.key, e = cand.e, yaw = yaw, pitch = pitch, ax = ax, az = az }
        break
      end
      held = held or why
    else
      held = held or ("out of reach: " .. cand.e.name)
    end
  end

  if not chosen then
    setFire(t, false)
    t.target, t.pitch = nil, nil
    t.state = held and ("hold: " .. held) or (t.noPower and "NO ROTATION" or "watching")
    return
  end
  t.target, t.pitch = chosen.key, chosen.pitch
  local my = (chosen.yaw + t.c.yawTrim) % 360
  local mp = (chosen.pitch + t.c.pitchTrim) * (INVERT_PITCH and -1 or 1)
  if not t.sent or abs(U.angDiff(t.sent[1], my)) > 0.05 or abs(t.sent[2] - mp) > 0.05 or now - t.sent[3] > 1 then
    P.call(t.name, "setTargetAngles", my, mp)
    t.sent = { my, mp, now }
  end

  -- fire while the barrel is within about a body-width of the aim point
  local dist = sqrt((chosen.ax - px) ^ 2 + (chosen.az - pz) ^ 2)
  local tol = max(0.5, deg(math.atan(0.8 / max(dist, 1))))
  if t.firing then tol = tol * 1.5 end
  local cy = T.realYaw(t, info)
  local aimed = cy and info.pitch and abs(U.angDiff(cy, my)) <= tol and abs(info.pitch - mp) <= tol
  local name = chosen.e.name
  if not aimed then
    setFire(t, false)
    t.state = "aiming at " .. name .. (t.noPower and " (NO ROTATION)" or "")
  elseif not T.armed then
    setFire(t, false)
    t.state = "on " .. name .. " (SAFE)"
  else
    setFire(t, true)
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
    sleep(0.05)
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
  local st = T.armed and " ARMED " or " SAFE "
  term.setCursorPos(w - #st + 1, 1)
  term.setBackgroundColor(T.armed and colors.red or colors.green)
  term.setTextColor(colors.white)
  write(st)
  term.setBackgroundColor(colors.black)
  term.setTextColor(colors.lightGray)
  term.setCursorPos(1, 2)
  write(string.format("%dx%d chunks, engage %s out, detector %s", B.chunks, B.chunks, U.m(ENGAGE_RANGE),
    P.det and "ok" or "MISSING"))

  local list = {}
  for _, p in pairs(S.players) do
    if p.edge <= ENGAGE_RANGE + 64 then list[#list + 1] = p end
  end
  table.sort(list, function(a, b) return a.edge < b.edge end)
  term.setCursorPos(1, 4)
  term.setTextColor(colors.gray)
  write("Players near (" .. #list .. ")")
  local row = 5
  local maxRows = max(1, h - 7 - #T.list)
  for i = 1, min(#list, maxRows) do
    local p = list[i]
    term.setCursorPos(1, row)
    term.setTextColor(p.friend and colors.lime or colors.red)
    local where = p.edge <= 0 and "INSIDE" or (U.m(p.edge) .. " " .. U.compass(p.x - B.cx, p.z - B.cz))
    local tag = p.friend and "friend" or (p.edge <= ENGAGE_RANGE and "TARGET" or "hostile")
    write(string.format("%-8s %-16s %s", tag, p.name:sub(1, 16), where))
    row = row + 1
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
  write("[A]rm [T]est shot [F]riends [Y]aw test [R]escan")
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

local ok, err = pcall(parallel.waitForAny, S.loop, T.loop, T.learnLoop, UI.loop, Upd.loop)
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
