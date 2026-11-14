local _, ns = ...
local L, UI = ns.L, ns.UI

local Panel = {}
ns.Panel = Panel

local FRAME_NAME = "BudgetForeverFrame"
local WIDTH, HEIGHT = 780, 520
local SIDEBAR_WIDTH = 200
local HEADER_OFFSET = -60
local FOOTER_HEIGHT = 30
local ITEM_SPACING = 8

local frame
local pages, buttons = {}, {}
local currentKey

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function CreateNote(parent, source)
    local holder = CreateFrame("Frame", nil, parent)
    holder.text = holder:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    holder.text:SetPoint("TOPLEFT", 4, -6)
    holder.text:SetJustifyH("LEFT")
    holder.text:SetWordWrap(true)
    UI.Localize(holder.text, source)
    function holder:Layout(width)
        self:SetWidth(width)
        self.text:SetWidth(width - 8)
        self:SetHeight(math.ceil(self.text:GetStringHeight()) + 12)
    end
    return holder
end

local function CountEnabled(categoryKey)
    local features = ns:GetFeatures(categoryKey)
    local enabled = 0
    for _, def in ipairs(features) do
        if ns:IsEnabled(def.key) then enabled = enabled + 1 end
    end
    return enabled, #features
end

local function DefaultKey()
    for _, category in ipairs(ns.categories) do
        if buttons[category.key] then return category.key end
    end
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local function LayoutPage(page)
    local width = page.scroll:GetWidth()
    if not width or width < 100 then
        width = WIDTH - SIDEBAR_WIDTH - 14 - 44
    end
    local y = 0
    for _, item in ipairs(page.items) do
        if item.Refresh then item:Refresh() end
        item:Layout(width)
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", page.child, "TOPLEFT", 0, -y)
        y = y + item:GetHeight() + ITEM_SPACING
    end
    local contentHeight = math.max(1, y - ITEM_SPACING)
    page.child:SetSize(width, contentHeight)
    if page.scroll.UpdateScrollChildRect then page.scroll:UpdateScrollChildRect() end
    if page.scroll.ScrollBar then
        page.scroll.ScrollBar:SetAlpha(contentHeight > page.scroll:GetHeight() + 1 and 1 or 0)
    end
end

local function CreateDivider(page, y)
    local rule = page:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 16, y)
    rule:SetPoint("TOPRIGHT", -16, y)
    rule:SetTexture("Interface\\Buttons\\WHITE8x8")
    if rule.SetGradient and CreateColor then
        rule:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.45), CreateColor(1, 0.82, 0, 0.02))
    else
        rule:SetVertexColor(1, 0.82, 0, 0.25)
    end
end

local function CreatePage(category)
    local page = CreateFrame("Frame", nil, frame.content)
    page:SetAllPoints()
    page:Hide()

    page.icon = page:CreateTexture(nil, "ARTWORK")
    page.icon:SetSize(32, 32)
    page.icon:SetPoint("TOPLEFT", 18, -14)
    page.icon:SetTexture(category.icon)
    page.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    page.title = page:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    page.title:SetPoint("TOPLEFT", page.icon, "TOPRIGHT", 10, -1)
    UI.Localize(page.title, category.title)

    page.desc = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    page.desc:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -4)
    page.desc:SetTextColor(unpack(UI.MUTED))
    UI.Localize(page.desc, category.desc)

    CreateDivider(page, -58)

    local template = UI.HasTemplate("ScrollFrameTemplate") and "ScrollFrameTemplate" or "UIPanelScrollFrameTemplate"
    page.scroll = CreateFrame("ScrollFrame", nil, page, template)
    page.scroll:SetPoint("TOPLEFT", 14, -70)
    page.scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    page.child = CreateFrame("Frame", nil, page.scroll)
    page.child:SetSize(1, 1)
    page.scroll:SetScrollChild(page.child)

    page.items = {}
    page:SetScript("OnShow", LayoutPage)
    -- For pages whose content changes size (e.g. the notebook list).
    function page.Relayout()
        if page:IsVisible() then LayoutPage(page) end
    end
    return page
end

