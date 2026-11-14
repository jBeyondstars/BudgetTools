local _, ns = ...
local L, UI, Wheel = ns.L, ns.UI, ns.MacroWheel

-- Wheel setup window: the 8 slots laid out like the wheel, the key in the
-- middle. Click a slot to pick a macro or an emote, drop a macro from
-- Blizzard's macro window on it, right-click to empty it.

local EDITOR_NAME = "BudgetForeverMacroWheelEditor"
local EDITOR_ICON = "Interface\\Icons\\Trade_Engineering"
local RADIUS = 122
local ICON = 40
local CENTER_Y = 10
local BODY_LINES = 4
local MODIFIERS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, LMETA = true, RMETA = true,
}
local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local editor
local capturing = false

local function IconText(icon)
    return ("|T%s:16:16:0:0:64:64:5:59:5:59|t"):format(tostring(icon))
end

local function OpenMacroWindow()
    if ShowMacroFrame then
        if pcall(ShowMacroFrame) then return end
    end
    if not MacroFrame then
        local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        if load then pcall(load, "Blizzard_MacroUI") end
    end
    if MacroFrame then ShowUIPanel(MacroFrame) end
end

---------------------------------------------------------------------------
-- Key capture
---------------------------------------------------------------------------

local function KeyButtonText()
    if capturing then return "|cffffd200" .. L.WHEEL_KEY_WAIT .. "|r" end
    local key = Wheel.GetKey()
    if key then return L.WHEEL_KEY:format(Wheel.KeyText(key)) end
    return L.WHEEL_KEY_NONE
end

local function RefreshKey()
    if editor then editor.key:SetText(KeyButtonText()) end
end

local function StopCapture()
    capturing = false
    if editor then editor.key:EnableKeyboard(false) end
    RefreshKey()
end

local function StartCapture()
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    capturing = true
    editor.key:EnableKeyboard(true)
    if editor.key.SetPropagateKeyboardInput then editor.key:SetPropagateKeyboardInput(false) end
    RefreshKey()
end

-- "ALT-CTRL-SHIFT-F": the order WoW writes bindings in.
local function Combo(key)
    local prefix = ""
    if IsAltKeyDown() then prefix = prefix .. "ALT-" end
    if IsControlKeyDown() then prefix = prefix .. "CTRL-" end
    if IsShiftKeyDown() then prefix = prefix .. "SHIFT-" end
    if IsMetaKeyDown and IsMetaKeyDown() then prefix = prefix .. "META-" end
    return prefix .. key
end

local function Capture(key)
    capturing = false
    editor.key:EnableKeyboard(false)
    Wheel.SetKey(Combo(key))
    RefreshKey()
end

---------------------------------------------------------------------------
-- Slots
---------------------------------------------------------------------------

local function DropMacro(slot)
    local kind, index = GetCursorInfo()
    if kind ~= "macro" then return false end
    local name = GetMacroInfo(index)
    ClearCursor()
    if name then
        UI.PlayClick()
        Wheel.SetSlot(slot.index, name)
    end
    return true
end

local function OpenPicker(slot)
    if not MenuUtil or not MenuUtil.CreateContextMenu then
        OpenMacroWindow()
        return
    end
    local general, character = Wheel.ListMacros()
    local current = Wheel.GetSlots()[slot.index]
    local close = MenuResponse and MenuResponse.Close
    MenuUtil.CreateContextMenu(slot, function(_, root)
        if root.SetScrollMode then root:SetScrollMode(420) end
        local function Radio(parent, icon, name, value)
            parent:CreateRadio(IconText(icon) .. " " .. name,
                function() return Wheel.SameSlot(current, value) end,
                function()
                    Wheel.SetSlot(slot.index, value)
                    return close
                end)
        end
        -- Emotes first: five short submenus, whatever the number of macros.
        root:CreateTitle(L.WHEEL_PICK_EMOTES)
        for _, group in ipairs(Wheel.EMOTE_GROUPS) do
            local submenu = root:CreateButton(L[group.title])
            for _, token in ipairs(group) do
                local emote = Wheel.EmoteInfo(token)
                Radio(submenu, emote.icon, emote.name, { emote = token })
            end
        end
        local function AddMacros(list, title)
            if #list == 0 then return end
            root:CreateTitle(title)
            for _, macro in ipairs(list) do
                Radio(root, macro.icon, macro.name, macro.name)
            end
        end
        AddMacros(general, L.WHEEL_PICK_GENERAL)
        AddMacros(character, L.WHEEL_PICK_CHAR)
        if #general + #character == 0 then root:CreateTitle(L.WHEEL_PICK_NONE) end
        root:CreateDivider()
        if current then
            root:CreateButton(L.WHEEL_PICK_EMPTY, function() Wheel.SetSlot(slot.index, nil) end)
        end
        root:CreateButton(L.WHEEL_PICK_OPEN, OpenMacroWindow)
    end)
