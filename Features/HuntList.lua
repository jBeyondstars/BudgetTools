local _, ns = ...
local L, UI, Util = ns.L, ns.UI, ns.Util

--[[
Hunting list: NPCs you want to find and tag first (a rare, a quest mob
that respawns, an NPC you keep looking for). One key, which you can spam,
targets the most important listed NPC around and casts your tag spell on
it. An alert says when one shows up.

The key runs a secure macro this file writes, out of combat:
    /cleartarget
    /targetexact <names, the least important first: the last one found wins>
    /cast [harm,nodead] <tag spell, rank 1>
    /petattack [harm,nodead]               (option)
    /targetlasttarget [dead][noexists]
/cleartarget comes first so the spell never goes to the mob you already
had targeted. The last line gives that target back when nobody from the
list is around, or only a corpse. [harm] never attacks a friendly NPC.
RXPGuides, RareScanner and ForeverDungeonJournal target the same way on
Forever.

A macro run by a button may be held to 255 characters like a real one
(not verified). When the names don't fit, those nearest to you are kept:
seen a moment ago, then by QuestieDB positions. That costs nothing, since
/targetexact only reaches units around you, and the choice is made again
as you move.

Storage, BudgetForeverDB.hunt (kept by /bgt reset):
  list  = { { name, id?, on, seen? }, ... }  most important first, account-wide
  chars = { ["Name-Realm"] = { spell = { id, name, rank? }, lowest, pet } }
  button = { point, relativePoint, x, y }     the on-screen button, once dragged
]]

local KEY = "huntList"
local TRIGGER_NAME = "BudgetForeverHunt"
local BUTTON_NAME = "BudgetForeverHuntButton"
local BINDING = "CLICK " .. TRIGGER_NAME .. ":LeftButton"
local LIST_ACTION = "bfhuntlist" -- custom action type: right-click on the button opens the list
local NO_ACTION = "bfhuntnone"   -- and Shift+click does nothing (Shift-drag moves the button)
local MAX_TEXT = 255      -- characters of macro text
local NEAR = 1500         -- yards: a known spot this close counts as around you
local RECENT = 120        -- seconds: an NPC seen this recently goes in the macro first
local ALERT_AGAIN = 90    -- seconds before the same NPC is announced again
local REFRESH = 10        -- seconds between checks of which names fit, out of combat
local OWN_PRESS = 1       -- seconds: a target change this soon after a press is the key's
local FAR = 1e9
local DEFAULT_ICON = "Interface\\Icons\\Ability_Hunter_SniperShot"

-- Rank 1 of an instant spell that hits at once (the first hit tags).
local SUGGESTIONS = {
    PRIEST = { 589 },          -- Shadow Word: Pain
    HUNTER = { 3044, 1978 },   -- Arcane Shot, Serpent Sting
    MAGE = { 2136 },           -- Fire Blast
    DRUID = { 8921 },          -- Moonfire
    SHAMAN = { 8042 },         -- Earth Shock
    WARLOCK = { 980 },         -- Curse of Agony
    PALADIN = { 20271 },       -- Judgement
    WARRIOR = { 100, 2764 },   -- Charge, Throw
    ROGUE = { 2764 },          -- Throw
}
local PET_CLASSES = { HUNTER = true, WARLOCK = true }

local Hunt = {}
ns.HuntList = Hunt
Hunt.KEY, Hunt.BINDING, Hunt.MAX_TEXT, Hunt.DEFAULT_ICON = KEY, BINDING, MAX_TEXT, DEFAULT_ICON

function Hunt.Enabled()
    return ns:IsEnabled(KEY)
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local validated = false
local byName = {} -- lower-case name -> entry

