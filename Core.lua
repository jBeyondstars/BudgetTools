local ADDON, ns = ...
local L = ns.L

local GetMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (GetMetadata and GetMetadata(ADDON, "Version")) or "dev"
-- The logo: ICON keeps its gold ring. ICON_MINI is zoomed on the goggles and
-- the face, on a round alpha, for places that draw their own ring (minimap
-- button, window portrait).
ns.ICON = "Interface\\AddOns\\" .. ADDON .. "\\Media\\Logo.tga"
ns.ICON_MINI = "Interface\\AddOns\\" .. ADDON .. "\\Media\\LogoMini.tga"

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------

local PREFIX = "|cffffd200BudgetTools|r: "

function ns:Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
end

-- Red line in the middle of the screen, like Blizzard's own errors.
function ns:Error(message)
    UIErrorsFrame:AddMessage(message, 1.0, 0.1, 0.1)
end

---------------------------------------------------------------------------
-- Internal callbacks (UI listens to these)
---------------------------------------------------------------------------

local listeners = {}

function ns:On(event, callback)
    listeners[event] = listeners[event] or {}
    table.insert(listeners[event], callback)
end

function ns:Fire(event, ...)
    for _, callback in ipairs(listeners[event] or {}) do
        callback(...)
    end
end

---------------------------------------------------------------------------
-- Categories and features
--
-- A feature is a table:
--   key       unique id, also the saved-variable key
--   category  key of a registered category
--   order     sort order inside the category
--   title, desc, tip   locale keys
--   default   true to enable it on a fresh install
--   reload    true if toggling it needs /reload (no live OnEnable/OnDisable)
--   reloadToDisable, IsActive   on works live, off needs /reload while
--             IsActive() is true (a load-on-demand module cannot be unloaded)
--   isNew     shows a NEW badge
--   options   sub-options: { { key, title, tip, default }, ... }
--             get(), set(value): the option is saved elsewhere (by a module)
--   OnEnable(def), OnDisable(def)
---------------------------------------------------------------------------

ns.categories = {}
ns.features = {}
local featureByKey = {}
local enabledAtLogin = {}

local function byOrder(a, b)
    if a.order == b.order then return a.key < b.key end
    return a.order < b.order
end

function ns:RegisterCategory(def)
    def.order = def.order or 100
    table.insert(self.categories, def)
    table.sort(self.categories, byOrder)
end

function ns:GetCategory(key)
    for _, category in ipairs(self.categories) do
        if category.key == key then return category end
    end
end

function ns:RegisterFeature(def)
    assert(type(def.key) == "string" and type(def.category) == "string", "BudgetTools: invalid feature")
    def.order = def.order or 100
    featureByKey[def.key] = def
    table.insert(self.features, def)
    table.sort(self.features, byOrder)
end

function ns:GetFeatures(categoryKey)
    local list = {}
    for _, def in ipairs(self.features) do
        if def.category == categoryKey then table.insert(list, def) end
    end
    return list
end

function ns:IsEnabled(key)
    return self.db ~= nil and self.db.features[key] == true
end

local function Run(def, method)
    local callback = def[method]
    if not callback then return end
    xpcall(function() callback(def) end, geterrorhandler())
end

function ns:SetEnabled(key, value)
    local def = featureByKey[key]
    if not def or not self.db then return end
    value = value and true or false
    if self.db.features[key] == value then return end
    self.db.features[key] = value
    if not def.reload then
        Run(def, value and "OnEnable" or "OnDisable")
    end
    self:Fire("FEATURE_CHANGED", key, value)
end

function ns:GetOption(key, option)
    local values = self.db and self.db.options[key]
    return values ~= nil and values[option] == true
end

function ns:SetOption(key, option, value)
    if not self.db then return end
    value = value and true or false
    self.db.options[key] = self.db.options[key] or {}
    if self.db.options[key][option] == value then return end
    self.db.options[key][option] = value
    self:Fire("OPTION_CHANGED", key, option, value)
end

-- True when a reload-only feature was toggled since login, or a module that
-- cannot be unloaded was turned off.
function ns:NeedsReload()
    if not self.db then return false end
    for _, def in ipairs(self.features) do
        if def.reload and (self.db.features[def.key] == true) ~= (enabledAtLogin[def.key] == true) then
            return true
        end
        if def.reloadToDisable and self.db.features[def.key] ~= true and def.IsActive and def.IsActive() then
            return true
        end
    end
    return false
