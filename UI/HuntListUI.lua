local _, ns = ...
local L, UI, Util, Hunt = ns.L, ns.UI, ns.Util, ns.HuntList

-- Hunting list window: the key, the tag spell, and the NPCs, the most
-- important first. Data and the secure macro live in Features\HuntList.lua.

local WINDOW_NAME = "BudgetForeverHuntList"
local ROW_HEIGHT = 28       -- row pitch; rows are 4px shorter for a gap
local SLOT = 36
local RECENT = 120          -- seconds: "here now"
local MODIFIERS = {
    LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true,
    LALT = true, RALT = true, LMETA = true, RMETA = true,
}
local MOUSE_KEYS = { MiddleButton = "BUTTON3", Button4 = "BUTTON4", Button5 = "BUTTON5" }

local ROW_BG = { 0, 0, 0, 0.28 }
local ROW_BG_HOVER = { 0.08, 0.07, 0.03, 0.45 }
local ROW_BORDER = { 1, 1, 1, 0.06 }
local ROW_BORDER_HOVER = { 1, 0.82, 0, 0.45 }

local window
local capturing = false
local Refresh

local function IconText(icon)
    return ("|T%s:16:16:0:0:64:64:5:59:5:59|t"):format(tostring(icon))
end

-- "seen 5 min ago", "never seen"...
local function Ago(stamp)
    if type(stamp) ~= "number" then return L.HUNT_NEVER end
    local seconds = math.max(0, time() - stamp)
    if seconds < 60 then return L.HUNT_SEEN_NOW end
    if seconds < 3600 then return L.HUNT_SEEN_MIN:format(math.floor(seconds / 60)) end
    if seconds < 86400 then return L.HUNT_SEEN_HOURS:format(math.floor(seconds / 3600)) end
    return L.HUNT_SEEN_DAYS:format(math.floor(seconds / 86400))
end

local function HereNow(entry)
    return type(entry.seen) == "number" and time() - entry.seen < RECENT
end

