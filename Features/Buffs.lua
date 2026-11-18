local _, ns = ...
local L, Util = ns.L, ns.Util

-- Buff sequences: each sequence is a list of buffs (order, tick, rank) with
-- its own key and its own macro to drag onto an action bar. Each press casts
-- the next missing buff of the list on the next player who lacks it.
--
-- What the game allows (read in Blizzard_APIDocumentationGenerated and the
-- secure templates on the forever branch):
-- * casting needs a secure button and a key press; its attributes can only
--   change out of combat. The buttons stay empty and are filled in PreClick,
--   at the moment of the press, so the choice is always fresh. In combat the
--   keys do nothing.
-- * aura data is SecretWhenUnitAuraRestricted: when the game hides it, we
--   can't tell who lacks what, so nothing is cast (never cast blind).
-- * UnitInRange always returns secrets; C_Spell.IsSpellInRange does not.
-- * Forever gives spells its own IDs: ranks are read from the spellbook by
--   name, never hard-coded.
-- * an addon can't put its own action on a bar. Each sequence gets a
--   character macro "/click <its button> LeftButton 1" that the window puts
--   on the cursor (as GnomeSequencer does). "1" is the down flag of /click:
--   with useOnKeyDown on the buttons, key and macro both cast on key down.
-- * a macro on a bar is renamed and gets its new icon from here. The game
--   fires ACTIONBAR_SLOT_CHANGED inside that EditMacro call: left alone, the
--   bar button would update as addon code and keep fields marked as ours,
--   and hovering it in combat would then be refused (MacroCall below). It is
--   never deleted from here.
--
-- A buff already there, at any rank and whoever cast it, is never cast
-- again; the single and group versions count as the same buff.

local Buffs = {}
ns.Buffs = Buffs

local KEY = "buffs"
local TRIGGER_PREFIX = "BudgetForeverBuffKey"
local MAX_SEQUENCES = 8    -- one secure button and one Bindings.xml line each
local MACRO_NAME_BYTES = 16
local ACTION_SLOTS = 180
local SLOT_EVENT = "ACTIONBAR_SLOT_CHANGED"
local MACRO_BARS = {
    "MainActionBar", "MultiBarBottomLeft", "MultiBarBottomRight", "MultiBarRight",
    "MultiBarLeft", "MultiBar5", "MultiBar6", "MultiBar7",
}
local PENDING_TIME = 2.5   -- seconds a cast buff counts as there before its aura shows
local LEVEL_GAP = 10       -- a buff rank lands on targets up to 10 levels under it
local MAX_AURAS = 80
local MESSAGE_THROTTLE = 0.4
local DEFAULT_ICON = 134400

local BANK = Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player
local SPELL_ITEM = Enum and Enum.SpellBookItemType and Enum.SpellBookItemType.Spell

-- Buffs per class, in their default order.
--   name     English spell name (fallback); classic = a classic spell ID that
--            gives the name in the game's language when it exists
--   family   buffs that replace each other (single and group versions)
--   scope    "self", "group" (you, the group, pets) or "prayer" (group
--            version: only in a group, never on pets)
--   on       ticked by default in the first sequence
--   racial   hidden when not known (other races never get it)
local CLASS_BUFFS = {
    PRIEST = {
        { id = "fort", name = "Power Word: Fortitude", classic = 1243, family = "fort", scope = "group", on = true },
        { id = "prayerFort", name = "Prayer of Fortitude", classic = 21562, family = "fort", scope = "prayer" },
        { id = "spirit", name = "Divine Spirit", classic = 14752, family = "spirit", scope = "group", on = true },
        { id = "prayerSpirit", name = "Prayer of Spirit", classic = 27681, family = "spirit", scope = "prayer" },
        { id = "shadow", name = "Shadow Protection", classic = 976, family = "shadow", scope = "group" },
        { id = "prayerShadow", name = "Prayer of Shadow Protection", classic = 27683, family = "shadow", scope = "prayer" },
        { id = "innerFire", name = "Inner Fire", classic = 588, family = "innerFire", scope = "self", on = true },
        { id = "fearWard", name = "Fear Ward", classic = 6346, family = "fearWard", scope = "group" },
        { id = "shadowguard", name = "Shadowguard", classic = 18137, family = "shadowguard", scope = "self", on = true, racial = true },
        { id = "touch", name = "Touch of Weakness", classic = 2652, family = "touch", scope = "self", on = true, racial = true },
    },
}

