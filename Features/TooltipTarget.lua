local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
"Target: <name>" in unit tooltips, "Target: Me" when the unit targets you.

How it hooks in:
  A TooltipDataProcessor post-call on Enum.TooltipDataType.Unit, limited to
  GameTooltip, adds the line each time the game builds a unit tooltip (world
  mouseover, nameplates, unit frames). The unit token comes from
  tooltip:GetUnit(); "<unit>target" is its target.

Live update:
  A unit can change target while the tooltip stays up (a mob switching to
  you). A throttled OnUpdate on GameTooltip re-reads the target and rewrites
  our line in place, or adds it when the unit picks a target. OnTooltipCleared
  forgets the line, so a rebuilt tooltip never keeps a stale one.

  Unit data can be secret in restricted contexts. Secret values are never
  read, so the line is simply missing then.
]]

local KEY = "tooltipTarget"
local THROTTLE = 0.2

local TooltipTarget = {}
ns.TooltipTarget = TooltipTarget

local active = false
local hooked = false

-- The line we added to GameTooltip: its font string, the unit, its text.
local line, lineUnit, lineText
local elapsedSince = 0

local function Str(value)
    if Util.Readable(value) and type(value) == "string" and value ~= "" then return value end
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c, d, e, f, g = pcall(fn, ...)
    if ok then return a, b, c, d, e, f, g end
end

local function Is(fn, ...)
    local value = Call(fn, ...)
    return Util.Readable(value) and value == true
end

---------------------------------------------------------------------------
-- Label
---------------------------------------------------------------------------

local SIDES = { Alliance = true, Horde = true }

-- A player of the other faction, flagged for PvP or not.
local function OtherFaction(unit)
    if not Is(UnitIsPlayer, unit) then return false end
    local theirs = Str((Call(UnitFactionGroup, unit)))
    local mine = Str((Call(UnitFactionGroup, "player")))
    return SIDES[theirs] and SIDES[mine] and theirs ~= mine or false
end

-- Mobs that can attack you, and players of the other faction.
function TooltipTarget.IsEnemy(unit)
    return Is(UnitCanAttack, unit, "player") or Is(UnitIsEnemy, unit, "player") or OtherFaction(unit)
end

-- Colored name of what unit targets, or nil when it targets nothing.
function TooltipTarget.Label(unit)
    local target = unit .. "target"
    if not Is(UnitExists, target) then return end
    if Is(UnitIsUnit, target, "player") then
        -- Red when an enemy is on you, so it reads as a warning.
        if TooltipTarget.IsEnemy(unit) then
            return "|cffff2020" .. L.TOOLTIPTARGET_ME .. "|r"
        end
        local class = select(2, Call(UnitClass, "player"))
        return Util.ClassColored(L.TOOLTIPTARGET_ME, Str(class))
    end
    local name = Util.CleanName((Call(UnitName, target)))
    if not name then return end
    if Is(UnitIsPlayer, target) then
        local class = select(2, Call(UnitClass, target))
        return Util.ClassColored(name, Str(class))
    end
    -- NPCs and pets in white, so the name stands out of the grey line.
    return "|cffffffff" .. name .. "|r"
end

local function LineText(unit)
    local label = TooltipTarget.Label(unit)
    if label then return L.TOOLTIPTARGET_LINE:format(label) end
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function TooltipUnit(tooltip)
    local _, unit = Call(tooltip.GetUnit, tooltip)
    unit = Str(unit)
    if unit and Is(UnitExists, unit) then return unit end
end

local function AddTargetLine(tooltip, unit, text)
    tooltip:AddLine(text, 0.7, 0.7, 0.7)
    line = _G[tooltip:GetName() .. "TextLeft" .. tooltip:NumLines()]
    lineUnit, lineText = unit, text
end

local function OnUnitTooltip(tooltip)
    if not active or tooltip ~= GameTooltip then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    line, lineUnit, lineText = nil, nil, nil
    local unit = TooltipUnit(tooltip)
    if not unit then return end
    lineUnit = unit
    local text = LineText(unit)
    if text then AddTargetLine(tooltip, unit, text) end
end

-- Follows target changes while the tooltip stays up.
local function OnUpdate(tooltip, elapsed)
    if not active or not lineUnit then return end
    elapsedSince = elapsedSince + elapsed
    if elapsedSince < THROTTLE then return end
    elapsedSince = 0
    if tooltip:IsForbidden() or not tooltip:IsShown() then return end
    -- The tooltip moved on to something else, or the unit is gone.
    if TooltipUnit(tooltip) ~= lineUnit then return end
    local text = LineText(lineUnit) or (line and L.TOOLTIPTARGET_LINE:format(L.TOOLTIPTARGET_NONE))
    if not text or text == lineText then return end
    if line then
        line:SetText(text)
        lineText = text
    else
        AddTargetLine(tooltip, lineUnit, text)
    end
    tooltip:Show()
end

local function InstallHook()
    if hooked then return end
    local types = Enum and Enum.TooltipDataType
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and types and types.Unit) then return end
    hooked = true
    TooltipDataProcessor.AddTooltipPostCall(types.Unit, function(tooltip)
        xpcall(OnUnitTooltip, geterrorhandler(), tooltip)
    end)
    GameTooltip:HookScript("OnTooltipCleared", function()
        line, lineUnit, lineText = nil, nil, nil
    end)
    GameTooltip:HookScript("OnUpdate", function(tooltip, elapsed)
        xpcall(OnUpdate, geterrorhandler(), tooltip, elapsed)
    end)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "frames",
    order = 25,
    title = "TOOLTIPTARGET_TITLE",
    desc = "TOOLTIPTARGET_DESC",
    tip = "TOOLTIPTARGET_TIP",
    default = true,
    isNew = true,
    OnEnable = function()
        active = true
        InstallHook()
    end,
    OnDisable = function()
        -- Hooks can't be removed; they stay and do nothing.
        active = false
        line, lineUnit, lineText = nil, nil, nil
    end,
})
