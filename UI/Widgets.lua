local _, ns = ...
local L = ns.L

local UI = {}
ns.UI = UI

UI.GOLD = { 1, 0.82, 0 }
UI.MUTED = { 0.66, 0.66, 0.70 }
UI.GREEN = { 0.30, 0.95, 0.45 }
UI.ORANGE = { 1, 0.55, 0.15 }
UI.RED = { 1, 0.27, 0.27 }

local CARD_BG = { 0, 0, 0, 0.32 }
local CARD_BG_HOVER = { 0.08, 0.07, 0.03, 0.45 }
local CARD_BORDER = { 1, 1, 1, 0.08 }
local CARD_BORDER_HOVER = { 1, 0.82, 0, 0.45 }

local FLAT = {
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
}

function UI.HasTemplate(name)
    return C_XMLUtil ~= nil and C_XMLUtil.GetTemplateInfo ~= nil and C_XMLUtil.GetTemplateInfo(name) ~= nil
end

function UI.HasAtlas(name)
    return C_Texture ~= nil and C_Texture.GetAtlasInfo ~= nil and C_Texture.GetAtlasInfo(name) ~= nil
end

function UI.ApplyFlat(frame, background, border)
    frame:SetBackdrop(FLAT)
    frame:SetBackdropColor(unpack(background))
    frame:SetBackdropBorderColor(unpack(border))
end

function UI.PlayClick()
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

function UI.PlayCheck(on)
    PlaySound(on and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
end

---------------------------------------------------------------------------
-- Localized text: regions remember where their text comes from so the
-- whole UI can switch language without a reload.
---------------------------------------------------------------------------

local bound = setmetatable({}, { __mode = "k" })

function UI.Localize(region, source)
    local getter = source
    if type(source) ~= "function" then
        getter = function() return L[source] end
    end
    bound[region] = getter
    region:SetText(getter())
end

function UI.RefreshTexts()
    for region, getter in pairs(bound) do
        region:SetText(getter())
    end
end

---------------------------------------------------------------------------
-- Window: Blizzard portrait frame (same chrome as the character sheet),
-- flat fallback if the template is missing. Movable, closes with Escape.
---------------------------------------------------------------------------

function UI.CreateWindow(name, width, height, icon)
    local modern = UI.HasTemplate("PortraitFrameTemplate")
    local window = CreateFrame("Frame", name, UIParent, modern and "PortraitFrameTemplate" or "BackdropTemplate")
    window:Hide()
    window:SetSize(width, height)
    window:SetToplevel(true)
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    if window.SetDontSavePosition then window:SetDontSavePosition(true) end
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    table.insert(UISpecialFrames, name)

    if modern then
        -- An addon's own texture is set as is: it is already round, and
        -- SetPortraitToAsset is made for Blizzard's square icons.
        local own = type(icon) == "string" and icon:find("AddOns", 1, true)
        if own and window.SetPortraitTextureRaw then
            window:SetPortraitTextureRaw(icon)
        elseif window.SetPortraitToAsset then
            window:SetPortraitToAsset(icon)
        elseif window.SetPortraitTextureRaw then
            window:SetPortraitTextureRaw(icon)
        end
    else
        UI.ApplyFlat(window, { 0.05, 0.05, 0.06, 0.97 }, { 0.3, 0.3, 0.32, 1 })
        local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        window.fallbackTitle = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        window.fallbackTitle:SetPoint("TOP", 0, -8)
    end

    function window:SetWindowTitle(text)
        if self.SetTitle then
            self:SetTitle(text)
        elseif self.TitleContainer and self.TitleContainer.TitleText then
            self.TitleContainer.TitleText:SetText(text)
        elseif self.TitleText then
            self.TitleText:SetText(text)
        elseif self.fallbackTitle then
            self.fallbackTitle:SetText(text)
        end
    end
    return window
end

function UI.CreateInset(parent)
    if UI.HasTemplate("InsetFrameTemplate") then
        return CreateFrame("Frame", nil, parent, "InsetFrameTemplate")
    end
    local inset = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    UI.ApplyFlat(inset, { 0, 0, 0, 0.35 }, { 1, 1, 1, 0.1 })
    return inset
end

---------------------------------------------------------------------------
-- Basic controls
---------------------------------------------------------------------------

function UI.CreateCheckbox(parent)
    local modern = UI.HasTemplate("MinimalCheckboxTemplate")
    local check = CreateFrame("CheckButton", nil, parent, modern and "MinimalCheckboxTemplate" or "UICheckButtonTemplate")
    check:SetSize(modern and 30 or 28, modern and 29 or 28)
    local label = check.Text or check.text
    if label then label:SetText("") end
    return check
end

function UI.CreateButton(parent, source, width)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width or 140, 24)
    UI.Localize(button, source)
    return button
end

