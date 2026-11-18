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
local overviewKey, overviewList -- the page the search box filters
local searchQuery = ""

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
    local category = ns:GetCategory(categoryKey)
    local features = (category and category.overview) and ns.features or ns:GetFeatures(categoryKey)
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
    UI.Localize(page.title, category.title)

    if category.desc then
        page.title:SetPoint("TOPLEFT", page.icon, "TOPRIGHT", 10, -1)
        page.desc = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        page.desc:SetPoint("TOPLEFT", page.title, "BOTTOMLEFT", 0, -4)
        page.desc:SetTextColor(unpack(UI.MUTED))
        UI.Localize(page.desc, category.desc)
    else
        -- No subtitle (Overview): the title sits level with the icon.
        page.title:SetPoint("LEFT", page.icon, "RIGHT", 10, 0)
    end

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

---------------------------------------------------------------------------
-- Overview: every feature on one line, grouped by category. The checkbox
-- toggles the feature, the tooltip holds the description, and a group
-- header opens that category's page (sub-options live there).
---------------------------------------------------------------------------

local OVERVIEW_ROW = 24
local OVERVIEW_HEADER = 26
local OVERVIEW_GROUP_GAP = 6

local function Text(source)
    if type(source) == "function" then return source() end
    return source and L[source] or nil
end

---------------------------------------------------------------------------
-- Search: the box in the window header filters the overview list. Texts
-- are compared in lower case, without accents or colour codes, so "metier"
-- finds "Métiers".
---------------------------------------------------------------------------

