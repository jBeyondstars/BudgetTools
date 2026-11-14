local _, ns = ...
local L, UI, Util = ns.L, ns.UI, ns.Util

-- Full bags while looting: proposes to destroy the cheapest item in your
-- bags to make room for the loot, when that item is worth less than the
-- loot. Nothing is destroyed until the player clicks "Destroy and loot"
-- (the game only lets an item be deleted on a real click anyway).

local KEY = "lootSwap"
local WINDOW_NAME = "BudgetForeverLootSwap"
local WINDOW_ICON = "Interface\\Icons\\INV_Misc_Bag_08"
local CALLER = "BudgetForever"      -- Auctionator API caller id
local RECENT = 1                    -- seconds: a LootSlot this recent caused the error
local PROPOSE_DELAY = 0.15          -- errors come in bursts: answer once
local RETRY_DELAY = 0.5             -- item data not cached yet
local MAX_QUALITY = 2               -- uncommon; blue and better are never proposed

-- Enum.ItemClass
local CLASS_CONSUMABLE, CLASS_CONTAINER, CLASS_REAGENT, CLASS_PROJECTILE = 0, 1, 5, 6
local CLASS_TRADEGOODS, CLASS_QUIVER, CLASS_QUEST, CLASS_KEY = 7, 11, 12, 13

-- Never proposed: what you carry on purpose (profession tools, Hearthstone...).
local TOOLS = {
    [6948] = true,                                  -- Hearthstone
    [2901] = true, [7005] = true, [5956] = true,    -- Mining Pick, Skinning Knife, Blacksmith Hammer
    [6219] = true, [10498] = true,                  -- Arclight Spanner, Gyromatic Micro-Adjustor
    [6256] = true, [6365] = true, [6366] = true,    -- fishing poles
    [6367] = true, [12225] = true, [19022] = true, [19970] = true,
    [6218] = true, [6339] = true, [11130] = true,   -- enchanting rods
    [11145] = true, [16207] = true,
    [5060] = true, [4471] = true, [9149] = true,    -- Thieves' Tools, Flint and Tinder, Philosopher's Stone
    [5175] = true, [5176] = true, [5177] = true, [5178] = true, -- shaman totems
    [6265] = true,                                  -- Soul Shard
    -- Lockboxes, junkboxes, locked chests and clams: containers, usually
    -- with a green inside. Also caught by their tooltip; this list is the
    -- safety net when the tooltip can't be read.
    [4632] = true, [4633] = true, [4634] = true, [4636] = true, [4637] = true, [4638] = true,
    [5758] = true, [5759] = true, [5760] = true,
    [16882] = true, [16883] = true, [16884] = true, [16885] = true,
    [6354] = true, [6355] = true, [13875] = true, [13918] = true,
    [5523] = true, [5524] = true, [7973] = true, [15874] = true,
}

-- Protected with "consumables, reagents, ammo and trade goods": class
-- reagents, in case the client files them under Miscellaneous.
local REAGENTS = {
    [17030] = true, [17033] = true, [21177] = true, [17020] = true, [17031] = true,
    [17032] = true, [17028] = true, [17029] = true, [5565] = true, [16583] = true,
    [17056] = true, [5140] = true, [5530] = true, [2928] = true, [8924] = true,
    [2930] = true, [8923] = true, [5173] = true, [17058] = true, [17057] = true,
    [17026] = true, [17021] = true, [17034] = true, [17035] = true, [17036] = true,
    [17037] = true, [17038] = true,
}
local USEFUL_CLASSES = {
    [CLASS_CONSUMABLE] = true, [CLASS_REAGENT] = true,
    [CLASS_PROJECTILE] = true, [CLASS_TRADEGOODS] = true,
}

local Swap = {}
ns.LootSwap = Swap

local lootOpen = false
local errorAt                -- last "Inventory is full." while looting
local wanted = {}            -- loot slot -> true: the player tried to loot it
local wantAll = false        -- autoloot: every slot left in the window failed
local focus                  -- the slot the player clicked last: shown first
local recentLoot = {}        -- loot slot -> GetTime() of the last LootSlot()
local notified = false       -- "nothing to destroy" printed for this window
local pending                -- { slot, link, time } after a swap
local generation = 0         -- cancels scheduled proposals
local window

