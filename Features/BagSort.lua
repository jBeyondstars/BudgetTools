local _, ns = ...
local L = ns.L
local Util = ns.Util

--[[
Choice of sort for the bag's "Clean up bags" button.

The modes:
  default  the game's own sort (C_Container.SortBags), untouched.
  pickup   the items in your bags the longest go first, the newest last.
           Items already there before the option was on count as the
           oldest of all.
  usage    the items you use most go first; never-used ones come after.
  Ours don't group anything by type or quality, grey items included: items
  with the same record (two stacks of one item, or items with no record)
  keep the order they have in the bags when the sort starts.

Choosing:
  Right-click on the clean-up button opens a menu with the three modes; the
  button's tooltip tells which one is set. The same choice is a setting of
  the feature in /bgt. Stored in BudgetForeverDB.bagsort.mode.

What is recorded, per character (BudgetForeverDB.bagsort.chars[key], kept
by /bgt reset):
  picked[itemID] = n   a counter that grows each time the bags hold more of
                       that item than before (loot, purchase, mail, bank...).
                       Moving items between bags doesn't change the totals.
  counts[itemID]       the totals at the last look, to compare with.
  used[itemID] = n     how many times the item was used: right-click in the
                       bags (not while a merchant, bank, mail, trade or
                       auction window is open, where right-click does
                       something else), an action button holding the item,
                       or a /use macro by name.

The sort itself:
  The game's sort runs inside the client and its order can't be changed, so
  for our modes the button's click no longer calls it: the items are moved
  with C_Container.PickupContainerItem, as by hand. A step runs every 0.1 s
  and waits while any slot is locked (a move the server hasn't confirmed):
    1. partial stacks of the same item are merged;
    2. the wanted order is computed once from what the bags hold then
       (again only if items come or go meanwhile), and every slot that
       holds the wrong item gets it by a swap. A slot touched once is left
       alone until the next step.
  It ends when every slot holds what it should. It stops on combat, if the
  cursor holds something the sort didn't put there, or after 30 s.
  The order follows the combined backpack as you read it (top row first,
  left to right); with separate bags, the backpack first, slot 1 first.
  Bags marked "Ignore this bag" and special bags (quiver, soul bag...) are
  left out, like the game's own sort does. The reagent bag is sorted the
  same way but on its own (only reagents fit in it), as its window reads.

Keeping equipment sets together (option "keepSets", off by default):
  The items of each equipment set go first in the bags, set after set; an
  item in two sets stays with the first one. With our modes they simply come
  before everything else. With the game's sort, which can't be told about
  sets, the game sorts first; once the bags have been quiet for a moment the
  set items are moved to the front and everything else keeps the order and
  the gaps the game left.
]]

local KEY = "bagSort"

local Sort = {}
ns.BagSort = Sort

local MODES = { "default", "pickup", "usage" }
local MODE_LABEL = {
    default = "BAGSORT_MODE_DEFAULT",
    pickup = "BAGSORT_MODE_PICKUP",
    usage = "BAGSORT_MODE_USAGE",
}

local STEP = 0.1
local TIMEOUT = 30
local SETTLE_QUIET = 1.5    -- seconds without a bag change: the game's sort is over
local SETTLE_TIMEOUT = 20

local active = false
local events
local hookedButton = false
local hookedUse = false
local bagCounts
local dirtyBags = {}
local trackAfterCursor = false

local function Num(value)
    if Util.Readable(value) and type(value) == "number" then return value end
end

local function Str(value)
    if Util.Readable(value) and type(value) == "string" and value ~= "" then return value end
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

local function Store()
    if not ns.db then return end
    local store = ns.db.bagsort
    if type(store) ~= "table" then
        store = {}
        ns.db.bagsort = store
    end
    if type(store.chars) ~= "table" then store.chars = {} end
    return store
end

function Sort.Mode()
    local store = ns.db and ns.db.bagsort
    local mode = type(store) == "table" and store.mode
    if MODE_LABEL[mode] then return mode end
    return "default"
end

function Sort.ModeName(mode)
    return L[MODE_LABEL[mode or Sort.Mode()]]
end

local function SetMode(mode)
    local store = Store()
    if not store or not MODE_LABEL[mode] then return end
    store.mode = mode
    ns:Fire("OPTION_CHANGED", KEY, "mode", mode)
end
Sort.SetMode = SetMode

function Sort.KeepSets()
    return ns.SetColors ~= nil and ns:GetOption(KEY, "keepSets")
end

-- This character's record; counts stays nil until the bags were seen once.
local charData
local function Char()
    if charData then return charData end
    local store = Store()
    if not store then return end
    local key = Util.CharacterKey()
    if key == "?" then return end
    local data = store.chars[key]
    if type(data) ~= "table" then
        data = {}
        store.chars[key] = data
    end
    if type(data.picked) ~= "table" then data.picked = {} end
    if type(data.used) ~= "table" then data.used = {} end
    if type(data.seq) ~= "number" then data.seq = 0 end
    if data.counts ~= nil and type(data.counts) ~= "table" then data.counts = nil end
    charData = data
    return data
end

-- For tests.
function Sort.ResetCache()
    charData = nil
    bagCounts = nil
end

---------------------------------------------------------------------------
-- Bags
---------------------------------------------------------------------------

local function LastBag()
    return NUM_BAG_SLOTS
        or (Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumBagSlots)
        or 4
end

-- Every equipped bag, the reagent bag included, for the totals: moving an
-- item into the reagent bag must not look like a new item.
local function LastCountedBag()
    return NUM_TOTAL_EQUIPPED_BAG_SLOTS or LastBag()
end

local function NumSlots(bag)
    local ok, count = pcall(C_Container.GetContainerNumSlots, bag)
    return ok and Num(count) or 0
end

local function Family(bag)
    if bag == 0 then return 0 end
    local ok, _, family = pcall(C_Container.GetContainerNumFreeSlots, bag)
    return ok and Num(family) or 0
end

-- "Ignore this bag" in the bag's settings menu.
local function Ignored(bag)
    if bag == 0 then
        local check = C_Container.GetBackpackAutosortDisabled
        if type(check) ~= "function" then return false end
        local ok, value = pcall(check)
        return ok and value == true
    end
    local flag = (Enum and Enum.BagSlotFlags and Enum.BagSlotFlags.DisableAutoSort) or LE_BAG_FILTER_FLAG_IGNORE_CLEANUP
    if not flag or type(C_Container.GetBagSlotFlag) ~= "function" then return false end
    local ok, value = pcall(C_Container.GetBagSlotFlag, bag, flag)
    return ok and value == true
end

-- What a slot holds, or nil when empty.
local function SlotItem(bag, slot)
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or not Util.ReadableTable(info) then return end
    local id = Num(info.itemID)
    if not id then return end
    return {
        id = id,
        count = Num(info.stackCount) or 1,
        link = Str(info.hyperlink) or tostring(id),
        quality = Num(info.quality),
        locked = info.isLocked == true,
    }
end

---------------------------------------------------------------------------
-- Pickup order
---------------------------------------------------------------------------

local function CountBag(bag)
    local counts = {}
    for slot = 1, NumSlots(bag) do
        local item = SlotItem(bag, slot)
        if item then
            counts[item.id] = (counts[item.id] or 0) + item.count
        end
    end
    return counts
end

local function CountItems()
    if not bagCounts then
        bagCounts = {}
        dirtyBags = {}
        for bag = 0, LastCountedBag() do
            dirtyBags[bag] = true
        end
    end
    for bag in pairs(dirtyBags) do bagCounts[bag] = CountBag(bag) end
    dirtyBags = {}

    -- Add up the bags only after both sides of a transfer have been read.
    local counts = {}
    for _, snapshot in pairs(bagCounts) do
        for id, count in pairs(snapshot) do
            counts[id] = (counts[id] or 0) + count
        end
    end
    return counts
end

local function HoldingItem()
    return GetCursorInfo and GetCursorInfo() == "item"
end

-- Compares the totals with the last look; more of an item = just picked up.
function Sort.Track(full)
    if full then bagCounts = nil end
    if bagCounts and not next(dirtyBags) then return end
    local data = Char()
    if not data then return end
    if HoldingItem() then
        trackAfterCursor = true
        return
    end
    trackAfterCursor = false
    local counts = CountItems()
    -- Bags can read as empty right after login. Retry a full scan once they load.
    if not next(counts) then
        bagCounts = nil
        return
    end
    if data.counts == nil then
        -- First look for this character: what is there is old, not new.
        data.counts = counts
        return
    end
    local fresh = {}
    for id, count in pairs(counts) do
        if count > (data.counts[id] or 0) then table.insert(fresh, id) end
    end
    table.sort(fresh) -- same order every time for items that came together
    for _, id in ipairs(fresh) do
        data.seq = data.seq + 1
        data.picked[id] = data.seq
    end
    data.counts = counts
end

---------------------------------------------------------------------------
-- Use counts
---------------------------------------------------------------------------

-- Windows where a right-click on a bag item sells, stores or sends it.
local BUSY_FRAMES = { "MerchantFrame", "BankFrame", "SendMailFrame", "TradeFrame",
    "AuctionHouseFrame", "AuctionFrame", "GuildBankFrame" }

local function RightClickBusy()
    for _, name in ipairs(BUSY_FRAMES) do
        local frame = _G[name]
        if type(frame) == "table" and frame.IsShown and frame:IsShown() then return true end
    end
    return false
end

function Sort.Used(id)
    if not active then return end
    id = Num(id)
    local data = id and Char()
    if not data then return end
    data.used[id] = (data.used[id] or 0) + 1
end

local function ItemIDFromName(name)
    if type(name) == "number" then return name end
    name = Str(name)
    if not name then return end
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not instant then return end
    local ok, id = pcall(instant, name)
    return ok and Num(id) or nil
end

local function InstallUseHooks()
    if hookedUse then return end
    hookedUse = true
    if C_Container and type(C_Container.UseContainerItem) == "function" then
        hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
            if not active or RightClickBusy() then return end
            local ok, id = pcall(C_Container.GetContainerItemID, bag, slot)
            if ok then Sort.Used(id) end
        end)
    end
    if type(UseAction) == "function" then
        hooksecurefunc("UseAction", function(slot)
            if not active then return end
            local ok, kind, id = pcall(GetActionInfo, slot)
            if ok and kind == "item" then Sort.Used(id) end
        end)
    end
    -- /use Name in a macro. The two can be the same function under two
    -- names; each hook only sees calls made through its own name.
    local function ByName(name)
        if not active then return end
        Sort.Used(ItemIDFromName(name))
    end
    if C_Item and type(C_Item.UseItemByName) == "function" then
        hooksecurefunc(C_Item, "UseItemByName", ByName)
    end
    if type(UseItemByName) == "function" then
        hooksecurefunc("UseItemByName", ByName)
    end
