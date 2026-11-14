local _, ns = ...
local L, UI, Util = ns.L, ns.UI, ns.Util

--[[
Player notes and blacklist.

  Right-click a player (chat, friends, guild, group, target frame) to write
  a note, rate them (liked / neutral / blacklisted) or blacklist them in one
  click. Notes are account-wide and have no size limit, unlike /ignore.

  Notes show in unit tooltips and as an icon in front of chat messages.
  Blacklisted players trigger a warning when they join your group, invite
  you or open a trade; their invites can be declined and their messages
  hidden.

  Storage: BudgetForeverDB.players[key] = {
      name = "Name-Realm", note = "...", status = "liked|neutral|blocked",
      class = "WARRIOR", updated = time() }
  key = lower-case "name-realm" (see Util.Key).
]]

local KEY = "playerNotes"

local Notes = {}
ns.Notes = Notes

Notes.MAX_LENGTH = 200
Notes.STATUSES = { "liked", "neutral", "blocked" }

local STATUS = {
    liked = {
        texture = "Interface\\RaidFrame\\ReadyCheck-Ready",
        color = UI.GREEN,
        label = "STATUS_LIKED",
    },
    neutral = {
        texture = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up",
        color = UI.GOLD,
        label = "STATUS_NEUTRAL",
    },
    blocked = {
        texture = "Interface\\RaidFrame\\ReadyCheck-NotReady",
        color = UI.RED,
        label = "STATUS_BLOCKED",
    },
}

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

local validated = false

-- Drops anything a hand-edited or older SavedVariables file could hold.
local function Players()
    if not ns.db then return {} end
    local players = ns.db.players
    if not validated then
        validated = true
        for key, entry in pairs(players) do
            if type(key) ~= "string" or type(entry) ~= "table" or type(entry.name) ~= "string" then
                players[key] = nil
            else
                if type(entry.note) ~= "string" then entry.note = "" end
                if not STATUS[entry.status] then entry.status = "neutral" end
                if type(entry.class) ~= "string" then entry.class = nil end
            end
        end
    end
    return players
end

local function Changed()
    ns:Fire("NOTES_CHANGED")
end

