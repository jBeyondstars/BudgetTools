local _, ns = ...
local L, UI = ns.L, ns.UI
local Util = ns.Util

--[[
Quest chains in the quest log.

A quest that belongs to a chain gets:
  - its step ("5/13") at the right of its line in the quest list. Clicking
    it opens the chain window;
  - the whole chain at the bottom of the tooltip of that line;
  - a "Chain 5/13" button in the quest's details, which opens the
    chain window too.
The chain window (UI\QuestChainUI.lua) lists the chain. Clicking a quest
there shows its objective, who gives it and who takes it, with a button
that shows them on the map.

What a chain is:
  Everything that leads to the quest (its prerequisites, and theirs), and
  everything it unlocks (the quests that need it, and what they unlock).
  Side branches of an earlier step are left out: the chain of a quest is its
  own line, not the whole web around it. Quests of another race or class are
  left out too, unless you did them or have them.
  A step is how far a quest is from the start of the chain. Two quests can
  share a step (two quests unlocked by the same one).

Where the data comes from:
  QuestieDB's public API (the global QuestDB), read while playing. It is an
  optional dependency: without it nothing is shown. The links between quests
  are stored on the following quest (its prerequisites), so finding what a
  quest unlocks needs one pass over every quest. That pass runs a few
  milliseconds per frame after login; the log gets its steps when it ends.
  Givers and their places come from the NPC finder (Features\NpcFinder.lua).

How it shows up without touching Blizzard's code:
  - QuestLogQuests_Update and QuestMapFrame_ShowQuestDetails are post-hooked.
  - The step is our own button on the quest's line. The title's right edge
    is moved to it so they never overlap; a title that wraps because of it
    makes its line taller, as the game does for "(Elite)".
  - The details button stays in the header, above the scrolling quest text,
    both on the map and in the standalone quest log details.
  - The tooltip lines are added from the event Blizzard's code sends once
    the tooltip of a quest line is built.
]]

local KEY = "questChain"
local CONTRACT = 4           -- the QuestieDB API version this was written against
local BUDGET = 5             -- milliseconds per frame spent reading quest links
local MAX_QUESTS = 200       -- quests kept in one chain
local STEP_LINES = 3         -- quests listed for one step in a tooltip, before "+N more"
local TOOLTIP_LINES = 12

local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local ARROW = "|TInterface\\ChatFrame\\ChatFrameExpandArrow:0|t"
local BULLET = "|TInterface\\QuestFrame\\UI-Quest-BulletPoint:0|t"

local Chain = {}
ns.QuestChain = Chain

local active = false

local function Safe(fn, ...)
    return xpcall(fn, geterrorhandler(), ...)
end

---------------------------------------------------------------------------
-- QuestieDB access
---------------------------------------------------------------------------

local function Ready()
    local lib, db = _G.LibQuestieDB, _G.QuestDB
    if type(lib) ~= "table" or type(db) ~= "table" or type(db.GetAllIds) ~= "function" then return false end
    if lib.RequireContract and not lib.RequireContract(CONTRACT) then return false end
    return true
end

-- A QuestieDB quest field, nil when it can't be read.
local function Field(name, id)
    local db = _G.QuestDB
    local get = db and db[name]
    if type(get) ~= "function" then return end
    local ok, value = pcall(get, id)
    if ok then return value end
end

---------------------------------------------------------------------------
-- Links between quests
---------------------------------------------------------------------------

-- after[a][b] = kind: b comes after a. before[b][a] = the same link.
--   "all"    a is one of the quests b needs
--   "any"    a is one of the quests b needs one of
--   "child"  b is only offered while a is in your log
--   "crumb"  a only sends you to b (optional)
--   "next"   a names b as what follows
-- A link said two ways keeps the first kind of this list (a breadcrumb
-- also names its quest as what follows: it stays optional).
local after, before = {}, {}
local STRENGTH = { all = 1, any = 2, child = 3, crumb = 4, next = 5 }

local function Link(from, to, kind)
    if type(from) ~= "number" or type(to) ~= "number" or from == to or from <= 0 or to <= 0 then return end
    local known = after[from] and after[from][to]
    if known and STRENGTH[known] <= STRENGTH[kind] then return end
    after[from] = after[from] or {}
    before[to] = before[to] or {}
    after[from][to] = kind
    before[to][from] = kind
end