---------------------------------------------------------------------------
-- Game data
---------------------------------------------------------------------------

local Container = C_Container or {}
local GetInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local LOOT_ITEM = (Enum and Enum.LootSlotType and Enum.LootSlotType.Item) or LOOT_SLOT_ITEM or 1

local function Call(func, ...)
    if type(func) ~= "function" then return false end
    return pcall(func, ...)
end

local function ItemID(link)
    local id = type(link) == "string" and link:match("item:(%d+)")
    return id and tonumber(id)
end

-- name, quality, icon, sellPrice (per unit), classID
local function ItemData(link)
    local ok, name, _, quality, _, _, _, _, _, _, icon, sellPrice, classID = Call(GetInfo, link)
    if not ok then name, quality, icon, sellPrice, classID = nil, nil, nil, nil, nil end
    if classID == nil then
        local okInstant, _, _, _, _, instantIcon, instantClass = Call(GetInstant, link)
        if okInstant then
            classID = instantClass
            icon = icon or instantIcon
        end
    end
    return name, quality, icon, sellPrice, classID
end

local function AuctionPrice(link)
    if not ns:GetOption(KEY, "useAuction") then return end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if type(api) ~= "table" then return end
    local ok, price = Call(api.GetAuctionPriceByItemLink, CALLER, link)
    if ok and type(price) == "number" and price > 0 then return price end
end

-- What a stack is worth: the vendor price, or the auction price when it is
-- higher. Returns total, unit price, "vendor" / "auction". Grey items are
-- vendor trash: a stray auction listing must not make them look valuable.
local function Worth(link, sellPrice, count, quality)
    local unit, source = sellPrice or 0, "vendor"
    local auction = quality and quality >= 1 and AuctionPrice(link)
    if auction and auction > unit then unit, source = auction, "auction" end
    return unit * (count or 1), unit, source
end

local function NumSlots(bag)
    local ok, count = Call(Container.GetContainerNumSlots or GetContainerNumSlots, bag)
    return ok and tonumber(count) or 0
end

-- free slots, bag family (0 = a normal bag that takes any item)
local function FreeSlots(bag)
    local ok, free, family = Call(Container.GetContainerNumFreeSlots or GetContainerNumFreeSlots, bag)
    if not ok then return 0, 0 end
    return tonumber(free) or 0, tonumber(family) or 0
end

local function LastBag()
    return NUM_BAG_SLOTS or 4
end

local function TotalFree()
    local total = 0
    for bag = 0, LastBag() do
        local free, family = FreeSlots(bag)
        if family == 0 then total = total + free end
    end
    return total
end