-- Single line, no escape sequences, at most MAX_LENGTH characters.
function Notes.Clean(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("[\r\n\t]+", " "):gsub("%c", ""):gsub("|", "")
    text = strtrim((text:gsub("%s%s+", " ")))
    return Util.Truncate(text, Notes.MAX_LENGTH, "")
end

function Notes.Texture(status)
    return (STATUS[status] or STATUS.neutral).texture
end

function Notes.Icon(status, size)
    return ("|T%s:%d|t"):format(Notes.Texture(status), size or 0)
end

function Notes.Color(status)
    return unpack((STATUS[status] or STATUS.neutral).color)
end

function Notes.Label(status)
    return L[(STATUS[status] or STATUS.neutral).label]
end

-- entry, key, canonical name
function Notes.Get(name)
    local key, canonical = Util.Key(name)
    if not key then return end
    local entry = Players()[key]
    return entry, key, canonical
end

function Notes.IsBlocked(name)
    local entry = Notes.Get(name)
    return entry ~= nil and entry.status == "blocked"
end

function Notes.Count()
    local count = 0
    for _ in pairs(Players()) do count = count + 1 end
    return count
end

-- fields: note, status, class. An empty neutral note is not worth keeping.
function Notes.Set(name, fields)
    local entry, key, canonical = Notes.Get(name)
    if not key then return end
    local note = fields.note
    if note == nil then note = entry and entry.note or "" end
    note = Notes.Clean(note)
    local status = fields.status or (entry and entry.status) or "neutral"
    if not STATUS[status] then status = "neutral" end

    if note == "" and status == "neutral" then
        if entry then
            Players()[key] = nil
            Changed()
        end
        return
    end

    entry = entry or { name = canonical }
    entry.note = note
    entry.status = status
    entry.class = fields.class or entry.class
    entry.updated = time()
    Players()[key] = entry
    Changed()
    return entry
end

function Notes.Delete(name)
    local entry, key = Notes.Get(name)
    if not entry then return end
    Players()[key] = nil
    Changed()
end

function Notes.SetBlocked(name, blocked, class)
    local entry = Notes.Get(name)
    if blocked then
        Notes.Set(name, { status = "blocked", class = class })
    elseif entry and entry.status == "blocked" then
        Notes.Set(name, { status = "neutral", class = class })
    end
end

-- Called whenever the game shows us a player we have a note about: keeps
-- the class (for colors) and the exact spelling of the name up to date.
function Notes.Remember(name, class)
    local entry, _, canonical = Notes.Get(name)
    if not entry then return end
    local changed = false
    if class and entry.class ~= class then entry.class, changed = class, true end
    if canonical and entry.name ~= canonical then entry.name, changed = canonical, true end
    if changed then Changed() end
end

local function Matches(entry, search)
    return strlower(entry.name):find(search, 1, true) ~= nil
        or strlower(entry.note):find(search, 1, true) ~= nil
end

-- Sorted by name. filter: nil/"all" or a status; search: lower-case text.
function Notes.List(filter, search)
    local list = {}
    for _, entry in pairs(Players()) do
        if (filter == nil or filter == "all" or entry.status == filter)
            and (search == nil or search == "" or Matches(entry, search)) then
            table.insert(list, entry)
        end
    end
    table.sort(list, function(a, b) return strlower(a.name) < strlower(b.name) end)
    return list
end

-- "|cffc79c6eName|r (note)" for chat lines and warnings.
function Notes.Describe(entry)
    local name = Util.ClassColored(Util.DisplayName(entry.name) or entry.name, entry.class)
    if entry.note ~= "" then
        return ("%s (%s)"):format(name, entry.note)
    end
    return name
end

---------------------------------------------------------------------------
-- Class helpers (12.x: every value from the game may be secret)
---------------------------------------------------------------------------

local function ClassFromUnit(unit)
    if not unit then return end
    local ok, _, class = pcall(UnitClass, unit)
    if ok and Util.Readable(class) and type(class) == "string" and class ~= "" then return class end
end

local function ClassFromGUID(guid)
    if not GetPlayerInfoByGUID or not Util.Readable(guid) or type(guid) ~= "string" or guid == "" then return end
    local ok, _, class = pcall(GetPlayerInfoByGUID, guid)
    if ok and Util.Readable(class) and type(class) == "string" and class ~= "" then return class end
end

local function IsPlayerUnit(unit)
    if not Util.Readable(unit) or type(unit) ~= "string" or unit == "" then return false end
    local ok, isPlayer = pcall(UnitIsPlayer, unit)
    return ok and Util.Readable(isPlayer) and isPlayer == true
end

-- fullName, class if `unit` is another player.
function Notes.UnitPlayer(unit)
    if not IsPlayerUnit(unit) then return end
    local name = Util.UnitFullName(unit)
    if not name or Util.IsSelf(name) then return end
    return name, ClassFromUnit(unit)
end

---------------------------------------------------------------------------
-- Right-click menu
---------------------------------------------------------------------------

local MENU_TAGS = {
    "MENU_UNIT_FRIEND",                     -- chat names, character friends
    "MENU_UNIT_FRIEND_OFFLINE",
    "MENU_UNIT_CHAT_ROSTER",
    "MENU_UNIT_GUILD",
    "MENU_UNIT_GUILD_OFFLINE",
    "MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
    "MENU_UNIT_COMMUNITIES_WOW_MEMBER",
    "MENU_UNIT_PARTY",                      -- unit frames
    "MENU_UNIT_RAID_PLAYER",
    "MENU_UNIT_RAID",
    "MENU_UNIT_PLAYER",
    "MENU_UNIT_ENEMY_PLAYER",
    "MENU_UNIT_TARGET",
    "MENU_UNIT_FOCUS",
}

-- fullName, class of the player a menu is about, nil if it is not a player.
local function MenuPlayer(context)
    if not Util.ReadableTable(context) then return end
    if Util.Readable(context.isMobile) and context.isMobile then return end

    local unit = context.unit
    if Util.Readable(unit) and type(unit) == "string" and unit ~= "" then
        if not IsPlayerUnit(unit) then return end -- NPC on the target frame
    else
        unit = nil
    end

    local fullName = Util.FullName(context) or Util.UnitFullName(unit)
    if not fullName or Util.IsSelf(fullName) then return end
    return fullName, ClassFromUnit(unit) or ClassFromGUID(context.guid)
end

local function AddNoteEntries(_, root, context)
    if not ns:IsEnabled(KEY) then return end
    local fullName, class = MenuPlayer(context)
    if not fullName then return end
    local entry = Notes.Get(fullName)
    if entry then Notes.Remember(fullName, class) end

    Util.MenuSection(root)

    local label
    if entry and entry.note ~= "" then
        label = Notes.Icon(entry.status) .. " " .. L.NOTES_MENU_NOTE:format(Util.Truncate(entry.note, 26))
    elseif entry then
        label = L.NOTES_MENU_EDIT
    else
        label = L.NOTES_MENU_ADD
    end

    local button = root:CreateButton(label, function()
        ns.NotesUI:OpenEditor(fullName, class)
    end)
    if button.SetTooltip then
        button:SetTooltip(function(tooltip)
            local title = Util.DisplayName(fullName) or fullName
            if GameTooltip_SetTitle then GameTooltip_SetTitle(tooltip, title) else tooltip:SetText(title) end
            if entry then
                local r, g, b = Notes.Color(entry.status)
                tooltip:AddLine(Notes.Icon(entry.status) .. " " .. Notes.Label(entry.status), r, g, b)
                if entry.note ~= "" then tooltip:AddLine(entry.note, 1, 1, 1, true) end
            else
                tooltip:AddLine(L.NOTES_MENU_ADD_TIP, 1, 1, 1, true)
            end
        end)
    end

    root:CreateCheckbox(Notes.Icon("blocked") .. " " .. L.NOTES_MENU_BLACKLIST,
        function() return Notes.IsBlocked(fullName) end,
        function() Notes.SetBlocked(fullName, not Notes.IsBlocked(fullName), class) end)
end

---------------------------------------------------------------------------
-- Tooltip
---------------------------------------------------------------------------

local function TooltipUnit(tooltip)
    local ok, _, unit = pcall(tooltip.GetUnit, tooltip)
    if ok and Util.Readable(unit) and type(unit) == "string" and unit ~= "" then return unit end
    if WorldFrame.IsMouseMotionFocus and WorldFrame:IsMouseMotionFocus() then return "mouseover" end
end

local function OnTooltipUnit(tooltip)
    if tooltip ~= GameTooltip or not ns:IsEnabled(KEY) or not ns:GetOption(KEY, "tooltip") then return end
    if tooltip.IsForbidden and tooltip:IsForbidden() then return end
    local unit = TooltipUnit(tooltip)
    if not IsPlayerUnit(unit) then return end
    local name = Util.UnitFullName(unit)
    local entry = name and Notes.Get(name)
    if not entry then return end
    Notes.Remember(name, ClassFromUnit(unit))

    local r, g, b = Notes.Color(entry.status)
    local text = entry.note ~= "" and entry.note or Notes.Label(entry.status)
    if entry.status == "blocked" and entry.note ~= "" then
        text = Notes.Label("blocked") .. " - " .. entry.note
    end
    tooltip:AddLine(Notes.Icon(entry.status) .. " " .. text, r, g, b, true)
    tooltip:Show()
end

---------------------------------------------------------------------------
-- Chat
---------------------------------------------------------------------------

-- Chat types the rating icon can be turned off for. Numbered channels
-- (General, Trade, custom ones...) are switched one by one, by name.
local CHAT_TYPES = {
    { key = "SAY", label = "NOTES_CH_SAY", events = { "CHAT_MSG_SAY" } },
    { key = "YELL", label = "NOTES_CH_YELL", events = { "CHAT_MSG_YELL" } },
    { key = "EMOTE", label = "NOTES_CH_EMOTE", events = { "CHAT_MSG_EMOTE" } },
    { key = "WHISPER", label = "NOTES_CH_WHISPER", events = { "CHAT_MSG_WHISPER" } },
    { key = "PARTY", label = "NOTES_CH_PARTY", events = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" } },
    { key = "RAID", label = "NOTES_CH_RAID",
      events = { "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING" } },
    { key = "INSTANCE", label = "NOTES_CH_INSTANCE",
      events = { "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" } },
    { key = "GUILD", label = "NOTES_CH_GUILD", events = { "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER" } },
}

local CHAT_EVENTS = { "CHAT_MSG_CHANNEL" }
local TYPE_OF_EVENT = {}
for _, chatType in ipairs(CHAT_TYPES) do
    for _, event in ipairs(chatType.events) do
        TYPE_OF_EVENT[event] = chatType.key
        table.insert(CHAT_EVENTS, event)
    end
end

-- Where the icon is turned off: options[KEY].skip = {
--     PARTY = true, ...              chat types (CHAT_TYPES keys)
--     ["#trade"] = "Trade", ...      channels: "#" .. lower-case name -> name
-- }
-- It sits with the other options, so /bf reset clears it.
local skipValidated = false

local function Skipped()
    local options = ns.db and ns.db.options[KEY]
    if not options then return {} end
    if type(options.skip) ~= "table" then options.skip = {} end
    local skip = options.skip
    if not skipValidated then
        skipValidated = true
        for id, value in pairs(skip) do
            local channel = type(id) == "string" and id:sub(1, 1) == "#"
            if type(id) ~= "string" or (channel and type(value) ~= "string") or (not channel and value ~= true) then
                skip[id] = nil
            end
        end
    end
    return skip
end

local function SetSkipped(id, value)
    local skip = Skipped()
    if skip[id] == value then return end
    skip[id] = value
    ns:Fire("OPTION_CHANGED", KEY, "skip", true)
end

-- "2. Trade - City", "Trade - City" -> "Trade": one switch per channel,
-- whatever the zone. Custom channel names have no spaces.
local function ChannelName(name)
    if not Util.Readable(name) or type(name) ~= "string" then return end
    name = name:gsub("^%d+%.%s*", "")
    name = strtrim(name:match("^(.-)%s+%-%s+") or name)
    if name ~= "" then return name end
end

local function ChannelId(name)
    return "#" .. strlower(name)
end

-- channelName (arg4) and baseName (arg9) only matter for CHAT_MSG_CHANNEL.
local function IconAllowed(event, channelName, baseName)
    local skip = Skipped()
    if next(skip) == nil then return true end
    if event == "CHAT_MSG_CHANNEL" then
        local name = ChannelName(baseName) or ChannelName(channelName)
        return not (name and skip[ChannelId(name)])
    end
    local chatType = TYPE_OF_EVENT[event]
    return not (chatType and skip[chatType])
end

function Notes.SkippedCount()
    local count = 0
    for _ in pairs(Skipped()) do count = count + 1 end
    return count
end

-- Numbered channels joined right now, in channel order.
local function JoinedChannels()
    local list, seen = {}, {}
    if not GetChannelList then return list end
    local values = { GetChannelList() } -- id, name, disabled, id, name, ...
    for i = 2, #values, 3 do
        local name = ChannelName(values[i])
        if name and not seen[ChannelId(name)] then
            seen[ChannelId(name)] = true
            table.insert(list, name)
        end
    end
    return list
end

-- Checkbox menu: ticked = the icon shows in that channel. Clicking a
-- checkbox keeps the menu open (Blizzard's default for checkboxes).
function Notes.OpenChannelMenu(owner)
    if not MenuUtil or not MenuUtil.CreateContextMenu then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.NOTES_CH_TITLE)
        for _, chatType in ipairs(CHAT_TYPES) do
            local id = chatType.key
            root:CreateCheckbox(L[chatType.label],
                function() return not Skipped()[id] end,
                function() SetSkipped(id, (not Skipped()[id]) and true or nil) end)
        end

        root:CreateDivider()
        root:CreateTitle(L.NOTES_CH_CHANNELS)
        local names, listed = JoinedChannels(), {}
        for _, name in ipairs(names) do listed[ChannelId(name)] = true end
        -- Channels turned off earlier but not joined now stay listed, so
        -- they can be turned back on.
        local others = {}
        for id, name in pairs(Skipped()) do
            if id:sub(1, 1) == "#" and not listed[id] then table.insert(others, name) end
        end
        table.sort(others, function(a, b) return strlower(a) < strlower(b) end)

        if #names + #others == 0 then
            root:CreateTitle("|cff999999" .. L.NOTES_CH_NONE .. "|r")
        end
        local function AddChannel(name, label)
            local id = ChannelId(name)
            root:CreateCheckbox(label,
                function() return not Skipped()[id] end,
                function() SetSkipped(id, (not Skipped()[id]) and name or nil) end)
        end
        for _, name in ipairs(names) do AddChannel(name, name) end
        for _, name in ipairs(others) do
            AddChannel(name, name .. " |cff999999(" .. L.NOTES_CH_NOT_JOINED .. ")|r")
        end

        root:CreateDivider()
        root:CreateButton(L.NOTES_CH_ALL, function()
            if next(Skipped()) == nil then return end
            wipe(Skipped())
            ns:Fire("OPTION_CHANGED", KEY, "skip", true)
        end)
    end)
end

local function ChatFilter(_, event, message, author, ...)
    if not ns:IsEnabled(KEY) or not ns.db or next(ns.db.players) == nil then return false end
    if not Util.Readable(author) or type(author) ~= "string" then return false end
    local entry = Notes.Get(author)
    if not entry then return false end

    if entry.status == "blocked" and ns:GetOption(KEY, "hideChat") then return true end

    if not entry.class then
        local guid = select(10, ...) -- arg12
        Notes.Remember(author, ClassFromGUID(guid))
    end

    if ns:GetOption(KEY, "chatIcons") and Util.Readable(message) and type(message) == "string"
        and IconAllowed(event, (select(2, ...)), (select(7, ...))) then -- arg4, arg9
        return false, Notes.Icon(entry.status) .. " " .. message, author, ...
    end
    return false
end

---------------------------------------------------------------------------
-- Alerts: group, invites, trades
---------------------------------------------------------------------------

local function Warn(text)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo then
        RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
    end
    if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING) end
    ns:Print(text)