local function LinkList(list, id, kind, reversed)
    if type(list) ~= "table" then return end
    for _, other in ipairs(list) do
        if type(other) == "number" then
            other = math.abs(other) -- a negative prerequisite must be in the log, not done
            if reversed then Link(id, other, kind) else Link(other, id, kind) end
        end
    end
end

local indexState     -- nil, "building", "ready", "failed"
local ids, cursor
local OnIndexReady

local function IndexBatch(budget)
    local start = debugprofilestop()
    local count = #ids
    while cursor < count do
        cursor = cursor + 1
        local id = ids[cursor]
        LinkList(Field("preQuestGroup", id), id, "all")
        LinkList(Field("preQuestSingle", id), id, "any")
        LinkList(Field("childQuests", id), id, "child", true)
        Link(Field("parentQuest", id), id, "child")
        Link(id, Field("nextQuestInChain", id), "next")
        Link(id, Field("breadcrumbForQuestId", id), "crumb")
        if budget and debugprofilestop() - start > budget then return false end
    end
    return true
end

local worker = CreateFrame("Frame")
worker:Hide()

local function Pump(budget)
    if indexState ~= "building" then return end
    local ok, done = pcall(IndexBatch, budget)
    if not ok then
        indexState = "failed"
        worker:Hide()
        ns:Print(L.QUESTCHAIN_DB_ERROR:format(tostring(done)))
    elseif done then
        indexState = "ready"
        ids = nil
        worker:Hide()
        if OnIndexReady then OnIndexReady() end
    end
end

worker:SetScript("OnUpdate", function() Pump(BUDGET) end)

local function StartIndex()
    if indexState or not Ready() then return end
    local ok, list = pcall(_G.QuestDB.GetAllIds)
    if not ok or type(list) ~= "table" then
        indexState = "failed"
        return
    end
    ids, cursor = list, 0
    indexState = "building"
    worker:Show()
end

-- Reads every link now (tests, and nothing else, need it in one go).
function Chain.BuildIndexNow()
    StartIndex()
    Pump(nil)
    return indexState == "ready"
end

---------------------------------------------------------------------------
-- The player
---------------------------------------------------------------------------

local raceFlag, classFlag

local function PlayerFlags()
    if raceFlag then return end
    local _, _, raceID = UnitRace("player")
    local _, _, classID = UnitClass("player")
    local lib = _G.LibQuestieDB
    local masks = type(lib) == "table" and type(lib.Enum) == "table" and lib.Enum.raceMaskById
    raceFlag = (type(masks) == "table" and masks[raceID]) or (type(raceID) == "number" and 2 ^ (raceID - 1)) or 0
    classFlag = (type(classID) == "number" and 2 ^ (classID - 1)) or 0
end

-- Race masks go past 32 bits on Forever, so no bit library here.
local function Allows(mask, flag)
    if type(mask) ~= "number" or mask == 0 or flag == 0 then return true end
    return mask % (flag * 2) >= flag
end

-- What is known of each quest while one refresh lasts.
local memo = {}

local function Info(id)
    local info = memo[id]
    if info then return info end
    info = {}
    memo[id] = info
    local index = C_QuestLog.GetLogIndexForQuestID(id)
    info.inLog = type(index) == "number" and index > 0
    info.done = not info.inLog and C_QuestLog.IsQuestFlaggedCompleted(id) == true
    info.had = info.inLog or info.done
    local name = info.inLog and C_QuestLog.GetTitleForQuestID(id) or nil
    if type(name) ~= "string" or name == "" then name = Field("name", id) end
    if type(name) == "string" and name ~= "" then info.name = name end
    return info
end

-- "done", "ready" (in your log, complete), "log" or "todo".
local function State(id)
    local info = Info(id)
    if info.done then return "done" end
    if info.inLog then return C_QuestLog.IsComplete(id) and "ready" or "log" end
    return "todo"
end

-- A quest that has its place in your chain: one you did or have, or one
-- your race and class can get.
local function Usable(id)
    local info = Info(id)
    if info.usable == nil then
        PlayerFlags()
        info.usable = info.name ~= nil and (info.had
            or (Allows(Field("requiredRaces", id), raceFlag) and Allows(Field("requiredClasses", id), classFlag)))
    end
    return info.usable
end

-- A quest you can no longer get: you took the other choice.
local function ShutOut(id)
    local info = Info(id)
    if info.shutOut == nil then
        info.shutOut = false
        if not info.had then
            local others = Field("exclusiveTo", id)
            if type(others) == "table" then
                for _, other in ipairs(others) do
                    if type(other) == "number" and Info(other).had then
                        info.shutOut = true
                        break
                    end
                end
            end
        end
    end
    return info.shutOut