-- Zone from QuestieDB (nil when it doesn't know the NPC).
local function Where(entry)
    local finder = ns.NpcFinder
    if not entry.id or not (finder and finder.NpcWhere) then return end
    local ok, text = pcall(finder.NpcWhere, entry.id)
    if ok then return text end
end

---------------------------------------------------------------------------
-- Key capture (as in the wheel's window)
---------------------------------------------------------------------------

local function KeyButtonText()
    if capturing then return "|cffffd200" .. L.WHEEL_KEY_WAIT .. "|r" end
    local key = Hunt.GetKey()
    if key then return L.WHEEL_KEY:format(Hunt.KeyText(key)) end
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
    window.key:EnableKeyboard(false)
    Hunt.SetKey(Combo(key))
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
            Hunt.ClearKey()
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
    key:SetScript("OnEnter", function(self) UI.ShowTooltip(self, L.HUNT_BINDING, L.WHEEL_KEY_TIP) end)
    key:SetScript("OnLeave", GameTooltip_Hide)
    return key
end

---------------------------------------------------------------------------
-- Tag spell
---------------------------------------------------------------------------

local function SpellText()
    local cast = Hunt.CastText()
    return cast or L.HUNT_SPELL_NONE
end

local function DropSpell()
    local spell = Hunt.CursorSpell()
    if not spell then return false end
    ClearCursor()
    UI.PlayClick()
    Hunt.SetSpell(spell)
    ns:Print(L.HUNT_SPELL_SET:format(SpellText()))
    return true
end

local function OpenSpellMenu(slot)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    local close = MenuResponse and MenuResponse.Close
    MenuUtil.CreateContextMenu(slot, function(_, root)
        root:CreateTitle(L.HUNT_SPELL_SUGGESTED)
        local suggestions = Hunt.Suggestions()
        for _, spell in ipairs(suggestions) do
            root:CreateRadio(IconText(Hunt.SpellIcon(spell)) .. " " .. spell.name,
                function()
                    local current = Hunt.Char().spell
                    return type(current) == "table" and current.name == spell.name
                end,
                function()
                    Hunt.SetSpell(spell)
                    ns:Print(L.HUNT_SPELL_SET:format(SpellText()))
                    return close
                end)
        end
        if #suggestions == 0 then root:CreateTitle("|cff999999" .. L.HUNT_SPELL_NO_SUGGESTION .. "|r") end
        root:CreateDivider()
        root:CreateRadio(L.HUNT_SPELL_NONE,
            function() return Hunt.Char().spell == nil end,
            function()
                Hunt.SetSpell(nil)
                return close
            end)
        root:CreateTitle("|cff999999" .. L.HUNT_SPELL_DROP .. "|r")
    end)
end

local function CreateSpellSlot(parent)
    local slot = CreateFrame("Button", nil, parent)
    slot:SetSize(SLOT, SLOT)
    slot:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    slot.icon = slot:CreateTexture(nil, "ARTWORK")
    slot.icon:SetAllPoints()
    slot.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    local border = slot:CreateTexture(nil, "BACKGROUND")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetColorTexture(1, 0.82, 0, 0.45)
    local highlight = slot:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.15)

    slot:SetScript("OnClick", function(self, button)
        if DropSpell() then return end
        if button == "RightButton" then
            if Hunt.Char().spell then
                UI.PlayCheck(false)
                Hunt.SetSpell(nil)
            end
            return
        end
        UI.PlayClick()
        OpenSpellMenu(self)
    end)
    slot:SetScript("OnReceiveDrag", DropSpell)
    slot:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.HUNT_SPELL, 1, 0.82, 0)
        GameTooltip:AddLine(SpellText(), 1, 1, 1)
        GameTooltip:AddLine(L.HUNT_SPELL_TIP, 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(L.HUNT_SPELL_CLICK, unpack(UI.MUTED))
        GameTooltip:AddLine(L.HUNT_SPELL_DROP, unpack(UI.MUTED))
        if Hunt.Char().spell then GameTooltip:AddLine(L.HUNT_SPELL_RIGHT, unpack(UI.MUTED)) end
        GameTooltip:Show()
    end)
    slot:SetScript("OnLeave", GameTooltip_Hide)
    return slot
end

-- A checkbox with a clickable label. get() and set(value).
local function CreateToggle(parent, label, tip, get, set)
    local holder = CreateFrame("Button", nil, parent)
    holder:SetHeight(24)
    holder.check = UI.CreateCheckbox(holder)
    holder.check:SetSize(24, 23)
    holder.check:SetPoint("LEFT")
    holder.text = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    holder.text:SetPoint("LEFT", holder.check, "RIGHT", 2, 0)
    holder.text:SetJustifyH("LEFT")
    UI.Localize(holder.text, label)

    function holder:Refresh(enabled)
        self.enabled = enabled
        self.check:SetChecked(get())
        self.check:SetEnabled(enabled)
        self:SetAlpha(enabled and 1 or 0.45)
        self:SetWidth(28 + self.text:GetStringWidth())
    end
    local function Toggle(value)
        if not holder.enabled then return end
        set(value)
        UI.PlayCheck(value)
    end
    holder.check:SetScript("OnClick", function(self) Toggle(self:GetChecked() and true or false) end)
    holder:SetScript("OnClick", function() Toggle(not get()) end)
    local function Enter() UI.ShowTooltip(holder, holder.text:GetText(), L[tip]) end
    holder:SetScript("OnEnter", Enter)
    holder:SetScript("OnLeave", GameTooltip_Hide)
    holder.check:HookScript("OnEnter", Enter)
    holder.check:HookScript("OnLeave", GameTooltip_Hide)
    return holder
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------