end

local seen = {}       -- keys already announced for the current group
local scanQueued = false

local function ScanGroup()
    scanQueued = false
    if not ns:IsEnabled(KEY) or not IsInGroup() then
        wipe(seen)
        return
    end
    local prefix, count = "party", GetNumSubgroupMembers()
    if IsInRaid() then prefix, count = "raid", GetNumGroupMembers() end

    local present = {}
    for index = 1, count do
        local unit = prefix .. index
        local name = Util.UnitFullName(unit)
        if name and name ~= UNKNOWNOBJECT and not Util.IsSelf(name) then
            local entry, key = Notes.Get(name)
            if entry then
                present[key] = true
                Notes.Remember(name, ClassFromUnit(unit))
                if not seen[key] and ns:GetOption(KEY, "alerts") then
                    if entry.status == "blocked" then
                        Warn(L.NOTES_ALERT_GROUP:format(Notes.Describe(entry)))
                    elseif entry.note ~= "" then
                        ns:Print(L.NOTES_IN_GROUP:format(Notes.Icon(entry.status), Notes.Describe(entry)))
                    end
                end
            end
        end
    end
    -- Someone who leaves and comes back is announced again.
    wipe(seen)
    for key in pairs(present) do seen[key] = true end
end

local function QueueScan()
    if scanQueued then return end
    scanQueued = true
    C_Timer.After(1, ScanGroup)
