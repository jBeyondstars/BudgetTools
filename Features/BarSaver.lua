local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
Keeps a copy of the action bars, one per character and per spec, and puts
back what the game lost.

Why:
  Since dual spec came to Forever (November 2026), the server sometimes
  hands back emptied action slots after a logout, a /reload or a spec swap,
  mostly on the second spec. Bars live on the server, so there is no local
  file to fix: the only cure is to place the actions again.

How:
  - The copy follows the bars: each change is saved two seconds later.
  - After a login, a reload or a spec swap, the bars are compared with the
    copy BEFORE saving resumes. A slot that was filled in the copy and is
    now empty counts as lost and is filled again. A slot that holds
    something else is left alone (only /bgt bars restore overwrites it).
  - Saving is on hold while the bars of the current spec have not been
    checked, so a wiped bar can never replace a good copy.

Limits:
  - Placing an action is protected in combat: the restore waits for the end
    of the fight.
  - Spells are saved by ID (the exact rank), items by ID, macros by name.
    Anything else (mounts, equipment sets, flyouts) is not put back.
]]

local KEY = "barSaver"
local MAX_SLOT = 180        -- pages 1-15; vehicle and override pages sit beyond
local SAVE_DELAY = 2        -- quiet time after the last bar change before saving
local LOGIN_DELAY = 3       -- the bars arrive a moment after the loading screen
local SPEC_DELAY = 1.5      -- same after a spec swap
local RETRY_DELAY = 5       -- second try for what could not be placed (spellbook still loading)
local CURSOR_RETRIES = 10

local Bars = {}
ns.BarSaver = Bars

local events = CreateFrame("Frame")
local active = false
local readySpec             -- spec whose bars were checked: saving is allowed for it
local held = false          -- actions are missing and automatic restore is off: keep the copy as it is
local restoring = false
local quietUntil = 0        -- no automatic save before this time (a retry is coming)
local generation = 0        -- cancels older delayed checks
local saveQueued = false
local dirty = false
local checkAfterCombat = false

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c = pcall(fn, ...)
    if ok then return a, b, c end
end

local function CurrentSpec()
    local spec = Call(C_SpecializationInfo and C_SpecializationInfo.GetActiveSpecGroup)
        or Call(GetActiveSpecGroup) or Call(GetActiveTalentGroup)
    if Util.Readable(spec) and type(spec) == "number" and spec >= 1 then return spec end
    return 1
end

local function Store()
    local all = ns.db.bars
    local key = Util.CharacterKey()
    if type(all[key]) ~= "table" then all[key] = {} end
    if type(all[key].specs) ~= "table" then all[key].specs = {} end
    return all[key].specs
end

-- "spell:139", "item:858", "macro:Name", "other:flyout", nil for an empty
-- slot. Second value false when the game hides the slot (secret value).
local function ReadSlot(slot)
    local ok, kind, id = pcall(GetActionInfo, slot)
    if not ok then return nil, false end
    if kind == nil then return nil, true end
    if not Util.Readable(kind) or type(kind) ~= "string" then return nil, false end
    if kind == "macro" then
        local name = Call(GetActionText, slot)
        if Util.Readable(name) and type(name) == "string" and name ~= "" then return "macro:" .. name, true end
        return nil, false
    end
    if kind == "spell" or kind == "item" then
        if not Util.Readable(id) or type(id) ~= "number" then return nil, false end
        return kind .. ":" .. id, true
    end
    return "other:" .. kind, true
end

-- Every filled slot, or nil when one slot could not be read: a partial
-- copy would look like lost actions.
local function Snapshot()
    local slots, count = {}, 0
    for slot = 1, MAX_SLOT do
        local entry, readable = ReadSlot(slot)
        if not readable then return nil end
        if entry then
            slots[slot] = entry
            count = count + 1
        end
    end
    return slots, count
end

local function Save(spec)
    local slots, count = Snapshot()
    if not slots then return nil end
    Store()[spec] = { slots = slots, count = count, time = time() }
    dirty = false
    return count
end

-- Saved slots that are empty now, and how many slots are filled now.
local function Compare(saved)
    local missing, filled = 0, 0
    for slot = 1, MAX_SLOT do
        local entry, readable = ReadSlot(slot)
        if not readable then return nil end
        if entry then
            filled = filled + 1
        elseif saved.slots[slot] then
            missing = missing + 1
        end
    end
    return missing, filled
end

---------------------------------------------------------------------------
-- Placing
---------------------------------------------------------------------------

local function CursorBusy()
    local kind = Call(GetCursorInfo)
    if kind ~= nil then return true end
    return Call(SpellIsTargeting) == true
end