local function BuildFeaturePage(page, category)
    for _, def in ipairs(ns:GetFeatures(category.key)) do
        table.insert(page.items, UI.CreateToggleCard(page.child, {
            title = def.title,
            desc = def.desc,
            tip = def.tip,
            isNew = def.isNew,
            reload = def.reload,
            get = function() return ns:IsEnabled(def.key) end,
            set = function(value) ns:SetEnabled(def.key, value) end,
            options = def.options,
            getOption = function(option) return ns:GetOption(def.key, option) end,
            setOption = function(option, value) ns:SetOption(def.key, option, value) end,
        }))
    end
    -- Extra content a category brings along (see Features\PlayerNotes.lua).
    if category.BuildExtra then category.BuildExtra(page) end
end

local function BuildSettingsPage(page)
    local options = {}
    for _, language in ipairs(ns.languages) do
        local label = language.key or function() return language.label end
        table.insert(options, { value = language.code, label = label })
    end
    local picker = UI.CreateSegmented(page.child, options,
        function() return ns.db.general.language end,
        function(code) ns:ChangeLanguage(code) end)
    table.insert(page.items, UI.CreateSettingCard(page.child, "GENERAL_LANGUAGE", "GENERAL_LANGUAGE_DESC", picker))

    table.insert(page.items, UI.CreateToggleCard(page.child, {
        title = "GENERAL_LOGIN_TITLE",
        desc = "GENERAL_LOGIN_DESC",
        get = function() return ns.db.general.loginMessage end,
        set = function(value) ns.db.general.loginMessage = value end,
    }))

    table.insert(page.items, UI.CreateToggleCard(page.child, {
        title = "GENERAL_MINIMAP_TITLE",
        desc = "GENERAL_MINIMAP_DESC",
        get = function() return ns.db.general.minimapButton end,
        set = function(value) ns.MinimapButton:SetShown(value) end,
    }))

    local reset = UI.CreateButton(page.child, "GENERAL_RESET_BUTTON", 150)
    reset:SetScript("OnClick", function() ns:ConfirmReset() end)
    table.insert(page.items, UI.CreateSettingCard(page.child, "GENERAL_RESET", "GENERAL_RESET_DESC", reset))

    table.insert(page.items, CreateNote(page.child, "GENERAL_ABOUT"))
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function SavePosition()
    local point, _, relativePoint, x, y = frame:GetPoint(1)
    if point then ns.db.window.point = { point, relativePoint, x, y } end
end

local function RestorePosition()
    frame:ClearAllPoints()
    local saved = ns.db.window.point
    if type(saved) == "table" and type(saved[1]) == "string" then
        frame:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
end

local function UpdateChrome()
    if not frame then return end
    for key, button in pairs(buttons) do
        button:SetCount(CountEnabled(key))
    end
    local needsReload = ns:NeedsReload()
    frame.reloadButton:SetShown(needsReload)
    frame.reloadText:SetShown(needsReload)
end

local function BuildChrome()
    frame = UI.CreateWindow(FRAME_NAME, WIDTH, HEIGHT, ns.ICON_MINI)
    frame:SetFrameStrata("HIGH")
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition()
    end)
    frame:SetScript("OnShow", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN)
        UpdateChrome()
    end)
    frame:SetScript("OnHide", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)
    frame:SetWindowTitle(L.ADDON_TITLE)

    local tagline = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tagline:SetPoint("TOPLEFT", 66, -37)
    tagline:SetTextColor(unpack(UI.MUTED))
    UI.Localize(tagline, "TAGLINE")

    frame.sidebar = UI.CreateInset(frame)
    frame.sidebar:SetPoint("TOPLEFT", 6, HEADER_OFFSET)
    frame.sidebar:SetPoint("BOTTOMLEFT", 6, FOOTER_HEIGHT)
    frame.sidebar:SetWidth(SIDEBAR_WIDTH)

    frame.content = UI.CreateInset(frame)
    frame.content:SetPoint("TOPLEFT", frame.sidebar, "TOPRIGHT", 4, 0)
    frame.content:SetPoint("BOTTOMRIGHT", -6, FOOTER_HEIGHT)

    -- Footer
    local version = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", 14, 11)
    UI.Localize(version, function() return L.VERSION_LINE:format(ns.version) end)

    frame.reloadButton = UI.CreateButton(frame, "RELOAD_UI", 130)
    frame.reloadButton:SetPoint("BOTTOMRIGHT", -8, 5)
    frame.reloadButton:SetScript("OnClick", function() ReloadUI() end)

    frame.reloadText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.reloadText:SetPoint("RIGHT", frame.reloadButton, "LEFT", -10, 0)
    frame.reloadText:SetTextColor(unpack(UI.ORANGE))
    UI.Localize(frame.reloadText, "RELOAD_NEEDED")
