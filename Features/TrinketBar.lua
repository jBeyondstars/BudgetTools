local _, ns = ...
local L = ns.L
local Util = ns.Util
local UI = ns.UI

--[[
Trinket bar: the two equipped trinkets on screen, and the trinkets of your
bags one hover away (in the spirit of TrinketMenu).

The bar:
  - Two secure buttons, one per trinket slot (13 on top, 14 below in the
    character window). A click uses the trinket, in combat too: their macro
    ("/use 13", "/use 14") never changes, whatever is equipped.
  - Two invisible copies are clicked by the key bindings (Bindings.xml).
  - Shift+drag moves it; right-click opens its menu.

The menu:
  - Opens when the mouse is over the bar, lists the trinkets found in the
    bags. Left-click equips in the top slot, right-click in the bottom one.
  - It is a plain frame, so it opens in combat too.

Swapping:
  - C_Item.EquipItemByName(item, slot), what /equipslot runs. No cursor is
    involved, so the action bars are left alone.
  - The game refuses to swap a trinket in combat, dead or while casting.
    The choice then waits (its icon sits in the corner of the slot) and is
    equipped as soon as nothing blocks it. Clicking it again cancels.

The bar holds secure buttons: showing, hiding and moving it are done out of
combat only, and put off to the end of the fight otherwise.
]]

local KEY = "trinketBar"
local SLOTS = { 13, 14 }                        -- top, bottom
local BAR_NAME = "BudgetForeverTrinketBar"
local BUTTON_NAME = "BudgetForeverTrinket"      -- .. 1 / 2
local TRIGGER_NAME = "BudgetForeverTrinketKey"  -- .. 1 / 2, clicked by the bindings
local FLYOUT_NAME = "BudgetForeverTrinketMenu"
local MENU_ACTION, NO_ACTION = "bftrinketmenu", "bftrinketnone"
local SIZE, GAP = 45, 2     -- the size of the game's action buttons
local ITEM_SCALE = 0.8      -- the menu's buttons are the same ones, smaller
local ITEM_SIZE, ITEM_GAP, ITEM_COLUMNS, PADDING = SIZE * ITEM_SCALE, 2, 6, 4
local SOUND_WINDOW = 3      -- seconds a swap we asked for may take to show up
local CLOSE_DELAY = 0.3     -- seconds the menu stays once the mouse left
local REACH = 6             -- pixels around the bar and the menu that still count as "over"
local QUEUE_TICK = 0.5
local EMPTY_ICON = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"

local Bar = {}
ns.TrinketBar = Bar
Bar.KEY, Bar.SLOTS = KEY, SLOTS

local active = false
local dirty = false         -- the bar's state is to be applied after combat
local bar, flyout
local buttons, triggers, items = {}, {}, {}
local queue = {}            -- [inventory slot] = { id, icon, link }: waits to be equipped
local asked = {}            -- [inventory slot] = { id, at }: swaps sent to the game, for the sound
local queueTicker
local events = CreateFrame("Frame")

local Apply, RefreshAll

---------------------------------------------------------------------------
-- Reading
---------------------------------------------------------------------------

local function Call(fn, ...)
    if type(fn) ~= "function" then return end
    local ok, a, b, c, d = pcall(fn, ...)
    if ok then return a, b, c, d end
end

local function Value(value, kind)
    if Util.Readable(value) and type(value) == kind then return value end
end

-- nil is absent; a value the game hides still counts as there.
local function Present(value)
    if issecretvalue and issecretvalue(value) then return true end
    return value ~= nil
end

local function Binding(index)
    return "CLICK " .. TRIGGER_NAME .. index .. ":LeftButton"
end

local trinketByID = {}

local function IsTrinket(id)
    local known = trinketByID[id]
    if known ~= nil then return known end
    local getInfo = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    local _, _, _, equipLoc = Call(getInfo, id)
    if Value(equipLoc, "string") == nil then return false end -- not known yet: asked again later
    known = equipLoc == "INVTYPE_TRINKET"
    trinketByID[id] = known
    return known
end

-- Item ID, icon and link of the trinket in a slot; nil when it is empty.
local function Equipped(slot)
    local id = Value(Call(GetInventoryItemID, "player", slot), "number")
    if not id then return end
    local icon = Call(GetInventoryItemTexture, "player", slot)
    return id, Util.Readable(icon) and icon or nil, Value(Call(GetInventoryItemLink, "player", slot), "string")
end