local triggers = {}        -- [slot] = secure button
local events = CreateFrame("Frame")
local active = false
local spellbookDirty = true
local known = {}           -- [entry id] = { ranks ascending { spellID, rank, level } }
local localName = {}       -- [entry id] = name in the game's language
local pending = {}         -- ["guid:family"] = time until which the buff counts as there
local lastChoice
local lastMessage, lastMessageTime

---------------------------------------------------------------------------
-- Reading values the game may hide
---------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

local function Value(value, kind)
    if Util.Readable(value) and type(value) == kind then return value end
end

local function True(fn, ...)
    return Value(Call(fn, ...), "boolean") == true
end

local function AurasHidden()
    return C_Secrets ~= nil and True(C_Secrets.ShouldAurasBeSecret)
end

---------------------------------------------------------------------------
-- Class list and spellbook
---------------------------------------------------------------------------

local function PlayerClass()
    local _, class = UnitClass("player")
    return Value(class, "string")
end

function Buffs.ClassList()
    return CLASS_BUFFS[PlayerClass() or ""]
end

function Buffs.Supported()
    return Buffs.ClassList() ~= nil
end

local function RankNumber(text)
    return type(text) == "string" and tonumber(text:match("%d+")) or nil
end

-- Name the spellbook shows: from a classic ID when the game knows it,
-- otherwise the English name.
local function SpellbookName(def)
    if localName[def.id] then return localName[def.id] end
    local name = C_Spell and Value(Call(C_Spell.GetSpellName, def.classic), "string")
    localName[def.id] = (name and name ~= "") and name or def.name
    return localName[def.id]
end

-- Every known rank of the class buffs, read once after each spellbook change.
local function ScanSpellbook()
    spellbookDirty = false
    wipe(known)
    local list = Buffs.ClassList()
    if not list or not C_SpellBook or not BANK then return end

    local byName = {}
    for _, def in ipairs(list) do
        byName[SpellbookName(def)] = def
        byName[def.name] = def
    end

    for line = 1, Value(Call(C_SpellBook.GetNumSpellBookSkillLines), "number") or 0 do
        local info = Call(C_SpellBook.GetSpellBookSkillLineInfo, line)
        if Util.ReadableTable(info) and not Value(info.isGuild, "boolean") then
            local offset = Value(info.itemIndexOffset, "number") or 0
            local count = Value(info.numSpellBookItems, "number") or 0
            for slot = offset + 1, offset + count do
                local item = Call(C_SpellBook.GetSpellBookItemInfo, slot, BANK)
                local name = Util.ReadableTable(item) and Value(item.name, "string")
                local def = name and byName[name]
                if def and Value(item.itemType, "number") == SPELL_ITEM and not Value(item.isPassive, "boolean")
                    and not Value(item.isOffSpec, "boolean") then
                    local spellID = Value(item.spellID, "number") or Value(item.actionID, "number")
                    if spellID then
                        local sub = Value(item.subName, "string")
                        if (not sub or sub == "") and C_Spell then
                            sub = Value(Call(C_Spell.GetSpellSubtext, spellID), "string")
                        end
                        if (not sub or sub == "") and C_Spell and C_Spell.RequestLoadSpellData then
                            Call(C_Spell.RequestLoadSpellData, spellID)
                        end
                        localName[def.id] = name
                        known[def.id] = known[def.id] or {}
                        table.insert(known[def.id], {
                            spellID = spellID,
                            rank = RankNumber(sub),
                            level = Value(Call(C_SpellBook.GetSpellBookItemLevelLearned, slot, BANK), "number") or 0,
                        })
                    end
                end
            end
        end
    end

    -- Lowest rank first. A rank whose text is not loaded yet gets its place
    -- from the level it is learned at.
    for _, ranks in pairs(known) do
        table.sort(ranks, function(a, b)
            if a.rank and b.rank and a.rank ~= b.rank then return a.rank < b.rank end
            if a.level ~= b.level then return a.level < b.level end
            return a.spellID < b.spellID
        end)
        for index, rank in ipairs(ranks) do
            rank.rank = rank.rank or index
        end
    end