end

local function HideInvitePopups()
    StaticPopup_Hide("PARTY_INVITE")
    StaticPopup_Hide("PARTY_INVITE_XREALM")
end

local function OnInvite(inviter)
    local entry = Notes.Get(inviter)
    if not entry or entry.status ~= "blocked" then return end
    if ns:GetOption(KEY, "declineInvites") then
        DeclineGroup()
        HideInvitePopups()
        C_Timer.After(0, HideInvitePopups) -- in case Blizzard shows it after us
        ns:Print(L.NOTES_DECLINED:format(Notes.Describe(entry)))
    elseif ns:GetOption(KEY, "alerts") then
        Warn(L.NOTES_ALERT_INVITE:format(Notes.Describe(entry)))
    end
end

local function OnTrade()
    local name = Util.UnitFullName("NPC") -- the trade partner
    local entry = name and Notes.Get(name)
    if entry and entry.status == "blocked" and ns:GetOption(KEY, "alerts") then
        Warn(L.NOTES_ALERT_TRADE:format(Notes.Describe(entry)))
    end
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, arg1)
    if not ns:IsEnabled(KEY) then return end
    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        QueueScan()
    elseif event == "PARTY_INVITE_REQUEST" then
        OnInvite(arg1)
    elseif event == "TRADE_SHOW" then
        OnTrade()
    end