end

---------------------------------------------------------------------------
-- Wanted order
---------------------------------------------------------------------------

-- What an item is sorted on: its score, then where it is now.
local function Keys(item, mode, data)
    local score = 0
    if mode == "pickup" then
        -- Oldest first: higher score goes first, so the counter is negated.
        -- Items with no record were in the bags before anything recorded,
        -- so they are the oldest and keep 0, ahead of every recorded one.
        score = -(data and data.picked[item.id] or 0)
    elseif mode == "usage" then
        score = data and data.used[item.id] or 0
    end
    item.score = score
end

-- item.set is the item's place among the equipment sets, only filled in when
-- sets are kept together.
local function Before(a, b)
    local setA, setB = a.set or math.huge, b.set or math.huge
    if setA ~= setB then return setA < setB end
    if a.score ~= b.score then return a.score > b.score end
    return a.pos < b.pos
end

-- Two stacks of one item are interchangeable whatever their size: once
-- partial stacks are merged, a full and a partial stack are never swapped
-- (dropping one on the other would merge them instead). Two copies of one
-- item are not when only one of them belongs to a set.
local function Signature(item)
    if not item then return "" end
    if item.set then return item.link .. "#set" .. item.set end
    return item.link
end

-- After the game's own sort: the set items first, then everything else as
-- the game left it, empty slots included.
local function PlanAfterGameSort(items, data)
    local sets, rest = {}, {}
    for index, item in ipairs(items) do
        if item and item.set then
            Keys(item, "default", data)
            item.pos = index
            table.insert(sets, item)
        else
            table.insert(rest, item)
        end
    end
    table.sort(sets, Before)
    local wanted = {}
    for _, item in ipairs(sets) do table.insert(wanted, Signature(item)) end
    for _, item in ipairs(rest) do table.insert(wanted, Signature(item)) end
    return wanted