end

---------------------------------------------------------------------------
-- Saved variables
---------------------------------------------------------------------------

local DEFAULTS = {
    general = {
        loginMessage = true,
        language = "auto",
        minimapButton = true,
        minimapAngle = 225,
    },
    features = {},
    options = {},
    players = {},  -- player notes, account-wide, kept by the reset
    lfg = {},      -- message = LFG application template
    loot = {       -- full-bags swap
        keep = {}, -- itemID -> true: never proposed for destruction
    },
    wheel = {},    -- ["Name-Realm"] = { slots = { macro names } }
    npc = {},      -- NPC finder: bar = { x, y } once the bar was dragged
    hunt = {},     -- hunting list: list, chars (tag spell), button position; kept by the reset
    recipes = {},  -- ["Name-Realm"] = { recipe notes pinned on screen }; kept by the reset
    bars = {},     -- ["Name-Realm"] = { specs = { [spec] = action bar copy } }; kept by the reset
    xp = {},       -- XP per hour: pos, scale, chars["Name-Realm"] = session; sessions kept by the reset
    bags = {},     -- item type names in the combined bag: font (text size), spacing (extra space between rows)
    trinkets = {}, -- trinket bar: pos = { point, relativePoint, x, y } once the bar was dragged
    buffs = {},    -- buff key: chars["Name-Realm"] = { order, on, rank }; kept by the reset
    window = {},
}

