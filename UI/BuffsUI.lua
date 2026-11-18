local _, ns = ...
local L, UI, Buffs = ns.L, ns.UI, ns.Buffs

-- Buff sequences window. Top line: the sequence menu (pick, new, rename,
-- delete), its key, and its icon to drag onto an action bar. Then the class
-- buffs in casting order, each with its tick, its rank and two arrows. The
-- bottom line says what the next press will do. Logic in Features\Buffs.lua.

local WINDOW_NAME = "BudgetForeverBuffs"
local WINDOW_ICON = "Interface\\Icons\\Spell_Holy_WordFortitude"
local WIDTH = 460
local ROW_HEIGHT = 30   -- row pitch; rows are 4px shorter for a gap
local TOP = 112         -- rows start under the hint and the sequence line
local MODIFIERS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, LMETA = true, RMETA = true,
}
local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local ROW_BG = { 0, 0, 0, 0.28 }
local ROW_BG_HOVER = { 0.08, 0.07, 0.03, 0.45 }
local ROW_BORDER = { 1, 1, 1, 0.06 }
local ROW_BORDER_HOVER = { 1, 0.82, 0, 0.45 }

local BuffsUI = {}
ns.BuffsUI = BuffsUI

local window
local rows = {}
local capturing = false
local Refresh

local function Seq()
    return (Buffs.Current())
end

---------------------------------------------------------------------------
-- Rename and delete popups
---------------------------------------------------------------------------

local function PopupEditBox(popup)
    return popup.editBox or popup.EditBox or (popup.GetEditBox and popup:GetEditBox())
end

StaticPopupDialogs["BUDGETFOREVER_BUFFS_RENAME"] = {
    text = "",
    button1 = ACCEPT,
    button2 = CANCEL,
    hasEditBox = 1,
    maxLetters = 32,
    OnShow = function(self, seq)
        local box = PopupEditBox(self)
        if box and seq then
            box:SetText(seq.name)
            box:HighlightText()
            box:SetFocus()
        end
    end,
    OnAccept = function(self, seq)
        local box = PopupEditBox(self)
        if box and seq then Buffs.Rename(seq, box:GetText()) end
    end,
    EditBoxOnEnterPressed = function(self, seq)
        if seq then Buffs.Rename(seq, self:GetText()) end
        self:GetParent():Hide()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["BUDGETFOREVER_BUFFS_DELETE"] = {
    text = "",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, seq) if seq then Buffs.Delete(seq) end end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function AskRename(seq)
    StaticPopupDialogs["BUDGETFOREVER_BUFFS_RENAME"].text = L.BUFFS_SEQ_RENAME_ASK
    StaticPopup_Show("BUDGETFOREVER_BUFFS_RENAME", nil, nil, seq)
end

local function AskDelete(seq)
    StaticPopupDialogs["BUDGETFOREVER_BUFFS_DELETE"].text = L.BUFFS_SEQ_DELETE_ASK
    StaticPopup_Show("BUDGETFOREVER_BUFFS_DELETE", seq.name, nil, seq)
end

---------------------------------------------------------------------------
-- Icon picker: Blizzard's own (the grid of the Macros window, driven the
-- way the equipment manager drives it), with the sequence's name on top.
---------------------------------------------------------------------------

local picker

local function BuildPicker()
    if picker ~= nil then return picker end
    picker = false
    if not UI.HasTemplate("IconSelectorPopupFrameTemplate") or not IconDataProviderMixin
        or not IconSelectorPopupFrameTemplateMixin then
        return picker
    end
    local frame = CreateFrame("Frame", "BudgetForeverBuffsIconPicker", window, "IconSelectorPopupFrameTemplate")
    frame:Hide()
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", window, "TOPRIGHT", 0, 0)
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    -- The template puts the grid in the HIGH strata, over a BorderBox at
    -- level 50. In our DIALOG window the BorderBox (and its shaded
    -- background) ended up over the grid and dimmed it (seen in game): the
    -- grid goes back above it, in the same strata.
    frame.IconSelector:SetFrameStrata(frame:GetFrameStrata())
    frame.IconSelector:SetFrameLevel(frame.BorderBox:GetFrameLevel() + 10)
    frame.BorderBox.EditBoxHeaderText:SetText(L.BUFFS_ICON_NAME)
    frame.BorderBox.IconSelectorEditBox:SetMaxLetters(32)

    -- The template's OnShow / OnHide scripts are bound when the frame is
    -- created, so overriding those methods afterwards does nothing (seen in
    -- game: empty grid). The icon list is filled after Show instead, with
    -- the calls of Blizzard's GearManagerPopupFrameMixin.
    frame:HookScript("OnHide", function(self)
        if self.iconDataProvider then
            self.iconDataProvider:Release()
            self.iconDataProvider = nil
        end
        self.seq = nil
    end)

    -- OkayButton's click calls self:OkayButton_OnClick() at click time, so
    -- this one does take over.
    function frame:OkayButton_OnClick()
        local seq = self.seq
        local icon = self.BorderBox.SelectedIconArea.SelectedIconButton:GetIconTexture()
        local name = self.BorderBox.IconSelectorEditBox:GetText()
        IconSelectorPopupFrameTemplateMixin.OkayButton_OnClick(self)
        if not seq then return end
        Buffs.Rename(seq, name)
        Buffs.SetIcon(seq, icon)
    end

    picker = frame
    return picker