end)

---------------------------------------------------------------------------
-- Feature
---------------------------------------------------------------------------

local hooked = false

local function Enable()
    events:RegisterEvent("GROUP_ROSTER_UPDATE")
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PARTY_INVITE_REQUEST")
    events:RegisterEvent("TRADE_SHOW")
    QueueScan()

    -- Hooks cannot be removed: they stay and check the setting each time.
    if hooked then return end
    hooked = true

    if Menu and Menu.ModifyMenu then
        for _, tag in ipairs(MENU_TAGS) do
            Menu.ModifyMenu(tag, AddNoteEntries)
        end
    end

    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnTooltipUnit)
    elseif GameTooltip:HasScript("OnTooltipSetUnit") then
        GameTooltip:HookScript("OnTooltipSetUnit", OnTooltipUnit)
    end

    local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    if addFilter then
        for _, event in ipairs(CHAT_EVENTS) do
            addFilter(event, ChatFilter)
        end
    end
end

local function Disable()
    events:UnregisterAllEvents()
    wipe(seen)
    if ns.NotesUI then ns.NotesUI:CloseEditor() end
end

ns:RegisterCategory({
    key = "notes",
    order = 20,
    title = "CAT_NOTES",
    desc = "CAT_NOTES_DESC",
    icon = "Interface\\Icons\\INV_Misc_Note_01",
    -- The notebook (list of every note) lives under the feature card.
    BuildExtra = function(page)
        if ns.NotesUI then ns.NotesUI:BuildNotebook(page) end
    end,
})