local ACCENTS = {
    ["à"] = "a", ["á"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a", ["å"] = "a",
    ["À"] = "a", ["Á"] = "a", ["Â"] = "a", ["Ã"] = "a", ["Ä"] = "a", ["Å"] = "a",
    ["ç"] = "c", ["Ç"] = "c", ["ñ"] = "n", ["Ñ"] = "n",
    ["è"] = "e", ["é"] = "e", ["ê"] = "e", ["ë"] = "e",
    ["È"] = "e", ["É"] = "e", ["Ê"] = "e", ["Ë"] = "e",
    ["ì"] = "i", ["í"] = "i", ["î"] = "i", ["ï"] = "i",
    ["Ì"] = "i", ["Í"] = "i", ["Î"] = "i", ["Ï"] = "i",
    ["ò"] = "o", ["ó"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
    ["Ò"] = "o", ["Ó"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ö"] = "o",
    ["ù"] = "u", ["ú"] = "u", ["û"] = "u", ["ü"] = "u",
    ["Ù"] = "u", ["Ú"] = "u", ["Û"] = "u", ["Ü"] = "u",
    ["ÿ"] = "y", ["œ"] = "oe", ["Œ"] = "oe", ["æ"] = "ae", ["Æ"] = "ae",
}

local function Fold(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    text = text:gsub("[\195-\197][\128-\191]", ACCENTS)
    -- ASCII letters only: the other bytes belong to multi-byte characters.
    return (text:gsub("[A-Z]", string.lower))
end
Panel.Fold = Fold

-- Everything a feature says about itself: its category, its title, its
-- description, its tooltip and its sub-options.
local function SearchText(def, category)
    local parts = {}
    local function add(source)
        local text = Text(source)
        if type(text) == "string" and text ~= "" then parts[#parts + 1] = Fold(text) end
    end
    add(category and category.title)
    add(def.title)
    add(def.desc)
    add(def.tip)
    for _, option in ipairs(def.options or {}) do
        add(option.title)
        add(option.tip)
    end
    return table.concat(parts, "\n")
end

-- True when every word of the query is somewhere in the feature's texts.
local function Matches(def, category, query)
    local text
    for word in Fold(query):gmatch("%S+") do
        text = text or SearchText(def, category)
        if not text:find(word, 1, true) then return false end
    end
    return true
end
Panel.Matches = Matches

local function CreateOverviewHeader(list, category)
    local header = CreateFrame("Button", nil, list)
    header:SetHeight(OVERVIEW_HEADER)
    header.isHeader = true

    local highlight = header:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 0.82, 0, 0.08)

    local rule = header:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("BOTTOMLEFT", 0, 0)
    rule:SetPoint("BOTTOMRIGHT", 0, 0)
    rule:SetTexture("Interface\\Buttons\\WHITE8x8")
    if rule.SetGradient and CreateColor then
        rule:SetGradient("HORIZONTAL", CreateColor(1, 0.82, 0, 0.35), CreateColor(1, 0.82, 0, 0.02))
    else
        rule:SetVertexColor(1, 0.82, 0, 0.2)
    end

    header.icon = header:CreateTexture(nil, "ARTWORK")
    header.icon:SetSize(16, 16)
    header.icon:SetPoint("LEFT", 4, 0)
    header.icon:SetTexture(category.icon)
    header.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    header.count = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    header.count:SetPoint("RIGHT", -8, 0)

    header.text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.text:SetPoint("LEFT", header.icon, "RIGHT", 6, 0)
    header.text:SetPoint("RIGHT", header.count, "LEFT", -6, 0)
    header.text:SetJustifyH("LEFT")
    header.text:SetWordWrap(false)
    UI.Localize(header.text, category.title)

    function header:Refresh()
        self.count:SetText(("%d/%d"):format(CountEnabled(category.key)))
    end

    header:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION)
        GameTooltip:Hide()
        Panel:Select(category.key)
    end)
    header:SetScript("OnEnter", function(self)
        UI.ShowTooltip(self, self.text:GetText(), L.OVERVIEW_OPEN_PAGE)
    end)
    header:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return header
end

local function CreateOverviewRow(list, def, category)
    local row = CreateFrame("Button", nil, list)
    row:SetHeight(OVERVIEW_ROW)
    row.def, row.category = def, category

    -- Shown on every other visible row (see list:Layout).
    row.stripe = row:CreateTexture(nil, "BACKGROUND")
    row.stripe:SetAllPoints()
    row.stripe:SetColorTexture(1, 1, 1, 0.025)

    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.06)

    row.check = UI.CreateCheckbox(row)
    row.check:SetSize(24, 23)
    row.check:SetPoint("LEFT", 14, 0)

    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.text:SetPoint("LEFT", row.check, "RIGHT", 4, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    UI.Localize(row.text, def.title)

    if def.reload then
        row.reload = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.reload:SetPoint("RIGHT", -8, 0)
        row.reload:SetTextColor(unpack(UI.ORANGE))
        UI.Localize(row.reload, "BADGE_RELOAD")
        row.text:SetPoint("RIGHT", row.reload, "LEFT", -8, 0)
    else
        row.text:SetPoint("RIGHT", -8, 0)
    end

    function row:Refresh()
        local on = ns:IsEnabled(def.key)
        self.check:SetChecked(on)
        local shade = on and 1 or 0.6
        self.text:SetTextColor(shade, shade, shade)
    end

    local function Toggle(value)
        ns:SetEnabled(def.key, value)
        UI.PlayCheck(value)
        row:Refresh()
    end
    row.check:SetScript("OnClick", function(self) Toggle(self:GetChecked() and true or false) end)
    row:SetScript("OnClick", function() Toggle(not ns:IsEnabled(def.key)) end)

    local function Enter()
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT", 8, 0)
        GameTooltip:SetText(row.text:GetText(), 1, 0.82, 0, 1, true)
        local desc, tip = Text(def.desc), Text(def.tip)
        if desc and desc ~= "" then GameTooltip:AddLine(desc, 1, 1, 1, true) end
        if tip and tip ~= "" then GameTooltip:AddLine(tip, UI.MUTED[1], UI.MUTED[2], UI.MUTED[3], true) end
        if def.reload then GameTooltip:AddLine(L.RELOAD_TIP, UI.ORANGE[1], UI.ORANGE[2], UI.ORANGE[3], true) end
        GameTooltip:Show()
    end
    local function Leave()
        if row:IsMouseOver() then return end
        GameTooltip:Hide()
    end
    row:SetScript("OnEnter", Enter)
    row:SetScript("OnLeave", Leave)
    row.check:HookScript("OnEnter", Enter)
    row.check:HookScript("OnLeave", Leave)
    return row
end

local function BuildOverviewPage(page)
    local list = CreateFrame("Frame", nil, page.child)
    list.lines = {}
    for _, category in ipairs(ns.categories) do
        local features = ns:GetFeatures(category.key)
        if not category.overview and #features > 0 then
            table.insert(list.lines, CreateOverviewHeader(list, category))
            for _, def in ipairs(features) do
                table.insert(list.lines, CreateOverviewRow(list, def, category))
            end
        end
    end

    list.empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    list.empty:SetPoint("TOP", 0, -24)
    list.empty:SetJustifyH("CENTER")
    list.empty:SetWordWrap(true)
    list.empty:Hide()

    function list:Refresh()
        for _, line in ipairs(self.lines) do line:Refresh() end
    end

    -- Lines are matched against the search on every layout, so a change of
    -- language or of a live label is picked up too. A header stays only
    -- when one of its features does.
    function list:Layout(width)
        self:SetWidth(width)
        local query = searchQuery
        local shown, header = {}, nil
        for _, line in ipairs(self.lines) do
            if line.isHeader then
                header = line
            elseif Matches(line.def, line.category, query) then
                if header then
                    shown[header] = true
                    header = nil
                end
                shown[line] = true
            end
        end

        local y, count, stripe = 0, 0, 0
        for _, line in ipairs(self.lines) do
            line:SetShown(shown[line] == true)
            if shown[line] then
                if line.isHeader then
                    if y > 0 then y = y + OVERVIEW_GROUP_GAP end
                    stripe = 0
                else
                    count = count + 1
                    stripe = stripe + 1
                    line.stripe:SetShown(stripe % 2 == 0)
                end
                line:ClearAllPoints()
                line:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -y)
                line:SetWidth(width)
                y = y + line:GetHeight()
            end
        end

        self.empty:SetShown(count == 0)
        if count == 0 then
            self.empty:SetWidth(width - 40)
            self.empty:SetText(L.SEARCH_EMPTY:format(query))
            y = 24 + math.ceil(self.empty:GetStringHeight()) + 24
        end
        self:SetHeight(math.max(1, y))
    end

    list:Refresh()
    table.insert(page.items, list)
    overviewList = list
end

-- Typing in the search box shows the overview, cut down to what matches.
local function ApplySearch(text)
    local query = strtrim(text or "")
    if query == searchQuery then return end
    searchQuery = query
    local page = overviewKey and pages[overviewKey]
    if not page then return end
    page.scroll:SetVerticalScroll(0)
    if query ~= "" and currentKey ~= overviewKey then
        Panel:Select(overviewKey) -- lays the page out as it shows
    else
        page.Relayout()
    end
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
        -- The window opens again on the full list, not on an old search.
        frame.searchBox:SetText("")
        frame.searchBox:ClearFocus()
        ApplySearch("")
    end)
    frame:SetWindowTitle(L.ADDON_TITLE)

    local tagline = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tagline:SetPoint("TOPLEFT", 66, -37)
    tagline:SetTextColor(unpack(UI.MUTED))
    UI.Localize(tagline, "TAGLINE")

    -- Search box, top right of the header: filters the overview as you type.
    local searchTemplate = UI.HasTemplate("SearchBoxTemplate") and "SearchBoxTemplate" or "InputBoxTemplate"
    frame.searchBox = CreateFrame("EditBox", nil, frame, searchTemplate)
    frame.searchBox:SetSize(200, 20)
    frame.searchBox:SetPoint("TOPRIGHT", -14, -32)
    frame.searchBox:SetAutoFocus(false)
    frame.searchBox:SetMaxLetters(40)
    if frame.searchBox.Instructions then UI.Localize(frame.searchBox.Instructions, "SEARCH_FEATURES") end
    frame.searchBox:HookScript("OnTextChanged", function(self) ApplySearch(self:GetText()) end)
    frame.searchBox:HookScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.searchBox:HookScript("OnEnterPressed", function(self) self:ClearFocus() end)

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
        if category.settings or category.overview or hasFeatures or category.BuildExtra then
            local button = UI.CreateCategoryButton(frame.sidebar, category)
            if category.overview then
                -- First in the sidebar, set apart from the feature pages.
                button:SetPoint("TOPLEFT", 6, y)
                button:SetPoint("TOPRIGHT", -6, y)
                local rule = frame.sidebar:CreateTexture(nil, "ARTWORK")
                rule:SetHeight(1)
                rule:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 4, -4)
                rule:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", -4, -4)
                rule:SetColorTexture(1, 1, 1, 0.08)
                y = y - 32 - 8
            elseif category.settings then
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
            elseif category.overview then
                BuildOverviewPage(page)
                overviewKey = category.key
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
    -- Leaving the overview for another page ends the search.
    if key ~= overviewKey and searchQuery ~= "" and frame.searchBox then
        frame.searchBox:SetText("")
        frame.searchBox:ClearFocus()
        searchQuery = "" -- the page being left is laid out again when it next shows
    end
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