end

-- Name to show for a saved value whose macro (or emote) is gone.
local function MissingName(value)
    if type(value) == "table" then return tostring(value.emote) end
    return tostring(value)
end

local function SlotTooltip(slot)
    GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
    if slot.info then
        GameTooltip:SetText(slot.info.name, 1, 0.82, 0)
        if slot.info.kind == "emote" then
            GameTooltip:AddLine(L.WHEEL_KIND_EMOTE, 0.6, 0.8, 1, true)
        else
            local shown = 0
            for line in slot.info.body:gmatch("[^\n]+") do
                shown = shown + 1
                if shown > BODY_LINES then
                    GameTooltip:AddLine("...", 0.6, 0.6, 0.6)
                    break
                end
                GameTooltip:AddLine((line:gsub("|", "||")), 0.6, 0.8, 1, false)
            end
        end
    elseif slot.value then
        GameTooltip:SetText(L.WHEEL_MISSING:format(MissingName(slot.value)), 1, 0.27, 0.27, 1, true)
    else
        GameTooltip:SetText(L.WHEEL_EMPTY_SLOT, 1, 0.82, 0)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.WHEEL_SLOT_CLICK, unpack(UI.MUTED))
    GameTooltip:AddLine(L.WHEEL_SLOT_DROP, unpack(UI.MUTED))
    if slot.value then GameTooltip:AddLine(L.WHEEL_SLOT_CLEAR, unpack(UI.MUTED)) end
    GameTooltip:Show()
end

local function CreateSlot(parent, index)
    local slot = CreateFrame("Button", nil, parent)
    slot.index = index
    slot:SetSize(ICON + 8, ICON + 8)
    slot:SetPoint("CENTER", parent, "CENTER", RADIUS * Wheel.COS[index], RADIUS * Wheel.SIN[index] + CENTER_Y)
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    slot.halo = Wheel.Circle(slot, "BACKGROUND", -1, ICON + 20, 1, 0.82, 0, 0)
    slot.halo:SetPoint("CENTER")
    slot.rim = Wheel.Circle(slot, "BACKGROUND", 0, ICON + 6, 0.32, 0.32, 0.36, 1)
    slot.rim:SetPoint("CENTER")
    slot.hole = Wheel.Circle(slot, "BACKGROUND", 1, ICON, 0.04, 0.04, 0.05, 1)
    slot.hole:SetPoint("CENTER")
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetSize(ICON, ICON)
    slot.icon:SetPoint("CENTER")
    Wheel.RoundIcon(slot.icon)
    slot.plus = slot:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
    slot.plus:SetPoint("CENTER", 0, 1)
    slot.plus:SetText("+")

    slot.label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slot.label:SetPoint("TOP", slot, "BOTTOM", 0, -1)
    slot.label:SetWidth(100)
    slot.label:SetWordWrap(false)

    slot:SetScript("OnClick", function(self, button)
        if DropMacro(self) then return end
        if button == "RightButton" then
            if self.value then
                UI.PlayCheck(false)
                Wheel.SetSlot(self.index, nil)
            end
            return
        end
        UI.PlayClick()
        OpenPicker(self)
    end)
    slot:SetScript("OnReceiveDrag", DropMacro)
    slot:SetScript("OnEnter", function(self)
        self.halo:SetAlpha(0.55)
        SlotTooltip(self)
    end)
    slot:SetScript("OnLeave", function(self)
        self.halo:SetAlpha(0)
        GameTooltip:Hide()
    end)
    return slot
end

local function RefreshSlots()
    local slots = Wheel.GetSlots()
    for i, slot in ipairs(editor.slots) do
        local value = slots[i]
        local info = value ~= nil and Wheel.SlotInfo(value) or nil
        slot.value, slot.info = value, info
        slot.icon:SetDesaturated(false)
        if info then
            slot.icon:SetTexture(info.icon)
            slot.icon:Show()
            slot.plus:Hide()
            slot.label:SetText(info.name)
            slot.label:SetTextColor(1, 1, 1)
        elseif value ~= nil then
            slot.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            slot.icon:SetDesaturated(true)
            slot.icon:Show()
            slot.plus:Hide()
            slot.label:SetText(MissingName(value))
            slot.label:SetTextColor(unpack(UI.RED))
        else
            slot.icon:Hide()
            slot.plus:Show()
            slot.label:SetText("")
        end
        if slot:IsMouseOver() and GameTooltip:IsOwned(slot) then SlotTooltip(slot) end
    end
