-- Regression: debug-only code (lines marked REMOVE_LINE) must not run in the installed add-on.
-- It once did: FindTrail called PrintPath, which reset TomTom's waypoints on every call, so
-- Compass's arrow was torn down and redrawn several times a second.
-- 1. deploy.sh installs a build with no REMOVE_LINE line and no file only a REMOVE_LINE line loads.
-- 2. FindTrail leaves TomTom and DevTool stand-ins untouched, in that build and in the repo as is.
-- luajit tests/removeline.lua
local root = arg[0]:match("^(.*)/tests/[^/]+$") or "."
local failures = 0
local function check(cond, what) if not cond then failures = failures + 1; print("FAIL: " .. what) end end

local function sh(cmd)
    local p = assert(io.popen(cmd .. " 2>&1"))
    local out = p:read("*a")
    local ok = p:close()
    return out, ok
end
local function read(path)
    local f = assert(io.open(path, "r"))
    local s = f:read("*a")
    f:close()
    return s
end
local function lines(cmd)
    local t = {}
    for l in sh(cmd):gmatch("[^\n]+") do t[#t + 1] = l end
    return t
end

-- Install into a scratch game folder with a retail and a Forever client.
local tmp = sh("mktemp -d"):gsub("%s+$", "")
local addons = tmp .. "/_retail_/Interface/AddOns"
os.execute("mkdir -p '" .. addons .. "' '" .. tmp .. "/_forever_/Interface/AddOns'")
local out, ok = sh("WOW_DIR='" .. tmp .. "' bash '" .. root .. "/deploy.sh'")
check(ok, "deploy.sh succeeds: " .. out)
local installed = addons .. "/FarstriderLib"

-- 1. The installed build.
local files = lines("find '" .. installed .. "' -type f")
check(#files > 0, "deploy.sh installed files")
local lua = {}
for _, f in ipairs(files) do
    local rel = f:sub(#installed + 2)
    if f:match("%.lua$") or f:match("%.xml$") or f:match("%.toc$") then
        check(not read(f):find("REMOVE_LINE", 1, true), rel .. " has a REMOVE_LINE line")
    end
    if f:match("%.lua$") then
        lua[#lua + 1] = f
        check(loadfile(f), rel .. " still parses")
        local s = read(f)
        check(not s:find("TomTom", 1, true) and not s:find("DevTool", 1, true), rel .. " mentions TomTom or DevTool")
    end
    check(not rel:match("%.d%.lua$"), rel .. " is a debug file")
    check(not rel:match("~Logger%.lua$") and not rel:match("~Debug%.lua$"), rel .. " is a debug file")
end
for _, f in ipairs(lines("find '" .. tmp .. "/_forever_' -name 'FarstriderLib.xml'")) do
    check(read(f) == read(installed .. "/FarstriderLib.xml"), "retail and Forever installs match")
end
local function loadOrder(dir, xml)
    local list = {}
    for file in read(dir .. "/" .. xml):gmatch("<Script%s+file=[\"']([^\"']+)[\"']") do
        file = file:gsub("\\", "/")
        check(io.open(dir .. "/" .. file), xml .. " lists " .. file .. ", which is missing")
        list[#list + 1] = file
    end
    return list
end
local dataXmls = lines("find '" .. installed .. "/Data' -name '*.xml'")
for _, x in ipairs(dataXmls) do loadOrder(x:match("^(.*)/[^/]+$"), x:match("[^/]+$")) end
check(read(installed .. "/FarstriderLib.toc"):find("FarstriderLib.xml", 1, true), "TOC loads FarstriderLib.xml")

-- 2. FindTrail against stand-ins for TomTom and DevTool.
local function recorder(name, calls)
    return setmetatable({}, {
        __index = function(_, k) calls[#calls + 1] = name .. "." .. tostring(k); return function() end end,
        __newindex = function(_, k) calls[#calls + 1] = name .. "." .. tostring(k) .. "=" end,
    })
end
local quiet = setmetatable({}, { __index = function() return function() end end })

local function findTrailTouches(dir)
    for _, g in ipairs({ "FarstriderLib", "FarstriderLib_API", "FarstriderLibData_API", "SlashCmdList" }) do _G[g] = nil end
    SlashCmdList = {}
    local calls = {}
    TomTom, DevTool = recorder("TomTom", calls), recorder("DevTool", calls)
    CreateFrame = function() return quiet end
    C_Timer = { After = function() end, NewTicker = function() return quiet end, NewTimer = function() return quiet end }
    IsLoggedIn = function() return false end
    GetTime = function() return 0 end
    hooksecurefunc = function() end
    CreateVector2D = function(x, y) return { x = x, y = y } end
    debugstack = function() return "Interface/AddOns/FarstriderLib/FarstriderLib~Init.lua:1:" end
    local ns = {}
    for _, file in ipairs(loadOrder(dir, "FarstriderLib.xml")) do
        assert(loadfile(dir .. "/" .. file))("FarstriderLib", ns)
    end
    local P = _G.FarstriderLib.Pathfinding
    local edge = { loc = { mapId = 1, pos = { x = 0.1, y = 0.2, z = 0 } }, loca = "Reach the destination", locaId = 1000 }
    P.FindPathBetweenLocations2 = function() return { edge }, { { key = "a" } }, { edge } end
    local okCall, optimized = pcall(FarstriderLib_API.FindTrail, 1, 0.1, 0.1, 0, 1, 0.9, 0.9, 0)
    check(okCall, "FindTrail runs: " .. tostring(optimized))
    check(okCall and #optimized == 1, "FindTrail returns the path")
    return calls
end

local function describe(calls) return table.concat(calls, ", ") end
local calls = findTrailTouches(installed)
check(#calls == 0, "FindTrail touches TomTom/DevTool in the installed build: " .. describe(calls))
calls = findTrailTouches(root)
check(#calls == 0, "FindTrail touches TomTom/DevTool in the repo: " .. describe(calls))

os.execute("rm -rf '" .. tmp .. "'")
if failures > 0 then os.exit(1) end
print("removeline: ok")
