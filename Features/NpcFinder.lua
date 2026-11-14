local _, ns = ...
local L, UI, Util = ns.L, ns.UI, ns.Util

--[[
Find an NPC from the world map: type a name in the bar on the map (or
/npc Name), the map goes to the NPC's zone and a star marks where it stands.

Items too: the same bar finds items (or /item Name, or Alt+click on an
item anywhere). Picking one lists where it comes from, nearest first:
vendors (the other faction's hidden), gathering nodes and chests, mobs
(with the drop rate when QuestieDB has it), containers and quest rewards.
A source shows on the map like an NPC; a group header shows all of them.
QuestieDB is quest-oriented: random drops, raid loot and crafted items
have no source there.

Where the data comes from:
  QuestieDB's public API (NpcDB, ItemDB, ObjectDB, QuestDB) and its zone
  and drop-rate tables, read while playing. QuestieDB is an optional
  dependency the player installs: none of its code or data is copied here
  (its LICENSE.md is unclear about copying).

Markers go through HereBeDragons-Pins (TomTom loads it), so OpenMap's
stitched map places them too. Shift when picking a result also sets a
TomTom arrow; Ctrl-click on an NPC puts it in the hunting list
(Features\HuntList.lua, which also uses the Finder.Npc* functions).

The bar sits in the map's top-left corner, to the right of any button
already there: other addons and the game keep theirs in that corner, so
they are looked for each time the map opens or changes. Shift-drag moves
the bar; the "Put the bar back" option undoes that.
]]

local KEY = "npcFinder"
local PIN_REF = "BudgetForeverNpcFinder" -- our tag for HereBeDragons' pins
local CONTRACT = 4          -- the QuestieDB API version this was written against
local ROWS = 12             -- result rows under the bar
local ROW_HEIGHT = 18
local CHECK = 40            -- best text matches whose positions are looked up
local MAX_POINTS = 80       -- markers per NPC at most (the nearest to you)
local KEPT_POINTS = 600     -- positions read per NPC or object
local GROUP_POINTS = 150    -- markers for a whole group of sources at most
local FAR = 1e9             -- distance of a point on another continent, or unknown
local POINT_ZOOM = 14       -- OpenMap's zoom on a single point (as its own search uses)
local BAR_WIDTH, BAR_HEIGHT = 220, 22
local BAR_X, BAR_Y = 10, -8 -- the bar's place in the map's top-left corner
local BAR_GAP = 16          -- space kept from a button already there (the search box's border reaches ~5 left of it)
local BIG = 260             -- a frame larger than this both ways is a panel, not a button
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"
local HIGHLIGHT = "Interface\\QuestFrame\\UI-QuestTitleHighlight"

-- How each kind of source looks: marker, its glow, and the icon in the list.
local ROLES = {
    npc = { icon = STAR, r = 1, g = 0.8, b = 0.2 },
    vendor = { icon = "Interface\\GossipFrame\\VendorGossipIcon", r = 1, g = 0.8, b = 0.2 },
    node = { icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_3", r = 0.75, g = 0.45, b = 1 },
    drop = { icon = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8", r = 1, g = 0.3, b = 0.25 },
    container = { icon = "Interface\\Icons\\INV_Box_01" },
    quest = { icon = "Interface\\GossipFrame\\AvailableQuestIcon", r = 1, g = 0.9, b = 0.2 },
}

local Finder = {}
ns.NpcFinder = Finder

---------------------------------------------------------------------------
-- QuestieDB access
---------------------------------------------------------------------------

-- False and a reason when QuestieDB can't be used (no reason: it isn't
-- loaded, said in the current language when shown).
local function DataReady()
    local lib, npc = _G.LibQuestieDB, _G.NpcDB
    if type(lib) ~= "table" or type(npc) ~= "table" then
        return false, nil
    end
    if lib.RequireContract then
        local ok, message = lib.RequireContract(CONTRACT)
        if not ok then return false, tostring(message) end
    end
    return true
end

-- Items need ItemDB and ObjectDB as well (same QuestieDB).
local function ItemsReady()
    return DataReady() and type(_G.ItemDB) == "table" and type(_G.ObjectDB) == "table"
end

-- A QuestieDB field, nil when it can't be read.
local function Field(db, name, id)
    local get = db and db[name]
    if type(get) ~= "function" then return end
    local ok, value = pcall(get, id)
    if ok then return value end
end

-- area ID -> uiMapID, and area ID -> dungeon entry, from QuestieDB's zone tables
local areaToMap, dungeonOf
local validMap = {}

local function Decode(source)
    if type(source) == "table" then return source end
    if type(source) ~= "string" then return {} end
    local chunk = loadstring(source)
    if not chunk then return {} end
    local ok, result = pcall(chunk)
    return (ok and type(result) == "table") and result or {}
end

local function Zones()
    if areaToMap then return end
    areaToMap, dungeonOf = {}, {}
    local lib = _G.LibQuestieDB
    local support = lib and lib.Support and lib.Support.Get and lib.Support.Get("ZoneDB")
    local private = support and support.private or {}
    for area, map in pairs(Decode(private.areaIdToUiMapId)) do areaToMap[area] = map end
    for area, map in pairs(Decode(private.areaIdToUiMapIdOverride)) do areaToMap[area] = map end
    if type(private.dungeons) == "table" then
        -- { name, alternativeAreaIds, parentZone, { { zoneAreaId, x, y }, ... } }
        for area, entry in pairs(private.dungeons) do
            if type(entry) == "table" then
                dungeonOf[area] = entry
                if type(entry[2]) == "table" then
                    for _, alt in ipairs(entry[2]) do dungeonOf[alt] = dungeonOf[alt] or entry end
                end
            end
        end
    end
end

local function MapOf(area)
    local map = areaToMap[area]
    if not map or map == 0 then return end
    if validMap[map] == nil then validMap[map] = C_Map.GetMapInfo(map) ~= nil end
    return validMap[map] and map or nil
end

-- Every place an NPC (or an object: kind "object") can be found:
-- { uiMapID, x, y } (0..1), with .dungeon for an instance's entrance
-- (what is inside instances has no map position).
local pointsCache = { npc = {}, object = {} }

local function Points(id, kind)
    local cache = pointsCache[kind or "npc"]
    local cached = cache[id]
    if cached then return cached end
    Zones()
    local out, entered = {}, {}
    local spawns = Field(kind == "object" and _G.ObjectDB or NpcDB, "spawns", id)
    if type(spawns) == "table" then
        for area, list in pairs(spawns) do
            local dungeon = dungeonOf[area]
            if dungeon then
                -- A dungeon's entrances once, even when its NPC is listed
                -- under several of its area IDs.
                local entrances = not entered[dungeon] and dungeon[4] or {}
                entered[dungeon] = true
                for _, entrance in ipairs(entrances) do
                    local map = type(entrance) == "table" and MapOf(entrance[1])
                    if map and type(entrance[2]) == "number" and type(entrance[3]) == "number" then
                        out[#out + 1] = { map, entrance[2] / 100, entrance[3] / 100, dungeon = dungeon[1] }
                    end
                end
            else
                local map = MapOf(area)
                if map and type(list) == "table" then
                    for _, spot in ipairs(list) do
                        if type(spot) == "table" and type(spot[1]) == "number" and type(spot[2]) == "number"
                            and spot[1] >= 0 and spot[2] >= 0 then
                            out[#out + 1] = { map, spot[1] / 100, spot[2] / 100 }
                        end
                        if #out >= KEPT_POINTS then break end
                    end
                end
            end
            if #out >= KEPT_POINTS then break end
        end
    end
    cache[id] = out
    return out
end

-- The map with the most points, the middle of its points, and the point
-- nearest that middle.
local function Summary(points)
    if #points == 0 then return end
    local count, best, maps = {}, nil, 0
    for _, point in ipairs(points) do
        local n = (count[point[1]] or 0) + 1
        if n == 1 then maps = maps + 1 end
        count[point[1]] = n
        if not best or n > count[best] then best = point[1] end
    end
    local sumX, sumY, n = 0, 0, 0
    for _, point in ipairs(points) do
        if point[1] == best then sumX, sumY, n = sumX + point[2], sumY + point[3], n + 1 end
    end
    local centerX, centerY = sumX / n, sumY / n
    local nearest, nearestDistance
    for _, point in ipairs(points) do
        if point[1] == best then
            local distance = (point[2] - centerX) ^ 2 + (point[3] - centerY) ^ 2
            if not nearestDistance or distance < nearestDistance then nearest, nearestDistance = point, distance end
        end
    end
    return best, centerX, centerY, nearest, maps
end

---------------------------------------------------------------------------
-- Distance from the player (HereBeDragons' world coordinates, in yards)
---------------------------------------------------------------------------

local function Geometry() return LibStub and LibStub("HereBeDragons-2.0", true) end

local worldOf = setmetatable({}, { __mode = "k" }) -- point -> { x, y, instance } or false

local function World(point)
    local known = worldOf[point]
    if known == nil then
        known = false
        local hbd = Geometry()
        if hbd and hbd.GetWorldCoordinatesFromZone then
            local ok, x, y, instance = pcall(hbd.GetWorldCoordinatesFromZone, hbd, point[2], point[3], point[1])
            if ok and x and y then known = { x, y, instance } end
        end
        worldOf[point] = known
    end
    return known or nil
end

-- Where the player is, for Distance(): world x, y, instance, and the map.
local function Here()
    local here = {}
    if C_Map and C_Map.GetBestMapForUnit then here.map = C_Map.GetBestMapForUnit("player") end
    local hbd = Geometry()
    if hbd and hbd.GetPlayerWorldPosition then
        local ok, x, y, instance = pcall(hbd.GetPlayerWorldPosition, hbd)
        if ok and x and y then here.x, here.y, here.instance = x, y, instance end
    end
    return here
end

-- Yards from the player; without world coordinates, 0 on the player's map
-- and FAR elsewhere.
local function Distance(point, here)
    if here.x then
        local world = World(point)
        if world and world[3] == here.instance then
            return math.sqrt((world[1] - here.x) ^ 2 + (world[2] - here.y) ^ 2)
        end
        return FAR
    end
    return (here.map and point[1] == here.map) and 0 or FAR
end

-- The point nearest the player and its distance.
local function Closest(points, here)
    local best, bestDistance
    for _, point in ipairs(points) do
        local distance = Distance(point, here)
        if not bestDistance or distance < bestDistance then best, bestDistance = point, distance end
    end
    return best, bestDistance or FAR
end

-- At most `count` points, the nearest to the player first.
local function Nearest(points, count, here)
    if #points <= count then return points end
    local ranked = {}
    for i, point in ipairs(points) do ranked[i] = { point, Distance(point, here), i } end
    table.sort(ranked, function(a, b)
        if a[2] ~= b[2] then return a[2] < b[2] end
        return a[3] < b[3]
    end)
    local out = {}
    for i = 1, count do out[i] = ranked[i][1] end
    return out
end

---------------------------------------------------------------------------
-- Drop rates: QuestieDB keeps Wowhead's rates for quest items, as one big
-- string. Only the block of the item asked for is read.
---------------------------------------------------------------------------

local dropText -- false when missing
local ratesCache = {}

function Finder.DropRates(itemId)
    local cached = ratesCache[itemId]
    if cached then return cached end
    if dropText == nil then
        dropText = false
        local lib = _G.LibQuestieDB
        local module = lib and lib.Support and lib.Support.Get and lib.Support.Get("QuestieClassicItemDrops")
        if module and type(module.wowheadData) == "string" then dropText = module.wowheadData end
    end
    local rates = {}
    if dropText then
        local _, open = dropText:find("[%[]" .. itemId .. "%]%s*=%s*{")
        local close = open and dropText:find("}", open + 1, true)
        if close then
            for npc, rate in dropText:sub(open + 1, close - 1):gmatch("%[(%d+)%]%s*=%s*([%d%.]+)") do
                rates[tonumber(npc)] = tonumber(rate)
            end
        end
    end
    ratesCache[itemId] = rates
    return rates
end

---------------------------------------------------------------------------
-- Name index: every NPC name folded (lower case, no accents), built a
-- slice per frame so opening the map never freezes the game.
---------------------------------------------------------------------------

local function Utf8(codepoint) return string.char(192 + math.floor(codepoint / 64), 128 + codepoint % 64) end

local FOLD = {}
local function FoldTo(to, ...)
    for i = 1, select("#", ...) do FOLD[Utf8((select(i, ...)))] = to end
end
FoldTo("a", 0xC0, 0xC1, 0xC2, 0xC3, 0xC4, 0xC5, 0xE0, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5)
FoldTo("ae", 0xC6, 0xE6)
FoldTo("c", 0xC7, 0xE7)
FoldTo("e", 0xC8, 0xC9, 0xCA, 0xCB, 0xE8, 0xE9, 0xEA, 0xEB)
FoldTo("i", 0xCC, 0xCD, 0xCE, 0xCF, 0xEC, 0xED, 0xEE, 0xEF)
FoldTo("n", 0xD1, 0xF1)
FoldTo("o", 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD8, 0xF2, 0xF3, 0xF4, 0xF5, 0xF6, 0xF8)
FoldTo("u", 0xD9, 0xDA, 0xDB, 0xDC, 0xF9, 0xFA, 0xFB, 0xFC)
FoldTo("y", 0xDD, 0xFD, 0xFF)
FoldTo("ss", 0xDF)

local function Fold(text)
    -- Accents first: lower() must never see a UTF-8 lead byte, which some
    -- C locales would change.
    text = text:gsub("\195[\128-\191]", FOLD):lower()
    text = text:gsub("['`]", ""):gsub("[%-_%.,:]", " "):gsub("%s+", " ")
    return (text:match("^%s*(.-)%s*$"))
end

local keys, ids, kinds = {}, {}, {}
local indexState            -- nil, "building", "ready", "failed"
local indexError            -- why it failed (nil: QuestieDB isn't loaded), see IndexError()
local phases, phase, cursor = nil, 1, 0 -- { kind, db, ids } per kind of name
local englishToo = GetLocale() ~= "enUS" -- also find English names on other clients
local OnIndexReady, OnIndexProgress

local function AddKey(kind, id, name)
    local key = Fold(name)
    if key ~= "" then
        keys[#keys + 1] = key
        ids[#ids + 1] = id
        kinds[#kinds + 1] = kind
    end
end

-- Indexes NPC then item names until done, or until `budget` milliseconds
-- have gone (nil: no limit).
local function IndexBatch(budget)
    local start = debugprofilestop()
    while phases[phase] do
        local current = phases[phase]
        local db, list = current.db, current.ids
        local count = #list
        while cursor < count do
            cursor = cursor + 1
            local id = list[cursor]
            local name = db.name(id)
            if type(name) == "string" and name ~= "" then
                AddKey(current.kind, id, name)
                if englishToo and db.GetRaw then
                    local raw = db.GetRaw(id, "name")
                    if type(raw) == "string" and raw ~= name then AddKey(current.kind, id, raw) end
                end
            end
            if budget and debugprofilestop() - start > budget then return false end
        end
        phase, cursor = phase + 1, 0
    end
    return true
end

local worker = CreateFrame("Frame")
worker:Hide()

local function Pump(budget)
    if indexState ~= "building" then return indexState == "ready" end
    local ok, done = pcall(IndexBatch, budget)
    if not ok then
        indexState, indexError = "failed", L.NPC_DB_ERROR:format(tostring(done))
        worker:Hide()
        ns:Print(indexError)
        return false
    end
    if done then
        indexState = "ready"
        worker:Hide()
        phases = nil
        if OnIndexReady then OnIndexReady() end
    end
    return done
end

worker:SetScript("OnUpdate", function()
    Pump(6)
    if indexState == "building" and OnIndexProgress then OnIndexProgress() end
end)

-- Starts the index once. False (IndexError() says why) when QuestieDB can't be read.
local function StartIndex()
    if indexState then return indexState ~= "failed" end
    local ok, problem = DataReady()
    if not ok then
        indexState, indexError = "failed", problem
        return false
    end
    phases = { { kind = "npc", db = NpcDB, ids = NpcDB.GetAllIds() } }
    if ItemsReady() and ItemDB.GetAllIds then
        phases[2] = { kind = "item", db = ItemDB, ids = ItemDB.GetAllIds() }
    end
    phase, cursor = 1, 0
    indexState = "building"
    worker:Show()
    return true
end

local function IndexError()
    return indexError or L.NPC_NO_DB
end

local function Percent()
    if indexState == "ready" then return 100 end
    if not phases then return 0 end
    local done, all = 0, 0
    for i, current in ipairs(phases) do
        local count = #current.ids
        all = all + count
        if i < phase then done = done + count elseif i == phase then done = done + cursor end
    end
    if all == 0 then return 0 end
    return math.floor(done / all * 100)
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

-- score: 0 the whole name, 1 its start, 2 a word's start, 3 inside a word,
-- 4 every typed word somewhere
local function ByText(a, b)
    if a.score ~= b.score then return a.score < b.score end
    if a.len ~= b.len then return a.len < b.len end
    return a.id < b.id
end

-- What an item can come from: the source lists QuestieDB has (nil when none).
local function ItemSources(id)
    local sources = {
        vendors = Field(ItemDB, "vendors", id),
        nodes = Field(ItemDB, "objectDrops", id),
        drops = Field(ItemDB, "npcDrops", id),
        containers = Field(ItemDB, "itemDrops", id),
        quests = Field(ItemDB, "questRewards", id),
    }
    for name, list in pairs(sources) do
        if type(list) ~= "table" or #list == 0 then sources[name] = nil end
    end
    return next(sources) and sources or nil
end

-- only: "npc" or "item" to search one kind of name.
local function Search(text, only)
    local query = Fold(text or "")
    if #query < 2 then return {}, 0 end
    local words = {}
    for word in query:gmatch("%S+") do words[#words + 1] = word end
    local byId, list = { npc = {}, item = {} }, {}
    for i = 1, #keys do
        local key = (not only or kinds[i] == only) and keys[i] or ""
        local score
        local at = key:find(query, 1, true)
        if at then
            if at == 1 then
                score = (#key == #query) and 0 or 1
            elseif key:sub(at - 1, at - 1) == " " then
                score = 2
            else
                score = 3
            end
        elseif #words > 1 then
            score = 4
            for w = 1, #words do
                if not key:find(words[w], 1, true) then score = nil; break end
            end
        end
        if score then
            local id, kind = ids[i], kinds[i]
            local hit = byId[kind][id]
            if not hit then
                hit = { kind = kind, id = id, score = score, len = #key }
                byId[kind][id] = hit
                list[#list + 1] = hit
            elseif score < hit.score then
                hit.score, hit.len = score, #key
            end
        end
    end
    table.sort(list, ByText)
    local total = #list
    -- The best matches, those with a known position (or source) first.
    local top = {}
    for i = 1, math.min(total, CHECK) do
        local hit = list[i]
        if hit.kind == "item" then
            hit.sources = ItemSources(hit.id)
            hit.unknown = hit.sources and 0 or 1
        else
            hit.points = Points(hit.id)
            hit.unknown = #hit.points == 0 and 1 or 0
        end
        top[i] = hit
    end
    table.sort(top, function(a, b)
        if a.unknown ~= b.unknown then return a.unknown < b.unknown end
        return ByText(a, b)
    end)
    return top, total
end

local function ItemIcon(id)
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if instant then
        local ok, _, _, _, _, icon = pcall(instant, id)
        if ok and icon then return icon end
    end
    return 134400 -- INV_Misc_QuestionMark
end

-- What a result shows: name, title, levels, faction, where. Objects (kind
-- "object") have a name and positions only; items a name and an icon.
local function Info(hit)
    if hit.name then return hit end
    local id = hit.id
    if hit.kind == "item" then
        hit.name = Field(ItemDB, "name", id) or ("#" .. id)
        hit.icon = ItemIcon(id)
        if hit.sources == nil then hit.sources = ItemSources(id) or false end
        return hit
    end
    if hit.kind == "object" then
        hit.name = Field(_G.ObjectDB, "name", id)
    else
        hit.name = Field(NpcDB, "name", id)
        hit.sub = Field(NpcDB, "subName", id)
        hit.minLevel, hit.maxLevel = Field(NpcDB, "minLevel", id), Field(NpcDB, "maxLevel", id)
        hit.friendly = Field(NpcDB, "friendlyToFaction", id)
    end
    if type(hit.name) ~= "string" then hit.name, hit.missing = "#" .. id, true end
    hit.points = hit.points or Points(id, hit.kind)
    hit.map, hit.centerX, hit.centerY, hit.nearest, hit.maps = Summary(hit.points)
    return hit
end

-- "|T...|t" for a texture, at the size of the list's text.
local function IconText(icon, size)
    return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(tostring(icon), size or 14, size or 14)
end

local function RoleIcon(role)
    local texture = ROLES[role].icon
    if texture:find("Icons", 1, true) then return IconText(texture, 12) end
    return ("|T%s:12:12|t"):format(texture)
end

-- 45.3 %, the way the language writes it.
local function Rate(rate)
    local text = rate >= 10 and ("%d"):format(math.floor(rate + 0.5)) or ("%.1f"):format(rate)
    return L.ITEM_RATE:format((text:gsub("%.", L.ITEM_DECIMAL)))
end

-- Green: friendly to your faction. Red: the other faction's. White: neither.
local function NameColor(faction)
    local mine = UnitFactionGroup("player")
    if faction == "AH" or (faction == "A" and mine == "Alliance") or (faction == "H" and mine == "Horde") then
        return "|cff7fff7f"
    end
    if faction == "A" or faction == "H" then return "|cffff7f7f" end
    return "|cffffffff"
end

local function MapName(map)
    local info = map and C_Map.GetMapInfo(map)
    return info and info.name or "?"
end

local function Coords(point) return ("%.1f, %.1f"):format(point[2] * 100, point[3] * 100) end

local function Place(point)
    if point.dungeon then return MapName(point[1]) .. " (" .. point.dungeon .. ")" end
    return MapName(point[1])
end

local function WhereText(hit)
    if not hit.map then return "|cffff6060" .. L.NPC_NO_POSITION .. "|r" end
    local text = Place(hit.nearest)
    if hit.maps > 1 then text = text .. " +" .. (hit.maps - 1) end
    return text
end

---------------------------------------------------------------------------
-- Markers and arrow
---------------------------------------------------------------------------

local function Pins() return LibStub and LibStub("HereBeDragons-Pins-2.0", true) end

local lastWaypoint

local function RemoveArrow()
    if lastWaypoint and _G.TomTom and TomTom.RemoveWaypoint then pcall(TomTom.RemoveWaypoint, TomTom, lastWaypoint) end
    lastWaypoint = nil
end

local function Arrow(hit, point)
    if not (_G.TomTom and TomTom.AddWaypoint) then
        ns:Print(L.NPC_NO_TOMTOM)
        return
    end
    RemoveArrow()
    lastWaypoint = TomTom:AddWaypoint(point[1], point[2], point[3], {
        title = hit.name, from = L.ADDON_TITLE, persistent = false, crazy = true,
    })
end

local function AddTooltipLines(hit, point, hints)
    GameTooltip:AddLine(NameColor(hit.friendly) .. hit.name .. "|r")
    if hit.sub and hit.sub ~= "" then GameTooltip:AddLine("<" .. hit.sub .. ">", 0.8, 0.8, 0.8) end
    -- What it has to do with the item looked for ("Sells ...", "Drops ...").
    if hit.about then GameTooltip:AddLine(hit.about, 0.4, 1, 0.4, true) end
    if type(hit.minLevel) == "number" and hit.minLevel > 0 then
        local level = tostring(hit.minLevel)
        if type(hit.maxLevel) == "number" and hit.maxLevel > hit.minLevel then level = level .. "-" .. hit.maxLevel end
        GameTooltip:AddLine(L.NPC_LEVEL:format(level), 1, 0.82, 0)
    end
    point = point or hit.nearest
    if point then
        GameTooltip:AddLine(Place(point) .. "   " .. Coords(point), 1, 1, 1)
        if #hit.points > 1 then GameTooltip:AddLine(L.NPC_SPOTS:format(#hit.points), 0.7, 0.7, 0.7) end
    else
        GameTooltip:AddLine(L.NPC_TT_NO_POSITION, 1, 0.4, 0.4)
    end
    for _, line in ipairs(hints) do GameTooltip:AddLine(line, 0.5, 0.8, 1) end
end

local pool, shown = {}, {}

local function ClearMarkers()
    local pins = Pins()
    if pins then pins:RemoveAllWorldMapIcons(PIN_REF) end
    for i = #shown, 1, -1 do
        local marker = shown[i]
        marker:Hide()
        marker.hit, marker.point = nil, nil
        pool[#pool + 1] = marker
        shown[i] = nil
    end
end

local function MarkerEnter(self)
    if not self.hit then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    local hints = {}
    if _G.TomTom then hints[#hints + 1] = L.NPC_MARKER_ARROW end
    hints[#hints + 1] = L.NPC_MARKER_CLEAR
    AddTooltipLines(self.hit, self.point, hints)
    GameTooltip:Show()
end

local function MarkerClick(self, button)
    if button == "RightButton" then
        GameTooltip:Hide()
        ClearMarkers()
    elseif IsShiftKeyDown() and self.hit then
        Arrow(self.hit, self.point)
    end
end

local function NewMarker()
    local marker = CreateFrame("Button", nil, UIParent)
    marker:SetSize(20, 20)
    marker:Hide()
    marker.glow = marker:CreateTexture(nil, "BACKGROUND")
    marker.glow:SetBlendMode("ADD")
    marker.glow:SetSize(34, 34)
    marker.glow:SetPoint("CENTER")
    marker.icon = marker:CreateTexture(nil, "ARTWORK")
    marker.icon:SetAllPoints()
    local pulse = marker.glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.1)
    fade:SetToAlpha(0.9)
    fade:SetDuration(0.7)
    marker:SetScript("OnShow", function() pulse:Play() end)
    marker:SetScript("OnHide", function() pulse:Stop() end)
    marker:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    marker:SetScript("OnEnter", MarkerEnter)
    marker:SetScript("OnLeave", GameTooltip_Hide)
    marker:SetScript("OnClick", MarkerClick)
    return marker
end

-- A marker on each { hit, point }. True when one was placed, nil without
-- HereBeDragons, false when HereBeDragons doesn't know the map.
local function PlaceMarkers(spots)
    ClearMarkers()
    local pins = Pins()
    if not pins then return nil end
    local placed = 0
    for _, spot in ipairs(spots) do
        local hit, point = spot[1], spot[2]
        local style = ROLES[hit.role or "npc"] or ROLES.npc
        local marker = table.remove(pool) or NewMarker()
        marker.hit, marker.point = hit, point
        marker.icon:SetTexture(style.icon)
        marker.glow:SetTexture(style.icon)
        marker.glow:SetVertexColor(style.r or 1, style.g or 0.8, style.b or 0.2)
        shown[#shown + 1] = marker
        if pins:AddWorldMapIconMap(PIN_REF, marker, point[1], point[2], point[3], HBD_PINS_WORLDMAP_SHOW_CONTINENT or 2) then
            placed = placed + 1
        end
    end
    return placed > 0
end

-- The nearest points of one NPC or object.
local function ShowMarkers(hit, here)
    local spots = {}
    for i, point in ipairs(Nearest(hit.points, MAX_POINTS, here or Here())) do spots[i] = { hit, point } end
    return PlaceMarkers(spots)
end

---------------------------------------------------------------------------
-- Map
---------------------------------------------------------------------------

-- OpenMap's stitched map glides to the spot; Blizzard's map opens the zone.
local function Navigate(map, x, y)
    local api = _G.OpenMapAPI
    if api and api.IsStitched and api.IsStitched() and api.WorldFromMap and api.ShowWorld then
        local u, v = api.WorldFromMap(map, x, y)
        if u and v then
            local _, _, zoom = api.GetView()
            api.ShowWorld(u, v, math.max(POINT_ZOOM, zoom or 1))
            return
        end
    end
    WorldMapFrame:SetMapID(map)
end

-- Returns: the map is open, it was just opened.
local function EnsureMapOpen()
    if WorldMapFrame:IsShown() then return true, false end
    if InCombatLockdown() then
        ns:Print(L.NPC_COMBAT)
        return false
    end
    if ToggleWorldMap then ToggleWorldMap() else WorldMapFrame:Show() end
    return WorldMapFrame:IsShown(), true
end

local function OpenMapAt(map, x, y)
    local open, justOpened = EnsureMapOpen()
    if not open then return end
    if justOpened then
        -- A map that just opened goes to the player's zone first: go after it.
        C_Timer.After(0.05, function() Navigate(map, x, y) end)
    else
        Navigate(map, x, y)
    end
end

local function ReportPlaced(placed)
    if placed == nil then
        ns:Print(L.NPC_NO_HBD)
    elseif placed == false then
        ns:Print(L.NPC_NO_HBD_MAP)
    end
end

-- An NPC (or an object) on the map. A source of an item (hit.closest set)
-- is shown where it is nearest to you; an NPC found by name, where most
-- of its positions are.
local function Go(hit, arrow)
    Info(hit)
    if not hit.map then
        ns:Print(L.NPC_NO_POSITION_LONG:format(hit.name))
        return
    end
    local here = Here()
    local placed = ShowMarkers(hit, here)
    local target = hit.closest or hit.nearest
    if hit.closest then
        OpenMapAt(target[1], target[2], target[3])
    else
        OpenMapAt(hit.map, hit.centerX, hit.centerY)
    end
    local message = NameColor(hit.friendly) .. hit.name .. "|r: " .. Place(target) .. "  " .. Coords(target)
    if #hit.points > 1 then message = message .. L.NPC_OTHER_SPOTS:format(#hit.points - 1) end
    ns:Print(message)
    ReportPlaced(placed)
    if arrow then Arrow(hit, target) end
end

-- Every source of a group on the map at once (the nearest positions),
-- centered on the nearest one.
local function GoGroup(group, arrow)
    local here = Here()
    local all = {}
    for _, hit in ipairs(group.hits) do
        for _, point in ipairs(hit.points or {}) do all[#all + 1] = { hit, point, Distance(point, here) } end
    end
    if #all == 0 then
        ns:Print(L.NPC_NO_POSITION_LONG:format(group.title))
        return
    end
    table.sort(all, function(a, b) return a[3] < b[3] end)
    local spots = {}
    for i = 1, math.min(#all, GROUP_POINTS) do spots[i] = all[i] end
    local placed = PlaceMarkers(spots)
    local first = spots[1]
    OpenMapAt(first[2][1], first[2][2], first[2][3])
    ns:Print(L.ITEM_GROUP_SHOWN:format(group.title, #spots, Place(first[2])))
    ReportPlaced(placed)
    if arrow then Arrow(first[1], first[2]) end
end

---------------------------------------------------------------------------
-- An item's sources, as rows for the list under the bar
---------------------------------------------------------------------------

local SOURCE_KINDS = {
    { "vendors", "vendor" }, { "nodes", "node" }, { "drops", "drop" },
    { "containers", "container" }, { "quests", "quest" },
}

-- Icons and counts: what the item comes from, at a glance.
local function SourcesText(sources)
    if not sources then return "|cffff6060" .. L.ITEM_NO_SOURCE_SHORT .. "|r" end
    local parts = {}
    for _, kind in ipairs(SOURCE_KINDS) do
        local list = sources[kind[1]]
        if list then parts[#parts + 1] = RoleIcon(kind[2]) .. " " .. #list end
    end
    return table.concat(parts, "   ")
end

-- The item's name in its quality color, when the game knows it already.
local function ItemName(item)
    local get = C_Item and C_Item.GetItemQualityByID
    if get then
        local ok, quality = pcall(get, item.id)
        local color = ok and quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if color and type(color.hex) == "string" then return color.hex .. item.name .. "|r" end
    end
    return item.name
end

local function Hostile(faction)
    local mine = UnitFactionGroup("player")
    return (faction == "A" and mine == "Horde") or (faction == "H" and mine == "Alliance")
end

local function ByDistance(a, b)
    if a.distance ~= b.distance then return a.distance < b.distance end
    return a.name < b.name
end

-- Where a source is: its nearest position's zone, red when unknown.
local function SourceWhere(hit)
    local point = hit.closest or hit.nearest
    if not point then return "|cffff6060" .. L.NPC_NO_POSITION .. "|r" end
    return Place(point)
end

-- One hit per NPC or object of `list`, with its position nearest to you.
-- Vendors of the other faction are left out (counted). Objects with the
-- same name are one hit: QuestieDB has a Copper Vein per kind of spot.
local function SourceHits(list, kind, role, here, about)
    local hits, hidden, byName = {}, 0, {}
    for _, id in ipairs(list or {}) do
        local hit = Info({ kind = kind, id = id, role = role })
        local same = kind == "object" and byName[hit.name]
        if hit.missing and #hit.points == 0 then
            -- neither a name nor a position: nothing to show
        elseif role ~= "drop" and Hostile(hit.friendly) then
            hidden = hidden + 1
        elseif same then
            if not same.merged then
                -- A copy: the cached positions of the first ID stay as they are.
                local copy = {}
                for i, point in ipairs(same.points) do copy[i] = point end
                same.points, same.merged = copy, true
            end
            for _, point in ipairs(hit.points) do same.points[#same.points + 1] = point end
            same.map, same.centerX, same.centerY, same.nearest, same.maps = Summary(same.points)
        else
            if kind == "object" then byName[hit.name] = hit end
            hit.about = about
            hits[#hits + 1] = hit
        end
    end
    for _, hit in ipairs(hits) do
        hit.closest, hit.distance = Closest(hit.points, here)
        if not hit.closest then hit.distance = FAR * 2 end -- no position: after the far ones
    end
    return hits, hidden
end

local function AddGroup(entries, role, title, hits, hidden)
    if #hits == 0 and hidden == 0 then return end
    local group = { role = role, title = title, hits = hits }
    local text = "|cffffd200" .. title .. " (" .. #hits .. ")|r"
    if hidden > 0 then text = text .. "   |cff999999" .. L.ITEM_HIDDEN:format(hidden) .. "|r" end
    entries[#entries + 1] = { text = text, group = #hits > 0 and group or nil }
    return group
end

local function Levels(hit)
    if type(hit.minLevel) ~= "number" or hit.minLevel <= 0 then return "" end
    local level = tostring(hit.minLevel)
    if type(hit.maxLevel) == "number" and hit.maxLevel > hit.minLevel then level = level .. "-" .. hit.maxLevel end
    return "  |cff999999" .. L.ITEM_ROW_LEVEL:format(level) .. "|r"
end

-- The first source with a position, for the map to show right away.
local function FirstPlaced(hits)
    for _, hit in ipairs(hits) do
        if hit.closest then return hit end
    end
end

-- Rows: back, then a header and rows per kind of source. `best` is what
-- the map shows when the item is picked: the nearest vendor, else every
-- gathering spot, else the best mob, else a quest giver.
local function BuildItemView(item)
    Info(item)
    local here = Here()
    local sources = item.sources or {}
    local name = item.name
    local entries = { { text = "|cffffd200<|r  " .. IconText(item.icon) .. " " .. ItemName(item), back = true } }
    local best

    local vendors, hidden = SourceHits(sources.vendors, "npc", "vendor", here, L.ITEM_TT_SELLS:format(name))
    table.sort(vendors, ByDistance)
    if AddGroup(entries, "vendor", L.ITEM_VENDORS, vendors, hidden) then
        for _, hit in ipairs(vendors) do
            local text = RoleIcon("vendor") .. " " .. NameColor(hit.friendly) .. hit.name .. "|r"
            if hit.sub and hit.sub ~= "" then text = text .. "  |cff999999<" .. hit.sub .. ">|r" end
            entries[#entries + 1] = { text = text, where = SourceWhere(hit), hit = hit }
        end
        local first = FirstPlaced(vendors)
        if first then best = { hit = first } end
    end

    local nodes = SourceHits(sources.nodes, "object", "node", here, L.ITEM_TT_HOLDS:format(name))
    table.sort(nodes, ByDistance)
    local nodeGroup = AddGroup(entries, "node", L.ITEM_NODES, nodes, 0)
    if nodeGroup then
        for _, hit in ipairs(nodes) do
            entries[#entries + 1] = { text = RoleIcon("node") .. " " .. hit.name, where = SourceWhere(hit), hit = hit }
        end
        if not best and FirstPlaced(nodes) then best = { group = nodeGroup } end
    end

    local rates = Finder.DropRates(item.id)
    local drops = SourceHits(sources.drops, "npc", "drop", here)
    for _, hit in ipairs(drops) do
        hit.rate = rates[hit.id]
        hit.about = hit.rate and L.ITEM_TT_DROPS_RATE:format(name, Rate(hit.rate)) or L.ITEM_TT_DROPS:format(name)
    end
    table.sort(drops, function(a, b)
        if (a.rate ~= nil) ~= (b.rate ~= nil) then return a.rate ~= nil end
        if a.rate and a.rate ~= b.rate then return a.rate > b.rate end
        return ByDistance(a, b)
    end)
    if AddGroup(entries, "drop", L.ITEM_DROPS, drops, 0) then
        for _, hit in ipairs(drops) do
            local text = RoleIcon("drop") .. " " .. NameColor(hit.friendly) .. hit.name .. "|r" .. Levels(hit)
            if hit.rate then text = text .. "  |cff7fff7f" .. Rate(hit.rate) .. "|r" end
            entries[#entries + 1] = { text = text, where = SourceWhere(hit), hit = hit }
        end
        if not best then
            local first = FirstPlaced(drops)
            if first then best = { hit = first } end
        end
    end

    local containers = {}
    for _, id in ipairs(sources.containers or {}) do
        containers[#containers + 1] = Info({ kind = "item", id = id, role = "container" })
    end
    table.sort(containers, function(a, b) return a.name < b.name end)
    if AddGroup(entries, "container", L.ITEM_CONTAINERS, containers, 0) then
        entries[#entries].group = nil -- containers have no position of their own
        for _, container in ipairs(containers) do
            entries[#entries + 1] = {
                text = IconText(container.icon) .. " " .. ItemName(container),
                where = SourcesText(container.sources),
                item = container,
            }
        end
    end

    -- Quests: shown with their giver (the first one of your faction).
    local quests, hiddenQuests = {}, 0
    for _, questId in ipairs(sources.quests or {}) do
        local questName = Field(_G.QuestDB, "name", questId) or ("#" .. questId)
        local starters = Field(_G.QuestDB, "startedBy", questId)
        local giver, hostileOnly
        for slot, kind in ipairs({ "npc", "object" }) do
            for _, id in ipairs(type(starters) == "table" and starters[slot] or {}) do
                local hit = Info({ kind = kind, id = id, role = "quest" })
                if Hostile(hit.friendly) then
                    hostileOnly = true
                elseif not giver or (not giver.map and hit.map) then
                    giver = hit
                end
            end
        end
        if not giver and hostileOnly then
            hiddenQuests = hiddenQuests + 1
        else
            local level = Field(_G.QuestDB, "questLevel", questId)
            local text = RoleIcon("quest") .. " " .. questName
            if type(level) == "number" and level > 0 then text = text .. "  |cff999999[" .. level .. "]|r" end
            if giver then
                giver.closest, giver.distance = Closest(giver.points, here)
                giver.about = L.ITEM_TT_QUEST:format(questName, name)
            end
            quests[#quests + 1] = {
                text = text, hit = giver, distance = giver and giver.distance or FAR * 2,
                where = giver and SourceWhere(giver) or "|cff999999?|r",
            }
        end
    end
    table.sort(quests, function(a, b) return a.distance < b.distance end)
    local questHits = {}
    for _, quest in ipairs(quests) do questHits[#questHits + 1] = quest.hit end
    if AddGroup(entries, "quest", L.ITEM_QUESTS, quests, hiddenQuests) then
        entries[#entries].group = #questHits > 0 and { role = "quest", title = L.ITEM_QUESTS, hits = questHits } or nil
        for _, quest in ipairs(quests) do entries[#entries + 1] = quest end
        if not best and quests[1] and quests[1].hit and quests[1].hit.closest then best = { hit = quests[1].hit } end
    end

    if #entries == 1 then
        entries[2] = { text = "|cff999999" .. L.ITEM_NO_SOURCE .. "|r" }
    end
    return { item = item, entries = entries, best = best, offset = 0 }
end

-- What the map shows first for an item. False when nothing has a position.
local function ShowBest(itemView)
    local best = itemView.best
    if not best then return false end
    if best.group then GoGroup(best.group) else Go(best.hit) end
    return true
end

---------------------------------------------------------------------------
-- The search bar on the world map
---------------------------------------------------------------------------

local box, list, rows, mapArea
local results, total, selected = {}, 0, 1
-- An item's sources, shown in the list instead of the search results
-- (nil: search results). See OpenItem.
local view
local quiet -- the text this file just put in the box: not a search

local function BarWanted()
    return ns:IsEnabled(KEY) and ns:GetOption(KEY, "showBar")
end

-- left, right, top, bottom in screen pixels
local function Rect(frame)
    local left, bottom, width, height = frame:GetRect()
    if not left then return end
    local scale = frame:GetEffectiveScale()
    return left * scale, (left + width) * scale, (bottom + height) * scale, bottom * scale
end

-- Visible frames you can click on the map, buttons or strips of buttons:
-- the bar must not cover them.
local function Obstacles()
    local found = {}
    local function Consider(frame, depth)
        if frame == box or frame == mapArea.Child or not frame:IsVisible() then return end
        if frame.IsForbidden and frame:IsForbidden() then return end
        local width, height = frame:GetSize()
        -- Skipped: anchors and holders without a size (they can hold map
        -- pins), and panels or canvases larger than a button both ways.
        if width <= 4 or height <= 4 or (width > BIG and height > BIG) then return end
        if frame:IsMouseEnabled() then
            found[#found + 1] = frame
        elseif depth > 0 then
            -- A row or a column holding buttons: look at the buttons.
            for _, child in ipairs({ frame:GetChildren() }) do Consider(child, depth - 1) end
        end
    end
    -- The map frame, its border and the map area are larger than any button:
    -- only what they hold is looked at (never the map canvas and its pins).
    for _, root in ipairs({ WorldMapFrame, WorldMapFrame.BorderFrame, mapArea }) do
        if root then
            for _, child in ipairs({ root:GetChildren() }) do Consider(child, 2) end
        end
    end
    for _, frame in ipairs(WorldMapFrame.overlayFrames or {}) do Consider(frame, 1) end
    return found
end

-- In the top-left corner, moved right past every button already there; or
-- where the player dragged it.
local function PlaceBar()
    if not box then return end
    box:ClearAllPoints()
    local saved = ns.db and ns.db.npc.bar
    if saved then
        box:SetPoint("TOPLEFT", mapArea, "TOPLEFT", saved[1], saved[2])
        return
    end
    local scale = box:GetEffectiveScale()
    local areaLeft, areaRight, areaTop = Rect(mapArea)
    local x = BAR_X * scale
    if areaLeft then
        local width, height = BAR_WIDTH * scale, BAR_HEIGHT * scale
        local top = areaTop + BAR_Y * scale
        local obstacles = Obstacles()
        -- Each pass moves past one button: x only grows, so this ends.
        for _ = 1, #obstacles + 1 do
            local left, right = areaLeft + x, areaLeft + x + width
            local blocker
            for _, frame in ipairs(obstacles) do
                local fLeft, fRight, fTop, fBottom = Rect(frame)
                if fLeft and fLeft < right and fRight > left and fTop > top - height and fBottom < top then
                    blocker = fRight
                    break
                end
            end
            if not blocker then break end
            x = blocker - areaLeft + BAR_GAP * scale
        end
        if areaLeft + x + width > areaRight then x = BAR_X * scale end -- no room: back to the corner
    end
    box:SetPoint("TOPLEFT", mapArea, "TOPLEFT", x / scale, BAR_Y)
end

-- After the game and other addons have laid out their own buttons. Never
-- while you type in it.
local function PlaceBarSoon()
    if not box or not box:IsShown() then return end
    C_Timer.After(0, function()
        if not box:HasFocus() then PlaceBar() end
    end)
end

-- Puts text in the box without searching it (an item's name).
local function SetBoxText(text)
    if box:GetText() == text then return end
    quiet = text
    box:SetText(text)
end

-- Rows that do something when clicked: back, a group, a source, an item.
local function Clickable(entry)
    return entry ~= nil and (entry.back or entry.group or entry.hit or entry.item) ~= nil
end

-- entry: what the row does (see Activate); index: its place in the item view.
local function SetRow(row, text, where, entry, index)
    row.entry, row.index = entry, index
    row.text:SetText(text)
    row.where:SetText(where or "")
    row:Show()
end

-- NPCs and items matching the box's text. Returns the rows used.
local function RenderSearch()
    local query = Fold(box:GetText() or "")
    if #query < 2 then return 0 end
    if indexState == "building" then
        SetRow(rows[1], "|cff999999" .. L.NPC_INDEXING:format(Percent()) .. "|r")
        return 1
    elseif indexState ~= "ready" then
        SetRow(rows[1], "|cffff6060" .. IndexError() .. "|r")
        return 1
    end
    local count = 0
    for i = 1, math.min(#results, ROWS) do
        local hit = Info(results[i])
        if hit.kind == "item" then
            SetRow(rows[i], IconText(hit.icon) .. " " .. ItemName(hit), SourcesText(hit.sources), { item = hit })
        else
            local text = NameColor(hit.friendly) .. hit.name .. "|r"
            if hit.sub and hit.sub ~= "" then text = text .. "  |cff999999<" .. hit.sub .. ">|r" end
            SetRow(rows[i], text, WhereText(hit), { hit = hit })
        end
        if i == selected then rows[i]:LockHighlight() end
        count = i
    end
    if total > count then
        local more = total - count
        count = count + 1
        SetRow(rows[count], "|cff999999" .. L.NPC_MORE:format(more) .. "|r")
    elseif count == 0 then
        count = 1
        SetRow(rows[1], "|cff999999" .. L.NPC_NONE .. "|r")
    end
    return count
end

-- An item's sources: the back row stays on top, the others scroll.
local function RenderView()
    local entries, room = view.entries, ROWS - 1
    local rest = #entries - 1
    view.offset = math.max(0, math.min(view.offset, rest - room))
    SetRow(rows[1], entries[1].text, nil, entries[1], 1)
    local count = 1
    for index = 2 + view.offset, math.min(#entries, 1 + view.offset + room) do
        local entry = entries[index]
        count = count + 1
        SetRow(rows[count], entry.text, entry.where, entry, index)
    end
    for i = 1, count do
        if rows[i].index == view.selected then rows[i]:LockHighlight() end
    end
    if rest > room then
        local below = rest - room - view.offset
        local hint = below > 0 and L.ITEM_SCROLL_DOWN:format(below) or L.ITEM_SCROLL_UP:format(view.offset)
        count = count + 1
        SetRow(rows[count], "|cff999999" .. hint .. "|r")
    end
    return count
end

local function Render()
    if not list then return end
    for _, row in ipairs(rows) do
        row:Hide()
        row:UnlockHighlight()
    end
    local count = view and RenderView() or RenderSearch()
    if count == 0 then
        list:Hide()
        return
    end
    list:SetHeight(12 + count * ROW_HEIGHT)
    list:Show()
end

local function Refresh()
    selected = 1
    StartIndex()
    if indexState == "ready" then
        results, total = Search(box:GetText())
    else
        results, total = {}, 0
    end
    Render()
end

local function CloseList()
    box:ClearFocus()
    list:Hide()
    GameTooltip:Hide()
end

-- An item's sources in the list, and the best one on the map.
--   parent: the item view it was opened from (it came out of a container)
--   fromSearch: picked from the search results, which Back goes back to
--   wait: the map opened just now, it goes to the player's zone first
local function OpenItem(item, parent, fromSearch, wait)
    local opened = BuildItemView(Info(item))
    opened.parent = parent
    if fromSearch then opened.query, opened.searchSelected = box:GetText(), selected end
    opened.selected = 1
    for index = 2, #opened.entries do
        if Clickable(opened.entries[index]) then
            opened.selected = index
            break
        end
    end
    view = opened
    SetBoxText(item.name)
    Render()
    local function Show()
        if ShowBest(opened) then return end
        ns:Print((item.sources and L.NPC_NO_POSITION_LONG or L.ITEM_NO_SOURCE_LONG):format(item.name))
    end
    if wait then C_Timer.After(0.05, Show) else Show() end
end

-- From an item back to the item it came out of, else to the search.
local function Back()
    local current = view
    if not current then return end
    view = current.parent
    if view then
        SetBoxText(view.item.name)
        Render()
        return
    end
    local query = current.query or ""
    SetBoxText(query)
    if query == "" then
        CloseList()
        return
    end
    Refresh()
    selected = math.max(1, math.min(current.searchSelected or 1, #results, ROWS))
    Render()
end

-- What a row does: back, an item's sources, a whole group or one source
-- on the map.
local function Activate(entry, arrow)
    if not Clickable(entry) then return end
    if entry.back then
        Back()
    elseif entry.item then
        OpenItem(entry.item, view, view == nil)
    elseif entry.group then
        GoGroup(entry.group, arrow)
    else
        if not view then CloseList() end -- an NPC found by name: done
        Go(entry.hit, arrow)
    end
end

local function PickSelected()
    if view then
        Activate(view.entries[view.selected], IsShiftKeyDown())
        return
    end
    if indexState == "building" then
        Pump(nil) -- Enter before the index is done: finish it now.
        results, total = Search(box:GetText())
    end
    local hit = results[selected]
    if hit then Activate(hit.kind == "item" and { item = hit } or { hit = hit }, IsShiftKeyDown()) end
end

local function RowClick(row, button)
    if button == "RightButton" then
        CloseList()
        return
    end
    -- Ctrl-click: into the hunting list (defined further down).
    if IsControlKeyDown() and Finder.HuntRow(row.entry) then return end
    if view and row.index and Clickable(row.entry) then
        view.selected = row.index
        Render()
    end
    Activate(row.entry, IsShiftKeyDown())
end

local function RowEnter(row)
    local entry = row.entry
    if not Clickable(entry) then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local arrow = _G.TomTom and L.NPC_SHIFT_CLICK
    if entry.back then
        GameTooltip:AddLine(L.ITEM_CLICK_BACK, 1, 1, 1)
    elseif entry.item then
        if not pcall(GameTooltip.SetItemByID, GameTooltip, entry.item.id) or GameTooltip:NumLines() == 0 then
            GameTooltip:AddLine(entry.item.name, 1, 1, 1)
        end
        GameTooltip:AddLine(L.ITEM_CLICK_ITEM, 0.5, 0.8, 1)
    elseif entry.group then
        GameTooltip:AddLine(entry.group.title, 1, 0.82, 0)
        GameTooltip:AddLine(L.ITEM_CLICK_GROUP, 0.5, 0.8, 1)
        if arrow then GameTooltip:AddLine(arrow, 0.5, 0.8, 1) end
    else
        local hints = { L.NPC_CLICK }
        if arrow then hints[#hints + 1] = arrow end
        if Finder.Huntable(entry) then hints[#hints + 1] = L.HUNT_FINDER_HINT end
        AddTooltipLines(entry.hit, entry.hit.closest, hints)
    end
    if view then GameTooltip:AddLine(L.ITEM_RIGHT_CLOSE, 0.6, 0.6, 0.6) end
    GameTooltip:Show()
end

local function MoveSelection(step)
    if view then
        local entries, index = view.entries, view.selected
        for _ = 1, #entries do
            index = (index - 1 + step) % #entries + 1
            if Clickable(entries[index]) then break end
        end
        view.selected = index
        -- Kept in sight (the back row always is): entry i sits on row i - offset.
        if index > 1 then
            view.offset = math.max(math.min(view.offset, index - 2), index - ROWS)
        end
        Render()
        return
    end
    local count = math.min(#results, ROWS)
    if count == 0 then return end
    selected = (selected - 1 + step) % count + 1
    Render()
end

local function Scroll(_, delta)
    if not view then return end
    view.offset = view.offset - delta * 3
    Render() -- keeps the offset in range
end

local function CreateList()
    list = CreateFrame("Frame", nil, box, "BackdropTemplate")
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    list:SetToplevel(true)
    list:SetPoint("TOPLEFT", box, "BOTTOMLEFT", -6, -2)
    list:SetWidth(380)
    list:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    list:SetBackdropColor(0, 0, 0, 0.92)
    list:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    list:EnableMouse(true)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", Scroll)
    list:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then CloseList() end
    end)
    list:Hide()

    rows = {}
    for i = 1, ROWS + 1 do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(368, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 6, -6 - (i - 1) * ROW_HEIGHT)
        row:SetHighlightTexture(HIGHLIGHT, "ADD")
        row.where = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.where:SetPoint("RIGHT", -4, 0)
        row.where:SetJustifyH("RIGHT")
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 4, 0)
        row.text:SetPoint("RIGHT", row.where, "LEFT", -8, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:SetScript("OnClick", RowClick)
        row:SetScript("OnEnter", RowEnter)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:Hide()
        rows[i] = row
    end
end

local function UpdateBar()
    if not box then return end
    if BarWanted() then
        box:Show()
        if WorldMapFrame:IsShown() then
            StartIndex()
            PlaceBarSoon()
        end
    else
        view = nil
        box:ClearFocus()
        list:Hide()
        box:Hide()
    end
end

-- True once the bar exists (the world map may load after this addon).
local function CreateBar()
    if box then return true end
    if not WorldMapFrame then return false end
    mapArea = WorldMapFrame.ScrollContainer or WorldMapFrame

    local template = UI.HasTemplate("SearchBoxTemplate") and "SearchBoxTemplate" or "InputBoxTemplate"
    box = CreateFrame("EditBox", "BudgetForeverNpcSearch", WorldMapFrame, template)
    box:SetSize(BAR_WIDTH, BAR_HEIGHT)
    box:SetAutoFocus(false)
    box:SetFrameStrata("FULLSCREEN_DIALOG")
    if box.Instructions then UI.Localize(box.Instructions, "NPC_PLACEHOLDER") end
    box:SetPoint("TOPLEFT", mapArea, "TOPLEFT", BAR_X, BAR_Y) -- until the map opens and PlaceBar runs
    box:Hide()

    -- Shift-drag moves it; the place is kept, relative to the map.
    box:SetMovable(true)
    box:SetClampedToScreen(true)
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnDragStart", function(self)
        if not IsShiftKeyDown() then return end
        self.moving = true
        self:StartMoving()
    end)
    box:SetScript("OnDragStop", function(self)
        if not self.moving then return end
        self.moving = nil
        self:StopMovingOrSizing()
        local x, y = self:GetLeft() - mapArea:GetLeft(), self:GetTop() - mapArea:GetTop()
        if self.SetUserPlaced then self:SetUserPlaced(false) end
        ns.db.npc.bar = { x, y }
        PlaceBar()
    end)
    box:HookScript("OnEnter", function(self)
        if self:HasFocus() then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine(L.NPC_TITLE)
        GameTooltip:AddLine(L.NPC_BAR_TIP, 1, 1, 1, true)
        GameTooltip:AddLine(L.NPC_BAR_MOVE, 0.5, 0.8, 1, true)
        GameTooltip:Show()
    end)
    box:HookScript("OnLeave", GameTooltip_Hide)

    CreateList()

    box:HookScript("OnTextChanged", function(self, userInput)
        -- An item's name put there by OpenItem: its sources stay listed.
        if not userInput and quiet ~= nil and self:GetText() == quiet then
            quiet = nil
            return
        end
        quiet = nil
        view = nil
        Refresh()
    end)
    box:HookScript("OnEditFocusGained", function()
        GameTooltip:Hide()
        if view then
            Render()
        elseif box:GetText() ~= "" then
            Refresh()
        end
    end)
    box:HookScript("OnEditFocusLost", function()
        -- Late, so a click on a result still lands. An item's sources stay
        -- open: you click them one after another.
        C_Timer.After(0.2, function()
            if not box:HasFocus() and not view then list:Hide() end
        end)
    end)
    box:SetScript("OnEnterPressed", PickSelected)
    box:HookScript("OnEscapePressed", CloseList)
    box:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then MoveSelection(-1) elseif key == "DOWN" then MoveSelection(1) end
    end)
    box:SetScript("OnTabPressed", function() MoveSelection(IsShiftKeyDown() and -1 or 1) end)
    if box.clearButton then
        box.clearButton:HookScript("OnClick", function()
            view = nil
            list:Hide()
            ClearMarkers()
        end)
    end

    OnIndexReady = function()
        if not view and box:HasFocus() and box:GetText() ~= "" then Refresh() end
    end
    OnIndexProgress = function()
        if list:IsShown() and not view then Render() end
    end

    -- Hooks can't be removed: they check the setting each time.
    WorldMapFrame:HookScript("OnShow", function()
        if not BarWanted() then return end
        StartIndex() -- names are ready by the time you type
        PlaceBarSoon()
    end)
    WorldMapFrame:HookScript("OnHide", function()
        box:ClearFocus()
        list:Hide()
    end)
    -- Buttons in the corner can differ from one map to another.
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", PlaceBarSoon) end
    if mapArea ~= WorldMapFrame then mapArea:HookScript("OnSizeChanged", PlaceBarSoon) end
    return true
end

function Finder.ResetBar()
    ns.db.npc.bar = nil
    if box and box:IsShown() then PlaceBar() end
    ns:Print(L.NPC_BAR_RESET)
end

---------------------------------------------------------------------------
-- /npc Name, /npc clear (also /bf npc)
---------------------------------------------------------------------------

function Finder.Command(message)
    if not ns:IsEnabled(KEY) then
        ns:Print(L.NPC_DISABLED)
        return
    end
    message = strtrim(message or "")
    local lower = strlower(message)
    if lower == "clear" or lower == "effacer" then
        ClearMarkers()
        RemoveArrow()
        return
    end
    if message == "" then
        if box and BarWanted() and EnsureMapOpen() then
            PlaceBar() -- now: the delayed placement skips a bar you type in
            box:SetFocus()
        else
            ns:Print(L.NPC_USAGE)
        end
        return
    end
    if not StartIndex() then
        ns:Print(IndexError())
        return
    end
    Pump(nil) -- first search: finish the index now
    if indexState ~= "ready" then return end
    local found, count = Search(message, "npc")
    if #found == 0 then
        ns:Print(L.NPC_NO_MATCH:format(message))
        return
    end
    Go(found[1], false)
    if count > 1 then
        ns:Print((BarWanted() and L.NPC_OTHER_MATCHES or L.NPC_OTHER_MATCHES_NO_BAR):format(count - 1))
    end
end

SLASH_BUDGETFOREVERNPC1 = "/npc"
SLASH_BUDGETFOREVERNPC2 = "/pnj"
SlashCmdList.BUDGETFOREVERNPC = Finder.Command

---------------------------------------------------------------------------
-- Items: /item Name (/objet), Alt+click on an item, the tooltip line
---------------------------------------------------------------------------

local function ItemProblem()
    local ok, problem = DataReady()
    if not ok then return problem or L.NPC_NO_DB end
    return L.ITEM_NO_DB
end

-- An item's sources: in the list under the map's bar when the bar is on,
-- else one line in the chat. The best source goes on the map either way.
function Finder.ShowItem(id)
    if not ns:IsEnabled(KEY) then
        ns:Print(L.NPC_DISABLED)
        return
    end
    if not ItemsReady() then
        ns:Print(ItemProblem())
        return
    end
    if not Field(ItemDB, "name", id) then
        local get = C_Item and C_Item.GetItemNameByID
        local ok, name = false, nil
        if get then ok, name = pcall(get, id) end
        ns:Print(L.ITEM_UNKNOWN:format(ok and type(name) == "string" and name or ("#" .. id)))
        return
    end
    local item = Info({ kind = "item", id = id })
    local open, justOpened
    if box and BarWanted() then open, justOpened = EnsureMapOpen() end
    if open then
        PlaceBar()
        OpenItem(item, nil, false, justOpened)
        return
    end
    ns:Print(IconText(item.icon) .. " " .. ItemName(item) .. ": "
        .. (item.sources and SourcesText(item.sources) or L.ITEM_NO_SOURCE))
    -- open == false: in combat, EnsureMapOpen already said so.
    if not item.sources or open == false then return end
    if not ShowBest(BuildItemView(item)) then ns:Print(L.NPC_NO_POSITION_LONG:format(item.name)) end
end

-- /item Name, an item link or an item ID (also /objet and /bf item).
function Finder.ItemCommand(message)
    if not ns:IsEnabled(KEY) then
        ns:Print(L.NPC_DISABLED)
        return
    end
    message = strtrim(message or "")
    local id = tonumber(message:match("item:(%d+)") or message:match("^#?(%d+)$"))
    if id then
        Finder.ShowItem(id)
        return
    end
    if message == "" then
        if box and BarWanted() and EnsureMapOpen() then
            PlaceBar()
            box:SetFocus()
        else
            ns:Print(L.ITEM_USAGE)
        end
        return
    end
    if not ItemsReady() then
        ns:Print(ItemProblem())
        return
    end
    if not StartIndex() then
        ns:Print(IndexError())
        return
    end
    Pump(nil) -- first search: finish the index now
    if indexState ~= "ready" then return end
    local found, count = Search(message, "item")
    if #found == 0 then
        ns:Print(L.ITEM_NO_MATCH:format(message))
        return
    end
    Finder.ShowItem(found[1].id)
    if count > 1 then
        ns:Print((BarWanted() and L.NPC_OTHER_MATCHES or L.NPC_OTHER_MATCHES_NO_BAR):format(count - 1))
    end
end

SLASH_BUDGETFOREVERITEM1 = "/item"
SLASH_BUDGETFOREVERITEM2 = "/objet"
SlashCmdList.BUDGETFOREVERITEM = Finder.ItemCommand

-- Auctionator has its own Alt+click shortcuts at the Auction House.
local function AuctionOpen()
    for _, name in ipairs({ "AuctionHouseFrame", "AuctionFrame" }) do
        local frame = _G[name]
        if type(frame) == "table" and frame.IsShown and frame:IsShown() then return true end
    end
    return false
end

local lastAltId, lastAltTime = nil, 0

-- Blizzard calls HandleModifiedItemClick for a modified click on an item
-- anywhere: bags, chat links, quest rewards, loot, professions...
local function OnModifiedItemClick(link)
    if not (ns:IsEnabled(KEY) and ns:GetOption(KEY, "altClick")) then return end
    if not IsAltKeyDown() or IsShiftKeyDown() or IsControlKeyDown() then return end
    local button = GetMouseButtonClicked and GetMouseButtonClicked()
    if button and button ~= "LeftButton" then return end
    if AuctionOpen() then return end
    if not Util.Readable(link) or type(link) ~= "string" then return end
    local id = tonumber(link:match("item:(%d+)"))
    if not id then return end
    -- Some frames pass one click on twice.
    if id == lastAltId and GetTime() - lastAltTime < 0.3 then return end
    lastAltId, lastAltTime = id, GetTime()
    Finder.ShowItem(id)
end

if HandleModifiedItemClick then hooksecurefunc("HandleModifiedItemClick", OnModifiedItemClick) end

local tipCache = {} -- item ID -> { text, map, time }

-- "Sold by 3 vendors, nearest: Name (zone)"; false when no vendor of your
-- faction sells it. Kept 10 seconds per item, on the same map.
local function VendorLine(id)
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local cached = tipCache[id]
    if cached and cached.map == map and GetTime() - cached.time < 10 then return cached.text end
    local text = false
    local vendors = Field(ItemDB, "vendors", id)
    if type(vendors) == "table" then
        local here, count = Here(), 0
        local best, bestPoint, bestDistance
        for _, npc in ipairs(vendors) do
            if not Hostile(Field(NpcDB, "friendlyToFaction", npc)) then
                count = count + 1
                local point, distance = Closest(Points(npc), here)
                if point and (not bestDistance or distance < bestDistance) then
                    best, bestPoint, bestDistance = npc, point, distance
                end
            end
        end
        if count > 0 and not best then
            text = L.ITEM_TT_VENDORS_ANY:format(count)
        elseif count == 1 then
            text = L.ITEM_TT_VENDOR:format(Field(NpcDB, "name", best) or "?", Place(bestPoint))
        elseif count > 1 then
            text = L.ITEM_TT_VENDORS:format(count, Field(NpcDB, "name", best) or "?", Place(bestPoint))
        end
    end
    tipCache[id] = { text = text, map = map, time = GetTime() }
    return text
end

local function OnItemTooltip(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= _G.ItemRefTooltip then return end
    if not (ns:IsEnabled(KEY) and ns:GetOption(KEY, "itemTooltip")) or not ItemsReady() then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    if not Util.ReadableTable(data) then return end
    local id = data.id
    if not Util.Readable(id) or type(id) ~= "number" then return end
    local ok, text = pcall(VendorLine, id)
    if not ok or not text then return end
    tooltip:AddLine(text, 0.4, 1, 0.4, true)
    if ns:GetOption(KEY, "altClick") then tooltip:AddLine(L.ITEM_TT_ALT, 0.5, 0.8, 1) end
    tooltip:Show()
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end

---------------------------------------------------------------------------
-- For the hunting list (Features\HuntList.lua). These work whether the
-- finder is on or off: only QuestieDB is needed.
---------------------------------------------------------------------------

Finder.Here = Here

local npcHits = {} -- NPC ID -> Info() of it

-- An NPC's name, title, levels and positions; nil without QuestieDB.
function Finder.Npc(id)
    if type(id) ~= "number" or not DataReady() then return end
    local hit = npcHits[id]
    if not hit then
        hit = Info({ kind = "npc", id = id })
        npcHits[id] = hit
    end
    return hit
end

-- "Zone" ("Zone +2" when it is in several), or "no known position" in red.
function Finder.NpcWhere(id)
    local hit = Finder.Npc(id)
    return hit and WhereText(hit)
end

-- Yards from you to the NPC's nearest known spot (FAR elsewhere), and
-- whether QuestieDB knows a spot at all. here: from Finder.Here().
function Finder.NpcDistance(id, here)
    local hit = Finder.Npc(id)
    if not hit or #hit.points == 0 then return FAR, false end
    local _, distance = Closest(hit.points, here or Here())
    return distance, true
end

-- On the map, as if picked in the bar (arrow: a TomTom arrow too).
function Finder.ShowNpc(id, arrow)
    local hit = Finder.Npc(id)
    if not hit then
        local _, problem = DataReady()
        ns:Print(problem or L.NPC_NO_DB)
        return
    end
    Go(hit, arrow)
end

-- Markers where the NPC can be (the nearest spots), without opening the map.
function Finder.MarkNpc(id)
    local hit = Finder.Npc(id)
    if hit and #hit.points > 0 then ShowMarkers(hit) end
end

-- The NPC called exactly `name` (any case or accents): its ID and its name
-- as QuestieDB writes it. Several NPCs can share a name: one with a known
-- position first. prefix: an NPC with a known position whose name starts
-- with `name` also does, when only one name starts that way, and it wins
-- over an exact name nobody knows where to find. That is what /target does
-- with a partial name ("/tar Anaya" targets Anaya Dawnrunner, while the
-- NPC called just "Anaya" spawns nowhere).
function Finder.LookupNpc(name, prefix)
    if type(name) ~= "string" or not StartIndex() then return end
    Pump(nil)
    if indexState ~= "ready" then return end
    local exact, exactName, start, startName
    for _, hit in ipairs((Search(name, "npc"))) do
        local full = Field(NpcDB, "name", hit.id)
        full = type(full) == "string" and full or nil
        if hit.score == 0 then
            if hit.unknown == 0 then return hit.id, full end
            if not exact then exact, exactName = hit.id, full end
        elseif prefix and hit.score == 1 and full and hit.unknown == 0 then
            if start == nil then
                start, startName = hit.id, full
            elseif startName ~= full then
                start = false -- two names start that way
            end
        end
    end
    if start then return start, startName end
    return exact, exactName
end

-- An NPC row of the list under the bar that can go in the hunting list.
function Finder.Huntable(entry)
    local hunt, hit = ns.HuntList, entry and entry.hit
    return hunt ~= nil and hunt.Enabled() and hit ~= nil and hit.kind == "npc" and not hit.missing
end

-- Ctrl-click on such a row: hunted.
function Finder.HuntRow(entry)
    if not Finder.Huntable(entry) then return false end
    local added, new = ns.HuntList.Add(entry.hit.name, entry.hit.id)
    if added then ns:Print((new and L.HUNT_ADDED or L.HUNT_ALREADY):format(added.name)) end
    return true
end

---------------------------------------------------------------------------
-- Enable / disable
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(self, _, name)
    -- Blizzard_WorldMap can load on demand: wait for it.
    if name == "Blizzard_WorldMap" and CreateBar() then
        self:UnregisterEvent("ADDON_LOADED")
        UpdateBar()
    end
end)

local function Enable()
    if CreateBar() then
        UpdateBar()
    else
        events:RegisterEvent("ADDON_LOADED")
    end
end

local function Disable()
    ClearMarkers()
    RemoveArrow()
    UpdateBar()
    wipe(tipCache)
end

ns:On("OPTION_CHANGED", function(key)
    if key == KEY then UpdateBar() end
end)

ns:On("LANGUAGE_CHANGED", function()
    wipe(tipCache)
    if view then
        -- Its headers and tooltips are in the old language: built again.
        local old = view
        view = BuildItemView(old.item)
        view.parent, view.query, view.searchSelected = old.parent, old.query, old.searchSelected
        view.selected, view.offset = math.min(old.selected, #view.entries), old.offset
    end
    if list and list:IsShown() then Render() end
end)

ns:RegisterCategory({
    key = "map",
    order = 35,
    title = "CAT_MAP",
    desc = "CAT_MAP_DESC",
    icon = "Interface\\Icons\\INV_Misc_Spyglass_02",
})

ns:RegisterFeature({
    key = KEY,
    category = "map",
    order = 10,
    title = "NPC_TITLE",
    desc = "NPC_DESC",
    tip = "NPC_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "showBar", title = "NPC_OPT_BAR", tip = "NPC_OPT_BAR_TIP", default = true },
        { key = "altClick", title = "ITEM_OPT_ALT", tip = "ITEM_OPT_ALT_TIP", default = true },
        { key = "itemTooltip", title = "ITEM_OPT_TOOLTIP", tip = "ITEM_OPT_TOOLTIP_TIP", default = false },
        { key = "resetBar", title = "NPC_OPT_RESET", tip = "NPC_OPT_RESET_TIP", action = function() Finder.ResetBar() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