-- link, count, locked, hasNoValue, quality, icon, hasLoot (can be opened)
local function BagItem(bag, slot)
    if Container.GetContainerItemInfo then
        local ok, info = pcall(Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" and info.hyperlink then
            return info.hyperlink, info.stackCount or 1, info.isLocked, info.hasNoValue, info.quality,
                info.iconFileID, info.hasLoot
        end
    elseif GetContainerItemInfo then
        local ok, icon, count, locked, quality, _, lootable, link, _, noValue = pcall(GetContainerItemInfo, bag, slot)
        if ok and link then return link, count or 1, locked, noValue, quality, icon, lootable end
    end
end

-- Lockboxes, clams, bags of loot: what is inside is worth more than the
-- vendor price. A locked lockbox does not always report hasLoot, so the
-- tooltip is read too ("Locked", "<Right Click to Open>").
local scanTip
local function TooltipLines(bag, slot)
    local lines = {}
    if C_TooltipInfo and C_TooltipInfo.GetBagItem then
        local ok, data = pcall(C_TooltipInfo.GetBagItem, bag, slot)
        if ok and type(data) == "table" and type(data.lines) == "table" then
            for _, line in ipairs(data.lines) do
                if type(line) == "table" then lines[#lines + 1] = line.leftText end
            end
            return lines
        end
    end
    if not scanTip then
        scanTip = CreateFrame("GameTooltip", "BudgetForeverScanTooltip", nil, "GameTooltipTemplate")
    end
    scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
    if pcall(scanTip.SetBagItem, scanTip, bag, slot) then
        for i = 1, scanTip:NumLines() or 0 do
            local region = _G["BudgetForeverScanTooltipTextLeft" .. i]
            lines[#lines + 1] = region and region:GetText()
        end
    end
    scanTip:Hide()
    return lines
end

local function IsOpenable(bag, slot, hasLoot)
    if hasLoot then return true end
    for _, text in ipairs(TooltipLines(bag, slot)) do
        if type(text) == "string" and Util.Readable(text) and (text == LOCKED or text == ITEM_OPENABLE) then
            return true
        end
    end
    return false
end

local function KeepList()
    if not ns.db then return {} end
    ns.db.loot = ns.db.loot or {}
    ns.db.loot.keep = ns.db.loot.keep or {}
    return ns.db.loot.keep
end

local function IsProtected(itemID, classID)
    if not itemID or TOOLS[itemID] or KeepList()[itemID] then return true end
    if classID == CLASS_QUEST or classID == CLASS_KEY or classID == CLASS_CONTAINER or classID == CLASS_QUIVER then
        return true
    end
    if ns:GetOption(KEY, "protectUseful") and (USEFUL_CLASSES[classID] or REAGENTS[itemID]) then
        return true
    end
    return false
end

---------------------------------------------------------------------------
-- The loot window
---------------------------------------------------------------------------

local function NumLoot()
    local ok, count = Call(GetNumLootItems)
    return ok and tonumber(count) or 0
end

local function LootIsOpen()
    return lootOpen and NumLoot() > 0
end

-- One item slot of the loot window, nil for money, currency or an empty slot.
function Swap.LootData(slot)
    local okType, kind = Call(GetLootSlotType, slot)
    if okType and kind ~= LOOT_ITEM then return end
    local okLink, link = Call(GetLootSlotLink, slot)
    if not okLink or type(link) ~= "string" or not Util.Readable(link) then return end

    local info = { pcall(GetLootSlotInfo, slot) }
    if not info[1] then return end
    local icon, quantity = info[2], tonumber(info[4]) or 1
    -- Modern: icon, name, quantity, currencyID, quality, locked, isQuestItem.
    -- Older clients have no currencyID, so everything shifts by one.
    local locked, isQuest
    if type(info[6]) == "number" then
        locked, isQuest = info[7], info[8]
    else
        locked, isQuest = info[6], info[7]
    end

    local name, quality, itemIcon, sellPrice, classID = ItemData(link)
    local loot = {
        slot = slot, link = link, itemID = ItemID(link), name = name, quality = quality,
        icon = itemIcon or icon, count = quantity, locked = locked == true,
        quest = isQuest == true or classID == CLASS_QUEST,
        unknown = sellPrice == nil,
    }
    loot.value, loot.unit, loot.source = Worth(link, sellPrice, quantity, quality)
    return loot
end

-- Quest items first (they sell for nothing but you want them), then value.
local function Better(a, b)
    if a.quest ~= b.quest then return a.quest end
    return a.value > b.value
end

function Swap.PickTarget()
    local best
    for slot = 1, NumLoot() do
        if wantAll or wanted[slot] then
            local loot = Swap.LootData(slot)
            if loot and not loot.locked and (not best or Better(loot, best)) then best = loot end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- What could make room
---------------------------------------------------------------------------

-- An item can make room when it is cheaper than the loot AND not of a better
-- quality: never a green for a grey. Quest loot is worth nothing at the
-- vendor but is wanted, so only quality caps apply to it.
function Swap.FindCandidates(loot)
    local list = {}
    local maxQuality = ns:GetOption(KEY, "allowGreen") and MAX_QUALITY or 1
    if not loot.quest then maxQuality = math.min(maxQuality, loot.quality or 0) end
    for bag = 0, LastBag() do
        local _, family = FreeSlots(bag)
        -- A slot freed in a quiver or herb bag would not take the loot.
        if family == 0 then
            for slot = 1, NumSlots(bag) do
                local link, count, locked, noValue, quality, icon, hasLoot = BagItem(bag, slot)
                if link and not locked and not noValue then
                    local itemID = ItemID(link)
                    local name, itemQuality, itemIcon, sellPrice, classID = ItemData(link)
                    quality = quality or itemQuality
                    if itemID and itemID ~= loot.itemID and quality and quality <= maxQuality
                        and sellPrice and sellPrice > 0 and not IsProtected(itemID, classID) then
                        local value, unit, source = Worth(link, sellPrice, count, quality)
                        if (loot.quest or value < loot.value) and not IsOpenable(bag, slot, hasLoot) then
                            list[#list + 1] = {
                                bag = bag, slot = slot, link = link, itemID = itemID, name = name,
                                quality = quality, icon = icon or itemIcon, count = count,
                                value = value, unit = unit, source = source,
                            }
                        end
                    end
                end
            end
        end
    end
    -- Grey junk first, then the cheapest.
    table.sort(list, function(a, b)
        if a.quality ~= b.quality then return a.quality < b.quality end
        if a.value ~= b.value then return a.value < b.value end
        if a.bag ~= b.bag then return a.bag < b.bag end
        return a.slot < b.slot
    end)
    return list
end

---------------------------------------------------------------------------
-- Text helpers
---------------------------------------------------------------------------

local function Money(copper)
    copper = math.floor(copper or 0)
    local ok, text = Call(GetMoneyString, copper, true)
    if not (ok and type(text) == "string" and text ~= "") then
        ok, text = Call(GetCoinTextureString, copper)
    end
    if ok and type(text) == "string" and text ~= "" then return text end
    local gold, silver, rest = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    if gold > 0 then return ("%dg %ds %dc"):format(gold, silver, rest) end
    if silver > 0 then return ("%ds %dc"):format(silver, rest) end
    return ("%dc"):format(rest)
end
Swap.Money = Money

local function QualityColor(quality)
    for _, getter in ipairs({ C_Item and C_Item.GetItemQualityColor, GetItemQualityColor }) do
        local ok, r, g, b = Call(getter, quality)
        if ok and type(r) == "number" then return r, g, b end
    end
    local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
    if color then return color.r, color.g, color.b end
    return 1, 1, 1
end

local function ColoredName(item)
    if not item.name then return item.link end
    local r, g, b = QualityColor(item.quality or 1)
    local function Byte(value) return math.floor(math.max(0, math.min(1, value)) * 255 + 0.5) end
    return ("|cff%02x%02x%02x%s|r"):format(Byte(r), Byte(g), Byte(b), item.name)
end

-- "[Linen Cloth]x20" for the chat line.
local function ChatItem(item)
    if (item.count or 1) > 1 then return item.link .. "x" .. item.count end
    return item.link
end

local function ValueText(item)
    if item.quest and (item.value or 0) == 0 then
        return "|cffffd200" .. L.SWAP_QUEST .. "|r"
    end
    local text = Money(item.value)
    if (item.count or 1) > 1 then
        text = text .. "  |cff9d9d9d(" .. item.count .. " x " .. Money(item.unit) .. ")|r"
    end
    return (item.source == "auction" and L.SWAP_VALUE_AH or L.SWAP_VALUE):format(text)
end

---------------------------------------------------------------------------
-- Destroying and looting
---------------------------------------------------------------------------

local PickupItem = Container.PickupContainerItem or PickupContainerItem

-- Runs inside the click on "Destroy and loot". Checks again that the loot
-- and the bag item are still the ones shown, so nothing else is destroyed.
function Swap.Execute(loot, candidate)
    local now = Swap.LootData(loot.slot)
    if not LootIsOpen() or not now or now.link ~= loot.link then
        ns:Error(L.SWAP_ERROR_GONE)
        return false, "gone"
    end
    local link, _, locked = BagItem(candidate.bag, candidate.slot)
    if link ~= candidate.link or locked then
        ns:Error(L.SWAP_ERROR_MOVED)
        return false, "moved"
    end
    if GetCursorInfo() then
        ns:Error(L.SWAP_ERROR_CURSOR)
        return false, "cursor"
    end

    PickupItem(candidate.bag, candidate.slot)
    local kind, itemID = GetCursorInfo()
    if kind ~= "item" or itemID ~= candidate.itemID then
        ClearCursor()
        ns:Error(L.SWAP_ERROR_MOVED)
        return false, "moved"
    end
    DeleteCursorItem()
    ns:Print(L.SWAP_DONE:format(ChatItem(candidate), Money(candidate.value), ChatItem(loot)))

    pending = { slot = loot.slot, link = loot.link, time = GetTime() }
    LootSlot(loot.slot)
    return true
end

function Swap.Keep(candidate)
    KeepList()[candidate.itemID] = true
    ns:Print(L.SWAP_KEPT:format(candidate.link))
end

function Swap.ClearKeep()
    local keep, count = KeepList(), 0
    for itemID in pairs(keep) do
        keep[itemID] = nil
        count = count + 1
    end
    ns:Print(L.SWAP_KEEP_CLEARED:format(count))
end

---------------------------------------------------------------------------
-- Proposal window
---------------------------------------------------------------------------

local function ItemTooltip(button)
    local item = button.item
    if not item then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local shown
    if item.bag then
        shown = pcall(GameTooltip.SetBagItem, GameTooltip, item.bag, item.slot)
    elseif item.slot then
        shown = pcall(GameTooltip.SetLootItem, GameTooltip, item.slot)
    end
    if not shown then pcall(GameTooltip.SetHyperlink, GameTooltip, item.link) end
    GameTooltip:Show()
end

local function CreateItemSlot(parent, y)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(36, 36)
    button:SetPoint("TOPLEFT", 14, y)

    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button.border = button:CreateTexture(nil, "OVERLAY")
    button.border:SetAllPoints()
    button.border:SetTexture("Interface\\Common\\WhiteIconFrame")
    button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    button.count:SetPoint("BOTTOMRIGHT", -2, 2)
    button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    button.name = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    button.name:SetPoint("TOPLEFT", button, "TOPRIGHT", 10, -2)
    button.name:SetWidth(300)
    button.name:SetJustifyH("LEFT")
    button.name:SetWordWrap(false)

    button.value = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.value:SetPoint("TOPLEFT", button.name, "BOTTOMLEFT", 0, -5)
    button.value:SetWidth(300)
    button.value:SetJustifyH("LEFT")
    button.value:SetWordWrap(false)

    function button:SetVisible(visible)
        self:SetShown(visible)
        self.name:SetShown(visible)
        self.value:SetShown(visible)
    end

    function button:SetItem(item)
        self.item = item
        self.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local quality = item.quality or 1
        self.border:SetShown(quality ~= 1)
        self.border:SetVertexColor(QualityColor(quality))
        self.count:SetText((item.count or 1) > 1 and item.count or "")
        self.name:SetText(ColoredName(item))
        self.value:SetText(ValueText(item))
    end

    button:SetScript("OnEnter", ItemTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Shift-click links the item in chat, Ctrl-click tries it on.
    button:SetScript("OnClick", function(self)
        if self.item and HandleModifiedItemClick then pcall(HandleModifiedItemClick, self.item.link) end
    end)
    return button
end

local function CreateArrow(parent, direction)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(24, 24)
    local base = "Interface\\Buttons\\UI-SpellbookIcon-" .. direction .. "Page-"
    button:SetNormalTexture(base .. "Up")
    button:SetPushedTexture(base .. "Down")
    button:SetDisabledTexture(base .. "Disabled")
    button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    return button
end

-- The counter stays visible ("1 / 1") so a single choice reads as one.
-- With no choice left (after "Always keep"), the window says why.
local function UpdateCandidate()
    local list, index = window.list, window.index
    local candidate = list[index]
    local any = candidate ~= nil
    window.candidateSlot:SetVisible(any)
    window.empty:SetShown(not any)
    if any then window.candidateSlot:SetItem(candidate) end
    window.counter:SetText(any and ("%d / %d"):format(index, #list) or "")
    window.prev:SetShown(any)
    window.next:SetShown(any)
    window.prev:SetEnabled(any and index > 1)
    window.next:SetEnabled(any and index < #list)
    window.confirm:SetEnabled(any)
    window.keep:SetEnabled(any)
end

local function Step(delta)
    local index = window.index + delta
    if index < 1 or index > #window.list then return end
    window.index = index
    PlaySound(SOUNDKIT.IG_ABILITY_PAGE_TURN or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    UpdateCandidate()
end

local function BuildWindow()
    window = UI.CreateWindow(WINDOW_NAME, 400, 256, WINDOW_ICON)
    window:SetFrameStrata("DIALOG")
    window:SetScript("OnShow", function() PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end)
    window:SetScript("OnHide", function()
        window.loot, window.list = nil, nil
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)

    local hint = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOPLEFT", 66, -32)
    hint:SetPoint("TOPRIGHT", -16, -32)
    hint:SetJustifyH("LEFT")
    hint:SetTextColor(unpack(UI.MUTED))
    UI.Localize(hint, "SWAP_HINT")

    local inset = UI.CreateInset(window)
    inset:SetPoint("TOPLEFT", 6, -60)
    inset:SetPoint("BOTTOMRIGHT", -6, 36)

    local lootLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lootLabel:SetPoint("TOPLEFT", 14, -10)
    UI.Localize(lootLabel, "SWAP_LOOT")
    window.lootSlot = CreateItemSlot(inset, -28)

    local destroyLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    destroyLabel:SetPoint("TOPLEFT", 14, -76)
    destroyLabel:SetTextColor(unpack(UI.RED))
    UI.Localize(destroyLabel, "SWAP_DESTROY")
    window.candidateSlot = CreateItemSlot(inset, -94)

    window.empty = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.empty:SetPoint("TOPLEFT", 14, -98)
    window.empty:SetPoint("TOPRIGHT", -14, -98)
    window.empty:SetJustifyH("LEFT")
    window.empty:SetJustifyV("TOP")
    window.empty:SetTextColor(unpack(UI.MUTED))
    UI.Localize(window.empty, "SWAP_EMPTY")
    window.empty:Hide()

    window.next = CreateArrow(inset, "Next")
    window.next:SetPoint("TOPRIGHT", -10, -68)
    window.counter = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    window.counter:SetPoint("RIGHT", window.next, "LEFT", -4, 0)
    window.prev = CreateArrow(inset, "Prev")
    window.prev:SetPoint("RIGHT", window.counter, "LEFT", -4, 0)
    window.prev:SetScript("OnClick", function() Step(-1) end)
    window.next:SetScript("OnClick", function() Step(1) end)
    for _, arrow in ipairs({ window.prev, window.next }) do
        arrow:SetScript("OnEnter", function(self)
            UI.ShowTooltip(self, L.SWAP_DESTROY, L.SWAP_CYCLE_TIP)
        end)
        arrow:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local warning = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    warning:SetPoint("TOPLEFT", 14, -140)
    warning:SetPoint("TOPRIGHT", -14, -140)
    warning:SetJustifyH("LEFT")
    UI.Localize(warning, "SWAP_WARNING")

    window.confirm = UI.CreateButton(window, "SWAP_CONFIRM", 160)
    window.confirm:SetPoint("BOTTOMRIGHT", -8, 7)
    window.confirm:SetScript("OnClick", function()
        local loot, candidate = window.loot, window.list and window.list[window.index]
        if not loot or not candidate then return end
        local ok, reason = Swap.Execute(loot, candidate)
        if ok or reason == "gone" then
            window:Hide()
        elseif reason == "moved" then
            Swap.Propose()
        end
    end)

    window.cancel = UI.CreateButton(window, "BUTTON_CANCEL", 90)
    window.cancel:SetPoint("RIGHT", window.confirm, "LEFT", -6, 0)
    window.cancel:SetScript("OnClick", function() window:Hide() end)

    window.keep = UI.CreateButton(window, "SWAP_KEEP", 120)
    window.keep:SetPoint("BOTTOMLEFT", 8, 7)
    window.keep:SetScript("OnClick", function()
        local candidate = window.list and window.list[window.index]
        if not candidate then return end
        UI.PlayClick()
        Swap.Keep(candidate)
        Swap.Propose()
    end)
    window.keep:SetScript("OnEnter", function(self)
        UI.ShowTooltip(self, self:GetText(), L.SWAP_KEEP_TIP)
    end)
    window.keep:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Next to the loot window, on whichever side has room.
local function Place()
    window:ClearAllPoints()
    local loot = _G.LootFrame
    local right = loot and loot:IsShown() and loot:GetRight()
    if right then
        local screen = UIParent:GetRight() or 0
        if right + 12 + window:GetWidth() <= screen then
            window:SetPoint("TOPLEFT", loot, "TOPRIGHT", 12, 0)
        else
            window:SetPoint("TOPRIGHT", loot, "TOPLEFT", -12, 0)
        end
    else
        window:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    end
end

function Swap.ShowProposal(loot, list)
    if not window then BuildWindow() end
    -- A refresh keeps the item the player was looking at.
    local index = 1
    local current = window:IsShown() and window.list and window.list[window.index]
    if current then
        for i, candidate in ipairs(list) do
            if candidate.bag == current.bag and candidate.slot == current.slot and candidate.link == current.link then
                index = i
                break
            end
        end
    end
    window.loot, window.list, window.index = loot, list, index
    window:SetWindowTitle(L.SWAP_WINDOW_TITLE)
    window.lootSlot:SetItem(loot)
    UpdateCandidate()
    if not window:IsShown() then
        Place()
        window:Show()
    end
    window:Raise()
end

function Swap.HideProposal()
    if window and window:IsShown() then window:Hide() end
end

---------------------------------------------------------------------------
-- When to propose
---------------------------------------------------------------------------

local function Schedule(delay)
    generation = generation + 1
    local mine = generation
    C_Timer.After(delay, function()
        if mine == generation then Swap.Propose() end
    end)
end

local retried = {}  -- loot link -> true: item data requested once

function Swap.Propose()
    generation = generation + 1
    if not ns:IsEnabled(KEY) or not LootIsOpen() then
        Swap.HideProposal()
        return
    end
    -- Room again (the player sold or moved something): nothing to do.
    if TotalFree() > 0 then
        Swap.HideProposal()
        return
    end

    -- The item just clicked, else the one already shown, else the best one.
    local function Valid(slot, link)
        local data = slot and Swap.LootData(slot)
        if data and not data.locked and (not link or data.link == link) then return data end
    end
    local shown = window and window:IsShown() and window.loot
    local loot = Valid(focus) or (shown and Valid(shown.slot, shown.link)) or Swap.PickTarget()
    if not loot then
        Swap.HideProposal()
        return
    end

    -- Not cached yet: ask the client and look again shortly.
    if loot.unknown and not loot.quest and not retried[loot.link] then
        retried[loot.link] = true
        if loot.itemID and C_Item and C_Item.RequestLoadItemDataByID then
            pcall(C_Item.RequestLoadItemDataByID, loot.itemID)
        end
        Schedule(RETRY_DELAY)
        return
    end

    local list = Swap.FindCandidates(loot)
    if #list == 0 and window and window:IsShown() then
        -- Open already (e.g. after "Always keep"): say why instead of vanishing.
        Swap.ShowProposal(loot, list)
        return
    elseif #list == 0 then
        Swap.HideProposal()
        if not notified then
            notified = true
            ns:Print(L.SWAP_NONE:format(loot.link))
        end
        return
    end
    Swap.ShowProposal(loot, list)
end

local function IsBagsFull(errorType, message)
    if type(errorType) == "string" and message == nil then message = errorType end
    if Util.Readable(message) and type(message) == "string"
        and (message == ERR_INV_FULL or message == INVENTORY_FULL) then
        return true
    end
    if GetGameMessageInfo and Util.Readable(errorType) and type(errorType) == "number" then
        local ok, name = pcall(GetGameMessageInfo, errorType)
        if ok and name == "ERR_INV_FULL" then return true end
    end
    return false
end

local function ResetWindowState()
    wipe(wanted)
    wipe(recentLoot)
    wipe(retried)
    wantAll = false
    focus = nil
    notified = false
    pending = nil
    errorAt = nil
    generation = generation + 1
    Swap.HideProposal()
end

local handlers = {}

function handlers.LOOT_OPENED()
    lootOpen = true
    -- With autoloot the error can come before the window opens.
    if errorAt and GetTime() - errorAt < 2 then Schedule(PROPOSE_DELAY) end
end

function handlers.LOOT_CLOSED()
    lootOpen = false
    ResetWindowState()
end

function handlers.LOOT_SLOT_CLEARED(slot)
    wanted[slot] = nil
    recentLoot[slot] = nil
    if focus == slot then focus = nil end
    if pending and pending.slot == slot then pending = nil end
    -- Several items failed: once this one is looted, propose the next.
    if (window and window:IsShown()) or wantAll or next(wanted) then Schedule(PROPOSE_DELAY) end
end

function handlers.UI_ERROR_MESSAGE(errorType, message)
    if not IsBagsFull(errorType, message) then return end
    local now = GetTime()
    errorAt = now

    -- Right after a swap the freed slot may not be known yet: loot once more
    -- a moment later instead of asking again.
    if pending and now - pending.time < 2 and not pending.retry then
        local swap = pending
        swap.retry = true
        C_Timer.After(RETRY_DELAY, function()
            if pending ~= swap or not LootIsOpen() then return end
            local loot = Swap.LootData(swap.slot)
            if loot and loot.link == swap.link then LootSlot(swap.slot) end
        end)
        return
    end

    local latest
    for slot, time in pairs(recentLoot) do
        if now - time <= RECENT then
            wanted[slot] = true
            if not latest or time > recentLoot[latest] then latest = slot end
        end
    end
    if latest then
        focus = latest
    else
        wantAll = true
    end
    if lootOpen then Schedule(PROPOSE_DELAY) end
end

function handlers.BAG_UPDATE_DELAYED()
    if window and window:IsShown() then Schedule(0) end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
    handlers[event](...)
end)
Swap.handlers = handlers

-- Which slot the player clicked (or autoloot tried): the error that follows
-- is about that item. A post-hook, so Blizzard's loot code is untouched.
local hooked = false
local function HookLootSlot()
    if hooked or type(LootSlot) ~= "function" then return end
    hooked = true
    hooksecurefunc("LootSlot", function(slot)
        if ns:IsEnabled(KEY) and type(slot) == "number" then recentLoot[slot] = GetTime() end
    end)
end

local function Enable()
    HookLootSlot()
    for event in pairs(handlers) do events:RegisterEvent(event) end
    lootOpen = NumLoot() > 0
end

local function Disable()
    events:UnregisterAllEvents()
    ResetWindowState()
end

ns:On("OPTION_CHANGED", function(key)
    if key == KEY and window and window:IsShown() then Swap.Propose() end
end)

ns:On("LANGUAGE_CHANGED", function()
    if window and window:IsShown() and window.loot then Swap.ShowProposal(window.loot, window.list) end
end)

ns:RegisterCategory({
    key = "items",
    order = 30,
    title = "CAT_ITEMS",
    desc = "CAT_ITEMS_DESC",
    icon = WINDOW_ICON,
})

ns:RegisterFeature({
    key = KEY,
    category = "items",
    order = 10,
    title = "SWAP_TITLE",
    desc = "SWAP_DESC",
    tip = "SWAP_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "allowGreen", title = "SWAP_OPT_GREEN", tip = "SWAP_OPT_GREEN_TIP", default = true },
        { key = "protectUseful", title = "SWAP_OPT_USEFUL", tip = "SWAP_OPT_USEFUL_TIP", default = true },
        { key = "useAuction", title = "SWAP_OPT_AH", tip = "SWAP_OPT_AH_TIP", default = true },
        { key = "clearKeep", title = "SWAP_OPT_CLEAR", tip = "SWAP_OPT_CLEAR_TIP", action = function() Swap.ClearKeep() end },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
