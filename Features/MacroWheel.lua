local _, ns = ...
local L, UI, Util = ns.L, ns.UI, ns.Util

-- Macro & emote wheel: hold a key and a wheel of up to 8 macros or emotes
-- opens around the cursor; move toward one and release to use it. A short
-- press keeps the wheel open: a click in a direction uses that slot, a
-- right-click closes.
--
-- Running a macro and showing a frame in combat need secure code, so the
-- wheel is driven by restricted snippets (SecureHandlerWrapScript):
--   * TRIGGER: the button the key clicks ("CLICK BudgetForeverMacroWheel:LeftButton").
--     Key down opens the wheel; key up picks the slot in the mouse direction
--     and renames the click "w<n>", so the button runs its "*macro-w<n>", or
--     for an emote its "*type-w<n>" = "bfemote": Blizzard then calls the
--     button's own bfemote function (inside securecall), which does DoEmote.
--   * CATCHER: a full-screen button shown with the open wheel, for the click
--     after a short press.
-- Everything the player sees (icons, highlight) is drawn by normal code.

local KEY = "macroWheel"
local SLOTS = 8
local TRIGGER_NAME = "BudgetForeverMacroWheel"
local BINDING = "CLICK " .. TRIGGER_NAME .. ":LeftButton"
local RADIUS = 110        -- center of the wheel to the center of an icon
local ICON = 44
local DEAD = 28           -- around the center: no macro picked
local MARGIN = RADIUS + 50
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local QUESTION = 134400   -- INV_Misc_QuestionMark: a macro whose icon is chosen by #showtooltip
local EMOTE_ACTION = "bfemote" -- custom action type of an emote slot

-- Emotes the wheel can hold, by group. DoEmote takes the token, which is the
-- same in every client language; the label is ours (locale key EMOTE_<token>).
local EMOTE_GROUPS = {
    { title = "WHEEL_GROUP_GREET", "WAVE", "HELLO", "BYE", "BOW", "SALUTE", "THANK", "WELCOME", "HUG" },
    { title = "WHEEL_GROUP_FUN", "DANCE", "LAUGH", "CHEER", "APPLAUD", "FLEX", "ROAR", "CHICKEN", "KISS",
        "FLIRT", "JOKE", "SILLY" },
    { title = "WHEEL_GROUP_REACT", "YES", "NO", "SHRUG", "CRY", "SIGH", "POINT", "RUDE", "VICTORY" },
    { title = "WHEEL_GROUP_POSE", "SIT", "KNEEL", "SLEEP", "PRAY" },
    { title = "WHEEL_GROUP_CALLS", "HEALME", "OOM", "HELPME", "INCOMING", "CHARGE", "FLEE", "FOLLOW", "WAIT",
        "OPENFIRE", "ATTACKMYTARGET" },
}

-- A bare name is in Interface\Icons.
local EMOTE_ICONS = {
    WAVE = "INV_Gauntlets_04",
    HELLO = "Spell_Holy_HolyBolt",
    BYE = "Spell_Nature_Invisibilty",
    BOW = "Ability_Druid_Cower",
    SALUTE = "Ability_Warrior_BattleShout",
    THANK = "Spell_Holy_Renew",
    WELCOME = "Spell_Holy_Heal",
    HUG = "Spell_Nature_Rejuvenation",
    DANCE = "INV_Misc_Ribbon_01",
    LAUGH = "Spell_Holy_FlashHeal",
    CHEER = "Ability_Warrior_WarCry",
    APPLAUD = "Spell_Holy_WordFortitude",
    FLEX = "Ability_Warrior_DefensiveStance",
    ROAR = "Ability_Druid_DemoralizingRoar",
    CHICKEN = "Spell_Nature_Polymorph",
    KISS = "Spell_Shadow_Charm",
    FLIRT = "Spell_Holy_MindVision",
    JOKE = "INV_Misc_Book_09",
    SILLY = "INV_Misc_Note_01",
    YES = "Interface\\RaidFrame\\ReadyCheck-Ready",
    NO = "Interface\\RaidFrame\\ReadyCheck-NotReady",
    SHRUG = "Interface\\RaidFrame\\ReadyCheck-Waiting",
    CRY = "Spell_Shadow_PsychicScream",
    SIGH = "Spell_Nature_ManaRegenTotem",
    POINT = "Ability_Hunter_Pathfinding",
    RUDE = "Ability_Warrior_Disarm",
    VICTORY = "INV_Misc_Head_Dragon_01",
    SIT = "INV_Misc_Food_15",
    KNEEL = "Spell_Holy_SealOfSalvation",
    SLEEP = "Spell_Nature_Sleep",
    PRAY = "Spell_Holy_PrayerOfHealing02",
    HEALME = "Spell_Holy_GreaterHeal",
    OOM = "INV_Drink_07",
    HELPME = "Spell_Holy_PowerWordShield",
    INCOMING = "Ability_Hunter_SniperShot",
    CHARGE = "Ability_Warrior_Charge",
    FLEE = "Ability_Rogue_Sprint",
    FOLLOW = "Ability_Tracking",
    WAIT = "INV_Misc_PocketWatch_01",
    OPENFIRE = "Spell_Fire_FlameBolt",
    ATTACKMYTARGET = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_8",
}