end

---------------------------------------------------------------------------
-- The chain of one quest
---------------------------------------------------------------------------

local NONE = {}

local function Collect(questID)
    local quests, count = { [questID] = true }, 1
    local function Add(queue, id)
        quests[id] = true
        count = count + 1
        queue[#queue + 1] = id
    end

    -- What leads to the quest.
    local queue, head = { questID }, 1
    while queue[head] do
        local id = queue[head]
        head = head + 1
        local links = before[id] or NONE
        local had = Info(id).had
        local pickedOne = false -- "one of these": you did one, the others don't count
        for other, kind in pairs(links) do
            if kind == "any" and Info(other).had then
                pickedOne = true
                break
            end
        end
        for other, kind in pairs(links) do
            if not quests[other] and count < MAX_QUESTS and Usable(other) and not ShutOut(other)
                and not (kind == "any" and pickedOne and not Info(other).had)
                -- a quest that only sent you here, and that you skipped
                and not (kind == "crumb" and had and not Info(other).had) then
                Add(queue, other)
            end
        end
    end

    -- What the quest unlocks.
    queue, head = { questID }, 1
    while queue[head] do
        local id = queue[head]
        head = head + 1
        for other in pairs(after[id] or NONE) do
            if not quests[other] and count < MAX_QUESTS and Usable(other) and not ShutOut(other) then
                Add(queue, other)
            end
        end
    end
    return quests, count
end

-- Step of each quest: 1 for a quest nothing leads to, else one more than
-- the furthest quest that leads to it.
local function Steps(quests)
    local step, walking = {}, {}
    local function StepOf(id)
        if step[id] then return step[id] end
        if walking[id] then return 1 end -- a loop in the data
        walking[id] = true
        local best = 1
        for other in pairs(before[id] or NONE) do
            if quests[other] then
                local value = StepOf(other) + 1
                if value > best then best = value end
            end
        end
        walking[id] = nil
        step[id] = best
        return best
    end
    local last = 1
    for id in pairs(quests) do
        local value = StepOf(id)
        if value > last then last = value end
    end
    return step, last
end

local function ByStep(a, b)
    if a.step ~= b.step then return a.step < b.step end
    if a.level ~= b.level then return a.level < b.level end
    return a.id < b.id
end

local function Level(id)
    local level = Field("questLevel", id)
    return type(level) == "number" and level or 0
end

local function Build(questID)
    if not before[questID] and not after[questID] then return nil end
    local quests, count = Collect(questID)
    if count < 2 then return nil end
    local step, last = Steps(quests)
    local list = {}
    for id in pairs(quests) do
        list[#list + 1] = {
            id = id,
            step = step[id],
            name = Info(id).name or ("#" .. id),
            level = Level(id),
            state = State(id),
            current = id == questID,
        }
    end
    table.sort(list, ByStep)
    return { id = questID, list = list, step = step[questID], steps = last, count = count }
end

local cache = {}

-- Forgets what was worked out: quests done or taken change every chain.
function Chain.Reset()
    for key in pairs(cache) do cache[key] = nil end
    for key in pairs(memo) do memo[key] = nil end
    raceFlag, classFlag = nil, nil
end

-- The chain a quest belongs to, or nil (no chain, or the links aren't read yet):
--   { id, step, steps, count, list = { { id, step, name, level, state, current }, ... } }
--   state: "done", "ready" (in your log, complete), "log", "todo"
function Chain.Get(questID)
    if type(questID) ~= "number" then return nil end
    if indexState ~= "ready" then
        if active then StartIndex() end
        return nil
    end
    local chain = cache[questID]
    if chain == nil then
        chain = Build(questID) or false
        cache[questID] = chain
    end
    return chain or nil
end

---------------------------------------------------------------------------
-- Lines to display
---------------------------------------------------------------------------

local RANK = { ready = 1, log = 2, done = 3, todo = 4 }

local function ByState(a, b)
    if a.current ~= b.current then return a.current end
    if RANK[a.state] ~= RANK[b.state] then return RANK[a.state] < RANK[b.state] end
    return a.order < b.order
end

-- The chain as lines: quests of one step that share a name make one line
-- (the same quest for several professions or givers).
--   { id, step, name, level, state, current }
-- perStep: a step with more quests than that (plus one) is cut to its
-- first ones and a { step, more = N } line; nil lists them all.
function Chain.Lines(chain, perStep)
    local lines = {}
    local list = chain.list
    local first = 1
    while list[first] do
        local last = first
        while list[last + 1] and list[last + 1].step == list[first].step do last = last + 1 end
        local byName, group = {}, {}
        for index = first, last do
            local quest = list[index]
            local line = byName[quest.name]
            if not line then
                line = { id = quest.id, step = quest.step, name = quest.name, level = quest.level,
                    state = quest.state, current = quest.current, order = index }
                byName[quest.name] = line
                group[#group + 1] = line
            elseif quest.current or (not line.current and RANK[quest.state] < RANK[line.state]) then
                -- the line stands for the quest itself, else for the one furthest along
                line.id, line.state, line.level = quest.id, quest.state, quest.level
                line.current = line.current or quest.current
            end
        end
        table.sort(group, ByState)
        local shown = #group
        if perStep and shown > perStep + 1 then shown = perStep end
        for index = 1, shown do lines[#lines + 1] = group[index] end
        if shown < #group then
            lines[#lines + 1] = { step = list[first].step, more = #group - shown }
        end
        first = last + 1
    end
    return lines
end

-- First and last line to show when only `limit` fit: a window that keeps
-- the quest itself in view, with a few lines before it.
local function Window(lines, limit)
    local count = #lines
    if count <= limit then return 1, count end
    local current = 1
    for index, line in ipairs(lines) do
        if line.current then
            current = index
            break
        end
    end
    local first = current - math.floor(limit / 3)
    if first + limit - 1 > count then first = count - limit + 1 end
    if first < 1 then first = 1 end
    return first, first + limit - 1
end

local function LineText(line)
    if line.more then return "      " .. L.QUESTCHAIN_MORE_STEP:format(line.more) end
    local marker = (line.state == "done" and CHECK) or (line.state == "todo" and BULLET) or ARROW
    local text = marker .. " " .. line.step .. ". " .. line.name
    if line.state == "todo" and line.level > 0 then
        text = text .. " (" .. L.QUESTCHAIN_LEVEL:format(line.level) .. ")"
    end
    return text
end

-- "current", "log", "done", "todo" or "more": what decides a line's color.
local function LineTone(line)
    if line.more then return "more" end
    if line.current then return "current" end
    if line.state == "ready" then return "log" end
    return line.state
end

local TOOLTIP_COLORS = {
    header = { 1, 0.82, 0 },
    current = { 1, 1, 1 },
    log = { 1, 0.82, 0 },
    todo = { 0.8, 0.8, 0.8 },
    done = { 0.5, 0.5, 0.5 },
    more = { 0.5, 0.5, 0.5 },
}

-- The chain at the bottom of a tooltip: a header, then a few lines around
-- the quest itself.
function Chain.AddToTooltip(tooltip, chain)
    local function Add(text, tone)
        local color = TOOLTIP_COLORS[tone]
        tooltip:AddLine(text, color[1], color[2], color[3])
    end
    local lines = Chain.Lines(chain, STEP_LINES)
    local first, last = Window(lines, TOOLTIP_LINES)
    tooltip:AddLine(" ")
    Add(L.QUESTCHAIN_HEADER:format(chain.step, chain.steps), "header")
    if first > 1 then Add("      " .. L.QUESTCHAIN_EARLIER:format(first - 1), "more") end
    for index = first, last do
        Add(LineText(lines[index]), LineTone(lines[index]))
    end
    if last < #lines then Add("      " .. L.QUESTCHAIN_LATER:format(#lines - last), "more") end
end

---------------------------------------------------------------------------
-- One quest of a chain: what the chain window shows about it
---------------------------------------------------------------------------

local GIVER_KINDS = { "npc", "object" }

local function Read(get, ...)
    if type(get) ~= "function" then return end
    local ok, value = pcall(get, ...)
    if ok and Util.Readable(value) then return value end
end

local function Number(value)
    if Util.Readable(value) and type(value) == "number" then return value end
end

local function Name(value)
    if Util.Readable(value) and type(value) == "string" and value ~= "" then return value end
end

local function RewardItem(id, name, icon, count, quality)
    local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
    if id and (not name or not icon or not quality) and getInfo then
        local ok, itemName, _, itemQuality, _, _, _, _, _, _, itemIcon = pcall(getInfo, id)
        if ok then
            name, icon, quality = name or Name(itemName), icon or Number(itemIcon), quality or Number(itemQuality)
        end
    end
    if id and not icon and C_Item then icon = Number(Read(C_Item.GetItemIconByID, id)) end
    return {
        itemID = id,
        name = name or (ItemDB and Name(Read(ItemDB.name, id))) or ("#" .. id),
        icon = icon, count = count, quality = quality,
    }
end

local function RewardItems(questID, getCount, getItem)
    local items = {}
    local count = Number(Read(getCount, questID))
    if count and type(getItem) == "function" then
        for index = 1, count do
            local ok, name, icon, quantity, quality, _, id = pcall(getItem, index, questID)
            if ok then
                id, name = Number(id), Name(name)
                if id and id <= 0 then id = nil end
                if id or name then
                    items[#items + 1] = RewardItem(id, name, Number(icon), Number(quantity), Number(quality))
                end
            end
        end
    end
    return items, count == #items
end

-- QuestieDB links items back to their source quests. Build the reverse lookup
-- on first use, in batches. These links give neither quantities nor choices.
local knownRewardItems, loadingRewardItems
local function IndexRewardItems()
    if knownRewardItems or loadingRewardItems or not ItemDB then return end
    local db = ItemDB
    local itemIDs = Read(db.GetAllIds)
    if not Util.ReadableTable(itemIDs) or type(db.questRewards) ~= "function" then return end

    loadingRewardItems = true
    local cursor, byQuest = 1, {}
    local function Batch()
        local start = debugprofilestop()
        while cursor <= #itemIDs do
            local itemID = itemIDs[cursor]
            local questIDs = Read(db.questRewards, itemID)
            if Util.ReadableTable(questIDs) then
                for _, questID in ipairs(questIDs) do
                    local items = byQuest[questID] or {}
                    byQuest[questID] = items
                    items[#items + 1] = itemID
                end
            end
            cursor = cursor + 1
            if debugprofilestop() - start >= BUDGET then
                C_Timer.After(0, Batch)
                return
            end
        end
        knownRewardItems, loadingRewardItems = byQuest, false
        ns:Fire("QUEST_CHAIN_REWARDS_UPDATED")
    end
    C_Timer.After(0, Batch)
end

-- A quest query and the preload of its reward items can finish separately.
local rewardRequests = {}
local function RequestRewards(questID)
    local loadQuest = C_QuestLog.RequestLoadQuestByID
    local preload = C_TaskQuest and C_TaskQuest.RequestPreloadRewardData
    if not loadQuest and not preload then return false end
    local now = GetTime()
    local last = rewardRequests[questID]
    if last and now - last < 30 then return now - last < 2 end
    rewardRequests[questID] = now
    if loadQuest then pcall(loadQuest, questID) end
    if preload then pcall(preload, questID) end
    C_Timer.After(0.3, function() ns:Fire("QUEST_CHAIN_REWARDS_UPDATED", questID) end)
    C_Timer.After(2, function() ns:Fire("QUEST_CHAIN_REWARDS_UPDATED", questID) end)
    return true
end

local function OtherRewards(questID)
    local rewards = {}
    local api = C_QuestInfoSystem or {}
    local currencies = Read(api.GetQuestRewardCurrencies, questID)
    if Util.ReadableTable(currencies) then
        for _, currency in ipairs(currencies) do
            if Util.ReadableTable(currency) and Name(currency.name) then
                rewards[#rewards + 1] = {
                    name = currency.name, icon = Number(currency.texture),
                    count = Number(currency.totalRewardAmount), currencyID = Number(currency.currencyID),
                    quality = Number(currency.quality),
                }
            end
        end
    end
    local spellIDs = Read(api.GetQuestRewardSpells, questID)
    if Util.ReadableTable(spellIDs) then
        for _, id in ipairs(spellIDs) do
            local spell = Read(api.GetQuestRewardSpellInfo, questID, id)
            if Util.ReadableTable(spell) and Name(spell.name) then
                rewards[#rewards + 1] = { name = spell.name, icon = Number(spell.texture), spellID = id }
            end
        end
    end
    local reputations = Field("reputationReward", questID)
    if type(reputations) == "table" then
        for _, reputation in ipairs(reputations) do
            local id, amount = reputation[1], reputation[2]
            if type(id) == "number" and type(amount) == "number" and amount ~= 0 then
                local faction = C_Reputation and Read(C_Reputation.GetFactionDataByID, id)
                local name = Util.ReadableTable(faction) and Name(faction.name) or Name(Read(GetFactionInfoByID, id))
                rewards[#rewards + 1] = {
                    name = L.QUESTCHAIN_REWARD_REPUTATION:format(amount, name or ("#" .. id)),
                }
            end
        end
    end
    return rewards
end

local function Rewards(questID)
    local inLog = Info(questID).inLog
    local loaded = Read(HaveQuestRewardData, questID)
    if loaded == nil and inLog then loaded = Read(HaveQuestData, questID) end
    local items, itemsReady = RewardItems(questID, GetNumQuestLogRewards, GetQuestLogRewardInfo)
    local choices, choicesReady = RewardItems(questID, GetNumQuestLogChoices, GetQuestLogChoiceInfo)
    local known = itemsReady and choicesReady and (loaded == true or #items + #choices > 0)
    local pending = not known and RequestRewards(questID)
    local xp = Number(Read(GetQuestLogRewardXP, questID))
    local referenceXP
    if not xp or (xp == 0 and not (inLog and loaded)) then
        xp = nil
        local support = LibQuestieDB and LibQuestieDB.Support
        local module = support and Read(support.Get, "QuestXP")
        local base = module and module.db and module.db[questID]
        referenceXP = base and type(base[2]) == "number" and base[2] >= 0 and base[2] or nil
    end

    local fallback = {}
    if not known and #items == 0 and #choices == 0 then
        IndexRewardItems()
        for _, id in ipairs(knownRewardItems and knownRewardItems[questID] or NONE) do
            fallback[#fallback + 1] = RewardItem(id)
        end
        pending = pending or loadingRewardItems
    end
    return {
        xp = xp, referenceXP = referenceXP, money = Number(Read(GetQuestLogRewardMoney, questID)),
        items = items, choices = choices, fallback = fallback, other = OtherRewards(questID),
        pending = pending, known = known,
    }
end

-- Who gives (field "startedBy") or takes ("finishedBy") a quest:
--   { name, where, hit }  an NPC or a world object the finder can show
--   { name, item }        an item that starts the quest
-- nil when QuestieDB names nobody. NPCs of the other faction are skipped,
-- and one whose place is known is preferred.
local function Giver(questID, field)
    local lists = Field(field, questID)
    if type(lists) ~= "table" then return nil end
    local Finder = ns.NpcFinder
    local best
    if Finder and Finder.Source then
        for slot, kind in ipairs(GIVER_KINDS) do
            local list = lists[slot]
            if type(list) == "table" then
                for _, id in ipairs(list) do
                    local hit = Finder.Source(kind, id)
                    if hit and not hit.missing and not Finder.SourceHostile(hit)
                        and (not best or (not best.map and hit.map)) then
                        best = hit
                    end
                end
            end
        end
    end
    if best then return { name = best.name, where = Finder.SourceWhere(best), hit = best } end
    local item = type(lists[3]) == "table" and lists[3][1]
    local items = _G.ItemDB
    if type(item) == "number" and type(items) == "table" and type(items.name) == "function" then
        local ok, name = pcall(items.name, item)
        if ok and type(name) == "string" and name ~= "" then return { name = name, item = item } end
    end
end

-- { id, name, level, minLevel, state, objective, start, finish, rewards }
function Chain.QuestInfo(questID)
    if type(questID) ~= "number" then return nil end
    local name = Info(questID).name
    if not name then return nil end
    local objective = Field("objectivesText", questID)
    if type(objective) == "table" then objective = table.concat(objective, " ") end
    if type(objective) ~= "string" or objective == "" then objective = nil end
    local minLevel = Field("requiredLevel", questID)
    return {
        id = questID,
        name = name,
        level = Level(questID),
        minLevel = type(minLevel) == "number" and minLevel or 0,
        state = State(questID),
        objective = objective,
        start = Giver(questID, "startedBy"),
        finish = Giver(questID, "finishedBy"),
        rewards = Rewards(questID),
    }
end

-- Shows a giver from Chain.QuestInfo on the map (arrow: a TomTom arrow too).
function Chain.ShowGiver(giver, arrow)
    local Finder = ns.NpcFinder
    if not giver or not Finder then return end
    if giver.hit then
        Finder.ShowSource(giver.hit, arrow)
    elseif giver.item then
        Finder.ShowItem(giver.item)
    end
end

-- Opens the chain window on a quest's chain.
function Chain.Open(questID)
    if not active or not ns.QuestChainUI then return end
    Chain.Reset()
    if Chain.Get(questID) then ns.QuestChainUI.Show(questID) end
end

---------------------------------------------------------------------------
-- Tooltip of a quest line
---------------------------------------------------------------------------

local function OnTitleEnter(_, _, questID)
    if not active then return end
    local chain = Chain.Get(questID)
    if not chain then return end
    Chain.AddToTooltip(GameTooltip, chain)
    GameTooltip:Show() -- sizes the tooltip again
end

-- Tooltip of our own buttons: the step, and what a click does.
local function StepTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L.QUESTCHAIN_HEADER:format(self.step or 0, self.steps or 0), 1, 0.82, 0)
    GameTooltip:AddLine(L.QUESTCHAIN_CLICK, 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function OpenFromButton(self)
    if UI and UI.PlayClick then UI.PlayClick() end
    Chain.Open(self.questID)
end

local function SetStep(button, chain)
    button.questID, button.step, button.steps = chain.id, chain.step, chain.steps
end

---------------------------------------------------------------------------
-- Step on the quest's line in the list
---------------------------------------------------------------------------

local BADGE_COLOR = { 0.7, 0.7, 0.7 }
local badges = setmetatable({}, { __mode = "k" }) -- [Blizzard's title button] = our button and what it changed

local function RightPoint(region)
    for index = 1, region:GetNumPoints() do
        local point, relativeTo, relativePoint, x, y = region:GetPoint(index)
        if point == "RIGHT" then return relativeTo, relativePoint, x, y end
    end
end

local function NewBadge(row)
    local button = CreateFrame("Button", nil, row)
    button:SetSize(30, 16)
    local text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    text:SetPoint("RIGHT")
    text:SetTextColor(BADGE_COLOR[1], BADGE_COLOR[2], BADGE_COLOR[3])
    button:SetScript("OnClick", OpenFromButton)
    button:SetScript("OnEnter", function(self)
        text:SetTextColor(1, 1, 1)
        StepTooltip(self)
    end)
    button:SetScript("OnLeave", function()
        text:SetTextColor(BADGE_COLOR[1], BADGE_COLOR[2], BADGE_COLOR[3])
        GameTooltip:Hide()
    end)
    local badge = { button = button, text = text }
    badges[row] = badge
    return badge
end

-- Puts the step where the title ended and ends the title before it. True
-- when the title wrapped and the line grew.
local function Attach(row, badge, chain)
    local title = row.Text
    local button = badge.button
    SetStep(button, chain)
    badge.text:SetText(chain.step .. "/" .. chain.steps)
    button:SetWidth((badge.text:GetStringWidth() or 26) + 2)
    button:Show()
    local relativeTo, relativePoint, x, y = RightPoint(title)
    if not relativeTo or relativeTo == button then return false end -- no edge to take, or already ours
    local height = title:GetHeight()
    button:ClearAllPoints()
    button:SetPoint("RIGHT", relativeTo, relativePoint, x, y)
    title:SetPoint("RIGHT", button, "LEFT", -4, 0)
    badge.relativeTo, badge.relativePoint, badge.x, badge.y = relativeTo, relativePoint, x, y
    local grown = title:GetHeight() - height
    if grown > 0.5 then
        row:SetHeight(row:GetHeight() + grown)
        badge.grown = grown
        return true
    end
    badge.grown = nil
    return false
end

-- Gives the title its edge back. True when the line shrinks back.
local function Detach(row, badge)
    badge.button:Hide()
    local title = row.Text
    if RightPoint(title) ~= badge.button or not badge.relativeTo then return false end
    title:SetPoint("RIGHT", badge.relativeTo, badge.relativePoint, badge.x, badge.y)
    local grown = badge.grown
    badge.grown = nil
    if grown then
        row:SetHeight(row:GetHeight() - grown)
        return true
    end
    return false
end

local function UpdateBadges()
    local scroll = QuestScrollFrame
    local pool = scroll and scroll.titleFramePool
    if not pool or not pool.EnumerateActive then return end
    local resized = false
    for row in pool:EnumerateActive() do
        if row.Text then
            local chain = active and Chain.Get(row.questID)
            local badge = badges[row]
            if chain then
                if Attach(row, badge or NewBadge(row), chain) then resized = true end
            elseif badge then
                if Detach(row, badge) then resized = true end
            end
        end
    end
    -- Lines changed height: the list places them again.
    if resized and scroll.Contents and scroll.Contents.Layout then scroll.Contents:Layout() end
end

---------------------------------------------------------------------------
-- Button in the quest's details
---------------------------------------------------------------------------

local openers = {}

local function DetailsFrame()
    return QuestMapFrame and QuestMapFrame.DetailsFrame
end

local function NewOpener(details)
    local bar = details.BackFrame
    local button = CreateFrame("Button", nil, bar or details, "UIPanelButtonTemplate")
    button:SetHeight(22)
    if details == QuestLogPopupDetailFrame then
        -- Between the book icon and the Show Map button.
        button:SetPoint("TOPLEFT", details, "TOPLEFT", 66, -32)
    elseif bar and bar.BackButton then
        button:SetPoint("LEFT", bar.BackButton, "RIGHT", 8, 0)
    else
        button:SetPoint("TOPLEFT", details, "TOPLEFT", 109, -15)
    end
    button:SetScript("OnClick", OpenFromButton)
    button:SetScript("OnEnter", StepTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return button
end

-- Shows the button for the quest whose details are up; the chain window,
-- when it is open, follows to that quest's chain.
local function UpdateOpener(details)
    local opener = openers[details]
    local chain = active and Chain.Get(details.questID)
    if not chain then
        if opener then opener:Hide() end
        return
    end
    if not opener then
        opener = NewOpener(details)
        openers[details] = opener
    end
    SetStep(opener, chain)
    opener:SetText(L.QUESTCHAIN_BUTTON:format(chain.step, chain.steps))
    local label = opener:GetFontString()
    opener:SetWidth((label and label:GetStringWidth() or 60) + 24)
    opener:Show()
    local window = ns.QuestChainUI
    if window and window.IsOpen() then window.Show(chain.id) end
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------

local logHooked, detailsHooked, popupHooked
local hookLoader = CreateFrame("Frame")

local function OnDetailsUpdated(details)
    if not active then return end
    Chain.Reset()
    Safe(UpdateOpener, details)
end

local function InstallHooks()
    local popup = QuestLogPopupDetailFrame
    if not logHooked and type(QuestLogQuests_Update) == "function" then
        logHooked = true
        hooksecurefunc("QuestLogQuests_Update", function()
            Chain.Reset()
            Safe(UpdateBadges)
        end)
        if EventRegistry and EventRegistry.RegisterCallback then
            EventRegistry:RegisterCallback("QuestMapLogTitleButton.OnEnter", function(...)
                Safe(OnTitleEnter, ...)
            end, Chain)
        end
    end
    if not detailsHooked and type(QuestMapFrame_ShowQuestDetails) == "function" and DetailsFrame() then
        detailsHooked = true
        hooksecurefunc("QuestMapFrame_ShowQuestDetails", function()
            OnDetailsUpdated(DetailsFrame())
        end)
    end
    if not popupHooked and popup and type(popup.Update) == "function" then
        popupHooked = true
        hooksecurefunc(popup, "Update", OnDetailsUpdated)
    end
    if logHooked and detailsHooked and popupHooked then
        hookLoader:UnregisterEvent("ADDON_LOADED")
    else
        hookLoader:RegisterEvent("ADDON_LOADED")
    end
end

-- Redraws what is on screen: after the links are read, or a setting changed.
local function Refresh()
    Chain.Reset()
    if QuestScrollFrame and QuestScrollFrame:IsVisible() then Safe(UpdateBadges) end
    if active then
        local details, popup = DetailsFrame(), QuestLogPopupDetailFrame
        if details and details:IsVisible() then Safe(UpdateOpener, details) end
        if popup and popup:IsVisible() then Safe(UpdateOpener, popup) end
    else
        for _, opener in pairs(openers) do opener:Hide() end
    end
    local window = ns.QuestChainUI
    if window then
        if active then window.Refresh() else window.Hide() end
    end
end

hookLoader:SetScript("OnEvent", function()
    InstallHooks()
end)

OnIndexReady = function()
    if active then Refresh() end
end

ns:On("LANGUAGE_CHANGED", function()
    if active then Refresh() end
end)

---------------------------------------------------------------------------
-- Registration
---------------------------------------------------------------------------

ns:RegisterFeature({
    key = KEY,
    category = "leveling",
    order = 20,
    title = "QUESTCHAIN_TITLE",
    desc = "QUESTCHAIN_DESC",
    tip = "QUESTCHAIN_TIP",
    default = true,
    isNew = true,
    OnEnable = function()
        active = true
        InstallHooks()
        -- Not during the loading screen; opening the log first starts it too.
        C_Timer.After(3, function()
            if active then StartIndex() end
        end)
        Refresh()
    end,
    OnDisable = function()
        -- Hooks can't be removed; they stay and do nothing.
        active = false
        hookLoader:UnregisterEvent("ADDON_LOADED")
        Refresh()
    end,
})