end

-- The wanted signature of each slot, in slot order. items[i] is what slot i
-- holds now, false when empty.
function Sort.Plan(items, mode, data)
    if mode == "default" then return PlanAfterGameSort(items, data) end
    local list = {}
    for index, item in ipairs(items) do
        if item then
            Keys(item, mode, data)
            item.pos = index
            table.insert(list, item)
        end
    end
    table.sort(list, Before)
    local wanted = {}
    for index = 1, #items do
        wanted[index] = Signature(list[index])
    end
    return wanted
end

---------------------------------------------------------------------------
-- Slots taking part, in reading order
---------------------------------------------------------------------------

local function Round(value)
    return math.floor(value + 0.5)
end

-- The slots of `bags` ({ [bag] = size }) as they read in `frame` (top row
-- first, left to right), or nil when the frame doesn't show them all.
local function ScreenOrder(frame, bags, total)
    if not frame or not frame:IsShown() or not Util.ReadableTable(frame.Items) then return end
    local list = {}
    for _, button in ipairs(frame.Items) do
        if button:IsShown() then
            local okBag, bag = pcall(button.GetBagID, button)
            local okSlot, slot = pcall(button.GetID, button)
            bag, slot = okBag and Num(bag), okSlot and Num(slot)
            local left, top = Num(button:GetLeft()), Num(button:GetTop())
            if bag and slot and left and top and bags[bag] then
                table.insert(list, { bag = bag, slot = slot, row = Round(top), left = left })
            end
        end
    end
    if #list ~= total then return end
    table.sort(list, function(a, b)
        if a.row ~= b.row then return a.row > b.row end
        return a.left < b.left
    end)
    return list