local function RowTooltip(row)
    local entry = row.entry
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT", 8, 0)
    GameTooltip:SetText(entry.name, 1, 0.82, 0)
    local where = Where(entry)
    if where then GameTooltip:AddLine(where, 1, 1, 1) end
    GameTooltip:AddLine(L.HUNT_ROW_SEEN:format(Ago(entry.seen)), 0.8, 0.8, 0.8)
    if not entry.on then
        GameTooltip:AddLine(L.HUNT_ROW_OFF, 0.6, 0.6, 0.6, true)
    elseif Hunt.InMacro(entry.name) then
        GameTooltip:AddLine(L.HUNT_ROW_IN, UI.GREEN[1], UI.GREEN[2], UI.GREEN[3], true)
    else
        GameTooltip:AddLine(L.HUNT_ROW_OUT, UI.ORANGE[1], UI.ORANGE[2], UI.ORANGE[3], true)
    end
    GameTooltip:AddLine(" ")
    if entry.id then GameTooltip:AddLine(L.NPC_CLICK, 0.5, 0.8, 1) end
    GameTooltip:AddLine(L.HUNT_ROW_CHECK, 0.5, 0.8, 1)
    GameTooltip:Show()
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

    row.check = UI.CreateCheckbox(row)
    row.check:SetSize(22, 21)
    row.check:SetPoint("LEFT", 3, 0)

    row.number = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.number:SetPoint("LEFT", row.check, "RIGHT", 0, 0)
    row.number:SetWidth(18)
    row.number:SetJustifyH("RIGHT")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.number, "RIGHT", 6, 0)
    row.name:SetWidth(150)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.delete = SmallButton(row, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "Interface\\Buttons\\UI-GroupLoot-Pass-Down",
        "Interface\\Buttons\\UI-GroupLoot-Pass-Highlight")
    row.delete:SetPoint("RIGHT", -6, 0)
    row.map = SmallButton(row, "Interface\\Icons\\INV_Misc_Map_01")
    row.map:GetNormalTexture():SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.map:SetSize(16, 16)
    row.map:SetPoint("RIGHT", row.delete, "LEFT", -6, 0)
    row.down = SmallButton(row, "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Highlight",
        "Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Disabled")
    row.down:SetPoint("RIGHT", row.map, "LEFT", -6, 0)
    row.up = SmallButton(row, "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Up",
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Down", "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Highlight",
        "Interface\\Buttons\\UI-ScrollBar-ScrollUpButton-Disabled")
    row.up:SetPoint("RIGHT", row.down, "LEFT", 0, 0)

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.info:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.info:SetPoint("RIGHT", row.up, "LEFT", -6, 0)
    row.info:SetJustifyH("LEFT")
    row.info:SetWordWrap(false)

    function row:SetHovered(hovered)
        self:SetBackdropColor(unpack(hovered and ROW_BG_HOVER or ROW_BG))
        self:SetBackdropBorderColor(unpack(hovered and ROW_BORDER_HOVER or ROW_BORDER))
    end

    function row:SetEntry(entry, index, count)
        self.entry, self.index = entry, index
        self.check:SetChecked(entry.on)
        self.number:SetText(index .. ".")
        self.name:SetText(entry.name)
        local info
        if HereNow(entry) then
            self.name:SetTextColor(unpack(UI.GREEN))
            info = "|cff4cf273" .. L.HUNT_HERE_NOW .. "|r"
        else
            local shade = entry.on and 1 or 0.55
            self.name:SetTextColor(shade, shade, shade)
            info = Ago(entry.seen)
        end
        local where = Where(entry)
        if where then info = where .. "  ·  " .. info end
        if entry.on and not Hunt.InMacro(entry.name) then
            info = info .. "  ·  |cffff8c26" .. L.HUNT_OUT .. "|r"
        end
        self.info:SetText(info)
        self.up:SetEnabled(index > 1)
        self.down:SetEnabled(index < count)
        self.map:SetEnabled(entry.id ~= nil)
        self.map:SetAlpha(entry.id and 1 or 0.3)
        self:SetAlpha(entry.on and 1 or 0.7)
    end

    local function Leave()
        if row:IsMouseOver() then return end
        row:SetHovered(false)
        GameTooltip:Hide()
    end

    local function ShowOnMap()
        local entry = row.entry
        if not entry.id or not (ns.NpcFinder and ns.NpcFinder.ShowNpc) then
            ns:Print(L.NPC_NO_POSITION_LONG:format(entry.name))
            return
        end
        UI.PlayClick()
        ns.NpcFinder.ShowNpc(entry.id, IsShiftKeyDown())
    end

    row:SetScript("OnClick", ShowOnMap)
    row:SetScript("OnEnter", function(self)
        self:SetHovered(true)
        RowTooltip(self)
    end)
    row:SetScript("OnLeave", Leave)

    row.check:SetScript("OnClick", function(self)
        local on = self:GetChecked() and true or false
        UI.PlayCheck(on)
        Hunt.SetOn(row.entry.name, on)
    end)
    row.check:HookScript("OnEnter", function()
        row:SetHovered(true)
        RowTooltip(row)
    end)
    row.check:HookScript("OnLeave", Leave)

    row.up:SetScript("OnClick", function()
        UI.PlayClick()
        Hunt.Move(row.index, -1)
    end)
    row.down:SetScript("OnClick", function()
        UI.PlayClick()
        Hunt.Move(row.index, 1)
    end)
    row.map:SetScript("OnClick", ShowOnMap)
    row.delete:SetScript("OnClick", function()
        UI.PlayCheck(false)
        local name = row.entry.name
        Hunt.Remove(name)
        ns:Print(L.HUNT_REMOVED:format(name))
    end)
    ButtonTip(row.up, "HUNT_UP")
    ButtonTip(row.down, "HUNT_DOWN")
    ButtonTip(row.map, "HUNT_MAP")
    ButtonTip(row.delete, "BUTTON_DELETE")

    row:SetHovered(false)
    return row
