local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
"Cast by <name>" at the bottom of buff and debuff tooltips.

How it hooks in:
  GameTooltip:SetUnitAura, SetUnitBuff, SetUnitDebuff and their
  ...ByAuraInstanceID versions all go through Blizzard's TooltipDataHandler.
  It runs the post-calls registered for Enum.TooltipDataType.UnitAura right
  before it shows the tooltip, and keeps the call's arguments in
  tooltip:GetProcessingTooltipInfo() (getterName, getterArgs). So the
  post-call knows the unit and which aura it is. Each refresh of the tooltip
  clears it and runs the post-call again, so the line is never doubled.

Where the caster comes from:
  - aura.sourceUnit, a unit token. It is only set when the caster is one of
    your units: you, your pet, your party or raid, target, mouseover, or a
    nameplate.
  - C_UnitAuras.GetAuraCasterGUID, which Forever's own aura frames use. It
    returns a GUID even for a passing stranger, and GetPlayerInfoByGUID turns
    a player GUID into a name and a class while the client remembers that
    player.

What it can't reach:
  Forever draws the target frame auras and the raid-style frame auras in the
  secure environment (Blizzard_AuraContainer, Blizzard_PrivateAurasUI), with
  a forbidden tooltip of their own. Addons can't add lines to it. The buff
  bar, the classic party frames and addons that show auras through
  GameTooltip (VellumUI) are covered.

  Aura data can be secret in restricted contexts. Secret values are never
  read, so the line is simply missing then.
]]

local KEY = "auraCaster"

local AuraCaster = {}
ns.AuraCaster = AuraCaster

local active = false
local hooked = false

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
-- Which aura the tooltip shows
---------------------------------------------------------------------------

local function WithFilter(base, filter)
    filter = Str(filter)
    return filter and (base .. "|" .. filter) or base
end

local GETTERS = {
    GetUnitAura = function(unit, index, filter)
        return Call(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
    end,
    GetUnitBuff = function(unit, index, filter)
        if C_UnitAuras.GetBuffDataByIndex then
            return Call(C_UnitAuras.GetBuffDataByIndex, unit, index, filter)
        end
        return Call(C_UnitAuras.GetAuraDataByIndex, unit, index, WithFilter("HELPFUL", filter))
    end,
    GetUnitDebuff = function(unit, index, filter)
        if C_UnitAuras.GetDebuffDataByIndex then
            return Call(C_UnitAuras.GetDebuffDataByIndex, unit, index, filter)
        end
        return Call(C_UnitAuras.GetAuraDataByIndex, unit, index, WithFilter("HARMFUL", filter))
    end,
}
local function ByInstance(unit, id)
    return Call(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, id)
end
GETTERS.GetUnitAuraByAuraInstanceID = ByInstance
GETTERS.GetUnitBuffByAuraInstanceID = ByInstance
GETTERS.GetUnitDebuffByAuraInstanceID = ByInstance

-- The unit and the aura data behind the tooltip being built.
local function TooltipAura(tooltip)
    local getInfo = tooltip.GetProcessingTooltipInfo or tooltip.GetPrimaryTooltipInfo
    local info = Call(getInfo, tooltip)
    if not Util.ReadableTable(info) then return end
    local getter = GETTERS[Str(info.getterName) or ""]
    local args = info.getterArgs
    if not getter or not Util.ReadableTable(args) then return end
    local unit, which, filter = args[1], args[2], args[3]
    unit = Str(unit)
    if not unit or not Util.Readable(which) or type(which) ~= "number" then return end
    if filter ~= nil and not Str(filter) then filter = nil end
    local aura = getter(unit, which, filter)
    if Util.ReadableTable(aura) then return unit, aura end
end

---------------------------------------------------------------------------
-- Who cast it
---------------------------------------------------------------------------

local function PlayerClass()
    return Str((select(2, Call(UnitClass, "player"))))
end

-- The owner of a pet token, when the token says it.
local function PetOwner(unit)
    if unit == "pet" then return "player" end
    local n = unit:match("^partypet(%d)$")
    if n then return "party" .. n end
    n = unit:match("^raidpet(%d+)$")
    if n then return "raid" .. n end
end

-- The name alone, never the server (the user's choice).
local function UnitLabel(unit, depth)
    depth = depth or 0
    if not Is(UnitExists, unit) then return end
    if Is(UnitIsUnit, unit, "player") then
        return Util.ClassColored(L.AURACASTER_YOU, PlayerClass())
    end
    local name = Util.CleanName((Call(UnitName, unit)))
    if not name then return end
    if Is(UnitIsPlayer, unit) then
        local class = select(2, Call(UnitClass, unit))
        return Util.ClassColored(name, Str(class))
    end
    -- NPCs and pets in white, so the name stands out of the grey line.
    local white = "|cffffffff" .. name .. "|r"
    local owner = depth == 0 and PetOwner(unit)
    if owner then
        local ownerLabel = UnitLabel(owner, 1)
        if ownerLabel then return L.AURACASTER_PET:format(white, ownerLabel) end
    end
    return white
end

local function GuidLabel(guid)
    if guid == Str(Call(UnitGUID, "player")) then
        return Util.ClassColored(L.AURACASTER_YOU, PlayerClass())
    end
    -- One of your units (pet, party member, target, nameplate...).
    local token = Str(Call(UnitTokenFromGUID, guid))
    local label = token and UnitLabel(token)
    if label then return label end
    -- A player the client remembers, such as a passer-by in town.
    if guid:find("^Player%-") then
        local _, class, _, _, _, name = Call(GetPlayerInfoByGUID, guid)
        name = Util.CleanName(name)
        if not name then return end
        return Util.ClassColored(name, Str(class))
    end
end

-- Colored caster text for an aura on unit, or nil when unknown.
function AuraCaster.Label(unit, aura)
    local source = Str(aura.sourceUnit)
    local label = source and UnitLabel(source)
    if label then return label end
    local id = aura.auraInstanceID
    if not Util.Readable(id) or type(id) ~= "number" then return end
    local guid = Str(Call(C_UnitAuras.GetAuraCasterGUID, unit, id))
    if guid then return GuidLabel(guid) end
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function OnAuraTooltip(tooltip)
    if not active or tooltip ~= GameTooltip then return end
    local unit, aura = TooltipAura(tooltip)
    if not unit then return end
    local label = AuraCaster.Label(unit, aura)
    if not label then return end
    tooltip:AddLine(L.AURACASTER_LINE:format(label), 0.7, 0.7, 0.7)
end

local function InstallHook()
    if hooked then return end
    local types = Enum and Enum.TooltipDataType
    if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and types and types.UnitAura) then return end
    hooked = true
    TooltipDataProcessor.AddTooltipPostCall(types.UnitAura, function(tooltip)
        xpcall(OnAuraTooltip, geterrorhandler(), tooltip)
    end)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "frames",
    order = 20,
    title = "AURACASTER_TITLE",
    desc = "AURACASTER_DESC",
    tip = "AURACASTER_TIP",
    default = true,
    isNew = true,
    OnEnable = function()
        active = true
        InstallHook()
    end,
    OnDisable = function()
        -- A post-call can't be removed; it stays and does nothing.
        active = false
    end,
})