ns:RegisterFeature({
    key = KEY,
    category = "notes",
    order = 10,
    title = "NOTES_TITLE",
    desc = "NOTES_DESC",
    tip = "NOTES_TIP",
    default = true,
    isNew = true,
    options = {
        { key = "tooltip", title = "NOTES_OPT_TOOLTIP", tip = "NOTES_OPT_TOOLTIP_TIP", default = true },
        { key = "chatIcons", title = "NOTES_OPT_CHAT", tip = "NOTES_OPT_CHAT_TIP", default = true },
        { key = "chatChannels", requires = "chatIcons", tip = "NOTES_OPT_CHANNELS_TIP",
          title = function()
              local count = Notes.SkippedCount()
              if count > 0 then return L.NOTES_OPT_CHANNELS_SOME:format(count) end
              return L.NOTES_OPT_CHANNELS
          end,
          action = function(button) Notes.OpenChannelMenu(button) end },
        { key = "alerts", title = "NOTES_OPT_ALERTS", tip = "NOTES_OPT_ALERTS_TIP", default = true },
        { key = "declineInvites", title = "NOTES_OPT_DECLINE", tip = "NOTES_OPT_DECLINE_TIP", default = false },
        { key = "hideChat", title = "NOTES_OPT_HIDE", tip = "NOTES_OPT_HIDE_TIP", default = false },
    },
    OnEnable = Enable,
    OnDisable = Disable,
})