end

---------------------------------------------------------------------------
-- Adding NPCs
---------------------------------------------------------------------------

local function AddTyped()
    local text = strtrim(window.nameBox:GetText() or "")
    if text == "" then return end
    local entry, new = Hunt.AddByName(text)
    if not entry then
        ns:Error(L.HUNT_USAGE)
        return
    end
    UI.PlayClick()
    ns:Print((new and L.HUNT_ADDED or L.HUNT_ALREADY):format(entry.name))
    window.nameBox:SetText("")
end

local function AddTarget()
    local name = Hunt.UnitNpcName("target")
    if not name then
        ns:Error(L.HUNT_ERROR_TARGET)
        return
    end
    UI.PlayClick()
    local entry, new = Hunt.Add(name, Hunt.NpcIdFromUnit("target"))
    if entry then ns:Print((new and L.HUNT_ADDED or L.HUNT_ALREADY):format(entry.name)) end
end

local function OpenImportMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        if root.SetScrollMode then root:SetScrollMode(420) end
        root:CreateTitle(L.HUNT_IMPORT_TITLE)
        local macros = Hunt.MacrosWithTargets()
        for _, macro in ipairs(macros) do
            local names = Util.Truncate(table.concat(macro.names, ", "), 40)
            root:CreateButton(IconText(macro.icon) .. " " .. macro.name .. "   |cff999999" .. names .. "|r", function()
                local added = Hunt.AddNames(macro.names)
                if added > 0 then
                    ns:Print(L.HUNT_IMPORTED:format(added, macro.name))
                else
                    ns:Print(L.HUNT_IMPORTED_NONE)
                end
            end)
        end
        if #macros == 0 then root:CreateTitle("|cff999999" .. L.HUNT_IMPORT_NONE .. "|r") end
    end)
end

---------------------------------------------------------------------------
-- What the key runs
---------------------------------------------------------------------------

local function StatusText()
    local kept, dropped, active, length = Hunt.Status()
    if active == 0 then return L.HUNT_STATUS_EMPTY end
    if dropped > 0 then return L.HUNT_STATUS_DROPPED:format(kept, dropped, length, Hunt.MAX_TEXT) end
    return L.HUNT_STATUS:format(kept, length, Hunt.MAX_TEXT)
end