local Wheel = {}
ns.MacroWheel = Wheel
Wheel.SLOTS = SLOTS
Wheel.BINDING = BINDING
Wheel.TRIGGER_NAME = TRIGGER_NAME
Wheel.MASK = MASK
Wheel.EMOTE_GROUPS = EMOTE_GROUPS

-- Slot 1 points up, then clockwise every 45 degrees. Rounded so that the
-- restricted code (which gets them as text) and the highlight use the very
-- same numbers.
local COS, SIN = {}, {}
local function Round(value) return tonumber(("%.5f"):format(value)) end
for i = 1, SLOTS do
    local angle = math.rad(90 - (i - 1) * 360 / SLOTS)
    COS[i], SIN[i] = Round(math.cos(angle)), Round(math.sin(angle))
end
local TIE = 0.001 -- exactly between two slots: the first one wins, in both codes
Wheel.COS, Wheel.SIN = COS, SIN

-- What the wheel uses right now. Only Rebuild changes entries and tokens, out
-- of combat, so they always match the secure attributes.
local entries = {}        -- slot -> saved value (macro name or { emote = token }), false = empty
local tokens = {}         -- slot -> emote token, nil for a macro or an empty slot
local labels = {}         -- slot -> name shown in the middle ("" = empty)
for i = 1, SLOTS do entries[i], labels[i] = false, "" end
local count = 0           -- filled slots
local dirty = false       -- changed during combat: rebuild after it

---------------------------------------------------------------------------
-- Saved slots, per character (character macros differ between them)
---------------------------------------------------------------------------

function Wheel.GetSlots()
    if not ns.db then return {} end
    ns.db.wheel = ns.db.wheel or {}
    local key = Util.CharacterKey(ns.db.wheel)
    ns.db.wheel[key] = ns.db.wheel[key] or { slots = {} }
    return ns.db.wheel[key].slots
end

-- value: a macro name, { emote = token }, or nil to empty the slot.
function Wheel.SetSlot(index, value)
    local slots = Wheel.GetSlots()
    if type(value) == "table" then
        value = type(value.emote) == "string" and { emote = value.emote } or nil
    elseif type(value) ~= "string" or value == "" then
        value = nil
    end
    slots[index] = value
    Wheel.Rebuild()
    ns:Fire("WHEEL_CHANGED")
end

-- Same content: two emote tables are equal when their token is.
function Wheel.SameSlot(a, b)
    if type(a) == "table" and type(b) == "table" then return a.emote == b.emote end
    return a == b
end

---------------------------------------------------------------------------
-- Macros
---------------------------------------------------------------------------

local function SpellIcon(spell)
    if C_Spell and C_Spell.GetSpellTexture then
        local ok, icon = pcall(C_Spell.GetSpellTexture, spell)
        if ok and icon then return icon end
    end
    if GetSpellTexture then
        local ok, icon = pcall(GetSpellTexture, spell)
        if ok and icon then return icon end
    end
end

local function ItemIcon(item)
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not instant then return end
    local ok, _, _, _, _, icon = pcall(instant, item)
    if ok then return icon end
end

-- index, name, icon, body of a macro, by name. The icon of a #showtooltip
-- macro is the spell or item it would use right now.
function Wheel.MacroInfo(name)
    if type(name) ~= "string" or name == "" or not GetMacroIndexByName then return end
    local index = GetMacroIndexByName(name)
    if not index or index == 0 then return end
    local macroName, icon, body = GetMacroInfo(index)
    if not macroName then return end
    if not icon or icon == QUESTION or icon == "Interface\\Icons\\INV_Misc_QuestionMark" then
        local spell = GetMacroSpell and GetMacroSpell(index)
        local item = not spell and GetMacroItem and GetMacroItem(index)
        icon = (spell and SpellIcon(spell)) or (item and ItemIcon(item)) or icon
    end
    return { index = index, name = macroName, icon = icon or QUESTION, body = body or "" }