-- Drops anything a hand-edited or older SavedVariables file could hold.
local function Data()
    if not ns.db then return { list = {}, chars = {} } end
    local data = ns.db.hunt
    if type(data) ~= "table" then
        data = {}
        ns.db.hunt = data
    end
    if type(data.list) ~= "table" then data.list = {} end
    if type(data.chars) ~= "table" then data.chars = {} end
    if not validated then
        validated = true
        local clean, seen = {}, {}
        for _, entry in ipairs(data.list) do
            local name = type(entry) == "table" and Util.CleanName(entry.name)
            if name and not seen[strlower(name)] then
                seen[strlower(name)] = true
                entry.name = name
                entry.on = entry.on ~= false
                if type(entry.id) ~= "number" then entry.id = nil end
                if type(entry.seen) ~= "number" then entry.seen = nil end
                clean[#clean + 1] = entry
            end
        end
        data.list = clean
    end
    return data
end

local function Index()
    wipe(byName)
    for _, entry in ipairs(Data().list) do byName[strlower(entry.name)] = entry end
end

-- The list, most important first.
function Hunt.List()
    return Data().list
end

-- entry, index for a name (any case).
function Hunt.Find(name)
    if type(name) ~= "string" then return end
    local key = strlower(name)
    for index, entry in ipairs(Data().list) do
        if strlower(entry.name) == key then return entry, index end
    end
end

function Hunt.ActiveCount()
    local count = 0
    for _, entry in ipairs(Data().list) do
        if entry.on then count = count + 1 end
    end
    return count
end

local function Changed()
    Index()
    Hunt.Rebuild()
    ns:Fire("HUNT_CHANGED")
end

-- Adds an NPC at the bottom (least important), or turns it back on.
-- id: QuestieDB's NPC ID when known. Returns the entry and whether it is
-- new. quiet: the caller calls Changed() itself.
local function Add(name, id, quiet)
    name = Util.CleanName(name)
    if not name then return end
    if type(id) ~= "number" then id = nil end
    local entry = Hunt.Find(name)
    if entry then
        local changed = not entry.on or (id ~= nil and entry.id == nil)
        entry.on = true
        entry.id = entry.id or id
        if changed and not quiet then Changed() end
        return entry, false
    end
    entry = { name = name, id = id, on = true }
    table.insert(Data().list, entry)
    if not quiet then Changed() end
    return entry, true
end

function Hunt.Add(name, id)
    return Add(name, id)
end

-- A typed name: written the way QuestieDB writes it when it knows the NPC
-- (/targetexact wants the whole name; a partial one is completed the way
-- /target would).
local function Resolve(name)
    name = Util.CleanName(name)
    if not name then return end
    local finder = ns.NpcFinder
    if finder and finder.LookupNpc then
        local ok, id, canonical = pcall(finder.LookupNpc, name, true)
        if ok and id then return canonical or name, id end
    end
    return name
end

function Hunt.AddByName(name)
    local resolved, id = Resolve(name)
    if not resolved then return end
    return Add(resolved, id)
end

-- Several names at once (an imported macro). Returns how many are new.
function Hunt.AddNames(names)
    local added = 0
    for _, name in ipairs(names) do
        local resolved, id = Resolve(name)
        local _, new = Add(resolved, id, true)
        if new then added = added + 1 end
    end
    Changed()
    return added
end

function Hunt.Remove(name)
    local _, index = Hunt.Find(name)
    if not index then return end
    table.remove(Data().list, index)
    Changed()
end

function Hunt.SetOn(name, on)
    local entry = Hunt.Find(name)
    if not entry or entry.on == (on and true or false) then return end
    entry.on = on and true or false
    Changed()
end

-- step -1: more important (up the list), 1: less important.
function Hunt.Move(index, step)
    local list = Data().list
    local other = index + step
    if not list[index] or not list[other] then return end
    list[index], list[other] = list[other], list[index]
    Changed()
end

---------------------------------------------------------------------------
-- Tag spell, per character
---------------------------------------------------------------------------

function Hunt.Char()
    local chars = Data().chars
    -- No copy from the old shared key: its defaults came from whichever
    -- class created it, each alt now gets its own class defaults.
    local key = Util.CharacterKey()
    local char = chars[key]
    if type(char) ~= "table" then
        local _, class = UnitClass("player")
        -- Hunters and warlocks: the pet's first hit tags too.
        char = { lowest = true, pet = PET_CLASSES[class] == true }
        chars[key] = char
    end
    return char
end

local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, id)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, id)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
end

-- "Rank 3" (localized), nil for a spell without ranks.
local function SpellRank(id)
    local get = (C_Spell and C_Spell.GetSpellSubtext) or GetSpellSubtext
    if not get then return end
    local ok, text = pcall(get, id)
    if ok and Util.Readable(text) and type(text) == "string" and text:find("%d") then return text end
end

function Hunt.SpellIcon(spell)
    if type(spell) ~= "table" then return DEFAULT_ICON end
    local get = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
    if get then
        local ok, icon = pcall(get, spell.id or spell.name)
        if ok and icon then return icon end
    end
    return DEFAULT_ICON