end

local function SlotOrder(bags, first, last)
    local list = {}
    for bag = first, last do
        if bags[bag] then
            for slot = 1, bags[bag] do
                table.insert(list, { bag = bag, slot = slot })
            end
        end
    end
    return list
end

function Sort.Slots()
    local bags, total = {}, 0
    for bag = 0, LastBag() do
        local size = NumSlots(bag)
        if size > 0 and Family(bag) == 0 and not Ignored(bag) then
            bags[bag] = size
            total = total + size
        end
    end
    -- The combined backpack, as it reads on screen.
    return ScreenOrder(ContainerFrameCombinedBags, bags, total) or SlotOrder(bags, 0, LastBag())
end

-- The window showing one bag on its own, if open.
local function BagFrame(bag)
    for index = 1, (NUM_CONTAINER_FRAMES or 13) do
        local frame = _G["ContainerFrame" .. index]
        if frame and frame:IsShown() and frame.GetBagID then
            local ok, id = pcall(frame.GetBagID, frame)
            if ok and id == bag then return frame end
        end
    end
end

-- Each reagent bag's slots, sorted on its own: only reagents fit there, so
-- its items can't be swapped with the other bags'.
function Sort.ReagentGroups()
    local groups = {}
    for bag = LastBag() + 1, LastCountedBag() do
        local size = NumSlots(bag)
        if size > 0 and not Ignored(bag) then
            local bags = { [bag] = size }
            table.insert(groups, ScreenOrder(BagFrame(bag), bags, size) or SlotOrder(bags, bag, bag))
        end
    end
    return groups
end

---------------------------------------------------------------------------
-- Moving items
---------------------------------------------------------------------------

local job
local runner
local settle -- waiting for the game's own sort to end: { started, last }

local function CursorBusy()
    return GetCursorInfo and GetCursorInfo() ~= nil
end

