local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
Item type names in the combined backpack.

A small label ("Consumable", "Weapon", "Quest"...) sits above the first item
of each run of same-type items, read left to right and top to bottom. After
"Clean up bags" that shows where each kind of item was put. The rows are
spread apart to make room for the labels.

Where the names come from:
  The sort itself runs inside the client and its order is not exposed, so the
  labels are not read from it. Each slot's item gives its type through
  C_Item.GetItemInfoInstant (classID + the localized type name, no server
  query), and a label is placed wherever the type changes. Empty slots carry
  no label and don't break a run. Grey items are one group, "Junk", whatever
  their type.

The labels:
  FontStrings of one frame of ours, a child of ContainerFrameCombinedBags
  that takes no mouse input.

The room between rows:
  Blizzard lays the slots out as a grid that grows upward from the money
  line, every slot anchored by one point with its own y offset
  (AnchorUtil.GridLayout), and sizes the window to fit. Right after each of
  those two steps (post-hooks on UpdateItemLayout and UpdateFrameSize) the
  rows are pushed up, the n-th row from the bottom by n times the extra
  spacing, and the window is made taller by as much. Nothing is written to
  Blizzard's tables: the buttons only get a new SetPoint, the window a new
  height. `moved` remembers each button's Blizzard offset so a change of
  setting, or turning the feature off, can redo or undo the push without
  asking Blizzard for a new layout.

With BagSort's own sorts:
  When "Clean up bags" sorts by pickup order or by use (Features\BagSort.lua),
  the items aren't grouped by type any more: the labels are hidden and the
  rows get Blizzard's spacing back, until the game's sort is chosen again.

When the labels refresh:
  When the bag shows, after Blizzard redraws or lays out the items, and on
  BAG_UPDATE_DELAYED. Refreshes are grouped to one per frame.
]]

local KEY = "bagCategories"

local Bags = {}
ns.BagCategories = Bags

local FONT_SIZES = { 8, 9, 10, 11, 12, 13, 14, 16 }
local SPACINGS = { 0, 4, 6, 8, 10, 12, 14, 16, 20, 24 }
local DEFAULT_FONT, DEFAULT_SPACING = 10, 10
local BLIZZARD_GAP = 5             -- Blizzard's own space between rows
local OFFSET_X = 1                 -- from the slot's left edge
local RIGHT_MARGIN = 2
local LEVEL_ABOVE_ITEMS = 6
local COLOR = { 0.87, 0.82, 0.68, 0.9 }

local active = false
local hooked = false
local pending = false
local waitingForCombat = false
local overlay
local labels = {}
local events
local moved = setmetatable({}, { __mode = "k" }) -- button -> its y offset in Blizzard's layout
local addedHeight = 0

local function Num(value)
    if Util.Readable(value) and type(value) == "number" then return value end
end

local function Container()
    return ContainerFrameCombinedBags
end

local function Round(value)
    return math.floor(value + 0.5)
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local function Stored(name, list, fallback)
    local store = ns.db and ns.db.bags
    local value = type(store) == "table" and store[name]
    if type(value) == "number" then
        for _, allowed in ipairs(list) do
            if allowed == value then return value end
        end
    end
    return fallback
end

function Bags.FontSize()
    return Stored("font", FONT_SIZES, DEFAULT_FONT)
end

function Bags.Spacing()
    return Stored("spacing", SPACINGS, DEFAULT_SPACING)
end

---------------------------------------------------------------------------
-- Item type
---------------------------------------------------------------------------

local typeCache = {}

-- classID and localized type name of an item, or nil when unknown.
local function ItemType(itemID)
    local known = typeCache[itemID]
    if known then return known.class, known.name end
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not instant then return end
    local ok, _, name, _, _, _, class = pcall(instant, itemID)
    if not ok then return end
    class = Num(class)
    if not class then return end
    if not (Util.Readable(name) and type(name) == "string" and name ~= "") then return end
    typeCache[itemID] = { class = class, name = name }
    return class, name
end

-- itemID and quality of the item in a slot, nil for an empty slot.
local function SlotItem(button)
    local okBag, bag = pcall(button.GetBagID, button)
    local okSlot, slot = pcall(button.GetID, button)
    bag, slot = okBag and Num(bag), okSlot and Num(slot)
    if not bag or not slot then return end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or not Util.ReadableTable(info) then return end
    return Num(info.itemID), Num(info.quality)
