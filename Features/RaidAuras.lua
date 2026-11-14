local _, ns = ...
local L = ns.L

--[[
Hide chosen auras (Boosted Rest) on Blizzard's party and raid frames.

Why it is built this way:
  On Forever, CompactUnitFrame.lua no longer draws the raid frame auras.
  Each party or raid member frame registers a "container" anchor, and
  Blizzard_PrivateAurasUI, which runs in a separate secure environment,
  draws the icons. Addons can't reach those icons, hook its filters, or hide
  one of them.

  The one door it leaves open is the blocked-aura list:
  C_UnitAuras.AddBlockedAura(unit, auraInstanceID) fires UNIT_AURA_BLOCKED,
  and the container skips that aura when it lays out its icons, so the other
  icons close the gap. Blizzard's arena frames use the same call to hide the
  crowd control they show in their own icon.

  Two catches:
  - Blocking does not redraw. The container redraws one frame after an aura
    change on its unit (C_Timer.After(0)), on entering or leaving combat, and
    when the frame's "update-settings" attribute is set. A block sent while
    handling UNIT_AURA or those combat events lands before that redraw.
    Otherwise, out of combat, the frame gets the attribute that Blizzard's
    own TriggerPrivateAuraSettingsUpdate sets.
  - The list lives in the container. It is emptied when Blizzard rebuilds
    the anchor (a new frame.anchorID), and blocks sent while the frame is
    hidden are not heard, because its event frame only listens while shown.
    So the block is sent again when a frame gets a unit or is shown, and on
    roster changes.

  Aura data can be secret in restricted contexts; secret auras are left
  alone, since they can't be read and addon code can't pass a secret value
  to AddBlockedAura.
]]

local KEY = "hideRaidAuras"

-- Aura names hidden from the group frames. Forever's client is English. A
-- spell ID would also work in other languages, but it isn't known yet:
-- /bf auras prints it.
local HIDDEN = {
    ["Boosted Rest"] = true,
}
local FILTERS = { "HELPFUL", "HARMFUL" }

local GROUP_UNIT = { player = true }
for i = 1, 4 do GROUP_UNIT["party" .. i] = true end
for i = 1, 40 do GROUP_UNIT["raid" .. i] = true end

local RaidAuras = {}
ns.RaidAuras = RaidAuras

local active = false
local hooked = false
local weak = { __mode = "k" }
local frames = setmetatable({}, weak)   -- party and raid member frames drawn by a container
local ignored = setmetatable({}, weak)  -- other unit frames seen by the hook
local done = setmetatable({}, weak)     -- frame -> what was last hidden there (see Refresh)
local pending = setmetatable({}, weak)  -- frames waiting for Flush
local scheduled = false
local events = CreateFrame("Frame")

local issecret = issecretvalue or function() return false end

local function Usable(value)
    return value ~= nil and not issecret(value)
end

---------------------------------------------------------------------------
-- Units and auras
---------------------------------------------------------------------------

local function FrameUnit(frame)
    local unit = frame.displayedUnit or frame.unit
    if issecret(unit) or type(unit) ~= "string" then return end
    local ok, exists = pcall(UnitExists, unit)
    if ok and Usable(exists) and exists then return unit end
end

local function SameUnit(a, b)
    if a == b then return true end
    local ok, same = pcall(UnitIsUnit, a, b)
    return ok and Usable(same) and same == true
end

-- The aura's instance ID when it is one we hide.
local function HiddenID(aura)
    if type(aura) ~= "table" then return end
    local name, id = aura.name, aura.auraInstanceID
    if Usable(name) and Usable(id) and HIDDEN[name] then return id end
end

local function ForEachHidden(unit, fn)
    local find = C_UnitAuras and C_UnitAuras.GetAuraDataBySpellName
    if not find then return end
    for name in pairs(HIDDEN) do
        for _, filter in ipairs(FILTERS) do
            local ok, aura = pcall(find, unit, name, filter)
            local id = ok and HiddenID(aura)
            if id then fn(id, aura, filter) end
        end
    end
end

local function Block(unit, id)
    return pcall(C_UnitAuras.AddBlockedAura, unit, id)
end