-- Trinkets in the bags, in bag order.
local function BagTrinkets()
    local list = {}
    local container = C_Container
    if type(container) ~= "table" then return list end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local count = Value(Call(container.GetContainerNumSlots, bag), "number") or 0
        for slot = 1, count do
            local info = Call(container.GetContainerItemInfo, bag, slot)
            local id = Util.ReadableTable(info) and Value(info.itemID, "number")
            if id and IsTrinket(id) then
                table.insert(list, {
                    id = id, bag = bag, slot = slot,
                    icon = Util.Readable(info.iconFileID) and info.iconFileID or nil,
                    link = Value(info.hyperlink, "string"),
                })
            end
        end
    end
    return list
end

local function InBags(id)
    for _, entry in ipairs(BagTrinkets()) do
        if entry.id == id then return true end
    end
    return false
end

local function HasTrinket()
    for _, slot in ipairs(SLOTS) do
        if Equipped(slot) then return true end
    end
    return #BagTrinkets() > 0
end

local function ItemName(entry)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name = Value(Call(getInfo, entry.id), "string")
    if name then return name end
    local fromLink = entry.link and entry.link:match("%[(.-)%]")
    return fromLink or ("#" .. entry.id)
end

-- nil, or why the game would refuse a swap right now.
local function Blocked()
    if InCombatLockdown() or Value(Call(UnitAffectingCombat, "player"), "boolean") == true then return "combat" end
    if Value(Call(UnitIsDeadOrGhost, "player"), "boolean") == true then return "dead" end
    if Present((Call(UnitCastingInfo, "player"))) or Present((Call(UnitChannelInfo, "player"))) then return "cast" end
end

local function KeyText(index)
    local key = GetBindingKey and GetBindingKey(Binding(index))
    if not key then return "" end
    if GetBindingText then
        local ok, text = pcall(GetBindingText, key, true)
        if ok and type(text) == "string" and text ~= "" then return text end
    end
    return key
end

local function SetCooldown(cooldown, start, duration)
    if Value(start, "number") and Value(duration, "number") then
        if start > 0 and duration > 0 then
            cooldown:SetCooldown(start, duration)
            return
        end
    elseif Present(start) and Present(duration) then
        -- Hidden numbers: the cooldown frame can still draw them.
        if pcall(cooldown.SetCooldown, cooldown, start, duration) then return end
    end
    if cooldown.Clear then cooldown:Clear() else cooldown:SetCooldown(0, 0) end
end

---------------------------------------------------------------------------
-- Swapping, now or when the game allows it
---------------------------------------------------------------------------

-- EquipItemByName is silent, unlike dropping the item on its slot by hand.
-- The trinket's own sound is played once it really sits in the slot.
local function PlaySwapSound(invSlot)
    local played = false
    if C_Sound and C_Sound.PlayItemSound and ItemLocation and ItemLocation.CreateFromEquipmentSlot
        and Enum and Enum.ItemSoundType then
        local ok, location = pcall(ItemLocation.CreateFromEquipmentSlot, ItemLocation, invSlot)
        if ok and location then
            played = pcall(C_Sound.PlayItemSound, Enum.ItemSoundType.Drop, location)
        end
    end
    -- What the game's equipment manager plays after a swap.
    if not played and PlaySound and SOUNDKIT and SOUNDKIT.PUT_DOWN_SMALL_CHAIN then
        pcall(PlaySound, SOUNDKIT.PUT_DOWN_SMALL_CHAIN)
    end
end

-- On an equipment change: was it a swap this bar asked for?
local function ConfirmSwap(invSlot)
    local swap = asked[invSlot]
    if not swap then return end
    if GetTime() - swap.at > SOUND_WINDOW then
        asked[invSlot] = nil
    elseif GetInventoryItemID and Value(Call(GetInventoryItemID, "player", invSlot), "number") == swap.id then
        asked[invSlot] = nil
        PlaySwapSound(invSlot)
    end
end

local function EquipNow(entry, invSlot)
    local equip = (C_Item and C_Item.EquipItemByName) or EquipItemByName
    if type(equip) ~= "function" then return false end
    asked[invSlot] = { id = entry.id, at = GetTime() }
    return (pcall(equip, entry.link or entry.id, invSlot))
end

local function StopQueue()
    if queueTicker then
        queueTicker:Cancel()
        queueTicker = nil
    end
end

local function ProcessQueue()
    if next(queue) == nil then
        StopQueue()
        return
    end
    if Blocked() then return end
    for _, invSlot in ipairs(SLOTS) do
        local entry = queue[invSlot]
        if entry then
            queue[invSlot] = nil
            -- Sold, mailed or equipped by hand meanwhile: nothing to do.
            if Equipped(invSlot) ~= entry.id and InBags(entry.id) then EquipNow(entry, invSlot) end
        end
    end
    StopQueue()
    RefreshAll()
