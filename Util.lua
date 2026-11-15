local _, ns = ...

-- Helpers shared by features. Everything that touches names guards against
-- 12.x secret values: they can never be read, compared or concatenated.
local Util = {}
ns.Util = Util

function Util.Readable(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return false end
    if canaccessvalue and not canaccessvalue(value) then return false end
    return true
end

function Util.ReadableTable(value)
    return Util.Readable(value) and type(value) == "table" and (not canaccesstable or canaccesstable(value))
end

local function MyRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if Util.Readable(realm) and type(realm) == "string" and realm ~= "" then return realm end
end

-- Strips colors and anything that could break a macro line. nil if unusable.
function Util.CleanName(value)
    if not Util.Readable(value) or type(value) ~= "string" then return end
    value = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    value = strtrim((value:gsub("[%c;%[%]]", "")))
    if value == "" or #value > 80 then return end
    return value
end

-- "Name" for players of your realm, "Name-Realm" otherwise.
local function WithRealm(name, realm)
    if Util.Readable(realm) and type(realm) == "string" and realm ~= "" and not name:find("-", 1, true) then
        realm = realm:gsub("%s", "")
        if realm ~= "" and realm ~= MyRealm() then name = name .. "-" .. realm end
    end
    return name
end

-- Player name from a UnitPopup menu context (chat, friends, guild...).
function Util.FullName(context)
    if UnitPopupSharedUtil and UnitPopupSharedUtil.GetFullPlayerName then
        local ok, full = pcall(UnitPopupSharedUtil.GetFullPlayerName, context)
        full = ok and Util.CleanName(full)
        if full then return full end
    end
    local name = Util.CleanName(context.name) or Util.CleanName(context.chatTarget)
    if not name then return end
    return WithRealm(name, Util.CleanName(context.server))
end

-- UnitName's second value is the surname on Forever ("Budget", "Heal") and
-- the realm on other clients (nil for your own realm).
local function IsSurname(unit, second)
    if second == MyRealm() or second == (GetRealmName and GetRealmName()) then return false end
    if unit == "player" then return true end
    if RegionalUniqueNamesEnabled then
        local ok, enabled = pcall(RegionalUniqueNamesEnabled)
        if ok and Util.Readable(enabled) and enabled == true then return true end
    end
    if UnitRealmRelationship and LE_REALM_RELATION_SAME then
        local ok, relation = pcall(UnitRealmRelationship, unit)
        if ok and Util.Readable(relation) and relation == LE_REALM_RELATION_SAME then return true end
    end
    return false
end

-- "Budget Heal" (surname joined with a space, as chat menus spell it),
-- "Name" or "Name-Realm".
function Util.UnitFullName(unit)
    if not Util.Readable(unit) or type(unit) ~= "string" or unit == "" then return end
    local name, second = UnitName(unit)
    name = Util.CleanName(name)
    if not name then return end
    second = Util.CleanName(second)
    if second and IsSurname(unit, second) then return name .. " " .. second end
    return WithRealm(name, second)
end

-- Account-wide key: lower case, always with a realm (spaces removed from
-- the realm, never from the name). Also returns the canonical "Name-Realm".
function Util.Key(name)
    name = Util.CleanName(name)
    if not name then return end
    local base, realm = name:match("^(.-)%-(.+)$")
    if base and base ~= "" then
        name = base .. "-" .. realm:gsub("%s", "")
    else
        local mine = MyRealm()
        if mine then name = name .. "-" .. mine end
    end
    return strlower(name), name
end

-- Drops your own realm suffix for display.
function Util.DisplayName(name)
    name = Util.CleanName(name)
    if not name then return end
    local realm = MyRealm()
    if realm and name:sub(-(#realm + 1)) == "-" .. realm then
        name = name:sub(1, -(#realm + 2))
    end
    return name
end

-- Same player, exact match on name, surname and realm: "Budget War" is
-- not "Budget Heal".
function Util.SamePlayer(a, b)
    local key = Util.Key(a)
    return key ~= nil and key == Util.Key(b)
end

function Util.IsSelf(full)
    return Util.SamePlayer(full, Util.UnitFullName("player"))
end

function Util.UnitIs(unit, full)
    return Util.SamePlayer(full, Util.UnitFullName(unit))
end

local function DeepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for k, v in pairs(value) do copy[k] = DeepCopy(v) end
    return copy
end

-- "Budget Heal-Realm": this character's key in per-character saved tables.
-- Until 2026-11-13 the key held the first name only ("Budget-Realm"), one
-- entry shared by every alt called Budget. Given `store`, each alt's first
-- login copies that shared entry to its own key, so nothing seems lost.
function Util.CharacterKey(store)
    local name = Util.UnitFullName("player")
    local realm = MyRealm() or Util.CleanName(GetRealmName and GetRealmName())
    if not name or not realm then return "?" end
    local key = name .. "-" .. realm
    if type(store) == "table" and store[key] == nil then
        local first = Util.CleanName((UnitName("player")))
        local legacy = first and first .. "-" .. realm
        if legacy and legacy ~= key and type(store[legacy]) == "table" then
            store[key] = DeepCopy(store[legacy])
        end
    end
    return key
end

function Util.ClassColored(text, class)
    local color = class and ((C_ClassColor and C_ClassColor.GetClassColor(class)) or (RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]))
    if not color then return text end
    if color.WrapTextInColorCode then return color:WrapTextInColorCode(text) end
    return ("|c%s%s|r"):format(color.colorStr, text)
end

-- Cuts after maxChars characters without splitting UTF-8 sequences.
function Util.Truncate(text, maxChars, suffix)
    local count, cut = 0, nil
    for position in text:gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > maxChars then cut = position; break end
    end
    if not cut then return text end
    return strtrim(text:sub(1, cut - 1)) .. (suffix or "...")
end

---------------------------------------------------------------------------
-- Menu helpers (11.x Menu API)
---------------------------------------------------------------------------

-- Index of the first menu element whose text is `text`, if any.
function Util.FindMenuElement(root, text)
    if not text or not root.EnumerateElementDescriptions or not MenuUtil or not MenuUtil.GetElementText then return end
    local ok, iterator, state, initial = pcall(root.EnumerateElementDescriptions, root)
    if not ok or type(iterator) ~= "function" then return end
    for index, element in iterator, state, initial do
        local found, elementText = pcall(MenuUtil.GetElementText, element)
        if found and elementText == text then return index end
    end
end

-- One "BudgetTools" header per menu, shared by every feature that
-- appends entries, so two features never print two headers.
local sections = setmetatable({}, { __mode = "k" })

function Util.MenuSection(root)
    if sections[root] then return end
    sections[root] = true
    root:CreateDivider()
    root:CreateTitle(ns.L.ADDON_TITLE)
end

---------------------------------------------------------------------------
-- Action bars: removing what addon code leaves on them
---------------------------------------------------------------------------

--[[
Blizzard's action bars redo their layout each time the grid shows or hides:
something goes on or off the cursor, or the spellbook / talent window opens
or closes. When addon code caused it (PickupSpell, PickupItem, ClearCursor,
opening the talent window), that layout runs as addon code and the notes it
writes on the bars stay marked as the addon's:
  bar.snappedToFrame     the frame the bar is anchored to
  bar.showAllButtons     why the grid is shown (0 once it is hidden)
  bar.flyoutDirection
  EditModeManagerFrame.editModeSystemAnchorDirty

On Forever the bottom bars are anchored again on every target change (the
pet bar hides itself, which redoes the whole stack). In combat, that pass
read MainActionBar.snappedToFrame between ClearAllPoints and SetPoint,
became "addon code" there, and SetPoint was refused: ADDON_ACTION_BLOCKED on
MainActionBar:SetPointBase(), blamed on this addon.

A key written by addon code stays marked even once set to nil, until the
table drops it on a rehash. PurgeKey forces that rehash (the known cure for
the dropdown taint), so Blizzard reads a plain nil again. Only values the
bars treat like nil are removed; snappedToFrame is written again by the next
layout, which then runs as Blizzard code.
]]

local BARS = {
    "MainActionBar", "SecondaryStatusTrackingBarContainer", "MainStatusTrackingBarContainer",
    "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarRight", "MultiBarLeft",
    "MultiBar5", "MultiBar6", "MultiBar7",
    "StanceBar", "PetActionBar", "PossessActionBar", "MainMenuBarVehicleLeaveButton",
    "MultiCastActionBarFrame",
}

local function Marked(t, key)
    return issecurevariable(t, key) ~= true
end

local function PurgeKey(t, key)
    if not Marked(t, key) then return end
    t[key] = nil
    -- Writing nil to keys the table doesn't have fills its free slots; the
    -- rehash that follows drops every nil key, this one included.
    local probe = 42
    for _ = 1, 4096 do
        if not Marked(t, key) then return end
        if t[probe] == nil then t[probe] = nil end
        probe = probe + 1
    end
end

local function CleanBar(bar)
    if Marked(bar, "snappedToFrame") then
        -- What Blizzard's ClearFrameSnap does before each new anchor.
        local target = rawget(bar, "snappedToFrame")
        local snapped = type(target) == "table" and rawget(target, "snappedFrames")
        if type(snapped) == "table" then snapped[bar] = nil end
        PurgeKey(bar, "snappedToFrame")
    end
    if Marked(bar, "showAllButtons") then
        -- Left alone while the grid is shown: there is no clean way to write
        -- a number. It is purged when the grid hides.
        local reasons = rawget(bar, "showAllButtons")
        if reasons == nil or reasons == 0 then PurgeKey(bar, "showAllButtons") end
    end
    PurgeKey(bar, "flyoutDirection") -- nil: the next layout works it out again
end

local function CleanBarsNow()
    if type(issecurevariable) ~= "function" then return end
    for _, name in ipairs(BARS) do
        local bar = _G[name]
        if type(bar) == "table" then CleanBar(bar) end
    end
    local manager = EditModeManagerFrame
    if type(manager) == "table" and not rawget(manager, "editModeSystemAnchorDirty") then
        PurgeKey(manager, "editModeSystemAnchorDirty")
    end
end

local cleanQueued = false

-- Call after anything that makes the bars redo their layout from addon code.
-- Cleans now, and again on the next frame: when an event is the cause, the
-- bars may handle it after the caller does. Only Lua fields are written, so
-- it is allowed in combat.
function Util.CleanBars()
    pcall(CleanBarsNow)
    if cleanQueued then return end
    cleanQueued = true
    C_Timer.After(0, function()
        cleanQueued = false
        pcall(CleanBarsNow)
    end)
end

-- The cursor being emptied hides the grid, whoever emptied it; entering
-- combat is the last moment before a marked field costs a refused action.
local barCleaner = CreateFrame("Frame")
barCleaner:RegisterEvent("ACTIONBAR_HIDEGRID")
barCleaner:RegisterEvent("PLAYER_REGEN_DISABLED")
barCleaner:SetScript("OnEvent", function() Util.CleanBars() end)
