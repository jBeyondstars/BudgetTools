local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
A color for each equipment set: the set's items get a border of that color in
the bags and the bank.

Choosing:
  The gear button of a set in the Equipment Manager (character window) gets
  two more entries, and the feature's button in /bgt lists every set. The
  color comes from the game's own color picker: the borders follow it live,
  and Cancel puts the old color back. The set's icon in the Equipment Manager
  wears the same border. Colors are per character, by set ID, so renaming a
  set keeps its color; deleting a set forgets it. Stored in
  BudgetForeverDB.setcolors.chars[key][setID] = { r, g, b }, kept by /bgt reset.

Which items:
  C_Container.GetContainerItemEquipmentSetInfo gives the names of the sets
  holding the item of a slot, for bags and bank alike, as one string
  ("Tank, Heal"). A name counts only as a whole entry of that list, so "Tank"
  is not found in "Off Tank". An item in two colored sets shows both: top and
  left in the first color, bottom and right in the second.

The border:
  Textures on the item button itself, 3 px wide and 1 px outside the slot,
  with a thin dark line inside so a color stays visible on an icon of the same
  hue. Nothing of Blizzard's is moved or replaced.

When borders refresh:
  Post-hooks on each bag window's UpdateItems and on the bank buttons' Refresh,
  so they follow every item move, plus a full pass when a set or a color
  changes.

ns.SetColors.Rank also serves the "keep sets together" option of the bag sort
(Features\BagSort.lua), which works even with the borders turned off.
]]

local KEY = "setColors"

local Colors = {}
ns.SetColors = Colors

local THICKNESS = 3
local OUTSET = 1
local SWATCH = "|TInterface\\Buttons\\WHITE8X8:12:12:0:0:8:8:0:8:0:8:%d:%d:%d|t "

-- First color offered to a set, the first one no other set wears.
local PALETTE = {
    { r = 1.00, g = 0.15, b = 0.15 },
    { r = 0.15, g = 0.55, b = 1.00 },
    { r = 0.20, g = 1.00, b = 0.25 },
    { r = 1.00, g = 0.85, b = 0.00 },
    { r = 0.80, g = 0.30, b = 1.00 },
    { r = 1.00, g = 0.50, b = 0.00 },
    { r = 0.00, g = 1.00, b = 0.90 },
    { r = 1.00, g = 0.40, b = 0.75 },
}

local active = false
local hooked = false
local pending = false

---------------------------------------------------------------------------
-- Saved colors
---------------------------------------------------------------------------

local function CharColors()
    if not ns.db then return end
    local store = ns.db.setcolors
    if type(store) ~= "table" then
        store = {}
        ns.db.setcolors = store
    end
    if type(store.chars) ~= "table" then store.chars = {} end
    local key = Util.CharacterKey()
    if key == "?" then return end
    if type(store.chars[key]) ~= "table" then store.chars[key] = {} end
    return store.chars[key]
end

-- The color of a set as { r, g, b }, nil when it has none.
function Colors.Get(setID)
    local data = CharColors()
    local color = data and data[setID]
    if type(color) == "table" and type(color.r) == "number"
        and type(color.g) == "number" and type(color.b) == "number" then
        return color
    end
end

---------------------------------------------------------------------------
-- Equipment sets
---------------------------------------------------------------------------

local setList

-- Every set of this character: { id, name, rank }. An empty answer is not
-- kept: the sets may not be loaded yet right after login.
local function Sets()
    if setList then return setList end
    local list = {}
    local ok, ids = pcall(C_EquipmentSet.GetEquipmentSetIDs)
    if ok and Util.ReadableTable(ids) then
        for _, id in ipairs(ids) do
            local okInfo, name = pcall(C_EquipmentSet.GetEquipmentSetInfo, id)
            if okInfo and Util.Readable(name) and type(name) == "string" and name ~= "" then
                table.insert(list, { id = id, name = name })
            end
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    for rank, set in ipairs(list) do set.rank = rank end
    if #list > 0 then setList = list end
    return list