end

local function FillPicker(frame)
    local seq = frame.seq
    if not seq then return end
    if not frame.iconDataProvider then
        frame.iconDataProvider = CreateAndInitFromMixin(IconDataProviderMixin, IconDataProviderExtraType.Spellbook)
    end
    frame:SetIconFilter(IconSelectorPopupFrameIconFilterTypes.All)

    local icon = Buffs.Icon(seq)
    local box = frame.BorderBox.IconSelectorEditBox
    box:SetText(seq.name)
    box:HighlightText()
    box:OnTextChanged()
    frame.IconSelector:SetSelectedIndex(frame:GetIndexOfIcon(icon))
    frame.BorderBox.SelectedIconArea.SelectedIconButton:SetIconTexture(icon)
    frame.IconSelector:SetSelectionsDataProvider(GenerateClosure(frame.GetIconByIndex, frame),
        GenerateClosure(frame.GetNumIcons, frame))
    frame.IconSelector:ScrollToSelectedIndex()
    frame:SetSelectedIconText()
    frame.IconSelector:SetSelectedCallback(function(_, chosen)
        frame.BorderBox.SelectedIconArea.SelectedIconButton:SetIconTexture(chosen)
        frame:SetSelectedIconText()
    end)
end

local function OpenIconPicker()
    local seq = Seq()
    if not seq then return end
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    local frame = BuildPicker()
    if not frame then
        ns:Error(L.BUFFS_ICON_MISSING)
        return
    end
    if frame:IsShown() then frame:Hide() end
    frame:Show()
    frame.seq = seq
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    xpcall(FillPicker, geterrorhandler(), frame)
end

---------------------------------------------------------------------------
-- Sequence menu
---------------------------------------------------------------------------

local function SequenceLabel(seq)
    local key = Buffs.GetKey(seq)
    if key then return seq.name .. "  |cff999999(" .. Buffs.KeyText(key) .. ")|r" end
    return seq.name
end

local function OpenSequenceMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    local refresh = MenuResponse and MenuResponse.Refresh
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.BUFFS_SEQ_MENU)
        local _, current = Buffs.Current()
        for index, seq in ipairs(Buffs.Sequences()) do
            root:CreateRadio(SequenceLabel(seq),
                function() return index == current end,
                function()
                    Buffs.Select(index)
                    return refresh
                end)
        end
        root:CreateDivider()
        local new = root:CreateButton(L.BUFFS_SEQ_NEW_BUTTON, function() Buffs.NewSequence() end)
        if new and new.SetEnabled then new:SetEnabled(Buffs.CanCreate()) end
        root:CreateButton(L.BUFFS_SEQ_RENAME, function() AskRename(Seq()) end)
        root:CreateButton(L.BUFFS_ICON_CHOOSE, function() OpenIconPicker() end)
        local delete = root:CreateButton(L.BUFFS_SEQ_DELETE, function() AskDelete(Seq()) end)
        if delete and delete.SetEnabled then delete:SetEnabled(#Buffs.Sequences() > 1) end
    end)
end