end

local function StartQueue()
    if not queueTicker then queueTicker = C_Timer.NewTicker(QUEUE_TICK, ProcessQueue) end
end

function Bar.Waiting(invSlot)
    return queue[invSlot]
end

function Bar.Cancel(invSlot)
    queue[invSlot] = nil
    if next(queue) == nil then StopQueue() end
    RefreshAll()
end

-- A click in the menu. Returns "equipped", "waiting" or "cancelled".
function Bar.Equip(entry, invSlot)
    local waiting = queue[invSlot]
    if waiting and waiting.id == entry.id then
        Bar.Cancel(invSlot)
        return "cancelled"
    end
    if not Blocked() then
        queue[invSlot] = nil
        EquipNow(entry, invSlot)
        RefreshAll()
        return "equipped"
    end
    -- One trinket can't wait for both slots: the last choice wins.
    for _, other in ipairs(SLOTS) do
        if other ~= invSlot and queue[other] and queue[other].id == entry.id then queue[other] = nil end
    end
    queue[invSlot] = { id = entry.id, icon = entry.icon, link = entry.link }
    StartQueue()
    RefreshAll()
    return "waiting"
end

---------------------------------------------------------------------------
-- Position
---------------------------------------------------------------------------

local function Place()
    if InCombatLockdown() then return end
    bar:ClearAllPoints()
    local saved = ns.db and ns.db.trinkets.pos
    if type(saved) == "table" and type(saved[1]) == "string" and type(saved[2]) == "string"
        and type(saved[3]) == "number" and type(saved[4]) == "number" then
        bar:SetPoint(saved[1], UIParent, saved[2], saved[3], saved[4])
    else
        bar:SetPoint("BOTTOM", UIParent, "BOTTOM", 150, 232)
    end
end

local function StopMoving()
    if not bar.moving then return end
    bar.moving = nil
    bar:StopMovingOrSizing()
    if bar.SetUserPlaced then bar:SetUserPlaced(false) end
    local point, _, relativePoint, x, y = bar:GetPoint(1)
    if point then ns.db.trinkets.pos = { point, relativePoint, x, y } end
end

function Bar.ResetPosition()
    if InCombatLockdown() then
        ns:Error(L.WHEEL_ERROR_COMBAT)
        return false
    end
    ns.db.trinkets.pos = nil
    Place()
    ns:Print(L.TRINKET_RESET_DONE)
    return true
end

---------------------------------------------------------------------------
-- Look
---------------------------------------------------------------------------

local function FitArt(texture, layer)
    if not texture then return end
    texture:ClearAllPoints()
    texture:SetPoint("TOPLEFT")
    texture:SetSize(46, 45)
    if layer then texture:SetDrawLayer(layer) end
end