end

-- True when `name` is a whole entry of the game's list of set names.
function Colors.Listed(names, name)
    local from = 1
    while true do
        local first, last = names:find(name, from, true)
        if not first then return false end
        local startsEntry = first == 1 or names:sub(first - 1, first - 1) == ","
            or names:sub(first - 2, first - 1) == ", "
        local endsEntry = last == #names or names:sub(last + 1, last + 1) == ","
        if startsEntry and endsEntry then return true end
        from = first + 1
    end
end

-- The sets holding the item of a slot, nil when there are none.
function Colors.SetsIn(bag, slot)
    local ok, inSet, names = pcall(C_Container.GetContainerItemEquipmentSetInfo, bag, slot)
    if not ok or not Util.Readable(inSet) or inSet ~= true then return end
    if not Util.Readable(names) or type(names) ~= "string" then return end
    local found
    for _, set in ipairs(Sets()) do
        if Colors.Listed(names, set.name) then
            found = found or {}
            table.insert(found, set)
        end
    end
    return found
end

-- The place of the slot's item among the sets, nil when it is in none.
function Colors.Rank(bag, slot)
    local sets = Colors.SetsIn(bag, slot)
    return sets and sets[1].rank or nil
end

---------------------------------------------------------------------------
-- Borders
---------------------------------------------------------------------------

local borders = setmetatable({}, { __mode = "k" }) -- owner -> its textures

local function Line(owner, sublevel, r, g, b, a)
    local line = owner:CreateTexture(nil, "OVERLAY", nil, sublevel)
    line:SetColorTexture(r, g, b, a)
    return line
end

local function NewBorder(owner, anchor)
    local T, O = THICKNESS, OUTSET
    local I = T - O -- where the colored line ends, inside the slot

    local top, bottom, left, right = Line(owner, 7, 1, 1, 1, 1), Line(owner, 7, 1, 1, 1, 1),
        Line(owner, 7, 1, 1, 1, 1), Line(owner, 7, 1, 1, 1, 1)
    top:SetPoint("TOPLEFT", anchor, "TOPLEFT", -O, O)
    top:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", O, O)
    top:SetHeight(T)
    bottom:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", -O, -O)
    bottom:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", O, -O)
    bottom:SetHeight(T)
    left:SetPoint("TOPLEFT", anchor, "TOPLEFT", -O, O - T)
    left:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", -O, T - O)
    left:SetWidth(T)
    right:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", O, O - T)
    right:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", O, T - O)
    right:SetWidth(T)

    local darkTop, darkBottom, darkLeft, darkRight = Line(owner, 6, 0, 0, 0, 0.85), Line(owner, 6, 0, 0, 0, 0.85),
        Line(owner, 6, 0, 0, 0, 0.85), Line(owner, 6, 0, 0, 0, 0.85)
    darkTop:SetPoint("TOPLEFT", anchor, "TOPLEFT", I, -I)
    darkTop:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -I, -I)
    darkTop:SetHeight(1)
    darkBottom:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", I, I)
    darkBottom:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -I, I)
    darkBottom:SetHeight(1)
    darkLeft:SetPoint("TOPLEFT", anchor, "TOPLEFT", I, -I - 1)
    darkLeft:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", I, I + 1)
    darkLeft:SetWidth(1)
    darkRight:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -I, -I - 1)
    darkRight:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -I, I + 1)
    darkRight:SetWidth(1)

    return {
        first = { top, left },
        second = { bottom, right },
        dark = { darkTop, darkBottom, darkLeft, darkRight },
    }
end

local function ShowLines(lines, shown, color)
    for _, line in ipairs(lines) do
        if color then line:SetColorTexture(color.r, color.g, color.b, 1) end
        line:SetShown(shown)
    end
end

-- Draws the border of `owner` around `anchor`; no color hides it.
local function Paint(owner, anchor, first, second)
    local border = borders[owner]
    if not first and not border then return end
    if not border then
        border = NewBorder(owner, anchor)
        borders[owner] = border
    end
    local shown = first ~= nil
    ShowLines(border.first, shown, first)
    ShowLines(border.second, shown, second or first)
    ShowLines(border.dark, shown)