end

-- Every macro of the account (general) and of this character.
function Wheel.ListMacros()
    local general, character = {}, {}
    if not GetNumMacros then return general, character end
    local numGeneral, numCharacter = GetNumMacros()
    local first = MAX_ACCOUNT_MACROS or 120
    for index = 1, numGeneral or 0 do
        local name, icon = GetMacroInfo(index)
        if name then general[#general + 1] = { index = index, name = name, icon = icon or QUESTION } end
    end
    for index = first + 1, first + (numCharacter or 0) do
        local name, icon = GetMacroInfo(index)
        if name then character[#character + 1] = { index = index, name = name, icon = icon or QUESTION } end
    end
    return general, character
end

---------------------------------------------------------------------------
-- Emotes
---------------------------------------------------------------------------

function Wheel.EmoteInfo(token)
    local icon = type(token) == "string" and EMOTE_ICONS[token]
    if not icon then return end
    if not icon:find("\\", 1, true) then icon = "Interface\\Icons\\" .. icon end
    return { kind = "emote", token = token, name = L["EMOTE_" .. token], icon = icon }
end

-- DoEmote is not protected: an emote works in combat, on the current target.
local function PerformEmote(token)
    if DoEmote then
        DoEmote(token)
    elseif C_ChatInfo and C_ChatInfo.PerformEmote then
        C_ChatInfo.PerformEmote(token)
    end
end

-- The bfemote action of both secure buttons: the click was renamed "w<n>".
local function RunEmote(_, _, button)
    local index = tonumber(tostring(button):match("^w(%d+)$"))
    local token = index and tokens[index]
    if token then PerformEmote(token) end
end

-- What a saved slot holds, for display: kind ("macro" or "emote"), name, icon
-- (+ index and body for a macro). nil when the macro no longer exists.
function Wheel.SlotInfo(value)
    if type(value) == "table" then return Wheel.EmoteInfo(value.emote) end
    local info = Wheel.MacroInfo(value)
    if info then info.kind = "macro" end
    return info
end

---------------------------------------------------------------------------
-- Secure part
---------------------------------------------------------------------------

-- Restricted code shared by both snippets: `pick` = the slot in the mouse
-- direction from the center (CX, CY), nil inside the dead zone.
local PICK = [[
    local pick
    local mx, my = screen:GetMousePosition()
    if mx then
        local dx, dy = mx * screen:GetWidth() - CX, my * screen:GetHeight() - CY
        if dx * dx + dy * dy >= DEAD2 then
            local best
            for i = 1, SLOTS do
                if FILLED[i] then
                    local dot = dx * COS[i] + dy * SIN[i]
                    if not best or dot > best + TIE then best, pick = dot, i end
                end
            end
        end
    end
]]

-- Pre-click of the key's button (self, button, down; owner = the wheel).
local TRIGGER_SNIPPET = [[
    if not ENABLED or COUNT == 0 then return false end
    if down then
        if owner:IsShown() then
            owner:Hide()
            CLOSING = true
            return false
        end
        CLOSING = false
        local mx, my = screen:GetMousePosition()
        local w, h = screen:GetWidth(), screen:GetHeight()
        local x, y = (mx or 0.5) * w, (my or 0.5) * h
        if x < MARGIN then x = MARGIN elseif x > w - MARGIN then x = w - MARGIN end
        if y < MARGIN then y = MARGIN elseif y > h - MARGIN then y = h - MARGIN end
        CX, CY = x, y
        owner:ClearAllPoints()
        owner:SetPoint("CENTER", screen, "BOTTOMLEFT", x, y)
        owner:Show()
        return false
    end
    if CLOSING then
        CLOSING = false
        return false
    end
    if not owner:IsShown() then return false end
]] .. PICK .. [[
    if not pick then return false end
    owner:Hide()
    return "w" .. pick
]]

-- Pre-click of the full-screen button while the wheel stays open.
local CATCHER_SNIPPET = [[
    if button == "RightButton" or not owner:IsShown() then
        owner:Hide()
        return false
    end
]] .. PICK .. [[
    if not pick then
        owner:Hide()
        return false
    end
    return "w" .. pick, "hide"
]]

local CATCHER_POST = [[ owner:Hide() ]]

Wheel.PICK, Wheel.TRIGGER_SNIPPET, Wheel.CATCHER_SNIPPET = PICK, TRIGGER_SNIPPET, CATCHER_SNIPPET

local ring, screen, trigger, catcher
local slices = {}

local function Number(value)
    return ("%.5f"):format(value)
end

local function SetupSecure()
    -- The whole screen, to read the mouse position in restricted code.
    screen = CreateFrame("Frame", nil, UIParent, "SecureHandlerBaseTemplate")
    screen:SetAllPoints(UIParent)

    ring = CreateFrame("Frame", "BudgetForeverMacroWheelRing", UIParent, "SecureHandlerBaseTemplate")
    ring:SetSize(2 * (RADIUS + 50), 2 * (RADIUS + 50))
    ring:SetPoint("CENTER")
    ring:SetFrameStrata("FULLSCREEN_DIALOG")
    ring:Hide()

    catcher = CreateFrame("Button", nil, ring, "SecureActionButtonTemplate")
    catcher:SetAllPoints(UIParent)
    catcher:RegisterForClicks("AnyUp")
    catcher:SetAttribute("type", "macro")
    catcher:SetAttribute("useOnKeyDown", false)

    -- Clicked by the key binding. Shown (bindings click it) but invisible.
    trigger = CreateFrame("Button", TRIGGER_NAME, UIParent, "SecureActionButtonTemplate")
    trigger:SetSize(1, 1)
    trigger:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10, -10)
    trigger:EnableMouse(false)
    trigger:RegisterForClicks("AnyDown", "AnyUp")
    trigger:SetAttribute("type", "macro")
    trigger:SetAttribute("useOnKeyDown", false)

    local cos, sin = {}, {}
    for i = 1, SLOTS do
        cos[i], sin[i] = Number(COS[i]), Number(SIN[i])
    end
    SecureHandlerSetFrameRef(ring, "screen", screen)
    SecureHandlerExecute(ring, ([[
        screen = self:GetFrameRef("screen")
        SLOTS = %d
        COS = newtable(%s)
        SIN = newtable(%s)
        DEAD2 = %d
        MARGIN = %d
        TIE = %s
        CX, CY = 0, 0
        ENABLED = false
        COUNT = 0
        FILLED = newtable(%s)
    ]]):format(SLOTS, table.concat(cos, ", "), table.concat(sin, ", "), DEAD * DEAD, MARGIN, Number(TIE),
        ("false, "):rep(SLOTS - 1) .. "false"))

    -- Custom action type of the emote slots (looked up with rawget).
    trigger[EMOTE_ACTION] = RunEmote
    catcher[EMOTE_ACTION] = RunEmote

    SecureHandlerWrapScript(trigger, "OnClick", ring, TRIGGER_SNIPPET)
    SecureHandlerWrapScript(catcher, "OnClick", ring, CATCHER_SNIPPET, CATCHER_POST)

    -- After the wraps: hooks added before a script change are lost.
    trigger:HookScript("OnClick", function(_, _, down)
        if down and ns:IsEnabled(KEY) and count == 0 then ns:Print(L.WHEEL_EMPTY) end
    end)
end

---------------------------------------------------------------------------
-- What the player sees
---------------------------------------------------------------------------

-- A filled circle: the round mask itself, tinted.
local function Circle(parent, layer, sublevel, size, r, g, b, a)
    local texture = parent:CreateTexture(nil, layer, nil, sublevel)
    texture:SetTexture(MASK)
    texture:SetSize(size, size)
    texture:SetVertexColor(r, g, b, a)
    return texture
end
Wheel.Circle = Circle

function Wheel.RoundIcon(texture)
    if texture.SetMask then
        if pcall(texture.SetMask, texture, MASK) then return end
    end
    local parent = texture:GetParent()
    if parent and parent.CreateMaskTexture and texture.AddMaskTexture then
        local mask = parent:CreateMaskTexture()
        mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(texture)
        texture:AddMaskTexture(mask)
    end
end

local hubText
local selected

local function BuildVisuals()
    local size = 2 * (RADIUS + 38)
    local edge = Circle(ring, "BACKGROUND", -2, size + 4, 1, 0.82, 0, 0.35)
    edge:SetPoint("CENTER")
    local disk = Circle(ring, "BACKGROUND", -1, size, 0.02, 0.02, 0.03, 0.72)
    disk:SetPoint("CENTER")

    local hubEdge = Circle(ring, "BORDER", 0, 84, 1, 0.82, 0, 0.55)
    hubEdge:SetPoint("CENTER")
    local hub = Circle(ring, "BORDER", 1, 80, 0.06, 0.06, 0.07, 0.96)
    hub:SetPoint("CENTER")
    hubText = ring:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    hubText:SetPoint("CENTER")
    hubText:SetWidth(70)
    hubText:SetWordWrap(true)
    if hubText.SetMaxLines then hubText:SetMaxLines(3) end

    for i = 1, SLOTS do
        local x, y = RADIUS * COS[i], RADIUS * SIN[i]
        local slice = {}
        slice.halo = Circle(ring, "ARTWORK", 0, ICON + 22, 1, 0.82, 0, 0)
        slice.halo:SetPoint("CENTER", ring, "CENTER", x, y)
        slice.rim = Circle(ring, "ARTWORK", 1, ICON + 6, 0.32, 0.32, 0.36, 1)
        slice.rim:SetPoint("CENTER", ring, "CENTER", x, y)
        slice.icon = ring:CreateTexture(nil, "ARTWORK", nil, 2)
        slice.icon:SetSize(ICON, ICON)
        slice.icon:SetPoint("CENTER", ring, "CENTER", x, y)
        Wheel.RoundIcon(slice.icon)
        slice.label = ring:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        slice.label:SetPoint("TOP", slice.icon, "BOTTOM", 0, -4)
        slice.label:SetWidth(96)
        slice.label:SetWordWrap(false)
        slice.label:SetShadowOffset(1, -1)
        slices[i] = slice
    end
end

local function ShowSlice(slice, shown)
    -- Alpha, not Show/Hide: also safe while the wheel is open in combat.
    local alpha = shown and 1 or 0
    if not shown then slice.halo:SetAlpha(0) end
    slice.rim:SetAlpha(alpha)
    slice.icon:SetAlpha(alpha)
    slice.label:SetAlpha(shown and ns:GetOption(KEY, "showNames") and 1 or 0)
end

local function Highlight(index)
    selected = index
    for i, slice in ipairs(slices) do
        local on = i == index
        slice.halo:SetAlpha(on and 0.85 or 0)
        if on then
            slice.rim:SetVertexColor(1, 0.82, 0, 1)
        else
            slice.rim:SetVertexColor(0.32, 0.32, 0.36, 1)
        end
        local shade = (index and not on) and 0.7 or 1
        slice.icon:SetVertexColor(shade, shade, shade)
        if labels[i] == "" then ShowSlice(slice, false) end
    end
    if index then
        hubText:SetText(labels[index])
        hubText:SetTextColor(1, 0.82, 0)
    else
        hubText:SetText(L.WHEEL_HUB)
        hubText:SetTextColor(unpack(UI.MUTED))
    end
end

-- Same rule as the restricted PICK: the slot whose direction is closest.
function Wheel.PickAt(dx, dy)
    if dx * dx + dy * dy < DEAD * DEAD then return end
    local best, pick
    for i = 1, SLOTS do
        if entries[i] then
            local dot = dx * COS[i] + dy * SIN[i]
            if not best or dot > best + TIE then best, pick = dot, i end
        end
    end
    return pick
end

local function OnUpdate(self)
    local cx, cy = self:GetCenter()
    if not cx then return end
    local scale = self:GetEffectiveScale()
    local x, y = GetCursorPosition()
    local pick = Wheel.PickAt(x / scale - cx, y / scale - cy)
    if pick ~= selected then Highlight(pick) end
end

-- Icons follow the macros (#showtooltip changes with the target or form),
-- emote names follow the language.
local function RefreshVisuals()
    for i, slice in ipairs(slices) do
        local info = entries[i] and Wheel.SlotInfo(entries[i])
        if info then
            slice.icon:SetTexture(info.icon)
            slice.label:SetText(info.name)
        end
        labels[i] = info and info.name or ""
        ShowSlice(slice, info and true or false)
    end
    Highlight(nil)
end

---------------------------------------------------------------------------
-- Building the wheel from the saved slots
---------------------------------------------------------------------------

local events = CreateFrame("Frame")

function Wheel.Rebuild()
    if not ns.db or not ring then return end
    if InCombatLockdown() then
        if not dirty then ns:Print(L.WHEEL_COMBAT_LATER) end
        dirty = true
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    dirty = false

    local enabled = ns:IsEnabled(KEY)
    local slots = Wheel.GetSlots()
    local filled = {}
    count = 0
    for i = 1, SLOTS do
        local value = slots[i]
        local info = enabled and value ~= nil and Wheel.SlotInfo(value)
        entries[i] = info and value or false
        tokens[i] = info and info.kind == "emote" and info.token or nil
        if info then count = count + 1 end
        filled[i] = info and "true" or "false"
        -- A macro slot falls back to type = "macro"; an emote slot overrides it.
        local action = tokens[i] and EMOTE_ACTION or nil
        local macro = info and info.kind == "macro" and info.name or nil
        trigger:SetAttribute("*type-w" .. i, action)
        catcher:SetAttribute("*type-w" .. i, action)
        trigger:SetAttribute("*macro-w" .. i, macro)
        catcher:SetAttribute("*macro-w" .. i, macro)
    end
    SecureHandlerExecute(ring, ("ENABLED = %s COUNT = %d FILLED = newtable(%s)"):format(
        enabled and "true" or "false", count, table.concat(filled, ", ")))
    if not enabled then ring:Hide() end
    RefreshVisuals()
end

function Wheel.Count()
    return count
end

---------------------------------------------------------------------------
-- Key binding
---------------------------------------------------------------------------

function Wheel.GetKey()
    return GetBindingKey and GetBindingKey(BINDING)
end

function Wheel.KeyText(key)
    if not key then return end
    if GetBindingText then
        local ok, text = pcall(GetBindingText, key)
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

function Wheel.SetKey(key)
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
        ns:Print(L.WHEEL_KEY_REPLACED:format(Wheel.KeyText(key), _G["BINDING_NAME_" .. old] or old))
    else
        ns:Print(L.WHEEL_KEY_SET:format(Wheel.KeyText(key)))
    end
    ns:Fire("WHEEL_CHANGED")
    return true
end

function Wheel.ClearKey()
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    if not Wheel.GetKey() then return false end
    ClearKeys()
    SaveBindings(GetCurrentBindingSet())
    ns:Print(L.WHEEL_KEY_CLEARED)
    ns:Fire("WHEEL_CHANGED")
    return true
end

-- Names in Blizzard's Key Bindings window (Bindings.xml).
local function BindingNames()
    _G.BINDING_HEADER_BUDGETFOREVER = L.ADDON_TITLE
    _G["BINDING_NAME_" .. BINDING] = L.WHEEL_BINDING
end

---------------------------------------------------------------------------
-- Enable / disable
---------------------------------------------------------------------------

events:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_ENABLED" then
        events:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if dirty then Wheel.Rebuild() end
    elseif event == "UPDATE_MACROS" then
        Wheel.Rebuild()
        ns:Fire("WHEEL_CHANGED")
    end
end)

local function Enable()
    events:RegisterEvent("UPDATE_MACROS")
    Wheel.Rebuild()
end

local function Disable()
    events:UnregisterEvent("UPDATE_MACROS")
    Wheel.Rebuild()
    if Wheel.CloseEditor then Wheel.CloseEditor() end
end

SetupSecure()
BuildVisuals()
ring:SetScript("OnUpdate", OnUpdate)
ring:HookScript("OnShow", function()
    RefreshVisuals()
    UI.PlayClick()
end)
BindingNames()

ns:On("OPTION_CHANGED", function(key)
    if key == KEY then RefreshVisuals() end
end)

ns:On("LANGUAGE_CHANGED", function()
    BindingNames()
    RefreshVisuals()
end)

ns:RegisterCategory({
    key = "actions",
    order = 25,
    title = "CAT_ACTIONS",
    desc = "CAT_ACTIONS_DESC",
    icon = "Interface\\Icons\\Trade_Engineering",
})

ns:RegisterFeature({
    key = KEY,
    category = "actions",
    order = 10,
    title = "WHEEL_TITLE",
    desc = "WHEEL_DESC",
    tip = "WHEEL_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "showNames", title = "WHEEL_OPT_NAMES", tip = "WHEEL_OPT_NAMES_TIP", default = true },
        { key = "configure", title = "WHEEL_OPT_EDIT", tip = "WHEEL_OPT_EDIT_TIP", action = function() Wheel.OpenEditor() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