end

function Buffs.Ranks(id)
    if spellbookDirty then ScanSpellbook() end
    return known[id] or {}
end

---------------------------------------------------------------------------
-- Sequences, per character:
--   { seqs = { { slot, name, blank, order, on, rank } }, current }
-- slot = the secure button (1..8), kept for life so keys and macros stay
-- on the right sequence. blank: buffs start unticked (new sequences).
---------------------------------------------------------------------------

local function Store()
    ns.db.buffs = ns.db.buffs or {}
    local db = ns.db.buffs
    db.chars = db.chars or {}
    local key = Util.CharacterKey(db.chars)
    db.chars[key] = db.chars[key] or {}
    local store = db.chars[key]
    if type(store.seqs) ~= "table" or #store.seqs == 0 then
        -- First use, or settings saved before sequences existed.
        store.seqs = { {
            slot = 1,
            name = L.BUFFS_SEQ_FIRST,
            order = store.order or {},
            on = store.on or {},
            rank = store.rank or {},
        } }
        store.order, store.on, store.rank = nil, nil, nil
        store.current = 1
    end
    for _, seq in ipairs(store.seqs) do
        seq.order = seq.order or {}
        seq.on = seq.on or {}
        seq.rank = seq.rank or {}
    end
    if type(store.current) ~= "number" or not store.seqs[store.current] then store.current = 1 end
    return store
end

function Buffs.Sequences()
    return Store().seqs
end

function Buffs.Current()
    local store = Store()
    return store.seqs[store.current], store.current
end

function Buffs.Select(index)
    local store = Store()
    if store.seqs[index] then
        store.current = index
        ns:Fire("BUFFS_CHANGED")
    end
end

function Buffs.BySlot(slot)
    for _, seq in ipairs(Store().seqs) do
        if seq.slot == slot then return seq end
    end
end

function Buffs.CanCreate()
    return #Store().seqs < MAX_SEQUENCES
end