-- The look of the game's own action buttons, with the art and the sizes of
-- its ActionButtonTemplate. It is drawn here instead of inheriting that
-- template, so that none of Blizzard's action button code runs on these.
local function Skin(button)
    button:SetSize(SIZE, SIZE)

    local background = button:CreateTexture(nil, "BACKGROUND", nil, -1)
    background:SetAllPoints()
    background:SetAtlas("UI-HUD-ActionBar-IconFrame-Background")

    button.icon = button:CreateTexture(nil, "BACKGROUND")
    button.icon:SetAllPoints()
    local mask = button:CreateMaskTexture()
    mask:SetAtlas("UI-HUD-ActionBar-IconFrame-Mask", true, nil, nil, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetPoint("CENTER", button.icon, "CENTER")
    button.icon:AddMaskTexture(mask)

    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetPoint("TOPLEFT", button.icon, "TOPLEFT", 3, -3)
    button.cooldown:SetPoint("BOTTOMRIGHT", button.icon, "BOTTOMRIGHT", -3, 3)
    button.cooldown:SetDrawBling(false)
    button.cooldown:SetDrawEdge(false)
    button.cooldown:SetSwipeColor(0, 0, 0, 0.64)

    button:SetNormalAtlas("UI-HUD-ActionBar-IconFrame")
    button:SetPushedAtlas("UI-HUD-ActionBar-IconFrame-Down")
    button:SetHighlightAtlas("UI-HUD-ActionBar-IconFrame-Mouseover")
    FitArt(button:GetNormalTexture(), "OVERLAY")
    FitArt(button:GetPushedTexture(), "OVERLAY")
    FitArt(button:GetHighlightTexture())
end

---------------------------------------------------------------------------
-- The menu of bag trinkets
---------------------------------------------------------------------------

-- The game puts the "Equipped" comparison next to a bag item's tooltip; in
-- this menu it only hides the bar. GameTooltip compares only while its
-- supportsItemComparison key is set, so the menu turns it off while it owns
-- the tooltip and gives it back on leave.
local savedComparison

local function HideComparison()
    if savedComparison == nil then
        savedComparison = GameTooltip.supportsItemComparison or false
    end
    GameTooltip.supportsItemComparison = false
    for _, name in ipairs({ "ShoppingTooltip1", "ShoppingTooltip2" }) do
        local tip = _G[name]
        if tip then tip:Hide() end
    end
end

local function RestoreComparison()
    if savedComparison ~= nil then
        GameTooltip.supportsItemComparison = savedComparison
        savedComparison = nil
    end
end

local function ItemTooltipLeave()
    GameTooltip_Hide()
    RestoreComparison()
end

local function ItemTooltip(self)
    local entry = self.entry
    if not entry then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    HideComparison()
    GameTooltip:SetBagItem(entry.bag, entry.slot)
    HideComparison()
    GameTooltip:AddLine(" ")
    local top, bottom = queue[SLOTS[1]], queue[SLOTS[2]]
    if top and top.id == entry.id then
        GameTooltip:AddLine(L.TRINKET_WAITING_TOP, 1, 0.55, 0.15, true)
    elseif bottom and bottom.id == entry.id then
        GameTooltip:AddLine(L.TRINKET_WAITING_BOTTOM, 1, 0.55, 0.15, true)
    else
        GameTooltip:AddLine(L.TRINKET_HINT_TOP, 0.5, 0.8, 1)
        GameTooltip:AddLine(L.TRINKET_HINT_BOTTOM, 0.5, 0.8, 1)
        if Blocked() then GameTooltip:AddLine(L.TRINKET_HINT_LATER, 1, 0.55, 0.15, true) end
    end
    GameTooltip:Show()
end

local function CreateItem(index)
    local item = CreateFrame("Button", nil, flyout)
    Skin(item)
    item:SetScale(ITEM_SCALE)
    item:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Gold frame around the trinket that waits for a slot (the art the game
    -- puts, in green, around an equipped item on a bar).
    item.waiting = item:CreateTexture(nil, "OVERLAY", nil, 1)
    item.waiting:SetAtlas("UI-HUD-ActionBar-IconFrame-Border")
    FitArt(item.waiting)
    item.waiting:SetVertexColor(1, 0.82, 0)
    item.waiting:Hide()

    item:SetScript("OnClick", function(self, mouseButton)
        if not self.entry then return end
        Bar.Equip(self.entry, mouseButton == "RightButton" and SLOTS[2] or SLOTS[1])
        if self:IsShown() and GameTooltip:IsOwned(self) then ItemTooltip(self) end
    end)
    item:SetScript("OnEnter", ItemTooltip)
    item:SetScript("OnLeave", ItemTooltipLeave)
    items[index] = item
    return item
end

-- Fills the menu; false when the bags hold no trinket.
local function FillFlyout()
    local list = BagTrinkets()
    local count = #list
    if count == 0 then return false end
    local columns = math.min(count, ITEM_COLUMNS)
    local rows = math.ceil(count / ITEM_COLUMNS)
    local width = PADDING * 2 + columns * ITEM_SIZE + (columns - 1) * ITEM_GAP
    local height = PADDING * 2 + rows * ITEM_SIZE + (rows - 1) * ITEM_GAP
    flyout:SetSize(width, height)

    -- Above the bar, below it when there is no room left at the top.
    local top = bar:GetTop() or 0
    local above = top + GAP + height < (UIParent:GetHeight() or 768)
    flyout:ClearAllPoints()
    if above then
        flyout:SetPoint("BOTTOM", bar, "TOP", 0, GAP)
    else
        flyout:SetPoint("TOP", bar, "BOTTOM", 0, -GAP)
    end

    local container = C_Container
    for index, entry in ipairs(list) do
        local item = items[index] or CreateItem(index)
        local column = (index - 1) % columns
        local row = math.floor((index - 1) / columns)
        local x = PADDING + column * (ITEM_SIZE + ITEM_GAP)
        local y = PADDING + row * (ITEM_SIZE + ITEM_GAP)
        item:ClearAllPoints()
        -- The first row is the one next to the bar. A scaled button counts
        -- its offsets in its own units.
        if above then
            item:SetPoint("BOTTOMLEFT", flyout, "BOTTOMLEFT", x / ITEM_SCALE, y / ITEM_SCALE)
        else
            item:SetPoint("TOPLEFT", flyout, "TOPLEFT", x / ITEM_SCALE, -y / ITEM_SCALE)
        end
        item.entry = entry
        item.icon:SetTexture(entry.icon or EMPTY_ICON)
        SetCooldown(item.cooldown, Call(container.GetContainerItemCooldown, entry.bag, entry.slot))
        local isWaiting = false
        for _, slot in ipairs(SLOTS) do
            if queue[slot] and queue[slot].id == entry.id then isWaiting = true end
        end
        item.waiting:SetShown(isWaiting)
        item:Show()
    end
    for index = count + 1, #items do
        items[index].entry = nil
        items[index]:Hide()
    end
    return true
end

local function OpenFlyout()
    if not active or bar.moving then return end
    flyout.away = 0
    if FillFlyout() then flyout:Show() else flyout:Hide() end
end

local function RefreshFlyout()
    if not flyout:IsShown() then return end
    if not FillFlyout() then flyout:Hide() end
end

local function CreateFlyout()
    flyout = CreateFrame("Frame", FLYOUT_NAME, UIParent, "BackdropTemplate")
    flyout:Hide()
    flyout:SetFrameStrata("HIGH")
    flyout:SetClampedToScreen(true)
    flyout:EnableMouse(true)
    UI.ApplyFlat(flyout, { 0, 0, 0, 0.5 }, { 0, 0, 0, 0.8 })
    flyout.away = 0
    -- Closes a moment after the mouse left both the bar and the menu.
    flyout:SetScript("OnUpdate", function(self, elapsed)
        if bar:IsMouseOver(REACH, -REACH, -REACH, REACH) or self:IsMouseOver(REACH, -REACH, -REACH, REACH) then
            self.away = 0
            return
        end
        self.away = self.away + elapsed
        if self.away >= CLOSE_DELAY then self:Hide() end
    end)
end

---------------------------------------------------------------------------
-- The bar
---------------------------------------------------------------------------

local function RefreshSlot(index)
    local button, slot = buttons[index], SLOTS[index]
    local _, icon = Equipped(slot)
    button.icon:SetTexture(icon or EMPTY_ICON)
    SetCooldown(button.cooldown, Call(GetInventoryItemCooldown, "player", slot))
    local waiting = queue[slot]
    if waiting then
        button.next:SetTexture(waiting.icon or EMPTY_ICON)
        button.next:Show()
        button.nextEdge:Show()
    else
        button.next:Hide()
        button.nextEdge:Hide()
    end
    button.hotkey:SetText(KeyText(index))
end

-- Puts the slot tooltip beside the bar, past the menu so it hides no
-- trinket: on the right, on the left when the screen ends first. It lines
-- up with the bar's edge on the side away from the menu.
local function PlaceSlotTooltip()
    local tipScale = GameTooltip:GetEffectiveScale()
    local barScale = bar:GetEffectiveScale()
    local left, right = bar:GetLeft() * barScale, bar:GetRight() * barScale
    local menuAbove = true
    if flyout:IsShown() and flyout:GetLeft() then
        local menuScale = flyout:GetEffectiveScale()
        left = math.min(left, flyout:GetLeft() * menuScale)
        right = math.max(right, flyout:GetRight() * menuScale)
        menuAbove = flyout:GetBottom() * menuScale >= bar:GetTop() * barScale
    end
    local edge = menuAbove and "BOTTOM" or "TOP"
    local width = GameTooltip:GetWidth() * tipScale
    local screen = UIParent:GetRight() * UIParent:GetEffectiveScale()
    GameTooltip:ClearAllPoints()
    local gap = 6
    if right + gap * tipScale + width <= screen then
        GameTooltip:SetPoint(edge .. "LEFT", bar, edge .. "RIGHT", (right - bar:GetRight() * barScale) / tipScale + gap, 0)
    else
        GameTooltip:SetPoint(edge .. "RIGHT", bar, edge .. "LEFT", (left - bar:GetLeft() * barScale) / tipScale - gap, 0)
    end
end

local function SlotTooltip(self)
    local index = self.index
    local slot = SLOTS[index]
    OpenFlyout()
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    local hasItem = Equipped(slot) ~= nil
    if hasItem then
        HideComparison()
        GameTooltip:SetInventoryItem("player", slot)
        HideComparison()
    else
        GameTooltip:SetText(index == 1 and L.TRINKET_SLOT_TOP or L.TRINKET_SLOT_BOTTOM, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    local waiting = queue[slot]
    if waiting then GameTooltip:AddLine(L.TRINKET_WAITING:format(ItemName(waiting)), 1, 0.55, 0.15, true) end
    if hasItem then GameTooltip:AddLine(L.TRINKET_HINT_USE, 0.5, 0.8, 1) end
    GameTooltip:AddLine(L.TRINKET_HINT_MENU, 0.5, 0.8, 1)
    if not ns:GetOption(KEY, "lock") then GameTooltip:AddLine(L.TRINKET_HINT_MOVE, 0.5, 0.8, 1) end
    GameTooltip:Show()
    PlaceSlotTooltip()
end

---------------------------------------------------------------------------
-- Quick Keybind Mode
---------------------------------------------------------------------------

--[[
The game's Quick Keybind Mode only knows the buttons that tell it, when the
mouse comes over them, which binding they stand for (Blizzard's
QuickKeybindButtonTemplate). These buttons do the same by hand:
  - hovering one hands its binding (commandName) to QuickKeybindFrame, which
    then takes the key pressed, and shows the game's own "press a key" tip;
  - other mouse buttons and the wheel are passed on, so they can be bound;
  - a highlight marks the buttons while the mode is on, as on action bars.
The binding is the one listed in the Key Bindings window, so both ways of
setting it stay in step.
]]

local quickBind = false     -- the mode is on

local function InQuickBind()
    if not KeybindFrames_InQuickKeybindMode or not QuickKeybindFrame or not QuickKeybindButtonTemplateMixin then
        return false
    end
    local ok, shown = pcall(KeybindFrames_InQuickKeybindMode)
    return ok and shown and true or false
end

local function SlotEnter(self)
    if InQuickBind() then
        flyout:Hide()
        GameTooltip:Hide()
        self.binding = true
        self.quickBind:SetAlpha(1)
        pcall(QuickKeybindFrame.SetSelected, QuickKeybindFrame, self.commandName, self)
        pcall(self.QuickKeybindButtonSetTooltip, self)
        return
    end
    SlotTooltip(self)
end

local function SlotLeave(self)
    GameTooltip:Hide()
    RestoreComparison()
    if not self.binding then return end
    self.binding = nil
    self.quickBind:SetAlpha(0.5)
    if QuickKeybindTooltip then QuickKeybindTooltip:Hide() end
    if InQuickBind() then pcall(QuickKeybindFrame.SetSelected, QuickKeybindFrame, nil, nil) end
end

-- Left and right keep their meaning; any other mouse button is a key to bind.
local function SlotClicked(self, mouseButton)
    if mouseButton == "LeftButton" or mouseButton == "RightButton" or not InQuickBind() then return end
    pcall(QuickKeybindFrame.OnKeyDown, QuickKeybindFrame, mouseButton)
end

local function SlotWheel(_, delta)
    if InQuickBind() then pcall(QuickKeybindFrame.OnMouseWheel, QuickKeybindFrame, delta) end
end

local function SetQuickBind(on)
    quickBind = on and true or false
    for index = 1, #SLOTS do
        local button = buttons[index]
        button.binding = nil
        button.quickBind:SetAlpha(0.5)
        button.quickBind:SetShown(quickBind)
        button:SetScript("OnMouseWheel", quickBind and SlotWheel or nil)
    end
    if quickBind then flyout:Hide() end
    Apply() -- which mouse buttons the bar listens to
end

local function OpenOptions()
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    flyout:Hide()
    GameTooltip:Hide()
    local close = MenuResponse and MenuResponse.Close
    local refresh = MenuResponse and MenuResponse.Refresh
    MenuUtil.CreateContextMenu(bar, function(_, root)
        root:CreateTitle(L.TRINKET_TITLE)
        for _, slot in ipairs(SLOTS) do
            local waiting = queue[slot]
            if waiting then
                root:CreateButton(L.TRINKET_MENU_CANCEL:format(ItemName(waiting)), function()
                    Bar.Cancel(slot)
                    return close
                end)
            end
        end
        root:CreateCheckbox(L.TRINKET_OPT_LOCK,
            function() return ns:GetOption(KEY, "lock") end,
            function()
                ns:SetOption(KEY, "lock", not ns:GetOption(KEY, "lock"))
                return refresh
            end)
        root:CreateButton(L.TRINKET_OPT_RESET, function()
            Bar.ResetPosition()
            return close
        end)
        root:CreateDivider()
        root:CreateButton(L.TRINKET_MENU_HIDE, function()
            ns:SetEnabled(KEY, false)
            ns:Print(L.TRINKET_HIDDEN)
            return close
        end)
    end)
end

local function CreateSlot(index)
    local slot = SLOTS[index]
    local macro = "/use " .. slot

    -- Clicked by the key binding. Shown (bindings click it) but invisible.
    local trigger = CreateFrame("Button", TRIGGER_NAME .. index, UIParent, "SecureActionButtonTemplate")
    trigger:SetSize(1, 1)
    trigger:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", -10, -20 - index)
    trigger:EnableMouse(false)
    -- Down and up: the "use on key down" setting picks one, like action bars.
    trigger:RegisterForClicks("AnyDown", "AnyUp")
    trigger:SetAttribute("macrotext", macro)
    triggers[index] = trigger

    local button = CreateFrame("Button", BUTTON_NAME .. index, bar, "SecureActionButtonTemplate")
    button.index = index
    Skin(button)
    button:SetPoint("LEFT", bar, "LEFT", (index - 1) * (SIZE + GAP), 0)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetAttribute("type1", "macro")
    button:SetAttribute("macrotext", macro)
    button:SetAttribute("type2", MENU_ACTION)
    button:SetAttribute("shift-type1", NO_ACTION) -- Shift is for dragging
    button:SetAttribute("useOnKeyDown", false)
    button[MENU_ACTION] = OpenOptions
    button[NO_ACTION] = function() end

    -- Above the cooldown: the key and the trinket that waits for this slot.
    local over = CreateFrame("Frame", nil, button)
    over:SetAllPoints()
    over:SetFrameLevel(button.cooldown:GetFrameLevel() + 1)

    -- Where the game writes an action button's key.
    button.hotkey = over:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
    button.hotkey:SetPoint("TOPRIGHT", -4, -5)
    button.hotkey:SetJustifyH("RIGHT")

    button.nextEdge = over:CreateTexture(nil, "ARTWORK")
    button.nextEdge:SetSize(20, 20)
    button.nextEdge:SetPoint("BOTTOMRIGHT", -2, 2)
    button.nextEdge:SetColorTexture(1, 0.82, 0, 1)
    button.nextEdge:Hide()

    button.next = over:CreateTexture(nil, "OVERLAY")
    button.next:SetSize(18, 18)
    button.next:SetPoint("CENTER", button.nextEdge, "CENTER")
    button.next:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    button.next:Hide()

    -- Quick Keybind Mode: what the game reads on the button under the mouse,
    -- and the highlight it gives its own buttons meanwhile.
    button.commandName = Binding(index)
    button.QuickKeybindButtonSetTooltip = QuickKeybindButtonTemplateMixin
        and QuickKeybindButtonTemplateMixin.QuickKeybindButtonSetTooltip
    button.quickBind = over:CreateTexture(nil, "OVERLAY", nil, 1)
    button.quickBind:SetAtlas("UI-HUD-ActionBar-IconFrame-Mouseover")
    button.quickBind:SetBlendMode("ADD")
    button.quickBind:SetPoint("CENTER")
    button.quickBind:SetSize(46, 45)
    button.quickBind:SetAlpha(0.5)
    button.quickBind:Hide()

    -- Shift+drag moves the bar (out of combat: it holds secure buttons).
    button:SetScript("OnDragStart", function()
        if not IsShiftKeyDown() or InCombatLockdown() or ns:GetOption(KEY, "lock") then return end
        flyout:Hide()
        GameTooltip:Hide()
        bar.moving = true
        bar:StartMoving()
    end)
    button:SetScript("OnDragStop", StopMoving)
    button:SetScript("OnEnter", SlotEnter)
    button:SetScript("OnLeave", SlotLeave)
    button:HookScript("OnClick", SlotClicked)
    buttons[index] = button
end

local function CreateBar()
    bar = CreateFrame("Frame", BAR_NAME, UIParent)
    bar:Hide()
    bar:SetSize(#SLOTS * SIZE + (#SLOTS - 1) * GAP, SIZE)
    bar:SetFrameStrata("MEDIUM")
    bar:SetClampedToScreen(true)
    bar:SetMovable(true)
    if bar.SetDontSavePosition then bar:SetDontSavePosition(true) end
    bar:SetPoint("BOTTOM", UIParent, "BOTTOM", 150, 232)
    CreateFlyout()
    for index = 1, #SLOTS do CreateSlot(index) end
    bar:SetScript("OnHide", function() flyout:Hide() end)
end

RefreshAll = function()
    if not bar then return end
    for index = 1, #SLOTS do RefreshSlot(index) end
    RefreshFlyout()
end

-- Brings the secure parts in line with the settings: the keys work and the
-- bar is shown when the feature is on and the character owns a trinket.
Apply = function()
    if InCombatLockdown() then
        dirty = true
        events:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    dirty = false
    for index = 1, #SLOTS do
        triggers[index]:SetAttribute("type", active and "macro" or nil)
        -- In Quick Keybind Mode every mouse button reaches the bar, to be
        -- bound; only left and right do something otherwise.
        if quickBind then
            buttons[index]:RegisterForClicks("AnyUp")
        else
            buttons[index]:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        end
    end
    local wanted = active and HasTrinket()
    if wanted and not bar:IsShown() then Place() end
    bar:SetShown(wanted and true or false)
end

-- Names in Blizzard's Key Bindings window (Bindings.xml).
local function BindingNames()
    _G.BINDING_HEADER_BUDGETFOREVER = L.ADDON_TITLE
    _G["BINDING_NAME_" .. Binding(1)] = L.TRINKET_BINDING_TOP
    _G["BINDING_NAME_" .. Binding(2)] = L.TRINKET_BINDING_BOTTOM
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

function Bar.Command(rest)
    local command = strlower(strtrim(rest or ""))
    if not active then
        ns:Print(L.TRINKET_OFF)
        return
    end
    if command == "reset" or command == "raz" then
        Bar.ResetPosition()
        return
    end
    for index, slot in ipairs(SLOTS) do
        local id, _, link = Equipped(slot)
        local text = id and (link or ("#" .. id)) or L.TRINKET_EMPTY
        local waiting = queue[slot]
        if waiting then text = text .. " " .. L.TRINKET_STATUS_WAITING:format(waiting.link or ItemName(waiting)) end
        ns:Print((index == 1 and L.TRINKET_SLOT_TOP or L.TRINKET_SLOT_BOTTOM) .. ": " .. text)
    end
    if not HasTrinket() then ns:Print(L.TRINKET_NONE) end
    ns:Print(L.TRINKET_COMMAND_HELP)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local EVENTS = {
    "PLAYER_EQUIPMENT_CHANGED", "BAG_UPDATE_DELAYED", "BAG_UPDATE_COOLDOWN", "PLAYER_ENTERING_WORLD",
    "UPDATE_BINDINGS", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
}

events:SetScript("OnEvent", function(_, event, arg1)
    if event == "PLAYER_EQUIPMENT_CHANGED" and active and Value(arg1, "number") then ConfirmSwap(arg1) end
    if event == "PLAYER_REGEN_ENABLED" then
        if dirty then Apply() end
        if not active then
            events:UnregisterEvent("PLAYER_REGEN_ENABLED")
            return
        end
        ProcessQueue()
        RefreshAll()
    elseif not active then
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        StopMoving() -- the last moment the bar may still be let go
    elseif event == "BAG_UPDATE_COOLDOWN" or event == "UPDATE_BINDINGS" then
        RefreshAll()
    else
        -- Equipment or bags changed: the first trinket shows the bar.
        if (HasTrinket() and true or false) ~= (bar:IsShown() and true or false) then Apply() end
        RefreshAll()
    end
end)

local function Enable()
    active = true
    for _, event in ipairs(EVENTS) do pcall(events.RegisterEvent, events, event) end
    Apply()
    RefreshAll()
end

local function Disable()
    active = false
    events:UnregisterAllEvents()
    for slot in pairs(queue) do queue[slot] = nil end
    for slot in pairs(asked) do asked[slot] = nil end
    StopQueue()
    flyout:Hide()
    Apply() -- after combat if need be
end

CreateBar()
BindingNames()

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("QuickKeybindFrame.QuickKeybindModeEnabled", function() SetQuickBind(true) end, Bar)
    EventRegistry:RegisterCallback("QuickKeybindFrame.QuickKeybindModeDisabled", function() SetQuickBind(false) end, Bar)
    -- The key just bound shows on its button at once.
    EventRegistry:RegisterCallback("KeybindListener.RebindSuccess", function() RefreshAll() end, Bar)
end

ns:On("OPTION_CHANGED", function(key)
    if key == KEY and active then RefreshAll() end
end)

ns:On("LANGUAGE_CHANGED", BindingNames)

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "actions",
    order = 40,
    title = "TRINKET_TITLE",
    desc = "TRINKET_DESC",
    tip = "TRINKET_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "lock", title = "TRINKET_OPT_LOCK", tip = "TRINKET_OPT_LOCK_TIP", default = false },
        { key = "reset", title = "TRINKET_OPT_RESET", tip = "TRINKET_OPT_RESET_TIP",
            action = function() Bar.ResetPosition() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