local function SortBlocked()
    if InCombatLockdown and InCombatLockdown() then return L.BAGSORT_STOP_COMBAT end
    if CursorBusy() then return L.BAGSORT_STOP_CURSOR end
end

local function Move(from, to)
    C_Container.PickupContainerItem(from.bag, from.slot)
    C_Container.PickupContainerItem(to.bag, to.slot)
    -- A move the client refused leaves the item on the cursor: put it back.
    if CursorBusy() then ClearCursor() end
end

local function Stop(message)
    job = nil
    settle = nil
    if runner then runner:Hide() end
    if message then ns:Print(message) end
end
Sort.Stop = Stop

function Sort.Running()
    return job ~= nil
end

local function MaxStack(id)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not info then return end
    local ok, _, _, _, _, _, _, _, stack = pcall(info, id)
    return ok and Num(stack) or nil
end

-- Merges partial stacks; true when moves were made.
local function MergeStacks(slots)
    local partial = {}
    for _, slot in ipairs(slots) do
        local item = slot.item
        if item then
            local max = MaxStack(item.id)
            if max and max > 1 and item.count < max then
                local group = partial[item.link]
                if not group then
                    group = {}
                    partial[item.link] = group
                end
                table.insert(group, slot)
            end
        end
    end
    local moved = false
    for _, group in pairs(partial) do
        -- Pairs from both ends: the last stacks go onto the first ones.
        local first, last = 1, #group
        while first < last do
            Move(group[last], group[first])
            moved = true
            first, last = first + 1, last - 1
        end
    end
    return moved
end

-- Swaps toward the wanted order; returns the number of moves and whether
-- every slot already holds what it should.
-- True when the slots hold exactly the signatures of the plan, in any order.
local function SameItems(slots, wanted)
    if #wanted ~= #slots then return false end
    local count = {}
    for _, slot in ipairs(slots) do
        local signature = Signature(slot.item)
        count[signature] = (count[signature] or 0) + 1
    end
    for _, signature in ipairs(wanted) do
        count[signature] = (count[signature] or 0) - 1
    end
    for _, left in pairs(count) do
        if left ~= 0 then return false end
    end
    return true
end

-- The plan is made once: ties keep the order the items had at the start,
-- which a plan redone after every swap would lose.
local function Arrange(slots, job, data)
    if not job.wanted or not SameItems(slots, job.wanted) then
        local items = {}
        for index, slot in ipairs(slots) do items[index] = slot.item or false end
        job.wanted = Sort.Plan(items, job.mode, data)
    end
    local wanted = job.wanted
    local current = {}
    for index, slot in ipairs(slots) do current[index] = Signature(slot.item) end

    local touched, moves, done = {}, 0, true
    for index = 1, #slots do
        if current[index] ~= wanted[index] then
            done = false
            if not touched[index] then
                local source
                for other = index + 1, #slots do
                    if not touched[other] and current[other] == wanted[index] and current[other] ~= wanted[other] then
                        source = other
                        break
                    end
                end
                if source then
                    -- Always pick up a slot that holds something.
                    if slots[source].item then
                        Move(slots[source], slots[index])
                    else
                        Move(slots[index], slots[source])
                    end
                    current[index], current[source] = current[source], current[index]
                    touched[index], touched[source] = true, true
                    moves = moves + 1
                end
            end
        end
    end
    return moves, done
end

-- One step of the sort. Returns "wait", "moved", "done" or "stuck".
function Sort.Step()
    if not job then return "done" end
    local message = SortBlocked()
    if message then
        Stop(message)
        return "stuck"
    end
    for _, group in ipairs(job.groups) do
        for _, slot in ipairs(group.slots) do
            slot.item = SlotItem(slot.bag, slot.slot)
            if slot.item and slot.item.locked then return "wait" end
            if slot.item and job.keepSets then
                slot.item.set = ns.SetColors.Rank(slot.bag, slot.slot)
            end
        end
    end
    if not job.merged then
        local merged = false
        for _, group in ipairs(job.groups) do
            if MergeStacks(group.slots) then merged = true end
        end
        if merged then return "moved" end
        job.merged = true
        return "wait" -- read the bags again before arranging
    end
    local data, moves, done = Char(), 0, true
    for _, group in ipairs(job.groups) do
        local groupMoves, groupDone = Arrange(group.slots, group, data)
        moves = moves + groupMoves
        done = done and groupDone
    end
    if done then
        Stop()
        return "done"
    end
    if moves > 0 then
        job.idle = 0
        return "moved"
    end
    job.idle = (job.idle or 0) + 1
    if job.idle > 20 then
        Stop(L.BAGSORT_STOP_STUCK)
        return "stuck"
    end
    return "wait"