function Buffs.NewSequence()
    local store = Store()
    if #store.seqs >= MAX_SEQUENCES then return end
    local used = {}
    for _, seq in ipairs(store.seqs) do used[seq.slot] = true end
    local slot = 1
    while used[slot] do slot = slot + 1 end
    local seq = { slot = slot, name = L.BUFFS_SEQ_NEW:format(#store.seqs + 1), blank = true,
        order = {}, on = {}, rank = {} }
    table.insert(store.seqs, seq)
    store.current = #store.seqs
    ns:Fire("BUFFS_CHANGED")
    return seq
end

---------------------------------------------------------------------------
-- Buffs of a sequence
---------------------------------------------------------------------------

-- The class list in the sequence's order, with its settings and the known
-- ranks. Racial buffs of other races are left out.
function Buffs.Entries(seq)
    local list = Buffs.ClassList()
    seq = seq or Buffs.Current()
    if not list or not seq then return {} end
    if spellbookDirty then ScanSpellbook() end

    local byID, seen, ordered = {}, {}, {}
    for _, def in ipairs(list) do byID[def.id] = def end
    for _, id in ipairs(seq.order) do
        if byID[id] and not seen[id] then
            seen[id] = true
            table.insert(ordered, byID[id])
        end
    end
    for _, def in ipairs(list) do
        if not seen[def.id] then table.insert(ordered, def) end
    end

    local entries = {}
    for _, def in ipairs(ordered) do
        local ranks = known[def.id] or {}
        if not def.racial or #ranks > 0 then
            local on = seq.on[def.id]
            if on == nil then on = not seq.blank and def.on == true end
            local top = ranks[#ranks]
            table.insert(entries, {
                def = def,
                id = def.id,
                name = SpellbookName(def),
                family = def.family,
                scope = def.scope,
                on = on,
                want = tonumber(seq.rank[def.id]) or 0,
                ranks = ranks,
                icon = top and C_Spell and Call(C_Spell.GetSpellTexture, top.spellID)
                    or (C_Spell and Call(C_Spell.GetSpellTexture, def.classic)) or DEFAULT_ICON,
            })
        end
    end
    return entries
end

function Buffs.SetOn(seq, id, on)
    seq.on[id] = on and true or false
    ns:Fire("BUFFS_CHANGED")
end

function Buffs.SetRank(seq, id, rank)
    seq.rank[id] = (rank and rank > 0) and rank or nil
    ns:Fire("BUFFS_CHANGED")
end

function Buffs.Move(seq, id, delta)
    local order = {}
    for _, entry in ipairs(Buffs.Entries(seq)) do table.insert(order, entry.id) end
    for index, value in ipairs(order) do
        if value == id then
            local target = index + delta
            if target < 1 or target > #order then return end
            order[index], order[target] = order[target], order[index]
            break
        end
    end
    -- Hidden racial buffs keep their place at the end.
    local kept = {}
    for _, value in ipairs(order) do kept[value] = true end
    for _, value in ipairs(seq.order) do
        if not kept[value] then table.insert(order, value) end
    end
    seq.order = order
    ns:Fire("BUFFS_CHANGED")
end

-- Icon of the sequence: the one chosen in the window, else its first
-- ticked buff you know.
function Buffs.Icon(seq)
    if seq.icon then return seq.icon end
    for _, entry in ipairs(Buffs.Entries(seq)) do
        if entry.on and #entry.ranks > 0 then return entry.icon end
    end
    return DEFAULT_ICON
end

---------------------------------------------------------------------------
-- Who needs what
---------------------------------------------------------------------------

-- You first, then the group, then the pets. Each unit once.
local function Units()
    local units, guids = {}, {}
    local function Add(unit, pet)
        if not True(UnitExists, unit) then return end
        local guid = Value(Call(UnitGUID, unit), "string")
        if guid then
            if guids[guid] then return end
            guids[guid] = true
        end
        table.insert(units, { unit = unit, guid = guid or unit, pet = pet })
    end
    Add("player", false)
    if True(IsInRaid) then
        local count = Value(Call(GetNumGroupMembers), "number") or 0
        for i = 1, count do Add("raid" .. i, false) end
        Add("pet", true)
        for i = 1, count do Add("raidpet" .. i, true) end
    else
        if True(IsInGroup) then
            for i = 1, 4 do Add("party" .. i, false) end
        end
        Add("pet", true)
        if True(IsInGroup) then
            for i = 1, 4 do Add("partypet" .. i, true) end
        end
    end
    return units
end

local function Eligible(unit)
    if True(UnitIsDeadOrGhost, unit) then return false end
    if True(UnitIsPlayer, unit) and not True(UnitIsConnected, unit) then return false end
    if not True(UnitIsVisible, unit) then return false end
    if not True(UnitCanAssist, "player", unit) then return false end
    if True(UnitIsCharmed, unit) then return false end
    return true
end

-- Names of the unit's buffs, or false when the game hides them.
local function AuraNames(unit, cache)
    if cache[unit] ~= nil then return cache[unit] end
    local get = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    local names = {}
    if not get then names = false end
    for index = 1, MAX_AURAS do
        if not names then break end
        local ok, aura = pcall(get, unit, index, "HELPFUL")
        if not ok or (issecretvalue and issecretvalue(aura)) then
            names = false
        elseif aura == nil then
            break
        elseif not Util.ReadableTable(aura) or not Util.Readable(aura.name) then
            names = false
        else
            names[aura.name] = true
        end
    end
    cache[unit] = names
    return names
end

-- Every name the buffs of a family can show (single and group versions,
-- in the game's language and in English).
local familyNames = {}
local function FamilyNames(family)
    if familyNames[family] then return familyNames[family] end
    local names = {}
    for _, def in ipairs(Buffs.ClassList() or {}) do
        if def.family == family then
            names[SpellbookName(def)] = true
            names[def.name] = true
        end
    end
    familyNames[family] = names
    return names
end

local function HasFamily(auraNames, family)
    for name in pairs(FamilyNames(family)) do
        if auraNames[name] then return true end
    end
    return false
end

local function IsPending(guid, family, now)
    local untilTime = pending[guid .. ":" .. family]
    return untilTime ~= nil and untilTime > now
end

-- The rank to cast: the chosen one, or the highest known under it; lower
-- when the target is too low level for it.
local function PickRank(entry, unit)
    local ranks = entry.ranks
    if #ranks == 0 then return end
    local best
    for _, rank in ipairs(ranks) do
        if entry.want == 0 or rank.rank <= entry.want then best = rank end
    end
    best = best or ranks[1]
    if unit ~= "player" then
        local level = Value(Call(UnitLevel, unit), "number")
        if level and level > 0 then
            local fit
            for _, rank in ipairs(ranks) do
                if rank.rank <= best.rank and rank.level <= level + LEVEL_GAP then fit = rank end
            end
            best = fit or ranks[1]
        end
    end
    return best
end

local function InRange(spellID, unit)
    if unit == "player" then return true end
    local inRange = C_Spell and Value(Call(C_Spell.IsSpellInRange, spellID, unit), "boolean")
    return inRange ~= false -- nil: the game can't tell, let it try
end

-- False when a reagent or something else than mana is missing.
local function Usable(spellID)
    if not (C_Spell and C_Spell.IsSpellUsable) then return true end
    local usable, noMana = Call(C_Spell.IsSpellUsable, spellID)
    if Value(usable, "boolean") == false and Value(noMana, "boolean") ~= true then return false end
    return true
end

local function OnCooldown(spellID)
    local info = C_Spell and Call(C_Spell.GetSpellCooldown, spellID)
    if not Util.ReadableTable(info) then return false end
    local start, duration = Value(info.startTime, "number"), Value(info.duration, "number")
    return start ~= nil and duration ~= nil and start > 0 and duration > 1.5
end

-- The next buff of a sequence: { entry, unit, guid, rank } or nil and why
-- ("off", "combat", "class", "gone", "none", "hidden", "range", "done").
function Buffs.Next(seq)
    if not ns:IsEnabled(KEY) then return nil, "off" end
    if InCombatLockdown() then return nil, "combat" end
    if not Buffs.Supported() then return nil, "class" end
    if not seq then return nil, "gone" end
    if AurasHidden() then return nil, "hidden" end

    local now = GetTime()
    local cache, units = {}, nil
    local any, far, hidden = false, 0, false
    local inGroup = True(IsInGroup)
    for _, entry in ipairs(Buffs.Entries(seq)) do
        local top = entry.ranks[#entry.ranks]
        if entry.on and top then
            any = true
            if Usable(top.spellID) and not OnCooldown(top.spellID) and (entry.scope ~= "prayer" or inGroup) then
                units = units or Units()
                for _, target in ipairs(units) do
                    local allowed = (entry.scope == "self" and target.unit == "player")
                        or (entry.scope == "group")
                        or (entry.scope == "prayer" and not target.pet)
                    if allowed and Eligible(target.unit) then
                        local names = AuraNames(target.unit, cache)
                        if names == false then
                            hidden = true
                        elseif not HasFamily(names, entry.family) and not IsPending(target.guid, entry.family, now) then
                            local rank = PickRank(entry, target.unit)
                            if rank and InRange(rank.spellID, target.unit) then
                                return { entry = entry, unit = target.unit, guid = target.guid, rank = rank }
                            end
                            far = far + 1
                        end
                    end
                end
            end
        end
    end
    if not any then return nil, "none" end
    if hidden then return nil, "hidden" end
    if far > 0 then return nil, "range", far end
    return nil, "done"
end

local REASON = {
    off = "BUFFS_OFF",
    combat = "BUFFS_COMBAT",
    class = "BUFFS_CLASS",
    gone = "BUFFS_SEQ_GONE",
    none = "BUFFS_NONE",
    hidden = "BUFFS_HIDDEN",
    range = "BUFFS_RANGE",
    done = "BUFFS_DONE",
}

function Buffs.ReasonText(reason, count)
    local text = L[REASON[reason] or "BUFFS_DONE"]
    if reason == "range" then text = text:format(count or 0) end
    return text
end

local function TargetName(unit)
    if unit == "player" then return L.BUFFS_YOU end
    return Util.UnitFullName and Util.UnitFullName(unit) or Value(Call(UnitName, unit), "string") or unit
end

function Buffs.RankText(rank)
    return L.BUFFS_RANK:format(rank.rank)
end

-- One line for the window: what the next press does.
function Buffs.Preview(seq)
    local choice, reason, count = Buffs.Next(seq or Buffs.Current())
    if not choice then return Buffs.ReasonText(reason, count), false end
    return L.BUFFS_NEXT:format(("|T%s:16:16:0:0:64:64:5:59:5:59|t"):format(tostring(choice.entry.icon)),
        choice.entry.name, Buffs.RankText(choice.rank), TargetName(choice.unit)), true
end

---------------------------------------------------------------------------
-- Keys: one secure button per sequence slot, filled at the moment of the
-- press. useOnKeyDown is on: the key and the macro ("/click ... 1") cast on
-- key down; the key up does nothing.
---------------------------------------------------------------------------

local function TriggerName(slot)
    return slot == 1 and TRIGGER_PREFIX or (TRIGGER_PREFIX .. slot)
end

local function Binding(slot)
    return "CLICK " .. TriggerName(slot) .. ":LeftButton"
end

local function Message(text)
    local now = GetTime()
    if text == lastMessage and lastMessageTime and now - lastMessageTime < MESSAGE_THROTTLE then return end
    lastMessage, lastMessageTime = text, now
    UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
end

local function Empty(button)
    if InCombatLockdown() then return end
    button:SetAttribute("type", nil)
    button:SetAttribute("spell", nil)
    button:SetAttribute("unit", nil)
end

local function PreClick(button, _, down)
    if not down then
        Empty(button)
        return
    end
    if InCombatLockdown() then
        Message(L.BUFFS_COMBAT)
        return
    end
    Empty(button)
    local choice, reason, count = Buffs.Next(Buffs.BySlot(button.slot))
    if choice then
        button:SetAttribute("type", "spell")
        button:SetAttribute("spell", choice.rank.spellID)
        button:SetAttribute("unit", choice.unit)
        choice.time = GetTime()
        lastChoice = choice
    else
        Message(Buffs.ReasonText(reason, count))
    end
end

local function CreateTriggers()
    for slot = 1, MAX_SEQUENCES do
        if not triggers[slot] then
            -- Clicked by the key binding and the macro. Shown but invisible.
            local trigger = CreateFrame("Button", TriggerName(slot), UIParent, "SecureActionButtonTemplate")
            trigger.slot = slot
            trigger:SetSize(1, 1)
            trigger:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10, -40 - slot)
            trigger:EnableMouse(false)
            trigger:RegisterForClicks("AnyDown", "AnyUp")
            trigger:SetAttribute("useOnKeyDown", true)
            trigger:SetScript("PreClick", PreClick)
            trigger:SetScript("PostClick", Empty)
            triggers[slot] = trigger
        end
    end
end

---------------------------------------------------------------------------
-- Key bindings (a single key, no modifier)
---------------------------------------------------------------------------

function Buffs.GetKey(seq)
    return seq and GetBindingKey(Binding(seq.slot)) or nil
end

function Buffs.KeyText(key)
    if not key then return end
    if GetBindingText then
        local ok, text = pcall(GetBindingText, key)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return key
end

local function ClearKeys(slot)
    for _ = 1, 10 do
        local key = GetBindingKey(Binding(slot))
        if not key then break end
        SetBinding(key)
    end
end

function Buffs.SetKey(seq, key)
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    local binding = Binding(seq.slot)
    local old = GetBindingAction(key)
    ClearKeys(seq.slot)
    if not SetBindingClick(key, TriggerName(seq.slot), "LeftButton") then
        ns:Error(L.WHEEL_ERROR_KEY:format(key))
        return false
    end
    SaveBindings(GetCurrentBindingSet())
    if old and old ~= "" and old ~= binding then
        ns:Print(L.BUFFS_KEY_REPLACED:format(seq.name, Buffs.KeyText(key), _G["BINDING_NAME_" .. old] or old))
    else
        ns:Print(L.BUFFS_KEY_SET:format(seq.name, Buffs.KeyText(key)))
    end
    ns:Fire("BUFFS_CHANGED")
    return true
end

function Buffs.ClearKey(seq)
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    if not Buffs.GetKey(seq) then return false end
    ClearKeys(seq.slot)
    SaveBindings(GetCurrentBindingSet())
    ns:Print(L.BUFFS_KEY_CLEARED:format(seq.name))
    ns:Fire("BUFFS_CHANGED")
    return true
end

-- Names in Blizzard's Key Bindings window: the sequence's name once known.
local function BindingNames()
    _G.BINDING_HEADER_BUDGETFOREVER = L.ADDON_TITLE
    local names = {}
    if ns.db and Buffs.Supported() then
        for _, seq in ipairs(Store().seqs) do names[seq.slot] = seq.name end
    end
    for slot = 1, MAX_SEQUENCES do
        _G["BINDING_NAME_" .. Binding(slot)] = names[slot] and L.BUFFS_BINDING_SEQ:format(names[slot])
            or L.BUFFS_BINDING_SLOT:format(slot)
    end
end

---------------------------------------------------------------------------
-- Macros to drag onto action bars
---------------------------------------------------------------------------

local MACRO_CONSTS = Constants and Constants.MacroConsts or {}
local ACCOUNT_MACROS = MACRO_CONSTS.MAX_ACCOUNT_MACROS or MAX_ACCOUNT_MACROS or 120
local CHARACTER_MACROS = MACRO_CONSTS.MAX_CHARACTER_MACROS or MAX_CHARACTER_MACROS or 30

local function MacroBody(slot)
    return "/click " .. TriggerName(slot) .. " LeftButton 1"
end

-- Index of the sequence's macro (character macros), or nil.
function Buffs.FindMacro(seq)
    local marker = "/click " .. TriggerName(seq.slot) .. " LeftButton"
    local first = ACCOUNT_MACROS + 1
    local last = ACCOUNT_MACROS + CHARACTER_MACROS
    for index = first, last do
        local name, _, body = Call(GetMacroInfo, index)
        if Value(name, "string") and Value(body, "string") and body:find(marker, 1, true) then
            return index
        end
    end
end

-- True when the macro sits in one of the action bar slots.
local function OnBars(index)
    for slot = 1, ACTION_SLOTS do
        local kind, id = Call(GetActionInfo, slot)
        if Value(kind, "string") == "macro" and Value(id, "number") == index then return true end
    end
    return false
end

-- A macro name is 16 bytes at most; never cut a letter in two.
local function MacroName(text)
    local out = ""
    for char in tostring(text):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if #out + #char > MACRO_NAME_BYTES then break end
        out = out .. char
    end
    return out ~= "" and out or "Buffs"
end

-- New icon and name on the bar buttons that hold a macro. Only the button's
-- texture and text are touched: no field of Blizzard's button is written.
local function RedrawMacroButtons()
    for _, barName in ipairs(MACRO_BARS) do
        local bar = _G[barName]
        local buttons = type(bar) == "table" and bar.actionButtons
        for _, button in ipairs(type(buttons) == "table" and buttons or {}) do
            local action = button.action
            if Value(Call(GetActionInfo, action), "string") == "macro" then
                local texture = Call(C_ActionBar.GetActionTexture, action)
                if button.icon and Util.Readable(texture) then
                    button.icon:SetTexture(texture)
                end
                if button.Name then
                    button.Name:SetText(Value(Call(C_ActionBar.GetActionText, action), "string") or "")
                end
            end
        end
    end
end

--[[
Creating, editing or deleting a macro fires ACTIONBAR_SLOT_CHANGED while our
code is still running. Blizzard's bar buttons would then update as addon code
and keep fields marked as ours (button.action first). Each hover in combat
reads them, then redoes the bar's SetShown, which is refused:
ADDON_ACTION_BLOCKED on MultiBarLeftButton1:SetShown(). So the buttons don't
hear that one event, and the macro's new look is drawn here instead. Every
caller has already checked that we are out of combat.
]]
local function MacroCall(fn, ...)
    local frame = ActionBarButtonEventsFrame
    local muted = frame and True(frame.IsEventRegistered, frame, SLOT_EVENT)
    if muted then Call(frame.UnregisterEvent, frame, SLOT_EVENT) end
    local result = Call(fn, ...)
    if muted then Call(frame.RegisterEvent, frame, SLOT_EVENT) end
    RedrawMacroButtons()
    return result
end

-- Creates the macro if needed and puts it on the cursor.
function Buffs.PickupMacro(seq)
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    local index = Buffs.FindMacro(seq)
    if not index then
        local _, perCharacter = Call(GetNumMacros)
        if (Value(perCharacter, "number") or 0) >= CHARACTER_MACROS then
            ns:Error(L.BUFFS_MACRO_FULL)
            return false
        end
        index = MacroCall(CreateMacro, MacroName(seq.name), Buffs.Icon(seq), MacroBody(seq.slot), true)
        index = Value(index, "number")
        if not index then
            ns:Error(L.BUFFS_MACRO_FAILED)
            return false
        end
    end
    ClearCursor()
    Call(PickupMacro, index)
    return true
end

-- Changes the sequence's macro (name and icon), on the bars too.
local function EditOwnMacro(seq)
    local index = Buffs.FindMacro(seq)
    if not index then return end
    local _, _, body = Call(GetMacroInfo, index)
    MacroCall(EditMacro, index, MacroName(seq.name), Buffs.Icon(seq), body)
end

-- Chosen icon: the window and the macro (on the bars too).
function Buffs.SetIcon(seq, icon)
    if icon == nil or icon == seq.icon then return end
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    seq.icon = icon
    EditOwnMacro(seq)
    ns:Fire("BUFFS_CHANGED")
end

-- New name: the window, the key bindings and the macro (on the bars too).
function Buffs.Rename(seq, name)
    name = strtrim(tostring(name or ""))
    if name == "" or name == seq.name then return end
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    seq.name = name
    EditOwnMacro(seq)
    BindingNames()
    ns:Fire("BUFFS_CHANGED")
end

function Buffs.Delete(seq)
    local store = Store()
    if #store.seqs <= 1 then return end
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    if Buffs.GetKey(seq) then
        ClearKeys(seq.slot)
        SaveBindings(GetCurrentBindingSet())
    end
    local index = Buffs.FindMacro(seq)
    if index then
        if OnBars(index) then
            ns:Print(L.BUFFS_MACRO_LEFT)
        else
            MacroCall(DeleteMacro, index)
        end
    end
    for i, value in ipairs(store.seqs) do
        if value == seq then
            table.remove(store.seqs, i)
            break
        end
    end
    store.current = math.min(store.current, #store.seqs)
    ns:Print(L.BUFFS_SEQ_DELETED:format(seq.name))
    BindingNames()
    ns:Fire("BUFFS_CHANGED")
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function OnEvent(_, event, unit, _, spellID)
    if event == "SPELLS_CHANGED" or event == "SPELL_TEXT_UPDATE" or event == "LEARNED_SPELL_IN_TAB" then
        spellbookDirty = true
        ns:Fire("BUFFS_CHANGED")
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- The buff counts as there until its aura shows, so a quick second
        -- press goes to the next one.
        spellID = Value(spellID, "number")
        local choice = lastChoice
        if choice and spellID == choice.rank.spellID and GetTime() - choice.time < 5 then
            local untilTime = GetTime() + PENDING_TIME
            pending[choice.guid .. ":" .. choice.entry.family] = untilTime
            if choice.entry.scope == "prayer" then
                for _, target in ipairs(Units()) do
                    if not target.pet then pending[target.guid .. ":" .. choice.entry.family] = untilTime end
                end
            end
            lastChoice = nil
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        for _, trigger in pairs(triggers) do Empty(trigger) end
    end
end

local function Enable()
    active = true
    CreateTriggers()
    familyNames = {}
    spellbookDirty = true
    BindingNames()
    events:RegisterEvent("SPELLS_CHANGED")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    pcall(events.RegisterEvent, events, "SPELL_TEXT_UPDATE")
    pcall(events.RegisterEvent, events, "LEARNED_SPELL_IN_TAB")
    events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    events:SetScript("OnEvent", OnEvent)
end

local function Disable()
    active = false
    events:UnregisterAllEvents()
    for _, trigger in pairs(triggers) do Empty(trigger) end
end

function Buffs.IsActive()
    return active
end

function Buffs.OpenWindow()
    if ns.BuffsUI then ns.BuffsUI.Open() end
end

function Buffs.Command()
    Buffs.OpenWindow()
end

BindingNames()
ns:On("LANGUAGE_CHANGED", BindingNames)

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "actions",
    order = 50,
    title = "BUFFS_TITLE",
    desc = "BUFFS_DESC",
    tip = "BUFFS_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "configure", title = "BUFFS_OPT_EDIT", tip = "BUFFS_OPT_EDIT_TIP", action = function() Buffs.OpenWindow() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
