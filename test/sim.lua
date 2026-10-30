-- Simulated CC world for autocannons.lua: event kernel, CC parallel, a player
-- detector, and cc-cbc-like autocannon mounts with CBC round physics.
local SRC, END_T = ...
CLOCK = 0
local queue, timers, nextTimer = {}, {}, 0
local files = {}
hits, logs, fired = {}, {}, {}

files["/config.lua"] = [[
ALLOWED = { "levisnakes" }
ALLIES = { "Bob" }
AUTO_UPDATE = false
]] .. (SHIPS and ('SHIP_TARGETS = "' .. SHIPS .. '"\n') or "")
-- "home" is the user's own parked ship, marked with [S] 6 earlier
files["/autocannons/myships"] = '{["home"]=true}'


-- ---------------------------------------------------------------- kernel
os.clock = function() return CLOCK end
os.epoch = function() return 1.7e12 + CLOCK * 1000 end
os.startTimer = function(s)
  nextTimer = nextTimer + 1
  timers[nextTimer] = CLOCK + math.max(s, 0.05)
  return nextTimer
end
os.pullEventRaw = function(f) return coroutine.yield(f) end
os.pullEvent = function(f)
  local e = table.pack(os.pullEventRaw(f))
  if e[1] == "terminate" then error("Terminated", 0) end
  return table.unpack(e, 1, e.n)
end
os.reboot = function() error("REBOOT", 0) end
sleep = function(s)
  local id = os.startTimer(s or 0)
  repeat local _, p = os.pullEvent("timer") until p == id
end

parallel = {}
local function run(fns, limit)
  local cos, filters = {}, {}
  for i, f in ipairs(fns) do cos[i] = coroutine.create(f) end
  local living = #cos
  local ev = { n = 0 }
  while true do
    for n = 1, #fns do
      local r = cos[n]
      if r and (filters[r] == nil or filters[r] == ev[1] or ev[1] == "terminate") then
        local ok, param = coroutine.resume(r, table.unpack(ev, 1, ev.n))
        if not ok then error(param, 0) end
        filters[r] = param
        if coroutine.status(r) == "dead" then
          cos[n] = nil
          living = living - 1
          if living <= limit then return n end
        end
      end
    end
    ev = table.pack(os.pullEventRaw())
  end