end

-- The game's sort has no end signal: it is over when the bags stay quiet and
-- nothing is locked. Then the set items, if any, are moved.
function Sort.SettleStep()
    if not settle then return end
    local now = GetTime()
    if now - settle.started > SETTLE_TIMEOUT or not Sort.KeepSets() then
        Stop()
        return
    end
    if now - settle.last < SETTLE_QUIET then return end
    local slots = Sort.Slots()
    local setItems, lastRank, needsGrouping = 0, 0, false
    for index, slot in ipairs(slots) do
        local item = SlotItem(slot.bag, slot.slot)
        if item and item.locked then return end
        slot.item = item
        local rank = item and ns.SetColors.Rank(slot.bag, slot.slot)
        if rank then
            setItems = setItems + 1
            -- The first slots must hold only set items, in set order.
            if index ~= setItems or rank < lastRank then needsGrouping = true end
            lastRank = rank
        end
    end
    if setItems == 0 then
        Stop()
        return
    end
    local message = SortBlocked()
    if message then
        Stop(message)
        return
    end
    local moved = MergeStacks(slots)
    if not moved and not needsGrouping then
        Stop()
        return
    end
    settle = nil
    job = { groups = { { mode = "default", slots = slots } }, started = now, merged = not moved, keepSets = true }
end

local function OnUpdate(self, elapsed)
    self.wait = (self.wait or 0) - elapsed
    if self.wait > 0 then return end
    self.wait = STEP
    if settle then
        local ok, err = pcall(Sort.SettleStep)
        if not ok then
            Stop()
            geterrorhandler()(err)
        end
        return
    end
    if not job then
        self:Hide()
        return
    end
    if GetTime() - job.started > TIMEOUT then
        Stop(L.BAGSORT_STOP_STUCK)
        return
    end
    local ok, err = pcall(Sort.Step)
    if not ok then
        Stop()
        geterrorhandler()(err)
    end
end

local function ShowRunner()
    if not runner then
        runner = CreateFrame("Frame")
        runner:SetScript("OnUpdate", OnUpdate)
    end
    runner.wait = 0
    runner:Show()
end

-- Called right after the game's own sort was asked for.
function Sort.AfterGameSort()
    local now = GetTime()
    settle = { started = now, last = now }
    ShowRunner()
end

function Sort.Start(mode)
    mode = mode or Sort.Mode()
    local message = SortBlocked()
    if message then
        ns:Print(message)
        return false
    end
    if mode == "pickup" then Sort.Track(true) end -- anything that just arrived counts
    settle = nil
    local groups = { { mode = mode, slots = Sort.Slots() } }
    for _, slots in ipairs(Sort.ReagentGroups()) do
        table.insert(groups, { mode = mode, slots = slots })
    end
    job = { groups = groups, started = GetTime(), merged = false, keepSets = Sort.KeepSets() }
    ShowRunner()
    return true
end

---------------------------------------------------------------------------
-- Choice menu
---------------------------------------------------------------------------

local MODE_TIP = {
    default = "BAGSORT_MODE_DEFAULT_TIP",
    pickup = "BAGSORT_MODE_PICKUP_TIP",
    usage = "BAGSORT_MODE_USAGE_TIP",
}