end

-- The two colors a slot's item wears, the sets without a color left out.
local function SlotColors(bag, slot)
    local sets = Colors.SetsIn(bag, slot)
    if not sets then return end
    local first
    for _, set in ipairs(sets) do
        local color = Colors.Get(set.id)
        if color then
            if first then return first, color end
            first = color
        end
    end
    return first
end

local function PaintSlot(button, bag, slot)
    if active and bag and slot then
        Paint(button, button, SlotColors(bag, slot))
    else
        Paint(button, button)
    end
end

local function PaintContainer(frame)
    if type(frame.EnumerateValidItems) ~= "function" then return end
    for _, button in frame:EnumerateValidItems() do
        PaintSlot(button, button:GetBagID(), button:GetID())
    end
end

local function PaintBankButton(button)
    PaintSlot(button, button:GetBankTabID(), button:GetContainerSlotID())
end

-- The set's icon in the Equipment Manager.
local function PaintRow(row)
    if not row.icon then return end
    Paint(row, row.icon, active and row.setID and Colors.Get(row.setID) or nil)
end

local function ForEachContainer(callback)
    local seen = {}
    local function Visit(frame)
        if frame and not seen[frame] then
            seen[frame] = true
            callback(frame)
        end
    end
    Visit(ContainerFrameCombinedBags)
    local list = ContainerFrameContainer and ContainerFrameContainer.ContainerFrames
    if Util.ReadableTable(list) then
        for _, frame in ipairs(list) do Visit(frame) end
    end
end

local function RefreshNow()
    pending = false
    ForEachContainer(PaintContainer)
    local bank = BankFrame and BankFrame.BankPanel
    if bank and type(bank.EnumerateValidItems) == "function" then
        for button in bank:EnumerateValidItems() do PaintBankButton(button) end
    end
    local pane = PaperDollFrame and PaperDollFrame.EquipmentManagerPane
    local box = pane and pane.ScrollBox
    if box and type(box.ForEachFrame) == "function" then
        box:ForEachFrame(PaintRow)
    end
end

local function SafeRefresh()
    xpcall(RefreshNow, geterrorhandler())
end

-- The color picker sends a color for each pixel the mouse moves: draw once
-- per frame.
local function Refresh()
    if pending then return end
    pending = true
    C_Timer.After(0, SafeRefresh)
end

---------------------------------------------------------------------------
-- Choosing a color
---------------------------------------------------------------------------

-- Gives a set its color; no color removes it.
function Colors.Set(setID, r, g, b)
    local data = CharColors()
    if not data then return end
    data[setID] = r and { r = r, g = g, b = b } or nil
    Refresh()
end

local function SameColor(a, b)
    return math.abs(a.r - b.r) < 0.01 and math.abs(a.g - b.g) < 0.01 and math.abs(a.b - b.b) < 0.01
end

-- The first color of the palette no other set of this character wears.
local function FreeColor(setID)
    local data = CharColors() or {}
    for _, candidate in ipairs(PALETTE) do
        local taken = false
        for otherID, color in pairs(data) do
            if otherID ~= setID and type(color) == "table" and type(color.r) == "number"
                and SameColor(candidate, color) then
                taken = true
                break
            end
        end
        if not taken then return candidate end
    end
    return PALETTE[1]
end

function Colors.Pick(setID)
    if not ColorPickerFrame or type(ColorPickerFrame.SetupColorPickerAndShow) ~= "function" then return end
    local old = Colors.Get(setID)
    local start = old or FreeColor(setID)
    -- Set right away: Okay with the offered color has to keep it.
    Colors.Set(setID, start.r, start.g, start.b)
    ColorPickerFrame:SetupColorPickerAndShow({
        r = start.r,
        g = start.g,
        b = start.b,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            Colors.Set(setID, r, g, b)
        end,
        cancelFunc = function()
            if old then
                Colors.Set(setID, old.r, old.g, old.b)
            else
                Colors.Set(setID)
            end
        end,
    })