local function Merge(target, source)
    for key, value in pairs(source) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            Merge(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

local function InitDB()
    if type(BudgetForeverDB) ~= "table" then BudgetForeverDB = {} end
    local db = BudgetForeverDB
    Merge(db, DEFAULTS)
    for _, def in ipairs(ns.features) do
        if db.features[def.key] == nil then db.features[def.key] = def.default == true end
        if def.options then
            db.options[def.key] = db.options[def.key] or {}
            for _, option in ipairs(def.options) do
                if not option.action and not option.get and db.options[def.key][option.key] == nil then
                    db.options[def.key][option.key] = option.default == true
                end
            end
        end
    end
    db.schema = 1
    ns.db = db
end

function ns:ChangeLanguage(code)
    self.db.general.language = code
    ns.ApplyLanguage(code)
    self:Fire("LANGUAGE_CHANGED")
end

StaticPopupDialogs["BUDGETFOREVER_RESET"] = {
    text = "",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        -- Settings go back to defaults; notes, the LFG message, the
        -- "always keep" list, the macro wheels, the hunting list, the
        -- pinned recipes, the action bar copies and the bag sort history are data, not settings (the hunting button goes
        -- back in place).
        local old = type(BudgetForeverDB) == "table" and BudgetForeverDB or {}
        local hunt = type(old.hunt) == "table" and { list = old.hunt.list, chars = old.hunt.chars } or nil
        local xp = type(old.xp) == "table" and { chars = old.xp.chars } or nil
        local bagsort = type(old.bagsort) == "table" and { chars = old.bagsort.chars } or nil
        local buffs = type(old.buffs) == "table" and { chars = old.buffs.chars } or nil
        BudgetForeverDB = { players = old.players, lfg = old.lfg, loot = old.loot, wheel = old.wheel, hunt = hunt,
            recipes = old.recipes, bars = old.bars, xp = xp, bagsort = bagsort, buffs = buffs,
            setcolors = old.setcolors }
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function ns:ConfirmReset()
    StaticPopupDialogs["BUDGETFOREVER_RESET"].text = L.GENERAL_RESET_CONFIRM
    StaticPopup_Show("BUDGETFOREVER_RESET")
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        self:UnregisterEvent("ADDON_LOADED")
        InitDB()
        ns.ApplyLanguage(ns.db.general.language)
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        for _, def in ipairs(ns.features) do
            local enabled = ns.db.features[def.key] == true
            enabledAtLogin[def.key] = enabled
            if enabled then Run(def, "OnEnable") end
        end
        if ns.Panel then ns.Panel:RegisterSettingsCategory() end
        if ns.db.general.loginMessage then
            ns:Print(L.LOADED:format(ns.version))
        end
    end
end)

---------------------------------------------------------------------------
-- Slash commands and addon compartment
---------------------------------------------------------------------------

SLASH_BUDGETFOREVER1 = "/bgt"
SLASH_BUDGETFOREVER2 = "/budgettools"
SLASH_BUDGETFOREVER3 = "/bf"            -- old command, still accepted
SLASH_BUDGETFOREVER4 = "/budgetforever" -- old name, still accepted
SlashCmdList.BUDGETFOREVER = function(message)
    local command, rest = strtrim(message or ""):match("^(%S*)%s*(.-)$")
    command = strlower(command or "")
    if command == "reset" then
        ns:ConfirmReset()
    elseif command == "note" and ns.NotesUI then
        -- Keeps the original case: names are case sensitive for display.
        ns.NotesUI:OpenEditor(rest ~= "" and rest or nil)
    elseif command == "lfg" and ns.LFGApply then
        ns.LFGApply.OpenEditor()
    elseif (command == "wheel" or command == "roue") and ns.MacroWheel then
        ns.MacroWheel.OpenEditor()
    elseif (command == "npc" or command == "pnj") and ns.NpcFinder then
        ns.NpcFinder.Command(rest)
    elseif (command == "item" or command == "objet") and ns.NpcFinder then
        ns.NpcFinder.ItemCommand(rest)
    elseif (command == "hunt" or command == "chasse") and ns.HuntList then
        ns.HuntList.Command(rest)
    elseif (command == "auras" or command == "aura") and ns.RaidAuras then
        ns.RaidAuras.Report()
    elseif (command == "bars" or command == "barres") and ns.BarSaver then
        ns.BarSaver.Command(rest)
    elseif command == "xp" and ns.XPRate then
        ns.XPRate.Command(rest)
    elseif (command == "trinket" or command == "trinkets" or command == "bijou" or command == "bijoux")
        and ns.TrinketBar then
        ns.TrinketBar.Command(rest)
    elseif (command == "buffs" or command == "buff") and ns.Buffs then
        ns.Buffs.Command(rest)
    elseif command == "swap" and ns.LootSwap then
        ns.LootSwap.ToggleTrace()
    elseif command == "help" or command == "?" then
        ns:Print(L.HELP_TOGGLE)
        ns:Print(L.HELP_NOTE)
        ns:Print(L.HELP_LFG)
        ns:Print(L.HELP_WHEEL)
        ns:Print(L.HELP_NPC)
        ns:Print(L.HELP_ITEM)
        ns:Print(L.HELP_HUNT)
        ns:Print(L.HELP_AURAS)
        ns:Print(L.HELP_BARS)
        ns:Print(L.HELP_XP)
        ns:Print(L.HELP_TRINKET)
        ns:Print(L.HELP_BUFFS)
        ns:Print(L.HELP_RESET)
    else
        ns.Panel:Toggle()
    end
end

function BudgetForever_OnCompartmentClick()
    ns.Panel:Toggle()
end

function BudgetForever_OnCompartmentEnter(_, button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:SetText(L.ADDON_TITLE, 1, 0.82, 0)
    GameTooltip:AddLine(L.TAGLINE, 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.COMPARTMENT_HINT, 1, 1, 1)
    GameTooltip:Show()
end

function BudgetForever_OnCompartmentLeave()
    GameTooltip:Hide()
end

---------------------------------------------------------------------------
-- Built-in categories (features register themselves in Features\*.lua)
---------------------------------------------------------------------------

-- First tab: every feature on one line (built in UI\Panel.lua).
ns:RegisterCategory({
    key = "overview",
    order = 1,
    title = "CAT_OVERVIEW",
    icon = "Interface\\Icons\\INV_Misc_Book_09",
    overview = true,
})

ns:RegisterCategory({
    key = "social",
    order = 10,
    title = "CAT_SOCIAL",
    desc = "CAT_SOCIAL_DESC",
    icon = "Interface\\Icons\\INV_Letter_15",
})

ns:RegisterCategory({
    key = "general",
    order = 1000,
    title = "CAT_GENERAL",
    desc = "CAT_GENERAL_DESC",
    icon = "Interface\\Icons\\INV_Misc_Gear_01",
    settings = true,
})