local function CreateBadge(parent, source, color)
    local badge = CreateFrame("Frame", nil, parent)
    badge:SetHeight(16)
    local background = badge:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(color[1], color[2], color[3], 0.16)
    badge.text = badge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badge.text:SetPoint("CENTER", 0, 0)
    badge.text:SetTextColor(color[1], color[2], color[3])
    UI.Localize(badge.text, source)
    function badge:Layout()
        self:SetWidth(math.ceil(self.text:GetStringWidth()) + 12)
    end
    return badge
end

---------------------------------------------------------------------------
-- Card: the building block of every page. Rounded-feeling dark tile with a
-- gold accent on the left when the option is on.
---------------------------------------------------------------------------

local function CreateCard(parent, clickable)
    local card = CreateFrame(clickable and "Button" or "Frame", nil, parent, "BackdropTemplate")
    UI.ApplyFlat(card, CARD_BG, CARD_BORDER)

    card.accent = card:CreateTexture(nil, "ARTWORK")
    card.accent:SetPoint("TOPLEFT", 1, -1)
    card.accent:SetPoint("BOTTOMLEFT", 1, 1)
    card.accent:SetWidth(3)
    card.accent:SetColorTexture(UI.GOLD[1], UI.GOLD[2], UI.GOLD[3], 0.9)
    card.accent:Hide()

    function card:SetHovered(hovered)
        self:SetBackdropColor(unpack(hovered and CARD_BG_HOVER or CARD_BG))
        self:SetBackdropBorderColor(unpack(hovered and CARD_BORDER_HOVER or CARD_BORDER))
    end
    return card
end

local function ShowTooltip(owner, title, text, extra, extraColor)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT", 8, 0)
    GameTooltip:SetText(title, 1, 0.82, 0, 1, true)
    if text and text ~= "" then GameTooltip:AddLine(text, 1, 1, 1, true) end
    if extra then GameTooltip:AddLine(extra, extraColor[1], extraColor[2], extraColor[3], true) end
    GameTooltip:Show()
end
UI.ShowTooltip = ShowTooltip

local OPTION_HEIGHT = 24

-- One sub-option line under a feature card: small checkbox and label.
-- Greyed out while the feature itself is off.
local function CreateOptionRow(card, option, get, set)
    local row = CreateFrame("Button", nil, card)
    row:SetHeight(OPTION_HEIGHT)

    row.check = UI.CreateCheckbox(row)
    row.check:SetSize(24, 23)
    row.check:SetPoint("LEFT", 0, 0)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    UI.Localize(row.text, option.title)

    function row:Refresh(active)
        self.active = active
        self.check:SetChecked(get())
        self.check:SetEnabled(active)
        self:SetAlpha(active and 1 or 0.45)
        local shade = active and 0.9 or 0.6
        self.text:SetTextColor(shade, shade, shade)
    end

    local function Toggle(value)
        if not row.active then return end
        set(value)
        UI.PlayCheck(value)
        row:Refresh(true)
    end
    row.check:SetScript("OnClick", function(self) Toggle(self:GetChecked() and true or false) end)
    row:SetScript("OnClick", function() Toggle(not get()) end)

    local function Enter()
        card:SetHovered(true)
        ShowTooltip(row, row.text:GetText(), option.tip and L[option.tip] or nil)
    end
    local function Leave()
        if card:IsMouseOver() then return end
        card:SetHovered(false)
        GameTooltip:Hide()
    end
    row:SetScript("OnEnter", Enter)
    row:SetScript("OnLeave", Leave)
    row.check:HookScript("OnEnter", Enter)
    row.check:HookScript("OnLeave", Leave)
    return row
end

-- A sub-option that is a button (option.action) instead of a checkbox.
local function CreateActionRow(card, option)
    local row = CreateFrame("Frame", nil, card)
    row:SetHeight(OPTION_HEIGHT)

    row.button = UI.CreateButton(row, option.title, 180)
    row.button:SetHeight(22)
    row.button:SetPoint("LEFT", 2, 0)
    if row.button.SetMotionScriptsWhileDisabled then row.button:SetMotionScriptsWhileDisabled(true) end

    function row:Refresh(active)
        self.active = active
        -- A title getter can show live state, e.g. "Channels (2 hidden)".
        if type(option.title) == "function" then self.button:SetText(option.title()) end
        self.button:SetEnabled(active)
        self:SetAlpha(active and 1 or 0.45)
    end

    row.button:SetScript("OnClick", function(self)
        if not row.active then return end
        UI.PlayClick()
        option.action(self) -- the button, to anchor a menu
    end)
    row.button:SetScript("OnEnter", function(self)
        card:SetHovered(true)
        ShowTooltip(self, self:GetText(), option.tip and L[option.tip] or nil)
    end)
    row.button:SetScript("OnLeave", function()
        if not card:IsMouseOver() then card:SetHovered(false) end
        GameTooltip:Hide()
    end)
    return row