end

-- Grey items are one group whatever their type: the cleanup puts them
-- together, and a grey sword is vendor trash like the rest.
local JUNK = "junk"
local POOR = (Enum and Enum.ItemQuality and Enum.ItemQuality.Poor) or 0

local function JunkName()
    local name = BAG_FILTER_JUNK -- the game's own word, in the client's language like the type names
    if type(name) == "string" and name ~= "" then return name end
    return L.BAGCAT_JUNK
end

-- The group of a slot's item and its name, or nil for an empty slot or an
-- item the client doesn't know.
local function SlotGroup(button)
    local itemID, quality = SlotItem(button)
    if not itemID then return end
    if quality == POOR then return JUNK, JunkName() end
    return ItemType(itemID)
end

---------------------------------------------------------------------------
-- Room between the rows
---------------------------------------------------------------------------

local function ShownButtons(frame)
    local list = {}
    local items = frame.Items
    if not Util.ReadableTable(items) then return list end
    for _, button in ipairs(items) do
        if button:IsShown() then table.insert(list, button) end
    end
    return list
end

-- With a gamepad Blizzard puts bag buttons in the same grid; leave it alone.
local function Gamepad()
    local check = InputUtil and InputUtil.IsGamepadUIEnabled
    if type(check) ~= "function" then return false end
    local ok, on = pcall(check)
    return ok and on == true
end

-- With one of BagSort's own sorts ("Clean up bags" by pickup order or by
-- use) the items aren't grouped by type, so a name would sit over almost
-- every item: no names then, and no room made for them.
local function OwnSort()
    local sort = ns.BagSort
    return sort ~= nil and ns:IsEnabled("bagSort") and sort.Mode() ~= "default"
end

local function Showing()
    return active and not OwnSort()
end

local function WantedSpacing()
    if not Showing() or Gamepad() then return 0 end
    return Bags.Spacing()
end

local function Locked(frame, buttons)
    if not (InCombatLockdown and InCombatLockdown()) then return false end
    if frame.IsProtected and frame:IsProtected() then return true end
    local first = buttons[1]
    return first ~= nil and first.IsProtected ~= nil and first:IsProtected() == true
end