local function PickUp(entry)
    local kind, value = entry:match("^(%a+):(.+)$")
    if kind == "spell" then
        Call((C_Spell and C_Spell.PickupSpell) or PickupSpell, tonumber(value))
    elseif kind == "item" then
        Call((C_Item and C_Item.PickupItem) or PickupItem, tonumber(value))
    elseif kind == "macro" then
        local index = Call(GetMacroIndexByName, value)
        if type(index) == "number" and index > 0 then Call(PickupMacro, index) end
    end
    return Call(GetCursorInfo) ~= nil
end

local function Place(slot, entry)
    ClearCursor()
    if not PickUp(entry) then
        ClearCursor()
        return false
    end
    PlaceAction(slot)
    ClearCursor()   -- PlaceAction hands the previous action back on the cursor
    return (ReadSlot(slot)) ~= nil
end

--[[
PlaceAction fires ACTIONBAR_SLOT_CHANGED while our code is still running, so
Blizzard's button updates for that slot run as addon code and the fields they
write on the button (button.action first) stay marked as ours. Every later
change of that slot reads them, so in combat the button's SetShown or
SetAttribute is refused: ADDON_ACTION_BLOCKED on
MultiBarBottomRightButton1:SetShown(), blamed on this addon. button.action
can't be purged like the bar fields (the button needs it), and only a reload
gives the buttons clean fields. The server keeps the restored actions.
]]
StaticPopupDialogs["BUDGETFOREVER_BARS_RELOAD"] = {
    text = "",
    button1 = RELOADUI or "Reload",
    button2 = CANCEL,
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function OfferReload()
    StaticPopupDialogs["BUDGETFOREVER_BARS_RELOAD"].text = L.BARS_RELOAD
    StaticPopup_Show("BUDGETFOREVER_BARS_RELOAD")
end

-- Fills the slots the copy has and the bars lost. With `force`, also
-- replaces slots that hold something else. Returns placed, failed.
local function Restore(saved, force)
    local placed, failed = 0, 0
    restoring = true
    local ok, err = pcall(function()
        for slot = 1, MAX_SLOT do
            local entry = saved.slots[slot]
            if entry then
                local current = ReadSlot(slot)
                if current ~= entry and (current == nil or force) then
                    if Place(slot, entry) then
                        placed = placed + 1
                    else
                        failed = failed + 1
                    end
                end
            end
        end
    end)
    ClearCursor()
    restoring = false
    -- Each pick-up and drop made the bars redo their layout as addon code.
    Util.CleanBars()
    if placed > 0 then OfferReload() end
    if not ok then geterrorhandler()(err) end
    return placed, failed
end

---------------------------------------------------------------------------
-- Check after a login, a reload or a spec swap
---------------------------------------------------------------------------

local Check

local function Later(delay, fn)
    generation = generation + 1
    local mine = generation
    C_Timer.After(delay, function()
        if active and mine == generation then fn() end
    end)
end

local function Report(spec, placed, failed)
    if placed > 0 then ns:Print(L.BARS_RESTORED:format(placed, spec)) end
    if failed > 0 then ns:Print(L.BARS_FAILED:format(failed)) end
end

-- attempt: 1 on the first look, 2 on the retry, then cursor retries.
function Check(attempt, cursorTries)
    if not active then return end
    local spec = CurrentSpec()
    local saved = Store()[spec]
    if type(saved) ~= "table" or type(saved.slots) ~= "table" then
        -- First time on this spec: the bars as they are become the copy.
        if Save(spec) then readySpec, held = spec, false end
        return
    end
    local missing = Compare(saved)
    if not missing then
        Later(RETRY_DELAY, function() Check(attempt, cursorTries) end)
        return
    end
    if missing == 0 then
        Save(spec)
        readySpec, held = spec, false
        return
    end
    if not ns:GetOption(KEY, "autoRestore") then
        readySpec, held = spec, true
        ns:Print(L.BARS_MISSING:format(missing, spec))
        return
    end
    if InCombatLockdown() then
        checkAfterCombat = true
        return
    end
    if CursorBusy() then
        cursorTries = (cursorTries or 0) + 1
        if cursorTries <= CURSOR_RETRIES then
            Later(1, function() Check(attempt, cursorTries) end)
        else
            readySpec, held = spec, true
            ns:Print(L.BARS_MISSING:format(missing, spec))
        end
        return
    end
    local placed, failed = Restore(saved, false)
    if failed > 0 and attempt == 1 then
        -- The spellbook may still be loading: keep the copy and try once more.
        if placed > 0 then ns:Print(L.BARS_RESTORED:format(placed, spec)) end
        quietUntil = GetTime() + RETRY_DELAY + 1
        Later(RETRY_DELAY, function() Check(2) end)
        return
    end
    Report(spec, placed, failed)
    readySpec, held = spec, false
end

local function ScheduleCheck(delay)
    readySpec = nil
    Later(delay, function() Check(1) end)
end

---------------------------------------------------------------------------
-- Automatic save
---------------------------------------------------------------------------

local function CanSave()
    return active and not restoring and not held and GetTime() >= quietUntil
        and readySpec ~= nil and readySpec == CurrentSpec()
end

local function QueueSave()
    if not active or restoring then return end
    dirty = true
    if saveQueued then return end
    saveQueued = true
    C_Timer.After(SAVE_DELAY, function()
        saveQueued = false
        if not active or not dirty then return end
        if CanSave() then
            Save(readySpec)
        elseif readySpec ~= nil and readySpec ~= CurrentSpec() then
            -- The spec changed without its event: check before saving again.
            ScheduleCheck(SPEC_DELAY)
        end
    end)
end

events:SetScript("OnEvent", function(_, event)
    if event == "ACTIONBAR_SLOT_CHANGED" then
        QueueSave()
    elseif event == "PLAYER_ENTERING_WORLD" then
        ScheduleCheck(LOGIN_DELAY)
    elseif event == "ACTIVE_TALENT_GROUP_CHANGED" then
        ScheduleCheck(SPEC_DELAY)
    elseif event == "PLAYER_REGEN_ENABLED" then
        if checkAfterCombat then
            checkAfterCombat = false
            Later(0.5, function() Check(1) end)
        end
    elseif event == "PLAYER_LOGOUT" then
        if dirty and CanSave() then Save(readySpec) end
    end
end)

---------------------------------------------------------------------------
-- Commands and buttons
---------------------------------------------------------------------------

function Bars.SaveNow()
    if not active then ns:Print(L.BARS_OFF) return end
    local spec = CurrentSpec()
    local count = Save(spec)
    if not count then ns:Print(L.BARS_UNREADABLE) return end
    readySpec, held = spec, false
    ns:Print(L.BARS_SAVED:format(count, spec))
end

function Bars.RestoreNow()
    if not active then ns:Print(L.BARS_OFF) return end
    local spec = CurrentSpec()
    local saved = Store()[spec]
    if type(saved) ~= "table" or type(saved.slots) ~= "table" then
        ns:Print(L.BARS_NO_SAVE:format(spec))
        return
    end
    if InCombatLockdown() then ns:Print(L.BARS_COMBAT) return end
    if CursorBusy() then ns:Print(L.BARS_CURSOR) return end
    local placed, failed = Restore(saved, true)
    if placed == 0 and failed == 0 then
        ns:Print(L.BARS_NOTHING)
    else
        Report(spec, placed, failed)
    end
    readySpec, held = spec, false
end

function Bars.Status()
    if not active then ns:Print(L.BARS_OFF) return end
    local spec = CurrentSpec()
    local saved = Store()[spec]
    if type(saved) ~= "table" or type(saved.slots) ~= "table" then
        ns:Print(L.BARS_NO_SAVE:format(spec))
        return
    end
    local missing, filled = Compare(saved)
    if not missing then ns:Print(L.BARS_UNREADABLE) return end
    ns:Print(L.BARS_STATUS:format(spec, saved.count or 0, date("%d/%m %H:%M", saved.time or 0), filled, missing))
    ns:Print(L.BARS_STATUS_HELP)
end

function Bars.Command(rest)
    local command = strlower(strtrim(rest or ""))
    if command == "save" or command == "sauver" or command == "sauvegarder" then
        Bars.SaveNow()
    elseif command == "restore" or command == "restaurer" then
        Bars.RestoreNow()
    else
        Bars.Status()
    end
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local function Enable()
    active = true
    held, dirty, checkAfterCombat = false, false, false
    events:RegisterEvent("ACTIONBAR_SLOT_CHANGED")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:RegisterEvent("PLAYER_LOGOUT")
    pcall(events.RegisterEvent, events, "ACTIVE_TALENT_GROUP_CHANGED")
    -- At login PLAYER_ENTERING_WORLD follows; this covers turning it on later.
    ScheduleCheck(LOGIN_DELAY)
end

local function Disable()
    active = false
    readySpec = nil
    generation = generation + 1
    events:UnregisterAllEvents()
end

ns:RegisterFeature({
    key = KEY,
    category = "actions",
    order = 30,
    title = "BARS_TITLE",
    desc = "BARS_DESC",
    tip = "BARS_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "autoRestore", title = "BARS_OPT_AUTO", tip = "BARS_OPT_AUTO_TIP", default = true },
        { key = "saveNow", title = "BARS_OPT_SAVE", tip = "BARS_OPT_SAVE_TIP", action = function() Bars.SaveNow() end },
        { key = "restoreNow", title = "BARS_OPT_RESTORE", tip = "BARS_OPT_RESTORE_TIP", action = function() Bars.RestoreNow() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