end

local OPTION_INDENT = 22

-- opts: title, desc, tip (locale keys or getters), isNew, reload, get(), set(value)
--       options = { { key, title, tip }, ... }, getOption(key), setOption(key, value)
--       an option with `action = function` is a button instead of a checkbox
--       an option with `get` and `set` reads and saves its value through them
--       an option with `requires = "otherKey"` is indented under that option
--       and greyed out while it is off
function UI.CreateToggleCard(parent, opts)
    local card = CreateCard(parent, true)

    card.check = UI.CreateCheckbox(card)
    card.check:SetPoint("TOPLEFT", 12, -12)

    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.title:SetPoint("TOPLEFT", card.check, "TOPRIGHT", 8, -5)
    card.title:SetJustifyH("LEFT")
    card.title:SetWordWrap(false)
    UI.Localize(card.title, opts.title)

    card.desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.desc:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -5)
    card.desc:SetJustifyH("LEFT")
    card.desc:SetJustifyV("TOP")
    card.desc:SetWordWrap(true)
    card.desc:SetTextColor(unpack(UI.MUTED))
    UI.Localize(card.desc, opts.desc)

    card.badges = {}
    if opts.isNew then table.insert(card.badges, CreateBadge(card, "BADGE_NEW", UI.GREEN)) end
    if opts.reload then table.insert(card.badges, CreateBadge(card, "BADGE_RELOAD", UI.ORANGE)) end

    card.options = {}
    for _, option in ipairs(opts.options or {}) do
        local row
        if option.action then
            row = CreateActionRow(card, option)
        else
            row = CreateOptionRow(card, option,
                option.get or function() return opts.getOption(option.key) end,
                option.set or function(value) opts.setOption(option.key, value) end)
        end
        row.option = option
        table.insert(card.options, row)
    end

    function card:Refresh()
        local on = opts.get() == true
        self.check:SetChecked(on)
        self.accent:SetShown(on)
        self.title:SetTextColor(on and 1 or 0.85, on and 1 or 0.85, on and 1 or 0.85)
        for _, row in ipairs(self.options) do
            local requires = row.option.requires
            row:Refresh(on and (requires == nil or opts.getOption(requires) == true))
        end
    end

    function card:Layout(width)
        self:SetWidth(width)
        local right = width - 12
        for _, badge in ipairs(self.badges) do
            badge:Layout()
            badge:ClearAllPoints()
            badge:SetPoint("TOPRIGHT", self, "TOPLEFT", right, -16)
            right = right - badge:GetWidth() - 6
        end
        local textLeft = 12 + self.check:GetWidth() + 8
        self.title:SetWidth(math.max(40, right - textLeft - 6))
        self.desc:SetWidth(width - textLeft - 16)
        local height = 17 + self.title:GetStringHeight() + 5 + self.desc:GetStringHeight() + 14
        if #self.options > 0 then
            local y = math.ceil(height) - 6
            for _, row in ipairs(self.options) do
                local indent = row.option.requires and OPTION_INDENT or 0
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", self, "TOPLEFT", textLeft - 4 + indent, -y)
                row:SetWidth(width - textLeft - 12 - indent)
                if row.text then row.text:SetWidth(width - textLeft - 48 - indent) end
                y = y + OPTION_HEIGHT
            end
            height = y + 10
        end
        self:SetHeight(math.max(56, math.ceil(height)))
    end

    local function Toggle(value)
        opts.set(value)
        UI.PlayCheck(value)
        card:Refresh()
    end

    card.check:SetScript("OnClick", function(self) Toggle(self:GetChecked() and true or false) end)
    card:SetScript("OnClick", function() Toggle(not opts.get()) end)

    local function Enter()
        card:SetHovered(true)
        local tip = opts.tip and L[opts.tip] or nil
        if opts.reload then
            ShowTooltip(card, card.title:GetText(), tip, L.RELOAD_TIP, UI.ORANGE)
        else
            ShowTooltip(card, card.title:GetText(), tip)
        end
    end
    local function Leave()
        if card:IsMouseOver() then return end
        card:SetHovered(false)
        GameTooltip:Hide()
    end
    card:SetScript("OnEnter", Enter)
    card:SetScript("OnLeave", Leave)
    card.check:HookScript("OnEnter", Enter)
    card.check:HookScript("OnLeave", Leave)
    card:SetScript("OnHide", function() card:SetHovered(false) end)

    card:Refresh()
    return card
end