-- Asks the frame's container to reread its settings and redraw. The frame
-- is protected, so only out of combat; entering or leaving combat redraws
-- it anyway.
local function Redraw(frame)
    if InCombatLockdown() then return false end
    return (pcall(frame.SetAttribute, frame, "update-settings", true))
end

-- Blocks the hidden auras on the frame's unit. With redraw, the frame is
-- also redrawn when the block may have come after its last drawing: a new
-- anchor, a new aura, or another player behind the same unit token.
local function Refresh(frame, redraw)
    local unit = FrameUnit(frame)
    local ids
    if unit then
        ForEachHidden(unit, function(id)
            Block(unit, id)
            ids = (ids and ids .. "," or "") .. id
        end)
    end
    if not ids then
        done[frame] = nil
        return
    end
    local anchor = frame.anchorID
    if issecret(anchor) then anchor = "?" end
    local key = tostring(anchor) .. "|" .. unit .. "|" .. ids
    if redraw and done[frame] ~= key then Redraw(frame) end
    done[frame] = key
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------

local function Flush()
    scheduled = false
    local list = {}
    for frame in pairs(pending) do list[#list + 1] = frame end
    wipe(pending)
    if not active then return end
    for _, frame in ipairs(list) do Refresh(frame, true) end
end

local function Queue(frame)
    pending[frame] = true
    if not scheduled then
        scheduled = true
        C_Timer.After(0, Flush)
    end
end

local function OnShow(frame)
    if not active then return end
    done[frame] = nil -- blocks sent while it was hidden were not heard
    Queue(frame)
end

local function IsForbidden(frame)
    return frame.IsForbidden ~= nil and frame:IsForbidden()
end

local function Track(frame)
    if frame == nil or issecret(frame) or type(frame) ~= "table" then return false end
    if frames[frame] then return true end
    if ignored[frame] then return false end
    local ok, forbidden = pcall(IsForbidden, frame)
    -- Only party and raid member frames draw their auras through a container.
    if not ok or forbidden or type(frame.TriggerPrivateAuraSettingsUpdate) ~= "function" then
        ignored[frame] = true
        return false
    end
    -- The frame is protected; if the hook is refused, try again next time.
    if not pcall(frame.HookScript, frame, "OnShow", OnShow) then return false end
    frames[frame] = true
    return true
end

local function TrackNamed()
    for i = 1, 5 do Track(_G["CompactPartyFrameMember" .. i]) end
    for group = 1, 8 do
        for i = 1, 5 do Track(_G["CompactRaidGroup" .. group .. "Member" .. i]) end
    end
    local i = 1
    while _G["CompactRaidFrame" .. i] do
        Track(_G["CompactRaidFrame" .. i])
        i = i + 1
    end
end

local function QueueAll()
    TrackNamed()
    for frame in pairs(frames) do Queue(frame) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnUnitAura(unit, info)
    if not GROUP_UNIT[unit] or issecret(info) then return end
    -- A full update makes the container read every aura again; otherwise
    -- only new auras matter (a refreshed aura keeps its instance ID).
    -- In restricted contexts the table itself is plain but its fields are
    -- secret, and a boolean test on a secret value is an error: leave those
    -- updates alone, the combat events and the next readable update catch up.
    local full = info and info.isFullUpdate
    if issecret(full) then return end
    local ids
    if info and not full then
        if issecret(info.addedAuras) or type(info.addedAuras) ~= "table" then return end
        for _, aura in ipairs(info.addedAuras) do
            local id = HiddenID(aura)
            if id then
                ids = ids or {}
                ids[#ids + 1] = id
            end
        end
        if not ids then return end
    end
    for frame in pairs(frames) do
        local frameUnit = FrameUnit(frame)
        if frameUnit and SameUnit(frameUnit, unit) then
            if ids then
                for _, id in ipairs(ids) do Block(frameUnit, id) end
            else
                Refresh(frame, false)
            end
        end
    end
end

events:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_AURA" then
        OnUnitAura(...)
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        -- Every container redraws on these: make sure the blocks are in.
        for frame in pairs(frames) do Refresh(frame, false) end
    else -- GROUP_ROSTER_UPDATE, PLAYER_ENTERING_WORLD
        QueueAll()
    end
end)

local function InstallHooks()
    if hooked or type(CompactUnitFrame_SetUnit) ~= "function" then return end
    hooked = true
    hooksecurefunc("CompactUnitFrame_SetUnit", function(frame)
        if active and Track(frame) then Queue(frame) end
    end)
end

local function Enable()
    active = true
    InstallHooks()
    wipe(done)
    events:RegisterEvent("UNIT_AURA")
    events:RegisterEvent("GROUP_ROSTER_UPDATE")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    QueueAll()
end

local function Disable()
    active = false
    events:UnregisterAllEvents()
    wipe(pending)
    wipe(done)
    -- Give the auras back. Nothing else blocks auras on party and raid
    -- units (the arena frames only block arena units), so the whole list
    -- can be emptied; the redraw also restores Blizzard's own use of it.
    local cleared = {}
    for frame in pairs(frames) do
        local unit = FrameUnit(frame)
        if unit then
            if not cleared[unit] then
                cleared[unit] = true
                pcall(C_UnitAuras.ClearBlockedAuras, unit)
            end
            Redraw(frame)
        end
    end
end

---------------------------------------------------------------------------
-- /bf auras: what is found and hidden on each frame
---------------------------------------------------------------------------

-- Auras whose name looks close, in case the game spells it differently.
local function NearMatches(unit)
    local found = {}
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if not get then return found end
    for _, filter in ipairs(FILTERS) do
        for index = 1, 100 do
            local ok, aura = pcall(get, unit, index, filter)
            if not ok or type(aura) ~= "table" then break end
            local name = aura.name
            if Usable(name) then
                local lower = name:lower()
                if lower:find("boost", 1, true) or lower:find("rest", 1, true) then
                    local spellId = Usable(aura.spellId) and aura.spellId or "?"
                    found[#found + 1] = ("%s (%s, %s)"):format(name, tostring(spellId), filter)
                end
            end
        end
    end
    return found
end

function RaidAuras.Report()
    if not active then ns:Print(L.RAIDAURA_REPORT_OFF) end
    TrackNamed()
    local list = {}
    for frame in pairs(frames) do
        if FrameUnit(frame) then list[#list + 1] = frame end
    end
    if #list == 0 then
        ns:Print(L.RAIDAURA_REPORT_EMPTY)
        return
    end
    table.sort(list, function(a, b) return (a:GetName() or "") < (b:GetName() or "") end)
    ns:Print(L.RAIDAURA_REPORT_HEADER:format(#list))
    for _, frame in ipairs(list) do
        local unit = FrameUnit(frame)
        local parts = {}
        ForEachHidden(unit, function(id, aura, filter)
            local spellId = tostring(Usable(aura.spellId) and aura.spellId or "?")
            if not active then
                parts[#parts + 1] = L.RAIDAURA_REPORT_SHOWN:format(aura.name, spellId, filter)
            else
                local ok, err = Block(unit, id)
                if ok then
                    parts[#parts + 1] = L.RAIDAURA_REPORT_HIDDEN:format(aura.name, spellId, filter)
                else
                    parts[#parts + 1] = L.RAIDAURA_REPORT_REFUSED:format(aura.name, tostring(err))
                end
            end
        end)
        if #parts == 0 then
            local near = NearMatches(unit)
            parts[1] = #near > 0 and L.RAIDAURA_REPORT_NEAR:format(table.concat(near, ", ")) or L.RAIDAURA_REPORT_NONE
        end
        local name = UnitName(unit)
        if not Usable(name) then name = "?" end
        ns:Print(("%s (%s, %s): %s"):format(frame:GetName() or "?", unit, name, table.concat(parts, "; ")))
    end
    -- Also redraw every frame now, in case one missed its block.
    if active then
        for _, frame in ipairs(list) do
            done[frame] = nil
            Queue(frame)
        end
    end
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterCategory({
    key = "frames",
    order = 40,
    title = "CAT_FRAMES",
    desc = "CAT_FRAMES_DESC",
    icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing02",
})

ns:RegisterFeature({
    key = KEY,
    category = "frames",
    order = 10,
    title = "RAIDAURA_TITLE",
    desc = "RAIDAURA_DESC",
    tip = "RAIDAURA_TIP",
    default = true,
    isNew = true,
    OnEnable = Enable,
    OnDisable = Disable,
})
