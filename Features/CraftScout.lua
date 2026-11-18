local ADDON, ns = ...
local L = ns.L

--[[
CraftScout as a BudgetTools module.

CraftScout (gold per day for each recipe, from Auction House scans) lives in
its own folder, BudgetTools_CraftScout, whose .toc says LoadOnDemand and
Dependencies: BudgetTools. The game never loads it by itself: this card does.
Off, it costs nothing; its code and recipe tables are not even read.

When it loads:
  As soon as BudgetTools' own saved data is there (our ADDON_LOADED), so the
  module is in place before PLAYER_LOGIN like any addon. Ticking the card
  later loads it on the spot; the module then plays the login it missed
  (Core/Namespace.lua, Events.CatchUp, in the module).
  An addon cannot be unloaded: unticking it closes its window and asks for a
  reload, through the usual reload button of the /bgt window.

The module keeps its own saved data (CraftScoutDB), its own settings and its
own /csc command. Until it is loaded, /csc only says where to turn it on.

Without the folder, nothing here exists: no card, no /csc.
]]

local MODULE = "BudgetTools_CraftScout"
local KEY = "craftScout"
local DEFAULT = false

local AddOns = C_AddOns or {}
local LoadAddOn = AddOns.LoadAddOn or _G.LoadAddOn
local IsAddOnLoaded = AddOns.IsAddOnLoaded or _G.IsAddOnLoaded
local EnableAddOn = AddOns.EnableAddOn or _G.EnableAddOn
local GetAddOnInfo = AddOns.GetAddOnInfo or _G.GetAddOnInfo
local DoesAddOnExist = AddOns.DoesAddOnExist

local function Installed()
    if DoesAddOnExist then
        local ok, exists = pcall(DoesAddOnExist, MODULE)
        if ok then return exists and true or false end
    end
    if not GetAddOnInfo then return false end
    local ok, name, _, _, _, reason = pcall(GetAddOnInfo, MODULE)
    return ok and name ~= nil and reason ~= "MISSING"
end

if not Installed() then return end

local CS = {}
ns.CraftScout = CS

function CS.IsLoaded()
    if not IsAddOnLoaded then return false end
    local ok, loaded = pcall(IsAddOnLoaded, MODULE)
    return ok and loaded and true or false
end

local function TryLoad()
    if not LoadAddOn then return false end
    local ok, loaded, reason = pcall(LoadAddOn, MODULE)
    if not ok then return false, nil end
    return loaded and true or false, reason
end

-- The module's minimap button: its setting lives in the module (CraftScoutDB),
-- so this card and the module's Display menu always show the same thing.
local function MinimapButton()
    local module = _G.CraftScout
    return type(module) == "table" and module.MinimapButton or nil
end

-- Ticked in the module's own menu: this card follows while /bgt is open.
local function WatchMinimapButton()
    local button = MinimapButton()
    if not button then return end
    button.onChange = function(value) ns:Fire("OPTION_CHANGED", KEY, "minimapButton", value) end
end

-- Loads the module; true when it is there. Unticked in the game's AddOns list,
-- it is ticked again for this character: ticking the card means wanting it.
function CS.Load()
    if CS.IsLoaded() then
        WatchMinimapButton()
        return true
    end
    local loaded, reason = TryLoad()
    if not loaded and reason == "DISABLED" and EnableAddOn then
        pcall(EnableAddOn, MODULE, UnitName("player"))
        loaded, reason = TryLoad()
    end
    if loaded then
        WatchMinimapButton()
    else
        local why = reason and (_G["ADDON_" .. reason] or reason) or UNKNOWN
        ns:Print(L.CRAFTSCOUT_LOAD_FAILED:format(tostring(why)))
    end
    return loaded
end

---------------------------------------------------------------------------
-- /csc before the module is loaded
---------------------------------------------------------------------------

-- The module sets SlashCmdList.CRAFTSCOUT itself when it loads. The chat may
-- have kept this function for /csc in the meantime: it then hands over.
local function SlashStub(message)
    local real = SlashCmdList.CRAFTSCOUT
    if real and real ~= SlashStub then return real(message) end
    ns:Print(L.CRAFTSCOUT_OFF)
end

SLASH_CRAFTSCOUT1 = "/craftscout"
SLASH_CRAFTSCOUT2 = "/csc"
SlashCmdList.CRAFTSCOUT = SlashStub

-- Same as /csc with nothing after it: opens or closes the window.
function CS.Open()
    if not CS.Load() then return end
    local run = SlashCmdList.CRAFTSCOUT
    if run and run ~= SlashStub then run("") end
end

local function CloseWindows()
    local module = _G.CraftScout
    if type(module) ~= "table" then return end
    local v2 = module.UIV2
    if type(v2) == "table" and v2.frame and v2.frame:IsShown() and v2.Hide then pcall(v2.Hide) end
    local v1 = module.UI
    if type(v1) == "table" and v1.frame then v1.frame:Hide() end
end

---------------------------------------------------------------------------
-- Early load
---------------------------------------------------------------------------

-- Read straight from the saved table: Core may not have filled it yet.
local early = CreateFrame("Frame")
early:RegisterEvent("ADDON_LOADED")
early:SetScript("OnEvent", function(self, _, name)
    if name ~= ADDON then return end
    self:UnregisterEvent("ADDON_LOADED")
    local db = BudgetForeverDB
    local on = type(db) == "table" and type(db.features) == "table" and db.features[KEY]
    if on == nil then on = DEFAULT end
    if on then CS.Load() end
end)

ns:RegisterFeature({
    key = KEY,
    category = "professions",
    order = 20,
    title = "CRAFTSCOUT_TITLE",
    desc = "CRAFTSCOUT_DESC",
    tip = "CRAFTSCOUT_TIP",
    default = DEFAULT,
    isNew = true,
    -- Off needs a reload once the module is loaded (Core, NeedsReload).
    reloadToDisable = true,
    IsActive = CS.IsLoaded,
    options = {
        { key = "open", title = "CRAFTSCOUT_OPEN", tip = "CRAFTSCOUT_OPEN_TIP", action = function() CS.Open() end },
        {
            key = "minimapButton",
            title = "CRAFTSCOUT_MINIMAP",
            tip = "CRAFTSCOUT_MINIMAP_TIP",
            get = function()
                local button = MinimapButton()
                return button ~= nil and button.IsEnabled()
            end,
            set = function(value)
                local button = MinimapButton()
                if button then button.SetEnabled(value) end
            end,
        },
    },
    OnEnable = function() CS.Load() end,
    OnDisable = CloseWindows,
})