local function StatusTooltip(self)
    local _, _, _, _, text = Hunt.Status()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L.HUNT_STATUS_TIP, 1, 0.82, 0)
    if text then
        for line in text:gmatch("[^\n]+") do GameTooltip:AddLine((line:gsub("|", "||")), 0.6, 0.8, 1) end
    else
        GameTooltip:AddLine(L.HUNT_STATUS_EMPTY, 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L.HUNT_STATUS_LIMIT, 1, 1, 1, true)
    GameTooltip:Show()
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function Build()
    window = UI.CreateWindow(WINDOW_NAME, 480, 560, Hunt.DEFAULT_ICON)
    window:SetFrameStrata("DIALOG")
    window:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    window:SetScript("OnShow", function(self)
        self:RegisterEvent("UPDATE_BINDINGS")
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
    end)
    window:SetScript("OnHide", function(self)
        self:UnregisterEvent("UPDATE_BINDINGS")
        StopCapture()
        self.nameBox:ClearFocus()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)
    window:SetScript("OnEvent", RefreshKey)

    local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 66, -28)
    hint:SetPoint("TOPRIGHT", -16, -28)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(unpack(UI.MUTED))
    UI.Localize(hint, "HUNT_WINDOW_HINT")

    -- Key, spell, options
    local top = UI.CreateInset(window)
    top:SetPoint("TOPLEFT", 6, -64)
    top:SetPoint("TOPRIGHT", -6, -64)
    top:SetHeight(86)

    window.key = CreateKeyButton(top)
    window.key:SetPoint("TOPLEFT", 12, -12)

    window.spell = CreateSpellSlot(top)
    window.spell:SetPoint("TOPLEFT", 190, -9)
    local spellLabel = top:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    spellLabel:SetPoint("TOPLEFT", window.spell, "TOPRIGHT", 10, -2)
    UI.Localize(spellLabel, "HUNT_SPELL")
    window.spellText = top:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    window.spellText:SetPoint("TOPLEFT", spellLabel, "BOTTOMLEFT", 0, -4)
    window.spellText:SetPoint("RIGHT", top, "RIGHT", -12, 0)
    window.spellText:SetJustifyH("LEFT")
    window.spellText:SetWordWrap(false)

    window.lowest = CreateToggle(top, "HUNT_LOWEST", "HUNT_LOWEST_TIP",
        function() return Hunt.Char().lowest == true end,
        function(value) Hunt.SetLowest(value) end)
    window.lowest:SetPoint("TOPLEFT", 10, -52)
    window.pet = CreateToggle(top, "HUNT_PET", "HUNT_PET_TIP",
        function() return Hunt.Char().pet == true end,
        function(value) Hunt.SetPet(value) end)
    window.pet:SetPoint("TOPLEFT", 236, -52)

    -- NPCs
    local listInset = UI.CreateInset(window)
    listInset:SetPoint("TOPLEFT", top, "BOTTOMLEFT", 0, -6)
    listInset:SetPoint("BOTTOMRIGHT", -6, 72)

    local header = listInset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("TOPLEFT", 12, -9)
    UI.Localize(header, "HUNT_LIST_HEADER")
    window.count = listInset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    window.count:SetPoint("LEFT", header, "RIGHT", 6, 0)

    local template = UI.HasTemplate("ScrollFrameTemplate") and "ScrollFrameTemplate" or "UIPanelScrollFrameTemplate"
    window.scroll = CreateFrame("ScrollFrame", nil, listInset, template)
    window.scroll:SetPoint("TOPLEFT", 8, -30)
    window.scroll:SetPoint("BOTTOMRIGHT", -28, 8)
    window.child = CreateFrame("Frame", nil, window.scroll)
    window.child:SetSize(1, 1)
    window.scroll:SetScrollChild(window.child)
    window.rows = {}

    window.empty = listInset:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    window.empty:SetPoint("TOPLEFT", 24, -56)
    window.empty:SetPoint("TOPRIGHT", -24, -56)
    window.empty:SetJustifyH("CENTER")
    window.empty:SetWordWrap(true)
    UI.Localize(window.empty, "HUNT_EMPTY_LIST")

    -- Adding: a name, your target
    local searchTemplate = UI.HasTemplate("SearchBoxTemplate") and "SearchBoxTemplate" or "InputBoxTemplate"
    window.nameBox = CreateFrame("EditBox", nil, window, searchTemplate)
    window.nameBox:SetSize(220, 22)
    window.nameBox:SetPoint("BOTTOMLEFT", 18, 42)
    window.nameBox:SetAutoFocus(false)
    window.nameBox:SetMaxLetters(80)
    if window.nameBox.Instructions then UI.Localize(window.nameBox.Instructions, "HUNT_ADD_PLACEHOLDER") end
    window.nameBox:SetScript("OnEnterPressed", AddTyped)
    window.nameBox:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local addTarget = UI.CreateButton(window, "HUNT_ADD_TARGET", 140)
    addTarget:SetPoint("LEFT", window.nameBox, "RIGHT", 10, 0)
    addTarget:SetScript("OnClick", AddTarget)

    -- Footer
    local import = UI.CreateButton(window, "HUNT_IMPORT", 150)
    import:SetPoint("BOTTOMLEFT", 8, 7)
    import:SetScript("OnClick", function(self)
        UI.PlayClick()
        OpenImportMenu(self)
    end)

    local done = UI.CreateButton(window, "WHEEL_DONE", 100)
    done:SetPoint("BOTTOMRIGHT", -8, 7)
    done:SetScript("OnClick", function() window:Hide() end)

    window.status = CreateFrame("Button", nil, window)
    window.status:SetPoint("LEFT", import, "RIGHT", 8, 0)
    window.status:SetPoint("RIGHT", done, "LEFT", -8, 0)
    window.status:SetHeight(22)
    window.status.text = window.status:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    window.status.text:SetAllPoints()
    window.status.text:SetJustifyH("CENTER")
    window.status.text:SetWordWrap(false)
    window.status:SetScript("OnEnter", StatusTooltip)
    window.status:SetScript("OnLeave", GameTooltip_Hide)