-- A card holding a title, a description and any control on the right.
function UI.CreateSettingCard(parent, title, desc, control, controlWidth)
    local card = CreateCard(parent, false)

    card.title = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.title:SetPoint("TOPLEFT", 16, -14)
    card.title:SetJustifyH("LEFT")
    UI.Localize(card.title, title)

    card.desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.desc:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -5)
    card.desc:SetJustifyH("LEFT")
    card.desc:SetJustifyV("TOP")
    card.desc:SetWordWrap(true)
    card.desc:SetTextColor(unpack(UI.MUTED))
    UI.Localize(card.desc, desc)

    control:SetParent(card)
    control:ClearAllPoints()
    control:SetPoint("RIGHT", card, "RIGHT", -14, 0)

    function card:Layout(width)
        self:SetWidth(width)
        if control.Layout then control:Layout() end
        local reserved = (controlWidth and controlWidth()) or control:GetWidth()
        local textWidth = width - 16 - reserved - 28
        self.title:SetWidth(textWidth)
        self.desc:SetWidth(textWidth)
        local height = 14 + self.title:GetStringHeight() + 5 + self.desc:GetStringHeight() + 14
        self:SetHeight(math.max(56, math.ceil(height)))
    end
    function card:Refresh()
        if control.Refresh then control:Refresh() end
    end
    return card
end

---------------------------------------------------------------------------
-- Segmented control (language picker, note ratings, filters)
-- options: { { value = ..., label = key-or-getter, color = {r,g,b} }, ... }
---------------------------------------------------------------------------

function UI.CreateSegmented(parent, options, get, set)
    local group = CreateFrame("Frame", nil, parent)
    group:SetHeight(24)
    group.buttons = {}

    for _, option in ipairs(options) do
        local button = CreateFrame("Button", nil, group, "BackdropTemplate")
        button:SetHeight(24)
        button.value = option.value
        button.color = option.color or UI.GOLD
        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        button.text:SetPoint("CENTER")
        UI.Localize(button.text, option.label)
        button:SetScript("OnClick", function(self)
            if get() == self.value then return end
            set(self.value)
            UI.PlayClick()
            group:Refresh()
        end)
        button:SetScript("OnEnter", function(self)
            if get() ~= self.value then
                self:SetBackdropBorderColor(self.color[1], self.color[2], self.color[3], 0.5)
            end
        end)
        button:SetScript("OnLeave", function() group:Refresh() end)
        table.insert(group.buttons, button)
    end

    function group:Refresh()
        local current = get()
        for _, button in ipairs(self.buttons) do
            local selected = button.value == current
            local r, g, b = unpack(button.color)
            UI.ApplyFlat(button,
                selected and { r, g, b, 0.18 } or { 0, 0, 0, 0.35 },
                selected and { r, g, b, 0.85 } or { 1, 1, 1, 0.14 })
            if selected then
                button.text:SetTextColor(r, g, b)
            else
                button.text:SetTextColor(0.85, 0.85, 0.85)
            end
        end
    end

    function group:Layout()
        local x = 0
        for _, button in ipairs(self.buttons) do
            local width = math.max(70, math.ceil(button.text:GetStringWidth()) + 24)
            button:SetWidth(width)
            button:ClearAllPoints()
            button:SetPoint("LEFT", self, "LEFT", x, 0)
            x = x + width + 4
        end
        self:SetWidth(x - 4)
    end

    group:Layout()
    group:Refresh()
    return group
end

---------------------------------------------------------------------------
-- Sidebar category button, styled like Blizzard's Options list
---------------------------------------------------------------------------

function UI.CreateCategoryButton(parent, category)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(30)

    button.selected = button:CreateTexture(nil, "BACKGROUND")
    button.selected:SetAllPoints()
    if UI.HasAtlas("Options_List_Active") then
        button.selected:SetAtlas("Options_List_Active")
    else
        button.selected:SetColorTexture(1, 0.82, 0, 0.15)
    end
    button.selected:Hide()

    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    if UI.HasAtlas("Options_List_Hover") then
        highlight:SetAtlas("Options_List_Hover")
    else
        highlight:SetColorTexture(1, 1, 1, 0.08)
    end

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetSize(18, 18)
    button.icon:SetPoint("LEFT", 10, 0)
    button.icon:SetTexture(category.icon)
    button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    button.count = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    button.count:SetPoint("RIGHT", -10, 0)

    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.text:SetPoint("LEFT", button.icon, "RIGHT", 8, 0)
    button.text:SetPoint("RIGHT", button.count, "LEFT", -4, 0)
    button.text:SetJustifyH("LEFT")
    button.text:SetWordWrap(false)
    UI.Localize(button.text, category.title)

    function button:SetSelected(selected)
        self.selected:SetShown(selected)
        self.text:SetFontObject(selected and "GameFontNormal" or "GameFontHighlight")
    end

    function button:SetCount(enabled, total)
        if total and total > 0 then
            self.count:SetText(("%d/%d"):format(enabled, total))
        else
            self.count:SetText("")
        end
    end

    return button
end