end

function Hunt.SpellFromId(id)
    if type(id) ~= "number" then return end
    local name = SpellName(id)
    if not name then return end
    return { id = id, name = name, rank = SpellRank(id) }
end

local function Known(id)
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, id)
        if ok and known then return true end
    end
    if IsSpellKnown then
        local ok, known = pcall(IsSpellKnown, id)
        if ok and known then return true end
    end
    return not IsPlayerSpell and not IsSpellKnown
end

-- Suggested spells of your class that you know.
function Hunt.Suggestions()
    local _, class = UnitClass("player")
    local out = {}
    for _, id in ipairs(SUGGESTIONS[class] or {}) do
        local spell = Hunt.SpellFromId(id)
        if spell and Known(id) then out[#out + 1] = spell end
    end
    return out
end

-- The spell held on the cursor (dragged from the spellbook), if any.
function Hunt.CursorSpell()
    if not GetCursorInfo then return end
    local kind, slot, book, id = GetCursorInfo()
    if kind ~= "spell" then return end
    if type(id) ~= "number" and C_SpellBook and C_SpellBook.GetSpellBookItemInfo and type(slot) == "number" then
        local ok, info = pcall(C_SpellBook.GetSpellBookItemInfo, slot, book)
        if ok and type(info) == "table" then id = info.spellID or info.actionID end
    end
    return Hunt.SpellFromId(id)
end

-- spell: from SpellFromId, or nil for none (the key only targets).
function Hunt.SetSpell(spell)
    Hunt.Char().spell = spell
    Changed()
end

function Hunt.SetLowest(on)
    Hunt.Char().lowest = on and true or false
    Changed()
end

function Hunt.SetPet(on)
    Hunt.Char().pet = on and true or false
    Changed()
end

-- What /cast gets: "Shadow Word: Pain(Rank 1)".
function Hunt.CastText()
    local char = Hunt.Char()
    local spell = char.spell
    if type(spell) ~= "table" or type(spell.name) ~= "string" or spell.name == "" then return end
    if char.lowest and type(spell.rank) == "string" then
        return spell.name .. "(" .. (spell.rank:gsub("%d+", "1", 1)) .. ")"
    end
    return spell.name
end

---------------------------------------------------------------------------
-- Names in your macros (to import them)
---------------------------------------------------------------------------

local TARGET_COMMANDS = { ["/tar"] = true, ["/target"] = true, ["/targetexact"] = true }
local UNITS = {
    [""] = true, player = true, focus = true, mouseover = true, none = true, vehicle = true,
    softenemy = true, softfriend = true, softinteract = true, anyenemy = true, anyfriend = true,
    anyinteract = true, npc = true,
}

-- "party1target", "pet", "mouseover"...: a unit, not an NPC's name.
local function IsUnitToken(text)
    local lower = strlower(text)
    if lower:find("[^%a%d]") then return false end
    local base, before = lower, nil
    repeat
        before = base
        base = base:gsub("target$", ""):gsub("pet$", "")
    until base == before
    return UNITS[base] == true or base:find("^party%d$") ~= nil or base:find("^raid%d+$") ~= nil
        or base:find("^arena%d$") ~= nil or base:find("^boss%d$") ~= nil or base:find("^nameplate%d+$") ~= nil
end

-- The names a macro targets with /tar, /target or /targetexact.
function Hunt.NamesInMacro(body)
    local names, seen = {}, {}
    for line in tostring(body or ""):gmatch("[^\r\n]+") do
        local command, rest = line:match("^%s*(/%S+)%s+(.-)%s*$")
        if command and TARGET_COMMANDS[strlower(command)] then
            for clause in (rest .. ";"):gmatch("([^;]*);") do
                local name = Util.CleanName((clause:gsub("%b[]", "")))
                if name and not name:find("^@") and not IsUnitToken(name) and not seen[strlower(name)] then
                    seen[strlower(name)] = true
                    names[#names + 1] = name
                end
            end
        end
    end
    return names
end

-- Your macros (general, then this character's) that target NPCs:
-- { { name, icon, names }, ... }
function Hunt.MacrosWithTargets()
    local out = {}
    if not GetNumMacros or not GetMacroInfo then return out end
    local numGeneral, numCharacter = GetNumMacros()
    local first = MAX_ACCOUNT_MACROS or 120
    local indexes = {}
    for index = 1, numGeneral or 0 do indexes[#indexes + 1] = index end
    for index = first + 1, first + (numCharacter or 0) do indexes[#indexes + 1] = index end
    for _, index in ipairs(indexes) do
        local name, icon, body = GetMacroInfo(index)
        if name then
            local names = Hunt.NamesInMacro(body)
            if #names > 0 then out[#out + 1] = { name = name, icon = icon, names = names } end
        end
    end
    return out
end

---------------------------------------------------------------------------
-- Units
---------------------------------------------------------------------------

local function Flag(fn, unit)
    if not fn then return false end
    local ok, value = pcall(fn, unit)
    return ok and Util.Readable(value) and value and true or false
end

-- The name of an NPC unit (nil for players and missing units).
local function UnitNpcName(unit)
    if not Flag(UnitExists, unit) or Flag(UnitIsPlayer, unit) then return end
    local ok, name = pcall(UnitName, unit)
    if not ok then return end
    return Util.CleanName(name)
end
Hunt.UnitNpcName = UnitNpcName

-- The NPC ID in a unit's GUID ("Creature-0-...-<id>-...").
function Hunt.NpcIdFromUnit(unit)
    local ok, guid = pcall(UnitGUID, unit)
    if not ok or not Util.Readable(guid) or type(guid) ~= "string" then return end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
end

-- "dead", "taken" (someone else tagged it), "yours" (you or your group:
-- fighting and not taken), "free".
function Hunt.TagState(unit)
    if Flag(UnitIsDead, unit) then return "dead" end
    if Flag(UnitIsTapDenied, unit) then return "taken" end
    if Flag(UnitAffectingCombat, unit) then return "yours" end
    return "free"
end

-- The listed NPC to show: your target if it is one, else one on a
-- nameplate (alive first). entry, unit.
function Hunt.ShownUnit()
    local name = UnitNpcName("target")
    local entry = name and byName[strlower(name)]
    if entry and entry.on then return entry, "target" end
    local corpse, corpseUnit
    for i = 1, 40 do
        local unit = "nameplate" .. i
        name = UnitNpcName(unit)
        entry = name and byName[strlower(name)]
        if entry and entry.on then
            if not Flag(UnitIsDead, unit) then return entry, unit end
            corpse, corpseUnit = corpse or entry, corpseUnit or unit
        end
    end
    return corpse, corpseUnit
end

---------------------------------------------------------------------------
-- The macro
---------------------------------------------------------------------------

local trigger, button          -- the key's button, the one on screen
local macroText                -- what both run now
local inMacro = {}             -- lower-case name -> true: in the macro now
local status = { kept = 0, dropped = 0, active = 0, length = 0 }
local lastSeenAt = {}          -- lower-case name -> GetTime() of the last sighting
local dirty = false
local events = CreateFrame("Frame")

-- How far an entry is: 0 seen just now, 1 a known spot nearby, 2 no known
-- position, 3 known but far; then the distance.
local function Rank(entry, here)
    local seen = lastSeenAt[strlower(entry.name)]
    if seen and GetTime() - seen < RECENT then return 0, 0 end
    local finder = ns.NpcFinder
    if not entry.id or not (finder and finder.NpcDistance) then return 2, FAR end
    local ok, distance, known = pcall(finder.NpcDistance, entry.id, here)
    if not ok or not known then return 2, FAR end
    return distance <= NEAR and 1 or 3, distance
end

-- The macro text (nil when no NPC is on), and the active entries with
-- .kept set on those it holds.
function Hunt.BuildMacro()
    local active = {}
    for index, entry in ipairs(Data().list) do
        if entry.on then active[#active + 1] = { entry = entry, index = index } end
    end
    if #active == 0 then return nil, active end

    local head = "/cleartarget"
    local tail = {}
    local cast = Hunt.CastText()
    if cast then tail[#tail + 1] = "/cast [harm,nodead] " .. cast end
    if Hunt.Char().pet then tail[#tail + 1] = "/petattack [harm,nodead]" end
    tail[#tail + 1] = "/targetlasttarget [dead][noexists]"
    tail = table.concat(tail, "\n")

    -- Each name line costs its length and a line break.
    local budget = MAX_TEXT - #head - 1 - #tail
    local total = 0
    for _, item in ipairs(active) do
        item.line = "/targetexact " .. item.entry.name
        total = total + #item.line + 1
    end
    if total <= budget then
        for _, item in ipairs(active) do item.kept = true end
    else
        local here = ns.NpcFinder and ns.NpcFinder.Here and ns.NpcFinder.Here()
        local order = {}
        for i, item in ipairs(active) do
            item.rank, item.distance = Rank(item.entry, here or {})
            order[i] = item
        end
        table.sort(order, function(a, b)
            if a.rank ~= b.rank then return a.rank < b.rank end
            if a.distance ~= b.distance then return a.distance < b.distance end
            return a.index < b.index
        end)
        for _, item in ipairs(order) do
            local cost = #item.line + 1
            if cost <= budget then
                item.kept = true
                budget = budget - cost
            end
        end
    end

    local lines = { head }
    for i = #active, 1, -1 do -- the least important first: the last name found wins
        if active[i].kept then lines[#lines + 1] = active[i].line end
    end
    lines[#lines + 1] = tail
    return table.concat(lines, "\n"), active
end

local UpdateButtonShown, RefreshButton

function Hunt.Rebuild()
    if not trigger or not ns.db then return end
    if InCombatLockdown() then
        if not dirty and ns:IsEnabled(KEY) then ns:Print(L.HUNT_COMBAT_LATER) end
        dirty = true
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    dirty = false
    local text, active = nil, {}
    if ns:IsEnabled(KEY) then text, active = Hunt.BuildMacro() end
    if text ~= macroText then
        macroText = text
        trigger:SetAttribute("macrotext", text)
        button:SetAttribute("macrotext", text)
    end
    wipe(inMacro)
    local kept = 0
    for _, item in ipairs(active) do
        if item.kept then
            kept = kept + 1
            inMacro[strlower(item.entry.name)] = true
        end
    end
    status.kept, status.dropped, status.active = kept, #active - kept, #active
    status.length = text and #text or 0
    UpdateButtonShown()
    RefreshButton()
    ns:Fire("HUNT_MACRO")
end

-- kept, dropped, active, length, and the macro text.
function Hunt.Status()
    return status.kept, status.dropped, status.active, status.length, macroText
end

function Hunt.InMacro(name)
    return type(name) == "string" and inMacro[strlower(name)] == true
end

---------------------------------------------------------------------------
-- Key binding
---------------------------------------------------------------------------

function Hunt.GetKey()
    return GetBindingKey and GetBindingKey(BINDING)
end

-- abbreviated: "s-F" instead of "Shift-F" (for the button's corner).
function Hunt.KeyText(key, abbreviated)
    if not key then return end
    if GetBindingText then
        local ok, text = pcall(GetBindingText, key, abbreviated and true or nil)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return key
end

local function ClearKeys()
    for _ = 1, 10 do
        local key = GetBindingKey(BINDING)
        if not key then break end
        SetBinding(key)
    end
end

function Hunt.SetKey(key)
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    local old = GetBindingAction(key)
    ClearKeys()
    if not SetBindingClick(key, TRIGGER_NAME, "LeftButton") then
        ns:Error(L.WHEEL_ERROR_KEY:format(key))
        return false
    end
    SaveBindings(GetCurrentBindingSet())
    if old and old ~= "" and old ~= BINDING then
        ns:Print(L.HUNT_KEY_REPLACED:format(Hunt.KeyText(key), _G["BINDING_NAME_" .. old] or old))
    else
        ns:Print(L.HUNT_KEY_SET:format(Hunt.KeyText(key)))
    end
    ns:Fire("HUNT_CHANGED")
    return true
end

function Hunt.ClearKey()
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    if not Hunt.GetKey() then return false end
    ClearKeys()
    SaveBindings(GetCurrentBindingSet())
    ns:Print(L.HUNT_KEY_CLEARED)
    ns:Fire("HUNT_CHANGED")
    return true
end

-- Names in Blizzard's Key Bindings window (Bindings.xml).
local function BindingNames()
    _G.BINDING_HEADER_BUDGETFOREVER = L.ADDON_TITLE
    _G["BINDING_NAME_" .. BINDING] = L.HUNT_BINDING
end

---------------------------------------------------------------------------
-- Pressing the key or the button
---------------------------------------------------------------------------

local lastPress, lastEmpty = 0, 0

-- The key reaches its button twice (down and up): both count as the press.
local function OnPress(_, mouseButton)
    if mouseButton == "RightButton" or not ns:IsEnabled(KEY) then return end
    lastPress = GetTime()
    if not macroText and GetTime() - lastEmpty > 5 then
        lastEmpty = GetTime()
        ns:Print(L.HUNT_EMPTY)
    end
end

---------------------------------------------------------------------------
-- Seeing a listed NPC: last seen, alert
---------------------------------------------------------------------------

local alertedAt = {}

local function Alert(entry, unit)
    local taken = Hunt.TagState(unit) == "taken"
    local text = (taken and L.HUNT_ALERT_TAKEN or L.HUNT_ALERT):format(entry.name)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
        RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
    end
    local key = Hunt.GetKey()
    ns:Print(text .. " " .. (key and L.HUNT_PRESS:format(Hunt.KeyText(key)) or L.HUNT_PRESS_NO_KEY))
    if ns:GetOption(KEY, "sound") and SOUNDKIT and SOUNDKIT.RAID_WARNING then
        PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    end
    if ns:GetOption(KEY, "flash") and FlashClientIcon then FlashClientIcon() end
    -- Where it can be, on the world map (QuestieDB's spots, nearest first).
    local finder = ns.NpcFinder
    if entry.id and finder and finder.MarkNpc then pcall(finder.MarkNpc, entry.id) end
end

-- how: "plate", "mouse" or "target".
local function Sighting(unit, how)
    local name = UnitNpcName(unit)
    local entry = name and byName[strlower(name)]
    if not entry or not entry.on then return end
    local key = strlower(entry.name)
    local now = GetTime()
    lastSeenAt[key] = now
    entry.seen = time()
    entry.id = entry.id or Hunt.NpcIdFromUnit(unit)
    -- Left out of a full macro: in it now, it is right here.
    if not inMacro[key] and not InCombatLockdown() then Hunt.Rebuild() end
    ns:Fire("HUNT_SEEN", entry)
    if Flag(UnitIsDead, unit) then return end
    local alerted = alertedAt[key]
    if alerted and now - alerted < ALERT_AGAIN then return end
    alertedAt[key] = now
    -- Your own key found it: you are already on it.
    if how == "target" and now - lastPress < OWN_PRESS then return end
    Alert(entry, unit)
end

---------------------------------------------------------------------------
-- Secure buttons
---------------------------------------------------------------------------

local STATE_COLORS = {
    free = { 1, 1, 1 },
    yours = UI.GREEN,
    taken = { 0.6, 0.6, 0.6 },
    dead = UI.RED,
}

local function OpenListAction()
    if Hunt.OpenList then Hunt.OpenList() end
end

local function SavePosition()
    local point, _, relativePoint, x, y = button:GetPoint(1)
    if point then Data().button = { point, relativePoint, x, y } end
end

local function RestorePosition()
    if InCombatLockdown() then return end
    button:ClearAllPoints()
    local saved = Data().button
    if type(saved) == "table" and type(saved[1]) == "string" then
        button:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        button:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 230)
    end
end

function Hunt.ResetButton()
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    Data().button = nil
    RestorePosition()
end

local function ButtonTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L.HUNT_TITLE, 1, 0.82, 0)
    local entry, unit = Hunt.ShownUnit()
    if entry then
        local state = Hunt.TagState(unit)
        local color = STATE_COLORS[state]
        GameTooltip:AddLine(entry.name .. ": " .. L["HUNT_STATE_" .. strupper(state)], color[1], color[2], color[3])
    end
    GameTooltip:AddLine(L.HUNT_BUTTON_CLICK, 1, 1, 1)
    GameTooltip:AddLine(L.HUNT_BUTTON_RIGHT, 0.5, 0.8, 1)
    GameTooltip:AddLine(L.HUNT_BUTTON_MOVE, 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function CreateButtons()
    -- Clicked by the key binding. Shown (bindings click it) but invisible.
    trigger = CreateFrame("Button", TRIGGER_NAME, UIParent, "SecureActionButtonTemplate")
    trigger:SetSize(1, 1)
    trigger:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10, -10)
    trigger:EnableMouse(false)
    -- Down and up: the "use on key down" setting picks one, like action bars.
    trigger:RegisterForClicks("AnyDown", "AnyUp")
    trigger:SetAttribute("type", "macro")
    trigger:HookScript("OnClick", OnPress)

    -- The same macro on screen: name of the NPC around and its tag state.
    button = CreateFrame("Button", BUTTON_NAME, UIParent, "SecureActionButtonTemplate,BackdropTemplate")
    button:SetSize(180, 44)
    button:SetFrameStrata("MEDIUM")
    button:SetClampedToScreen(true)
    button:SetMovable(true)
    if button.SetDontSavePosition then button:SetDontSavePosition(true) end
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetAttribute("type", "macro")
    button:SetAttribute("type2", LIST_ACTION)
    button:SetAttribute("shift-type1", NO_ACTION)
    button:SetAttribute("useOnKeyDown", false)
    button[LIST_ACTION] = OpenListAction
    button[NO_ACTION] = function() end
    UI.ApplyFlat(button, { 0, 0, 0, 0.6 }, { 1, 0.82, 0, 0.35 })
    button:Hide()

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(36, 36)
    button.icon:SetPoint("LEFT", 4, 0)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.hotkey = button:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    button.hotkey:SetPoint("TOPRIGHT", button.icon, "TOPRIGHT", -1, -2)
    button.hotkey:SetJustifyH("RIGHT")

    button.name = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    button.name:SetPoint("TOPLEFT", button.icon, "TOPRIGHT", 8, -3)
    button.name:SetPoint("RIGHT", -6, 0)
    button.name:SetJustifyH("LEFT")
    button.name:SetWordWrap(false)

    button.state = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.state:SetPoint("BOTTOMLEFT", button.icon, "BOTTOMRIGHT", 8, 3)
    button.state:SetPoint("RIGHT", -6, 0)
    button.state:SetJustifyH("LEFT")
    button.state:SetWordWrap(false)

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 1, -1)
    highlight:SetPoint("BOTTOMRIGHT", -1, 1)
    highlight:SetColorTexture(1, 0.82, 0, 0.08)

    -- Shift-drag moves it (out of combat: it is a secure button).
    button:SetScript("OnDragStart", function(self)
        if not IsShiftKeyDown() or InCombatLockdown() then return end
        self.moving = true
        self:StartMoving()
    end)
    button:SetScript("OnDragStop", function(self)
        if not self.moving then return end
        self.moving = nil
        self:StopMovingOrSizing()
        if self.SetUserPlaced then self:SetUserPlaced(false) end
        SavePosition()
    end)
    button:SetScript("OnEnter", ButtonTooltip)
    button:SetScript("OnLeave", GameTooltip_Hide)
    button:HookScript("OnClick", OnPress)

    local elapsed = 0
    button:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.25 then return end
        elapsed = 0
        RefreshButton()
    end)
end

-- Shown with the option on and at least one NPC on. Out of combat only.
UpdateButtonShown = function()
    if not button or InCombatLockdown() then return end
    local wanted = ns:IsEnabled(KEY) and ns:GetOption(KEY, "showButton") and status.active > 0
    if wanted and not button:IsShown() then RestorePosition() end
    button:SetShown(wanted and true or false)
end

RefreshButton = function()
    if not button or not button:IsShown() then return end
    button.icon:SetTexture(Hunt.SpellIcon(Hunt.Char().spell))
    local key = Hunt.GetKey()
    button.hotkey:SetText(key and Hunt.KeyText(key, true) or "")
    local entry, unit = Hunt.ShownUnit()
    if entry then
        local state = Hunt.TagState(unit)
        local color = STATE_COLORS[state]
        button.name:SetText(entry.name)
        button.state:SetText(L["HUNT_STATE_" .. strupper(state)])
        button.state:SetTextColor(color[1], color[2], color[3])
    else
        button.name:SetText(L.HUNT_BUTTON_IDLE:format(status.active))
        button.state:SetText(L.HUNT_BUTTON_NOBODY)
        button.state:SetTextColor(unpack(UI.MUTED))
    end
end

---------------------------------------------------------------------------
-- Target and focus portraits: right-click to hunt the NPC
---------------------------------------------------------------------------

local MENU_TAGS = { "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS" }

local function AddMenuEntry(_, root, context)
    if not ns:IsEnabled(KEY) or not Util.ReadableTable(context) then return end
    local unit = context.unit
    if not Util.Readable(unit) or type(unit) ~= "string" or unit == "" then return end
    local name = UnitNpcName(unit)
    if not name then return end
    local id = Hunt.NpcIdFromUnit(unit)
    Util.MenuSection(root)
    root:CreateCheckbox(L.HUNT_MENU,
        function()
            local entry = Hunt.Find(name)
            return entry ~= nil and entry.on
        end,
        function()
            local entry = Hunt.Find(name)
            if entry and entry.on then
                Hunt.Remove(name)
                ns:Print(L.HUNT_REMOVED:format(name))
            else
                Hunt.Add(name, id)
                ns:Print(L.HUNT_ADDED:format(name))
            end
        end)
end

---------------------------------------------------------------------------
-- /hunt Name, /chasse Nom (also /bgt hunt)
---------------------------------------------------------------------------

function Hunt.Command(message)
    if not ns:IsEnabled(KEY) then
        ns:Print(L.HUNT_DISABLED)
        return
    end
    message = strtrim(message or "")
    if message == "" then
        if Hunt.OpenList then Hunt.OpenList() end
        return
    end
    local entry, new = Hunt.AddByName(message)
    if not entry then
        ns:Print(L.HUNT_USAGE)
        return
    end
    ns:Print((new and L.HUNT_ADDED or L.HUNT_ALREADY):format(entry.name))
end

SLASH_BUDGETFOREVERHUNT1 = "/hunt"
SLASH_BUDGETFOREVERHUNT2 = "/chasse"
SlashCmdList.BUDGETFOREVERHUNT = Hunt.Command

---------------------------------------------------------------------------
-- Enable / disable
---------------------------------------------------------------------------

local EVENTS = {
    "NAME_PLATE_UNIT_ADDED", "UPDATE_MOUSEOVER_UNIT", "PLAYER_TARGET_CHANGED",
    "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
    "SPELLS_CHANGED", "UPDATE_BINDINGS",
}

local queued = false
local function QueueRebuild()
    if queued then return end
    queued = true
    C_Timer.After(1, function()
        queued = false
        Hunt.Rebuild()
    end)
end

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_REGEN_ENABLED" then
        events:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if dirty then Hunt.Rebuild() end
        UpdateButtonShown()
    elseif not ns:IsEnabled(KEY) then
        return
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        Sighting(arg1, "plate")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        Sighting("mouseover", "mouse")
    elseif event == "PLAYER_TARGET_CHANGED" then
        Sighting("target", "target")
        RefreshButton()
    elseif event == "UPDATE_BINDINGS" then
        RefreshButton()
        ns:Fire("HUNT_CHANGED")
    else
        QueueRebuild() -- zone, spells: names nearby and the spell may change
    end
end)

-- Names that didn't all fit: the nearest ones change as you move.
local ticker
local function Tick()
    if status.dropped > 0 and not InCombatLockdown() then Hunt.Rebuild() end
end

local hooked = false

local function Enable()
    for _, event in ipairs(EVENTS) do events:RegisterEvent(event) end
    Index()
    Hunt.Rebuild()
    if not ticker then ticker = C_Timer.NewTicker(REFRESH, Tick) end
    -- Hooks cannot be removed: they check the setting each time.
    if hooked then return end
    hooked = true
    if Menu and Menu.ModifyMenu then
        for _, tag in ipairs(MENU_TAGS) do Menu.ModifyMenu(tag, AddMenuEntry) end
    end
end

local function Disable()
    events:UnregisterAllEvents()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    Hunt.Rebuild() -- empties the macro, hides the button (after combat if need be)
    if Hunt.CloseList then Hunt.CloseList() end
end

CreateButtons()
BindingNames()

ns:On("OPTION_CHANGED", function(key)
    if key ~= KEY then return end
    UpdateButtonShown()
    RefreshButton()
end)

ns:On("LANGUAGE_CHANGED", function()
    BindingNames()
    RefreshButton()
end)

ns:RegisterFeature({
    key = KEY,
    category = "actions",
    order = 20,
    title = "HUNT_TITLE",
    desc = "HUNT_DESC",
    tip = "HUNT_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "showButton", title = "HUNT_OPT_BUTTON", tip = "HUNT_OPT_BUTTON_TIP", default = true },
        { key = "sound", title = "HUNT_OPT_SOUND", tip = "HUNT_OPT_SOUND_TIP", default = true },
        { key = "flash", title = "HUNT_OPT_FLASH", tip = "HUNT_OPT_FLASH_TIP", default = true },
        { key = "edit", title = "HUNT_OPT_EDIT", tip = "HUNT_OPT_EDIT_TIP", action = function() OpenListAction() end },
        { key = "resetButton", title = "HUNT_OPT_RESET", tip = "HUNT_OPT_RESET_TIP", action = function() Hunt.ResetButton() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