end

local function RefreshRows()
    local list = Hunt.List()
    local width = window.scroll:GetWidth()
    if not width or width < 100 then width = 410 end
    for index, entry in ipairs(list) do
        local row = window.rows[index]
        if not row then
            row = CreateRow(window.child)
            window.rows[index] = row
        end
        row:SetEntry(entry, index, #list)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", window.child, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)
        row:SetWidth(width)
        row:Show()
        if row:IsMouseOver() and GameTooltip:IsOwned(row) then RowTooltip(row) end
    end
    for index = #list + 1, #window.rows do window.rows[index]:Hide() end
    local height = math.max(1, #list * ROW_HEIGHT - 4)
    window.child:SetSize(width, height)
    if window.scroll.UpdateScrollChildRect then window.scroll:UpdateScrollChildRect() end
    if window.scroll.ScrollBar then
        window.scroll.ScrollBar:SetAlpha(height > window.scroll:GetHeight() + 1 and 1 or 0)
    end
    window.empty:SetShown(#list == 0)
    window.count:SetText(("(%d)"):format(#list))
end

Refresh = function()
    if not window or not window:IsShown() then return end
    window:SetWindowTitle(L.HUNT_WINDOW_TITLE)
    RefreshKey()
    local spell = Hunt.Char().spell
    window.spell.icon:SetTexture(Hunt.SpellIcon(spell))
    window.spell.icon:SetDesaturated(spell == nil)
    window.spellText:SetText(SpellText())
    window.lowest:Refresh(type(spell) == "table" and spell.rank ~= nil)
    window.pet:Refresh(true)
    RefreshRows()
    window.status.text:SetText(StatusText())
end

function Hunt.OpenList()
    if not window then Build() end
    window:Show()
    window:Raise()
    Refresh()
    -- The scroll frame has its size once shown: rows laid out again.
    C_Timer.After(0, Refresh)
end

function Hunt.CloseList()
    if window then window:Hide() end
end

ns:On("HUNT_CHANGED", function() Refresh() end)
ns:On("HUNT_MACRO", function() Refresh() end)
ns:On("HUNT_SEEN", function() Refresh() end)
ns:On("LANGUAGE_CHANGED", function() Refresh() end)