end
parallel.waitForAny = function(...) return run({ ... }, #{ ... } - 1) end
parallel.waitForAll = function(...) return run({ ... }, 0) end

-- ---------------------------------------------------------------- basics
fs = {
  exists = function(p) return files[p] ~= nil end,
  makeDir = function() end,
  open = function(p, mode)
    if mode == "r" then
      if not files[p] then return nil end
      return { readAll = function() return files[p] end, close = function() end }
    end
    files[p] = ""
    return { write = function(s) files[p] = files[p] .. s end, close = function() end }
  end,
}
loadfile = function(p, mode, env) return load(files[p], p, mode, env) end
shell = { getRunningProgram = function() return "startup.lua" end }
colors = setmetatable({}, { __index = function() return 1 end })
term = setmetatable({ getSize = function() return 51, 19 end }, { __index = function() return function() end end })
write = function(s) lastPrompt = tostring(s) end
printed = {}
print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
printError = function(e) logs[#logs + 1] = "PRINTERROR " .. tostring(e) end

local function ser(v)
  local t = type(v)
  if t == "table" then
    local out = {}
    for k, x in pairs(v) do out[#out + 1] = "[" .. ser(k) .. "]=" .. ser(x) end
    return "{" .. table.concat(out, ",") .. "}"
  elseif t == "string" then return string.format("%q", v)
  else return tostring(v) end
end
textutils = { serialize = ser, unserialize = function(s) local f = load("return " .. s) return f and f() end }

-- ---------------------------------------------------------------- world
local function lerp(a, b, f) return a + (b - a) * f end
local players = {}
local function P(name, fn) players[name] = { name = name, fn = fn } end
P("levisnakes", function(t)
  -- track test: walk a circle (about 4.3 blocks/s) for cm0 to follow
  if TRACK and t > 16 then return 10 * math.cos(0.43 * t), 64, 10 * math.sin(0.43 * t) end
  return 0, 64, 0
end)
P("Bob", function(t)
  if FRIEND and t >= 40 then local x, y, z = players.Mechanoo.fn(t) return x + 2, y, z + 1 end
  return 20, 64, 40
end)
P("Mechanoo", function(t)
  if t < 30 then return 300, 64, 0 end
  if t < 40 then return lerp(160, 60, (t - 30) / 10), 64, 0 end
  -- strafing around inside the east side of the base
  return 40 + 10 * math.sin(0.6 * t), 64, 12 * math.cos(0.4 * t)
end)
P("FarGuy", function(t) return 0, 64, -250 end)       -- outside ENGAGE_RANGE: only shot when picked

-- ships (Sable) seen by the radars: centre positions
local ships = {
  -- empty drone flying past the north side, 22 m out
  drone = function(t) return lerp(-150, 150, math.max(0, math.min(1, (t - 10) / 40))), 90, -70 end,
  -- hostile ship hovering 36 m east of the base with Pilot on deck
  raider = function(t) return 100 + 3 * math.sin(0.3 * t), 90, 60 end,
  -- the user's own ship parked inside the base
  home = function(t) return 0, 72, 30 end,
}
P("Pilot", function(t) local x, y, z = ships.raider(t) return x, y + 2, z end)
mechHits = 0

-- read = how getInfo().yaw relates to the real yaw on each mount
local mounts = {
  cm0 = { x = -40, y = 66, z = -40, read = function(y) return y end },
  cm1 = { x = 56, y = 66, z = 56, read = function(y) return -y end },
  cm2 = { x = 56, y = 66, z = -40, read = function(y) return 90 - y end },
}
for name, m in pairs(mounts) do
  m.yaw, m.pitch, m.ty, m.tp, m.fire, m.cc, m.asm, m.cool = 0, 0, 0, 0, false, false, false, 0
  fired[name] = 0
end
-- like CBC: steel, recoil spring + 3 barrels (the spring counts as a barrel: 3 + 1.5 * 4 = 9 b/t),
-- the cannon pivots on the block 2 above the mount, muzzle 4.5 blocks out
local SPEED, LIFE, BARREL, DRAG, G = 9, 60, 4.5, 0.01, 0.025
local shells = {}
local function spawnShell(name, m)
  local cp = math.cos(math.rad(m.pitch))
  local dx, dy, dz = -math.sin(math.rad(m.yaw)) * cp, math.sin(math.rad(m.pitch)), math.cos(math.rad(m.yaw)) * cp
  local s = math.rad(0.4)                              -- a little spread
  dx, dy, dz = dx + (math.random() - 0.5) * s, dy + (math.random() - 0.5) * s, dz + (math.random() - 0.5) * s
  local px, py, pz = m.x + 0.5, m.y + 2.5, m.z + 0.5
  shells[#shells + 1] = { x = px + dx * BARREL, y = py + dy * BARREL, z = pz + dz * BARREL,
    vx = dx * SPEED, vy = dy * SPEED, vz = dz * SPEED, life = LIFE, from = name }
  fired[name] = fired[name] + 1
end

local function segDist(ax, ay, az, bx, by, bz, px, py, pz)
  local vx, vy, vz = bx - ax, by - ay, bz - az
  local wx, wy, wz = px - ax, py - ay, pz - az
  local vv = vx * vx + vy * vy + vz * vz
  local f = vv > 0 and math.max(0, math.min(1, (wx * vx + wy * vy + wz * vz) / vv)) or 0
  local cx, cy, cz = ax + vx * f - px, ay + vy * f - py, az + vz * f - pz
  return math.sqrt(cx * cx + cy * cy + cz * cz)
end

-- cm0's per-tick yaw steps while following levisnakes in the track test
yawSteps, aimErrs = {}, {}
local lastYaw
shipHits, missY = {}, {}
local function tick()
  CLOCK = CLOCK + 0.05
  if TRACK and CLOCK > 22 then
    local m = mounts.cm0
    if lastYaw then yawSteps[#yawSteps + 1] = (m.yaw - lastYaw + 180) % 360 - 180 end
    aimErrs[#aimErrs + 1] = aimAt("cm0", "levisnakes")
  end
  lastYaw = mounts.cm0.yaw
  for name, m in pairs(mounts) do
    if m.cc and m.asm then
      local dy = (m.ty - m.yaw + 180) % 360 - 180
      local step = 3
      if math.abs(dy) <= step then m.yaw = m.ty else m.yaw = m.yaw + step * (dy > 0 and 1 or -1) end
      m.yaw = m.yaw % 360
      local dp = math.max(-30, math.min(60, m.tp)) - m.pitch
      if math.abs(dp) <= 2 then m.pitch = m.pitch + dp else m.pitch = m.pitch + 2 * (dp > 0 and 1 or -1) end
    end
    m.cool = m.cool - 1
    if m.fire and m.asm and m.cool <= 0 then spawnShell(name, m) m.cool = 4 end
  end
  for i = #shells, 1, -1 do
    local s = shells[i]
    local ox, oy, oz = s.x, s.y, s.z
    local fx, fy, fz = -DRAG * s.vx, -DRAG * s.vy - G, -DRAG * s.vz
    s.x, s.y, s.z = s.x + s.vx + fx / 2, s.y + s.vy + fy / 2, s.z + s.vz + fz / 2
    s.vx, s.vy, s.vz = s.vx + fx, s.vy + fy, s.vz + fz
    s.life = s.life - 1
    local dead = s.life <= 0 or s.y < 63
    for name, p in pairs(players) do
      local x, y, z = p.fn(CLOCK)
      if not dead and segDist(ox, oy, oz, s.x, s.y, s.z, x, y + 0.9, z) < 1.0 then
        hits[#hits + 1] = { t = CLOCK, who = name, from = s.from }
        dead = true
      end
    end
    for name, fn in pairs(ships) do
      local x, y, z = fn(CLOCK)
      if not dead and segDist(ox, oy, oz, s.x, s.y, s.z, x, y, z) < 3 then
        shipHits[name] = (shipHits[name] or 0) + 1
        dead = true
      end
    end
    if s.from ~= "enemy" then
      local x, y, z = players.Mechanoo.fn(CLOCK)
      local h2 = (s.x - x) ^ 2 + (s.z - z) ^ 2
      if h2 < 4 and (not s.best or h2 < s.best) then s.best, s.dy = h2, s.y - (y + 0.9) end
    end
    if (dead or s.life <= 0) and s.dy then missY[#missY + 1] = s.dy s.dy = nil end
    if dead then table.remove(shells, i) end
  end
end

local function dist(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local per = {
  player_detector_0 = { types = { "player_detector" }, m = {
    getPlayersInRange = function(r)
      local out = {}
      for name, p in pairs(players) do
        local x, y, z = p.fn(CLOCK)
        if dist(x, y - 64, z) <= r then out[#out + 1] = name end
      end
      return out
    end,
    getPlayer = function(n)
      local x, y, z = players[n].fn(CLOCK)
      return { x = x, y = y, z = z, eyeHeight = 1.62 }
    end } },
  modem_0 = { types = { "modem" }, m = {} },
  -- the radar monitor has getTracks too, but must not count as a radar
  radar_monitor_0 = { types = { "create_radar:monitor" }, m = {
    getTracks = function() error("monitor polled as a radar") end, getSelectedTrackId = function() end } },
}
local function tracks()
  local out = {}
  for name, fn in pairs(ships) do
    local x, y, z = fn(CLOCK)
    out[#out + 1] = { id = name, category = "SABLE", entityType = "sable:sub_level", position = { x = x, y = y, z = z } }
  end
  for name, pl in pairs(players) do
    local x, y, z = pl.fn(CLOCK)
    out[#out + 1] = { id = "p" .. name, category = "PLAYER", position = { x = x, y = y, z = z } }
  end
  return out
end
for i = 0, 1 do
  per["plane_radar_" .. i] = { types = { "create_radar:plane_radar" }, m = {
    getTracks = tracks, getPosition = function() return { x = 0, y = 64, z = 0 } end } }
end
for name, m in pairs(mounts) do
  per[name] = { types = { "cannon_mount" }, m = {
    getInfo = function()
      return { x = m.x, y = m.y, z = m.z, yaw = m.read(m.yaw) % 360, pitch = m.pitch, targetYaw = m.ty,
        targetPitch = m.tp, computerControl = m.cc, assembled = m.asm, yawShaftSpeed = 32, pitchShaftSpeed = 32 }
    end,
    -- like cc-cbc: turning control on copies the real angles into the target
    setComputerControl = function(v)
      if v then m.ty, m.tp = m.yaw, m.pitch end
      m.cc = v
    end,
    assemble = function(v) m.asm = v return true end,
    setTargetAngles = function(y, p)
      assert(y == y and p == p, "NaN angle")
      m.ty, m.tp = y % 360, p
    end,
    fire = function(v) m.fire = v return true end } }
end
peripheral = {
  getNames = function()
    local o = {}
    for n in pairs(per) do o[#o + 1] = n end
    o[#o + 1] = "cm0" -- duplicate, like two modems on one network
    return o
  end,
  hasType = function(n, t) for _, x in ipairs(per[n].types) do if x == t then return true end end return false end,
  getMethods = function(n) local o = {} for k in pairs(per[n].m) do o[#o + 1] = k end return o end,
  call = function(n, meth, ...)
    local f = per[n] and per[n].m[meth]
    if not f then error("No such method " .. tostring(meth)) end
    -- most peripheral calls take a game tick
    local r = table.pack(f(...))
    sleep(0.05)
    return table.unpack(r, 1, r.n)
  end,
}

read = function()
  local p = lastPrompt or ""
  if p:find("ARM") then return "ARM" end
  if ANSWERS and #ANSWERS > 0 then return table.remove(ANSWERS, 1) end
  -- pick menu: choose the line naming PICK
  if p == "> " and PICK then
    for i = #printed, 1, -1 do
      local n = printed[i]:match("^(%d+)%) " .. PICK)
      if n then return n end
    end
  end
  return ""
end

local keys = { { 20, "a" } }
-- track test on, then armed too: must aim at friends but never fire
if TRACK then keys = { { 15, "k" }, { 20, "a" } } end
if PICK then keys = { { 20, "a" }, { 22, "p" } } end
-- settings menu: 9x9 chunks, 20 m engage range, ship mode hostile -> unknown, back
if SETTINGS then keys = { { 5, "s" } } ANSWERS = { "1", "9", "2", "20", "3", "" } end
function aimAt(name, who)
  local m, p = mounts[name], players[who]
  local x, _, z = p.fn(CLOCK)
  local want = math.deg(math.atan(-(x - m.x - 0.5), z - m.z - 0.5)) % 360
  return math.abs((m.yaw - want + 180) % 360 - 180)
end

-- ---------------------------------------------------------------- run
local main = coroutine.create(function() return load(SRC, "=autocannons")() end)
local filter
local ev = { n = 0 }
while CLOCK < END_T do
  local ok, f = coroutine.resume(main, table.unpack(ev, 1, ev.n))
  if not ok then logs[#logs + 1] = "FATAL " .. tostring(f) break end
  if coroutine.status(main) == "dead" then break end
  filter = f
  ev = nil
  while not ev do
    if #queue > 0 then
      ev = table.remove(queue, 1)
    else
      local best, bid = math.huge, nil
      for id, at in pairs(timers) do if at < best or (at == best and id < bid) then best, bid = at, id end end
      if keys[1] and keys[1][1] <= best then
        while CLOCK < keys[1][1] do tick() end
        ev = table.pack("char", keys[1][2])
        table.remove(keys, 1)
      elseif bid then
        while CLOCK + 1e-9 < best do tick() end
        timers[bid] = nil
        ev = table.pack("timer", bid)
      else
        logs[#logs + 1] = "FATAL no timers" CLOCK = END_T ev = { n = 0 }
      end
    end
    if ev and filter and ev[1] ~= filter and ev[1] ~= "terminate" then ev = nil end
  end
end
yawmap = files["/autocannons/yawmap"]
savedSettings = files["/autocannons/settings"]
-- check each learned map turns the reading back into the real yaw
mapOk = {}
local map = yawmap and textutils.unserialize(yawmap) or {}
for name, m in pairs(mounts) do
  local mp = map[name]
  if mp then
    local real = (mp[1] * (m.read(m.yaw) % 360 - mp[2])) % 360
    mapOk[name] = math.abs((real - m.yaw + 180) % 360 - 180) < 0.01
  else
    mapOk[name] = false
  end
end