end

local function AddEntries(parent, setID)
    parent:CreateButton(L.SETCOLORS_MENU_CHOOSE, function() Colors.Pick(setID) end)
    if Colors.Get(setID) then
        parent:CreateButton(L.SETCOLORS_MENU_CLEAR, function() Colors.Set(setID) end)
    end
end

local function Swatch(color)
    if not color then return "" end
    return SWATCH:format(math.floor(color.r * 255 + 0.5), math.floor(color.g * 255 + 0.5),
        math.floor(color.b * 255 + 0.5))
end

-- The list of sets, from the button in /bgt.
function Colors.OpenMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.SETCOLORS_MENU_TITLE)
        local sets = Sets()
        if #sets == 0 then
            root:CreateTitle(L.SETCOLORS_MENU_EMPTY)
            return
        end
        for _, set in ipairs(sets) do
            AddEntries(root:CreateButton(Swatch(Colors.Get(set.id)) .. set.name), set.id)
        end
    end)
end

-- The set whose gear button was just pressed: Blizzard's menu doesn't say.
local function HoveredSet()
    local pane = PaperDollFrame and PaperDollFrame.EquipmentManagerPane
    local box = pane and pane.ScrollBox
    local found
    if box and type(box.ForEachFrame) == "function" then
        box:ForEachFrame(function(row)
            if row.setID and row:IsMouseOver() then found = row.setID end
        end)
    end
    return found or (pane and pane.selectedSetID)
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

local function InstallHooks()
    if hooked then return end
    hooked = true
    ForEachContainer(function(frame)
        if type(frame.UpdateItems) == "function" then
            hooksecurefunc(frame, "UpdateItems", function(self)
                xpcall(PaintContainer, geterrorhandler(), self)
            end)
        end
    end)
    -- Forever's bank buttons call this one from their own Refresh.
    if BankPanelItemButtonMixin and type(BankPanelItemButtonMixin.Refresh) == "function" then
        hooksecurefunc(BankPanelItemButtonMixin, "Refresh", function(self)
            xpcall(PaintBankButton, geterrorhandler(), self)
        end)
    end
    if type(PaperDollEquipmentManagerPane_InitButton) == "function" then
        hooksecurefunc("PaperDollEquipmentManagerPane_InitButton", function(row)
            xpcall(PaintRow, geterrorhandler(), row)
        end)
    end
    if Menu and type(Menu.ModifyMenu) == "function" then
        Menu.ModifyMenu("MENU_PAPERDOLL_FRAME", function(_, root)
            if not active then return end
            local setID = HoveredSet()
            if not setID then return end
            Util.MenuSection(root)
            AddEntries(root, setID)
        end)
    end
end

-- Runs whether the borders are on or not: the bag sort reads the sets too.
local events = CreateFrame("Frame")
events:RegisterEvent("EQUIPMENT_SETS_CHANGED")
events:SetScript("OnEvent", function()
    setList = nil
    if active then Refresh() end
end)

if C_EquipmentSet and type(C_EquipmentSet.DeleteEquipmentSet) == "function" then
    hooksecurefunc(C_EquipmentSet, "DeleteEquipmentSet", function(setID)
        local data = CharColors()
        if data then data[setID] = nil end
    end)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "items",
    order = 27,
    title = "SETCOLORS_TITLE",
    desc = "SETCOLORS_DESC",
    tip = "SETCOLORS_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "colors", title = "SETCOLORS_OPT_COLORS", tip = "SETCOLORS_OPT_COLORS_TIP",
            action = function(button) Colors.OpenMenu(button) end },
    },
    OnEnable = function()
        active = true
        InstallHooks()
        SafeRefresh()
    end,
    OnDisable = function()
        -- The post-hooks can't be removed; they stay and draw nothing.
        active = false
        SafeRefresh()
    end,
})