local function Rows(frame, buttons)
    local ok, rows = pcall(frame.GetRows, frame)
    rows = ok and Num(rows)
    if rows and rows > 0 then return rows end
    return math.ceil(#buttons / 10)
end

-- Pushes the rows apart and makes the window taller, or puts both back.
-- fresh = Blizzard has just laid the slots out: every offset is its own.
local function Spread(frame, fresh)
    if fresh then
        for button in pairs(moved) do moved[button] = nil end
    end
    local extra = WantedSpacing()
    if extra == 0 and next(moved) == nil then return end
    local buttons = ShownButtons(frame)
    if Locked(frame, buttons) then
        waitingForCombat = true
        if events then events:RegisterEvent("PLAYER_REGEN_ENABLED") end
        return
    end

    local entries, seen, levels = {}, {}, {}
    for _, button in ipairs(buttons) do
        if button:GetNumPoints() == 1 then
            local point, relativeTo, relativePoint, x, y = button:GetPoint(1)
            x, y = Num(x), Num(y)
            if point and x and y then
                local base = moved[button] or y
                local key = Round(base)
                if not seen[key] then
                    seen[key] = true
                    table.insert(levels, key)
                end
                table.insert(entries, { button, point, relativeTo, relativePoint, x, base, key })
            end
        end
    end
    -- The grid grows upward: the smallest offset is the bottom row.
    table.sort(levels)
    local rank = {}
    for index, key in ipairs(levels) do rank[key] = index - 1 end

    for _, entry in ipairs(entries) do
        local button, point, relativeTo, relativePoint, x, base, key = unpack(entry)
        button:SetPoint(point, relativeTo, relativePoint, x, base + rank[key] * extra)
        moved[button] = extra ~= 0 and base or nil
    end
end

-- fresh = Blizzard has just sized the window itself.
local function Grow(frame, fresh)
    if fresh then addedHeight = 0 end
    local extra = WantedSpacing()
    if extra == 0 and addedHeight == 0 then return end
    local buttons = ShownButtons(frame)
    if Locked(frame, buttons) then
        waitingForCombat = true
        if events then events:RegisterEvent("PLAYER_REGEN_ENABLED") end
        return
    end
    local want = extra * Rows(frame, buttons)
    if want == addedHeight then return end
    local height = Num(frame:GetHeight())
    if not height then return end
    frame:SetHeight(height - addedHeight + want)
    addedHeight = want
end

---------------------------------------------------------------------------
-- Layout of the labels
---------------------------------------------------------------------------

-- The shown slots in reading order: top row first, left to right.
local function Slots(frame)
    local list = {}
    for _, button in ipairs(ShownButtons(frame)) do
        local left, top = Num(button:GetLeft()), Num(button:GetTop())
        local width, height = Num(button:GetWidth()), Num(button:GetHeight())
        if left and top and width and height then
            table.insert(list, { button = button, left = left, top = top, row = Round(top), width = width, height = height })
        end
    end
    table.sort(list, function(a, b)
        if a.row ~= b.row then return a.row > b.row end
        return a.left < b.left
    end)
    return list
end

-- The free space above a row of slots, measured between two rows.
function Bags.Gap(slots)
    local first = slots[1]
    if first then
        for _, slot in ipairs(slots) do
            if slot.row ~= first.row then
                return math.max(0, first.top - slot.top - first.height)
            end
        end
    end
    return BLIZZARD_GAP + WantedSpacing()
end

-- The slots that start a run, each with its text and the width it may use:
-- up to the next label on the same row, or to the end of the row.
function Bags.Plan(slots)
    local plan = {}
    local previous
    for index, slot in ipairs(slots) do
        local class, name = SlotGroup(slot.button)
        if class and class ~= previous then
            table.insert(plan, { index = index, slot = slot, text = name })
        end
        if class then previous = class end
    end
    for i, entry in ipairs(plan) do
        local slot = entry.slot
        local limit
        local nextEntry = plan[i + 1]
        if nextEntry and nextEntry.slot.row == slot.row then
            limit = nextEntry.slot.left
        else
            local last = slot
            for index = entry.index + 1, #slots do
                if slots[index].row ~= slot.row then break end
                last = slots[index]
            end
            limit = last.left + last.width
        end
        entry.width = math.max(1, limit - slot.left - OFFSET_X - RIGHT_MARGIN)
    end
    return plan
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function Overlay(frame)
    if overlay then return overlay end
    overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:EnableMouse(false)
    return overlay
end

local function Label(index, size)
    local label = labels[index]
    if not label then
        label = overlay:CreateFontString(nil, "OVERLAY")
        label:SetTextColor(COLOR[1], COLOR[2], COLOR[3], COLOR[4])
        label:SetJustifyH("LEFT")
        label:SetJustifyV("BOTTOM")
        label:SetWordWrap(false)
        labels[index] = label
    end
    if label.size ~= size then
        local file = GameFontNormalSmall:GetFont()
        label:SetFont(file or STANDARD_TEXT_FONT, size, "OUTLINE")
        label.size = size
    end
    return label
end

local function HideLabels(from)
    for index = from, #labels do labels[index]:Hide() end
end

local function Refresh()
    pending = false
    local frame = Container()
    if not Showing() or not frame or not frame:IsShown() then
        if overlay then overlay:Hide() end
        return
    end
    Overlay(frame)
    local slots = Slots(frame)
    local plan = Bags.Plan(slots)
    if slots[1] then
        overlay:SetFrameLevel(slots[1].button:GetFrameLevel() + LEVEL_ABOVE_ITEMS)
    end
    -- Centered in the space above the row; when the text is taller than that
    -- space it spills evenly over the two rows.
    local size = Bags.FontSize()
    local offsetY = (Bags.Gap(slots) - size) / 2
    for index, entry in ipairs(plan) do
        local label = Label(index, size)
        label:ClearAllPoints()
        label:SetPoint("BOTTOMLEFT", entry.slot.button, "TOPLEFT", OFFSET_X, offsetY)
        label:SetWidth(entry.width)
        label:SetText(entry.text)
        label:Show()
    end
    HideLabels(#plan + 1)
    overlay:Show()
end

local function SafeRefresh()
    xpcall(Refresh, geterrorhandler())
end

-- Blizzard redraws the bag several times while items move; draw once.
local function Schedule()
    if not active or pending then return end
    pending = true
    C_Timer.After(0, SafeRefresh)
end

-- Redo the spacing and the labels after a change of setting or of state.
local function Apply()
    local frame = Container()
    if not frame then return end
    xpcall(function()
        Grow(frame, false)
        Spread(frame, false)
    end, geterrorhandler())
    if Showing() then
        Schedule()
    elseif overlay then
        overlay:Hide()
    end
end

-- The sort's mode, or the sort feature itself, changed.
local function SortChanged(key)
    if key == "bagSort" and active then Apply() end
end
ns:On("OPTION_CHANGED", SortChanged)
ns:On("FEATURE_CHANGED", SortChanged)

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

local function InstallHooks()
    if hooked then return true end
    local frame = Container()
    if not frame then return false end
    hooked = true
    frame:HookScript("OnShow", Schedule)
    if type(frame.UpdateItems) == "function" then
        hooksecurefunc(frame, "UpdateItems", Schedule)
    end
    if type(frame.UpdateItemLayout) == "function" then
        hooksecurefunc(frame, "UpdateItemLayout", function(self)
            xpcall(Spread, geterrorhandler(), self, true)
            Schedule()
        end)
    end
    if type(frame.UpdateFrameSize) == "function" then
        hooksecurefunc(frame, "UpdateFrameSize", function(self)
            xpcall(Grow, geterrorhandler(), self, true)
        end)
    end
    return true
end

local function OnEvent(self, event)
    if event == "PLAYER_REGEN_ENABLED" then
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        if waitingForCombat then
            waitingForCombat = false
            Apply()
        end
        return
    end
    if not InstallHooks() then return end
    local frame = Container()
    if frame and frame:IsShown() then Schedule() end
end

---------------------------------------------------------------------------
-- Options
---------------------------------------------------------------------------

local function Set(name, value)
    if not ns.db then return end
    if type(ns.db.bags) ~= "table" then ns.db.bags = {} end
    ns.db.bags[name] = value
    Apply()
    ns:Fire("OPTION_CHANGED", KEY, name, value)
end

local function OpenMenu(owner, title, list, current, format, name)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    local refresh = MenuResponse and MenuResponse.Refresh
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(title)
        for _, value in ipairs(list) do
            root:CreateRadio(format:format(value),
                function() return current() == value end,
                function()
                    Set(name, value)
                    return refresh
                end)
        end
    end)
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "items",
    order = 20,
    title = "BAGCAT_TITLE",
    desc = "BAGCAT_DESC",
    tip = "BAGCAT_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "font", title = function() return L.BAGCAT_OPT_FONT:format(Bags.FontSize()) end,
            tip = "BAGCAT_OPT_FONT_TIP",
            action = function(button)
                OpenMenu(button, L.BAGCAT_MENU_FONT, FONT_SIZES, Bags.FontSize, "%d", "font")
            end },
        { key = "spacing", title = function() return L.BAGCAT_OPT_SPACING:format(Bags.Spacing()) end,
            tip = "BAGCAT_OPT_SPACING_TIP",
            action = function(button)
                OpenMenu(button, L.BAGCAT_MENU_SPACING, SPACINGS, Bags.Spacing, "+%d", "spacing")
            end },
    },
    OnEnable = function()
        active = true
        if not events then
            events = CreateFrame("Frame")
            events:SetScript("OnEvent", OnEvent)
        end
        events:RegisterEvent("BAG_UPDATE_DELAYED")
        events:RegisterEvent("PLAYER_ENTERING_WORLD")
        InstallHooks()
        Apply()
    end,
    OnDisable = function()
        -- The post-hooks can't be removed; they stay and do nothing.
        active = false
        if events then
            events:UnregisterEvent("BAG_UPDATE_DELAYED")
            events:UnregisterEvent("PLAYER_ENTERING_WORLD")
        end
        Apply() -- rows and window height back to Blizzard's
    end,
})