end

local function RefreshAll()
    if not editor then return end
    editor:SetWindowTitle(L.WHEEL_EDITOR_TITLE)
    RefreshSlots()
    RefreshKey()
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function Build()
    editor = UI.CreateWindow(EDITOR_NAME, 430, 500, EDITOR_ICON)
    editor:SetFrameStrata("DIALOG")
    -- Right of the center: Blizzard's macro window opens on the left.
    editor:SetPoint("CENTER", UIParent, "CENTER", 200, 30)
    editor:SetScript("OnShow", function(self)
        self:RegisterEvent("UPDATE_BINDINGS")
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    end)
    editor:SetScript("OnHide", function(self)
        self:UnregisterEvent("UPDATE_BINDINGS")
        StopCapture()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)
    editor:SetScript("OnEvent", RefreshKey)

    local hint = editor:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 66, -30)
    hint:SetPoint("TOPRIGHT", -16, -30)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(unpack(UI.MUTED))
    UI.Localize(hint, "WHEEL_EDITOR_HINT")

    local inset = UI.CreateInset(editor)
    inset:SetPoint("TOPLEFT", 6, -66)
    inset:SetPoint("BOTTOMRIGHT", -6, 40)

    local disk = Wheel.Circle(inset, "BORDER", 0, 2 * RADIUS + 64, 0, 0, 0, 0.32)
    disk:SetPoint("CENTER", 0, CENTER_Y)
    local track = Wheel.Circle(inset, "BORDER", -1, 2 * RADIUS + 68, 1, 0.82, 0, 0.18)
    track:SetPoint("CENTER", 0, CENTER_Y)

    editor.slots = {}
    for i = 1, Wheel.SLOTS do
        editor.slots[i] = CreateSlot(inset, i)
    end

    local key = CreateFrame("Button", nil, inset, "UIPanelButtonTemplate")
    key:SetSize(140, 26)
    key:SetPoint("CENTER", 0, CENTER_Y)
    key:RegisterForClicks("AnyUp")
    key:SetScript("OnClick", function(_, button)
        if capturing then
            if MOUSE_KEYS[button] then
                Capture(MOUSE_KEYS[button])
            else
                StopCapture()
            end
            return
        end
        if button == "RightButton" then
            Wheel.ClearKey()
            RefreshKey()
            return
        end
        if button == "LeftButton" then
            UI.PlayClick()
            StartCapture()
        end
    end)
    key:SetScript("OnKeyDown", function(_, pressed)
        if not capturing then return end
        if pressed == "ESCAPE" then
            StopCapture()
        elseif not MODIFIERS[pressed] then
            Capture(pressed)
        end
    end)
    key:SetScript("OnEnter", function(self)
        UI.ShowTooltip(self, L.WHEEL_BINDING, L.WHEEL_KEY_TIP)
    end)
    key:SetScript("OnLeave", function() GameTooltip:Hide() end)
    editor.key = key

    local footer = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", 14, 10)
    footer:SetPoint("BOTTOMRIGHT", -14, 10)
    footer:SetJustifyH("CENTER")
    UI.Localize(footer, "WHEEL_EDITOR_FOOTER")

    local macros = UI.CreateButton(editor, "WHEEL_MACROS", 130)
    macros:SetPoint("BOTTOMLEFT", 8, 7)
    macros:SetScript("OnClick", function()
        UI.PlayClick()
        OpenMacroWindow()
    end)

    local done = UI.CreateButton(editor, "WHEEL_DONE", 110)
    done:SetPoint("BOTTOMRIGHT", -8, 7)
    done:SetScript("OnClick", function() editor:Hide() end)
end

function Wheel.OpenEditor()
    if not editor then Build() end
    RefreshAll()
    editor:Show()
    editor:Raise()
end

function Wheel.CloseEditor()
    if editor then editor:Hide() end
end

ns:On("WHEEL_CHANGED", function()
    if editor and editor:IsShown() then RefreshAll() end
end)

ns:On("LANGUAGE_CHANGED", RefreshAll)