end

local function BuildNavigation()
    local y = -8
    for _, category in ipairs(ns.categories) do
        local hasFeatures = #ns:GetFeatures(category.key) > 0
        if category.settings or hasFeatures or category.BuildExtra then
            local button = UI.CreateCategoryButton(frame.sidebar, category)
            if category.settings then
                -- Settings live at the bottom of the sidebar, apart from features.
                button:SetPoint("BOTTOMLEFT", 6, 8)
                button:SetPoint("BOTTOMRIGHT", -6, 8)
                local rule = frame.sidebar:CreateTexture(nil, "ARTWORK")
                rule:SetHeight(1)
                rule:SetPoint("BOTTOMLEFT", button, "TOPLEFT", 4, 6)
                rule:SetPoint("BOTTOMRIGHT", button, "TOPRIGHT", -4, 6)
                rule:SetColorTexture(1, 1, 1, 0.08)
            else
                button:SetPoint("TOPLEFT", 6, y)
                button:SetPoint("TOPRIGHT", -6, y)
                y = y - 32
            end
            button:SetScript("OnClick", function()
                PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
                Panel:Select(category.key)
            end)
            buttons[category.key] = button

            local page = CreatePage(category)
            if category.settings then
                BuildSettingsPage(page)
            else
                BuildFeaturePage(page, category)
            end
            pages[category.key] = page
        end
    end
end

local function Build()
    BuildChrome()
    BuildNavigation()
    RestorePosition()
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function Panel:Select(key)
    if not pages[key] then key = DefaultKey() end
    currentKey = key
    ns.db.window.page = key
    for pageKey, page in pairs(pages) do
        page:SetShown(pageKey == key)
    end
    for buttonKey, button in pairs(buttons) do
        button:SetSelected(buttonKey == key)
    end
end

function Panel:Open(key)
    if not frame then Build() end
    frame:Show()
    frame:Raise()
    self:Select(key or currentKey or ns.db.window.page)
end

function Panel:Toggle()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        self:Open()
    end
end

-- Launcher inside Game Menu > Options > AddOns.
function Panel:RegisterSettingsCategory()
    if self.category or not Settings or not Settings.RegisterCanvasLayoutCategory then return end

    local canvas = CreateFrame("Frame")

    local icon = canvas:CreateTexture(nil, "ARTWORK")
    icon:SetSize(56, 56)
    icon:SetPoint("TOPLEFT", 24, -24)
    icon:SetTexture(ns.ICON)

    local title = canvas:CreateFontString(nil, "OVERLAY", _G.GameFontNormalHuge and "GameFontNormalHuge" or "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 14, -6)
    title:SetText(L.ADDON_TITLE)

    local tagline = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tagline:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    tagline:SetTextColor(unpack(UI.MUTED))
    UI.Localize(tagline, "TAGLINE")

    local open = UI.CreateButton(canvas, "OPEN_PANEL", 220)
    open:SetHeight(28)
    open:SetPoint("TOPLEFT", icon, "BOTTOMLEFT", 0, -24)
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel:IsShown() and not InCombatLockdown() then
            HideUIPanel(SettingsPanel)
        end
        Panel:Open()
    end)

    local hint = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", open, "RIGHT", 12, 0)
    UI.Localize(hint, "SLASH_HINT")

    self.category = Settings.RegisterCanvasLayoutCategory(canvas, L.ADDON_TITLE)
    Settings.RegisterAddOnCategory(self.category)
end

local function RefreshCurrentPage()
    local page = pages[currentKey]
    if page and page:IsShown() then
        for _, item in ipairs(page.items) do
            if item.Refresh then item:Refresh() end
        end
    end
end

ns:On("FEATURE_CHANGED", function()
    if not frame then return end
    UpdateChrome()
    RefreshCurrentPage()
end)

ns:On("OPTION_CHANGED", function()
    if frame then RefreshCurrentPage() end
end)

ns:On("LANGUAGE_CHANGED", function()
    UI.RefreshTexts()
    if not frame then return end
    UpdateChrome()
    local page = pages[currentKey]
    if page and page:IsShown() then LayoutPage(page) end
end)