local function CreateSequenceButton(parent)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(160, 26)
    button:SetScript("OnClick", function(self)
        UI.PlayClick()
        OpenSequenceMenu(self)
    end)
    button:SetScript("OnEnter", function(self) UI.ShowTooltip(self, L.BUFFS_SEQ_MENU, L.BUFFS_SEQ_TIP) end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

---------------------------------------------------------------------------
-- Key capture: a single key, modifiers are ignored on purpose
---------------------------------------------------------------------------

local function KeyButtonText()
    if capturing then return "|cffffd200" .. L.WHEEL_KEY_WAIT .. "|r" end
    local key = Buffs.GetKey(Seq())
    if key then return L.WHEEL_KEY:format(Buffs.KeyText(key)) end
    return L.WHEEL_KEY_NONE
end

local function RefreshKey()
    if window then window.key:SetText(KeyButtonText()) end
end

local function StopCapture()
    capturing = false
    if window then window.key:EnableKeyboard(false) end
    RefreshKey()
end

local function StartCapture()
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return
    end
    capturing = true
    window.key:EnableKeyboard(true)
    if window.key.SetPropagateKeyboardInput then window.key:SetPropagateKeyboardInput(false) end
    RefreshKey()
end

local function Capture(key)
    capturing = false
    window.key:EnableKeyboard(false)
    Buffs.SetKey(Seq(), key)
    RefreshKey()
end

local function CreateKeyButton(parent)
    local key = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    key:SetSize(150, 26)
    key:RegisterForClicks("AnyUp")
    key:SetScript("OnClick", function(_, button)
        if capturing then
            if MOUSE_KEYS[button] then Capture(MOUSE_KEYS[button]) else StopCapture() end
            return
        end
        if button == "RightButton" then
            Buffs.ClearKey(Seq())
            RefreshKey()
        elseif button == "LeftButton" then
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
    key:SetScript("OnEnter", function(self) UI.ShowTooltip(self, L.BUFFS_KEY_TITLE, L.BUFFS_KEY_TIP) end)
    key:SetScript("OnLeave", GameTooltip_Hide)
    return key
end

---------------------------------------------------------------------------
-- Icon to drag onto an action bar (a character macro)
---------------------------------------------------------------------------

local function CreateDragButton(parent)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(34, 34)
    UI.ApplyFlat(button, { 0, 0, 0, 0.6 }, { 1, 0.82, 0, 0.6 })
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetPoint("TOPLEFT", 2, -2)
    button.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local function Pick()
        if Buffs.PickupMacro(Seq()) then UI.PlayClick() end
    end
    button:SetScript("OnDragStart", Pick)
    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then
            UI.PlayClick()
            OpenIconPicker()
        else
            Pick()
        end
    end)
    button:SetScript("OnEnter", function(self) UI.ShowTooltip(self, L.BUFFS_DRAG_TITLE, L.BUFFS_DRAG_TIP) end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local SCOPE_TEXT = { self = "BUFFS_SCOPE_SELF", group = "BUFFS_SCOPE_GROUP", prayer = "BUFFS_SCOPE_PRAYER" }

local function RankLabel(entry)
    if #entry.ranks == 0 then return L.BUFFS_NOT_LEARNED end
    if entry.want == 0 then return L.BUFFS_RANK_MAX:format(entry.ranks[#entry.ranks].rank) end
    return L.BUFFS_RANK:format(entry.want)
end

local function RowTooltip(row)
    local entry = row.entry
    if not entry then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetText(entry.name, 1, 1, 1)
    GameTooltip:AddLine(L[SCOPE_TEXT[entry.scope]], UI.GOLD[1], UI.GOLD[2], UI.GOLD[3], true)
    if #entry.ranks == 0 then
        GameTooltip:AddLine(L.BUFFS_NOT_LEARNED_TIP, UI.MUTED[1], UI.MUTED[2], UI.MUTED[3], true)
    else
        GameTooltip:AddLine(L.BUFFS_ROW_RANK_TIP, 1, 1, 1, true)
    end
    GameTooltip:AddLine(L.BUFFS_ROW_PRESENT_TIP, UI.MUTED[1], UI.MUTED[2], UI.MUTED[3], true)
    GameTooltip:Show()
end

local function OpenRankMenu(owner, entry)
    if not MenuUtil or not MenuUtil.CreateContextMenu or #entry.ranks == 0 then return end
    local refresh = MenuResponse and MenuResponse.Refresh
    local seq = Seq()
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(entry.name)
        root:CreateRadio(L.BUFFS_RANK_MAX:format(entry.ranks[#entry.ranks].rank),
            function() return entry.want == 0 end,
            function()
                Buffs.SetRank(seq, entry.id, 0)
                entry.want = 0
                return refresh
            end)
        for index = #entry.ranks, 1, -1 do
            local rank = entry.ranks[index]
            local label = L.BUFFS_RANK:format(rank.rank)
            if rank.level and rank.level > 0 then label = label .. "  |cff999999" .. L.BUFFS_LEVEL:format(rank.level) .. "|r" end
            root:CreateRadio(label,
                function() return entry.want == rank.rank end,
                function()
                    Buffs.SetRank(seq, entry.id, rank.rank)
                    entry.want = rank.rank
                    return refresh
                end)
        end
    end)
end

local function SmallButton(row, normal, pushed, highlight, disabled)
    local button = CreateFrame("Button", nil, row)
    button:SetSize(18, 18)
    button:SetNormalTexture(normal)
    if pushed then button:SetPushedTexture(pushed) end
    if disabled then button:SetDisabledTexture(disabled) end
    button:SetHighlightTexture(highlight or normal, "ADD")
    if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
    return button
end

local function ButtonTip(button, text)
    button:SetScript("OnEnter", function(self)
        self:GetParent():SetHovered(true)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L[text], 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        if not self:GetParent():IsMouseOver() then self:GetParent():SetHovered(false) end
        GameTooltip:Hide()
    end)
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT - 4)
    UI.ApplyFlat(row, ROW_BG, ROW_BORDER)

    function row:SetHovered(hovered)
        self:SetBackdropColor(unpack(hovered and ROW_BG_HOVER or ROW_BG))
        self:SetBackdropBorderColor(unpack(hovered and ROW_BORDER_HOVER or ROW_BORDER))
    end

    row.check = UI.CreateCheckbox(row)
    row.check:SetSize(22, 21)
    row.check:SetPoint("LEFT", 3, 0)

    row.number = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.number:SetPoint("LEFT", row.check, "RIGHT", 0, 0)
    row.number:SetWidth(16)
    row.number:SetJustifyH("RIGHT")

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(20, 20)
    row.icon:SetPoint("LEFT", row.number, "RIGHT", 6, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    row.down = SmallButton(row, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight",
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")
    row.down:SetPoint("RIGHT", -6, 0)
    row.up = SmallButton(row, "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight",
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled")
    row.up:SetPoint("RIGHT", row.down, "LEFT", 0, 0)

    row.rank = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.rank:SetSize(104, 20)
    row.rank:SetPoint("RIGHT", row.up, "LEFT", -6, 0)
    if row.rank.SetMotionScriptsWhileDisabled then row.rank:SetMotionScriptsWhileDisabled(true) end

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row.rank, "LEFT", -8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    local function Leave()
        if not row:IsMouseOver() then row:SetHovered(false) end
        GameTooltip:Hide()
    end

    row:SetScript("OnEnter", function(self)
        self:SetHovered(true)
        RowTooltip(self)
    end)
    row:SetScript("OnLeave", Leave)
    row:SetScript("OnClick", function(self) self.check:Click() end)

    row.check:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        UI.PlayCheck(on)
        Buffs.SetOn(Seq(), row.entry.id, on)
    end)
    row.check:HookScript("OnEnter", function()
        row:SetHovered(true)
        RowTooltip(row)
    end)
    row.check:HookScript("OnLeave", Leave)

    row.rank:SetScript("OnClick", function(self)
        UI.PlayClick()
        OpenRankMenu(self, row.entry)
    end)
    row.rank:SetScript("OnEnter", function(self)
        row:SetHovered(true)
        UI.ShowTooltip(self, L.BUFFS_RANK_TITLE, L.BUFFS_ROW_RANK_TIP)
    end)
    row.rank:SetScript("OnLeave", Leave)

    row.up:SetScript("OnClick", function()
        UI.PlayClick()
        Buffs.Move(Seq(), row.entry.id, -1)
    end)
    row.down:SetScript("OnClick", function()
        UI.PlayClick()
        Buffs.Move(Seq(), row.entry.id, 1)
    end)
    ButtonTip(row.up, "BUFFS_UP")
    ButtonTip(row.down, "BUFFS_DOWN")

    row:SetHovered(false)
    return row
end

local function FillRow(row, entry, index, count)
    row.entry = entry
    local learned = #entry.ranks > 0
    row.check:SetChecked(entry.on)
    row.number:SetText(index)
    row.icon:SetTexture(entry.icon)
    row.icon:SetDesaturated(not learned)
    row.name:SetText(entry.name)
    if learned and entry.on then
        row.name:SetTextColor(1, 1, 1)
    else
        row.name:SetTextColor(unpack(UI.MUTED))
    end
    row.rank:SetText(RankLabel(entry))
    row.rank:SetEnabled(learned)
    row.up:SetEnabled(index > 1)
    row.down:SetEnabled(index < count)
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function RefreshStatus()
    if not window or not window:IsShown() then return end
    local text, ready = Buffs.Preview(Seq())
    window.status:SetText(text)
    if ready then
        window.status:SetTextColor(1, 1, 1)
    else
        window.status:SetTextColor(unpack(UI.MUTED))
    end
end

Refresh = function()
    if not window or not window:IsShown() then return end
    local seq = Seq()
    if picker and picker:IsShown() and picker.seq ~= seq then picker:Hide() end
    window.sequence:SetText(seq and seq.name or "")
    window.drag.icon:SetTexture(seq and Buffs.Icon(seq) or 134400)
    RefreshKey()
    local entries = Buffs.Entries(seq)
    for index, entry in ipairs(entries) do
        local row = rows[index]
        if not row then
            row = CreateRow(window.inset)
            row:SetPoint("TOPLEFT", 8, -8 - (index - 1) * ROW_HEIGHT)
            row:SetPoint("TOPRIGHT", -8, -8 - (index - 1) * ROW_HEIGHT)
            rows[index] = row
        end
        FillRow(row, entry, index, #entries)
        row:Show()
    end
    for index = #entries + 1, #rows do rows[index]:Hide() end

    window.empty:SetShown(#entries == 0)
    window:SetHeight(TOP + math.max(#entries, 2) * ROW_HEIGHT + 16 + 40)
    RefreshStatus()
end

local function Build()
    window = UI.CreateWindow(WINDOW_NAME, WIDTH, 420, WINDOW_ICON)
    window:SetFrameStrata("DIALOG")
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    window:SetWindowTitle(L.BUFFS_TITLE)
    window:SetScript("OnShow", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
        Refresh()
    end)
    window:SetScript("OnHide", function()
        StopCapture()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)

    local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 66, -30)
    hint:SetPoint("TOPRIGHT", -16, -30)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(unpack(UI.MUTED))
    UI.Localize(hint, "BUFFS_HINT")

    window.sequence = CreateSequenceButton(window)
    window.sequence:SetPoint("TOPLEFT", 66, -70)

    window.key = CreateKeyButton(window)
    window.key:SetPoint("LEFT", window.sequence, "RIGHT", 6, 0)

    window.drag = CreateDragButton(window)
    window.drag:SetPoint("LEFT", window.key, "RIGHT", 10, 0)

    window.inset = UI.CreateInset(window)
    window.inset:SetPoint("TOPLEFT", 6, -TOP + 8)
    window.inset:SetPoint("BOTTOMRIGHT", -6, 36)

    window.empty = window.inset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    window.empty:SetPoint("TOPLEFT", 14, -14)
    window.empty:SetPoint("TOPRIGHT", -14, -14)
    window.empty:SetJustifyH("LEFT")
    UI.Localize(window.empty, "BUFFS_CLASS")

    window.status = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    window.status:SetPoint("BOTTOMLEFT", 14, 12)
    window.status:SetPoint("BOTTOMRIGHT", -14, 12)
    window.status:SetJustifyH("LEFT")
    window.status:SetWordWrap(false)

    -- Range and auras change without an event we can trust: the bottom
    -- line is checked twice a second while the window is open.
    local elapsed = 0
    window:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.5 then return end
        elapsed = 0
        RefreshStatus()
    end)
end

function BuffsUI.Open()
    if not window then Build() end
    if window:IsShown() then
        Refresh()
    else
        window:Show()
    end
end

function BuffsUI.Toggle()
    if window and window:IsShown() then window:Hide() else BuffsUI.Open() end
end

ns:On("BUFFS_CHANGED", function() Refresh() end)
ns:On("LANGUAGE_CHANGED", function()
    if window then window:SetWindowTitle(L.BUFFS_TITLE) end
    Refresh()
end)