function Sort.OpenMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    local refresh = MenuResponse and MenuResponse.Refresh
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.BAGSORT_MENU)
        for _, mode in ipairs(MODES) do
            local radio = root:CreateRadio(Sort.ModeName(mode),
                function() return Sort.Mode() == mode end,
                function()
                    SetMode(mode)
                    return refresh
                end)
            if radio and radio.SetTooltip then
                radio:SetTooltip(function(tooltip)
                    GameTooltip_SetTitle(tooltip, Sort.ModeName(mode))
                    GameTooltip_AddNormalLine(tooltip, L[MODE_TIP[mode]])
                end)
            end
        end
    end)
end

---------------------------------------------------------------------------
-- The clean-up button
---------------------------------------------------------------------------

local function InstallButton()
    if hookedButton then return true end
    local button = BagItemAutoSortButton
    if not button or not button.GetScript then return false end
    hookedButton = true
    local original = button:GetScript("OnClick")
    button:SetScript("OnClick", function(self, ...)
        if active and Sort.Mode() ~= "default" then
            if PlaySound and SOUNDKIT and SOUNDKIT.UI_BAG_SORTING_01 then
                PlaySound(SOUNDKIT.UI_BAG_SORTING_01)
            end
            Sort.Start()
            return
        end
        if active and Sort.KeepSets() then
            Stop()
            if original then original(self, ...) end
            Sort.AfterGameSort()
            return
        end
        if original then return original(self, ...) end
    end)
    -- The button only answers the left button; a right-click still gets
    -- OnMouseUp.
    button:HookScript("OnMouseUp", function(self, mouse)
        if active and mouse == "RightButton" then Sort.OpenMenu(self) end
    end)
    button:HookScript("OnEnter", function(self)
        if not active or not GameTooltip:IsOwned(self) then return end
        GameTooltip:AddLine(L.BAGSORT_TOOLTIP_MODE:format(Sort.ModeName()), 1, 1, 1)
        GameTooltip:AddLine(L.BAGSORT_TOOLTIP_RIGHT, 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    return true
end

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

local function TrackAfterCursor()
    -- The cursor event can come before the bag events for the drop.
    if active and trackAfterCursor then Sort.Track() end
end

local function OnEvent(_, event, bag)
    if event == "PLAYER_REGEN_DISABLED" then
        if job then
            Stop(L.BAGSORT_STOP_COMBAT)
        elseif settle then
            Stop()
        end
        return
    end
    if event == "BAG_UPDATE" then
        bag = Num(bag)
        if bag and bag >= 0 and bag <= LastCountedBag() then dirtyBags[bag] = true end
    elseif event == "BAG_UPDATE_DELAYED" then
        if settle then settle.last = GetTime() end
        Sort.Track()
    elseif event == "CURSOR_CHANGED" then
        if trackAfterCursor and not HoldingItem() then C_Timer.After(0, TrackAfterCursor) end
    elseif event == "PLAYER_ENTERING_WORLD" then
        InstallButton()
        Sort.Track(true)
    end
end

ns:RegisterFeature({
    key = KEY,
    category = "items",
    order = 25,
    title = "BAGSORT_TITLE",
    desc = "BAGSORT_DESC",
    tip = "BAGSORT_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "mode", title = function() return L.BAGSORT_OPT_MODE:format(Sort.ModeName()) end,
            tip = "BAGSORT_OPT_MODE_TIP",
            action = function(button) Sort.OpenMenu(button) end },
        { key = "keepSets", title = "BAGSORT_OPT_SETS", tip = "BAGSORT_OPT_SETS_TIP", default = false },
    },
    OnEnable = function()
        active = true
        if not events then
            events = CreateFrame("Frame")
            events:SetScript("OnEvent", OnEvent)
        end
        events:RegisterEvent("BAG_UPDATE")
        events:RegisterEvent("BAG_UPDATE_DELAYED")
        events:RegisterEvent("CURSOR_CHANGED")
        events:RegisterEvent("PLAYER_ENTERING_WORLD")
        events:RegisterEvent("PLAYER_REGEN_DISABLED")
        InstallUseHooks()
        InstallButton()
        Sort.Track(true)
    end,
    OnDisable = function()
        -- The hooks can't be removed; they stay and let the game's sort run.
        active = false
        trackAfterCursor = false
        Stop()
        if events then events:UnregisterAllEvents() end
    end,
})
