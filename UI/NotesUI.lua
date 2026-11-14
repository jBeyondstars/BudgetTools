local _, ns = ...
local L, UI, Util, Notes = ns.L, ns.UI, ns.Util, ns.Notes

-- Note editor dialog and the notebook (list of every note) shown on the
-- "Player notes" page. Data lives in Features\PlayerNotes.lua.

local NotesUI = {}
ns.NotesUI = NotesUI

local EDITOR_NAME = "BudgetForeverNoteEditor"
local NOTE_ICON = "Interface\\Icons\\INV_Misc_Note_01"

local ROW_HEIGHT = 30   -- row pitch; rows are 4px shorter for a gap
local LIST_TOP = 74     -- notebook header + toolbar height

local ROW_BG = { 0, 0, 0, 0.28 }
local ROW_BG_HOVER = { 0.08, 0.07, 0.03, 0.45 }
local ROW_BORDER = { 1, 1, 1, 0.06 }
local ROW_BORDER_HOVER = { 1, 0.82, 0, 0.45 }

local editor, book

local function ColoredName(entry, name, class)
    name = entry and entry.name or name
    return Util.ClassColored(Util.DisplayName(name) or name, entry and entry.class or class)
end

-- Segmented options for the three ratings, "all" first for the filter.
local function StatusOptions(withAll)
    local options = {}
    if withAll then table.insert(options, { value = "all", label = "FILTER_ALL" }) end
    for _, status in ipairs(Notes.STATUSES) do
        table.insert(options, {
            value = status,
            color = { Notes.Color(status) },
            label = function()
                local text = withAll and L["FILTER_" .. strupper(status)] or Notes.Label(status)
                return Notes.Icon(status, 12) .. " " .. text
            end,
        })
    end
    return options
end

-- Grey hint shown while an edit box is empty.
local function AddPlaceholder(editBox, source, font)
    local hint = editBox:CreateFontString(nil, "ARTWORK", font or "GameFontDisable")
    hint:SetJustifyH("LEFT")
    UI.Localize(hint, source)
    local function Update() hint:SetShown(editBox:GetText() == "") end
    editBox:HookScript("OnTextChanged", Update)
    editBox:HookScript("OnShow", Update)
    return hint
end

---------------------------------------------------------------------------
-- Delete confirmation (shared by the editor and the notebook)
---------------------------------------------------------------------------

StaticPopupDialogs["BUDGETFOREVER_DELETE_NOTE"] = {
    text = "%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, name)
        Notes.Delete(name)
        if editor and editor:IsShown() and editor.name and Util.Key(editor.name) == Util.Key(name) then
            editor:Hide()
        end
    end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function NotesUI:ConfirmDelete(name)
    local entry = name and Notes.Get(name)
    if not entry then return end
    StaticPopup_Show("BUDGETFOREVER_DELETE_NOTE", L.NOTES_DELETE_CONFIRM:format(ColoredName(entry)), nil, entry.name)
end

---------------------------------------------------------------------------
-- Editor
---------------------------------------------------------------------------

local function UpdateCounter()
    local count = editor.noteEdit.GetNumLetters and editor.noteEdit:GetNumLetters() or #editor.noteEdit:GetText()
    editor.counter:SetText(("%d / %d"):format(count, Notes.MAX_LENGTH))
end

local function Save()
    if not editor:IsShown() then return end
    local name, class = editor.name, editor.class
    if editor.isNew then
        name = Util.CleanName(editor.nameBox:GetText())
        if not name then
            ns:Error(L.NOTES_ERROR_NAME)
            editor.nameBox:SetFocus()
            return
        end
        if editor.prefill and strlower(name) == strlower(editor.prefill) then
            class = editor.prefillClass
        end
    end
    if Util.IsSelf(name) then
        ns:Error(L.NOTES_ERROR_SELF)
        return
    end
    Notes.Set(name, { note = editor.noteEdit:GetText(), status = editor.status, class = class })
    editor:Hide()
end

-- Typing the name of someone already in the notebook opens their note.
local function CheckTypedName()
    local name = Util.CleanName(editor.nameBox:GetText())
    local entry = name and Notes.Get(name)
    if entry and editor.noteEdit:GetText() == "" then
        NotesUI:OpenEditor(entry.name)
    else
        editor.noteEdit:SetFocus()
    end
end

local function BuildEditor()
    editor = UI.CreateWindow(EDITOR_NAME, 400, 290, NOTE_ICON)
    editor:SetFrameStrata("DIALOG")
    editor:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
    editor:SetScript("OnShow", function() PlaySound(SOUNDKIT.IG_CHARACTER_INFO_OPEN) end)
    editor:SetScript("OnHide", function()
        editor.nameBox:ClearFocus()
        editor.noteEdit:ClearFocus()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_CLOSE)
    end)

    -- Who the note is about: plain text, or an edit box for a new player.
    editor.nameText = editor:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    editor.nameText:SetPoint("TOPLEFT", 66, -34)
    editor.nameText:SetWidth(316)
    editor.nameText:SetJustifyH("LEFT")
    editor.nameText:SetWordWrap(false)

    editor.nameBox = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
    editor.nameBox:SetSize(240, 20)
    editor.nameBox:SetPoint("TOPLEFT", 74, -32)
    editor.nameBox:SetAutoFocus(false)
    editor.nameBox:SetMaxLetters(60)
    local nameHint = AddPlaceholder(editor.nameBox, "NOTES_EDITOR_NAME", "GameFontDisableSmall")
    nameHint:SetPoint("LEFT", 2, 0)
    editor.nameBox:SetScript("OnEnterPressed", CheckTypedName)
    editor.nameBox:SetScript("OnTabPressed", CheckTypedName)
    editor.nameBox:SetScript("OnEscapePressed", function() editor:Hide() end)

    local inset = UI.CreateInset(editor)
    inset:SetPoint("TOPLEFT", 6, -60)
    inset:SetPoint("BOTTOMRIGHT", -6, 36)

    local opinion = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    opinion:SetPoint("TOPLEFT", 14, -12)
    UI.Localize(opinion, "NOTES_EDITOR_OPINION")

    editor.rating = UI.CreateSegmented(inset, StatusOptions(false),
        function() return editor.status end,
        function(status) editor.status = status end)
    editor.rating:SetPoint("TOPLEFT", 14, -32)

    local noteLabel = inset:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    noteLabel:SetPoint("TOPLEFT", 14, -70)
    UI.Localize(noteLabel, "NOTES_EDITOR_NOTE")

    editor.counter = inset:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    editor.counter:SetPoint("TOPRIGHT", -14, -72)

    local box = CreateFrame("Frame", nil, inset, "BackdropTemplate")
    box:SetPoint("TOPLEFT", 12, -88)
    box:SetPoint("BOTTOMRIGHT", -12, 12)
    UI.ApplyFlat(box, { 0, 0, 0, 0.45 }, { 1, 1, 1, 0.14 })
    box:EnableMouse(true)

    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", 8, -7)
    edit:SetPoint("BOTTOMRIGHT", -8, 7)
    edit:SetMultiLine(true) -- wraps long notes; Enter still saves
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetTextColor(1, 1, 1)
    edit:SetMaxLetters(Notes.MAX_LENGTH)
    editor.noteEdit = edit

    box:SetScript("OnMouseDown", function() edit:SetFocus() end)
    edit:SetScript("OnEscapePressed", function() editor:Hide() end)
    edit:SetScript("OnEnterPressed", Save)
    edit:SetScript("OnTextChanged", function(self, userInput)
        -- A multi-line box inserts the line break itself: treat it as Save.
        if userInput and self:GetText():find("[\r\n]") then
            self:SetText((self:GetText():gsub("[\r\n]", "")))
            Save()
            return
        end
        UpdateCounter()
    end)
    edit:SetScript("OnEditFocusGained", function() box:SetBackdropBorderColor(1, 0.82, 0, 0.6) end)
    edit:SetScript("OnEditFocusLost", function() box:SetBackdropBorderColor(1, 1, 1, 0.14) end)

    -- After SetScript: SetScript drops hooks added before it.
    local noteHint = AddPlaceholder(edit, "NOTES_EDITOR_PLACEHOLDER")
    noteHint:SetPoint("TOPLEFT", 0, 0)
    noteHint:SetPoint("RIGHT", 0, 0)
    noteHint:SetWordWrap(true)

    editor.save = UI.CreateButton(editor, "BUTTON_SAVE", 110)
    editor.save:SetPoint("BOTTOMRIGHT", -8, 7)
    editor.save:SetScript("OnClick", Save)

    editor.cancel = UI.CreateButton(editor, "BUTTON_CANCEL", 110)
    editor.cancel:SetPoint("RIGHT", editor.save, "LEFT", -6, 0)
    editor.cancel:SetScript("OnClick", function() editor:Hide() end)

    editor.delete = UI.CreateButton(editor, "BUTTON_DELETE", 110)
    editor.delete:SetPoint("BOTTOMLEFT", 8, 7)
    editor.delete:SetScript("OnClick", function() NotesUI:ConfirmDelete(editor.name) end)
end

-- name: player to edit, nil to add a new one (prefilled with your target).
function NotesUI:OpenEditor(name, class)
    if not editor then BuildEditor() end

    local entry, canonical
    name = Util.CleanName(name)
    if name then
        local _
        entry, _, canonical = Notes.Get(name)
    end

    editor.isNew = canonical == nil
    editor.name = entry and entry.name or canonical
    editor.class = entry and entry.class or class
    editor.status = entry and entry.status or "neutral"
    editor.prefill, editor.prefillClass = nil, nil

    editor:SetWindowTitle(L.NOTES_EDITOR_TITLE)
    if editor.isNew then
        editor.prefill, editor.prefillClass = Notes.UnitPlayer("target")
        editor.nameText:Hide()
        editor.nameBox:SetText(editor.prefill or "")
        editor.nameBox:Show()
    else
        editor.nameBox:Hide()
        editor.nameText:SetText(ColoredName(entry, editor.name, editor.class))
        editor.nameText:Show()
    end
    editor.noteEdit:SetText(entry and entry.note or "")
    editor.delete:SetShown(entry ~= nil)
    editor.rating:Layout()
    editor.rating:Refresh()
    UpdateCounter()

    editor:Show()
    editor:Raise()
    if editor.isNew then
        editor.nameBox:SetFocus()
        editor.nameBox:HighlightText()
    else
        editor.noteEdit:SetFocus()
    end
end

function NotesUI:CloseEditor()
    if editor then editor:Hide() end
end

---------------------------------------------------------------------------
-- Notebook
---------------------------------------------------------------------------

local function ShowRowTooltip(row)
    local entry = row.entry
    local r, g, b = Notes.Color(entry.status)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT", 8, 0)
    GameTooltip:SetText(ColoredName(entry), 1, 1, 1)
    GameTooltip:AddLine(Notes.Icon(entry.status) .. " " .. Notes.Label(entry.status), r, g, b)
    if entry.note ~= "" then GameTooltip:AddLine(entry.note, 1, 1, 1, true) end
    if type(entry.updated) == "number" then
        GameTooltip:AddLine(L.NOTEBOOK_UPDATED:format(date(L.DATE_FORMAT, entry.updated)), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine(L.NOTEBOOK_ROW_HINT, UI.GREEN[1], UI.GREEN[2], UI.GREEN[3])
    GameTooltip:Show()
end

local function CreateRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT - 4)
    UI.ApplyFlat(row, ROW_BG, ROW_BORDER)

    row.stripe = row:CreateTexture(nil, "ARTWORK")
    row.stripe:SetPoint("TOPLEFT", 1, -1)
    row.stripe:SetPoint("BOTTOMLEFT", 1, 1)
    row.stripe:SetWidth(3)

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", 12, 0)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)

    row.delete = CreateFrame("Button", nil, row)
    row.delete:SetSize(18, 18)
    row.delete:SetPoint("RIGHT", -8, 0)
    row.delete:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    row.delete:SetPushedTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Down")
    row.delete:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Highlight", "ADD")

    row.note = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.note:SetPoint("LEFT", row.name, "RIGHT", 12, 0)
    row.note:SetPoint("RIGHT", row.delete, "LEFT", -10, 0)
    row.note:SetJustifyH("LEFT")
    row.note:SetWordWrap(false)

    function row:SetHovered(hovered)
        self:SetBackdropColor(unpack(hovered and ROW_BG_HOVER or ROW_BG))
        self:SetBackdropBorderColor(unpack(hovered and ROW_BORDER_HOVER or ROW_BORDER))
        self.delete:SetAlpha(hovered and 1 or 0.45)
    end

    function row:SetEntry(entry, nameWidth)
        self.entry = entry
        local r, g, b = Notes.Color(entry.status)
        self.stripe:SetColorTexture(r, g, b, 0.9)
        self.icon:SetTexture(Notes.Texture(entry.status))
        self.name:SetWidth(nameWidth)
        self.name:SetText(ColoredName(entry))
        if entry.note ~= "" then
            self.note:SetText(entry.note)
            self.note:SetTextColor(unpack(UI.MUTED))
        else
            self.note:SetText(Notes.Label(entry.status))
            self.note:SetTextColor(r, g, b, 0.7)
        end
    end

    local function Leave()
        if row:IsMouseOver() then return end
        row:SetHovered(false)
        GameTooltip:Hide()
    end

    row:SetScript("OnClick", function(self)
        UI.PlayClick()
        NotesUI:OpenEditor(self.entry.name)
    end)
    row:SetScript("OnEnter", function(self)
        self:SetHovered(true)
        ShowRowTooltip(self)
    end)
    row:SetScript("OnLeave", Leave)

    row.delete:SetScript("OnClick", function() NotesUI:ConfirmDelete(row.entry.name) end)
    row.delete:SetScript("OnEnter", function(self)
        row:SetHovered(true)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(L.BUTTON_DELETE, 1, 1, 1)
        GameTooltip:Show()
    end)
    row.delete:SetScript("OnLeave", Leave)

    row:SetHovered(false)
    return row
end

function NotesUI:BuildNotebook(page)
    book = CreateFrame("Frame", nil, page.child)
    book.page = page
    book.rows = {}
    book.filter = "all"
    book.search = ""

    book.title = book:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    book.title:SetPoint("TOPLEFT", 4, -14)
    UI.Localize(book.title, "NOTEBOOK_TITLE")

    book.count = book:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    book.count:SetPoint("LEFT", book.title, "RIGHT", 6, 0)

    book.add = UI.CreateButton(book, "NOTEBOOK_ADD", 170)
    book.add:SetPoint("TOPRIGHT", 0, -8)
    book.add:SetScript("OnClick", function() NotesUI:OpenEditor() end)

    local rule = book:CreateTexture(nil, "ARTWORK")
    rule:SetHeight(1)
    rule:SetPoint("TOPLEFT", 0, -38)
    rule:SetPoint("TOPRIGHT", 0, -38)
    rule:SetColorTexture(1, 1, 1, 0.08)

    local searchTemplate = UI.HasTemplate("SearchBoxTemplate") and "SearchBoxTemplate" or "InputBoxTemplate"
    book.searchBox = CreateFrame("EditBox", nil, book, searchTemplate)
    book.searchBox:SetSize(180, 20)
    book.searchBox:SetPoint("TOPLEFT", 8, -46)
    book.searchBox:SetAutoFocus(false)
    if book.searchBox.Instructions then UI.Localize(book.searchBox.Instructions, "NOTEBOOK_SEARCH") end
    book.searchBox:HookScript("OnTextChanged", function(self)
        local text = strlower(strtrim(self:GetText() or ""))
        if text == book.search then return end
        book.search = text
        page.Relayout()
    end)

    book.filterControl = UI.CreateSegmented(book, StatusOptions(true),
        function() return book.filter end,
        function(filter)
            book.filter = filter
            page.Relayout()
        end)
    book.filterControl:SetPoint("TOPRIGHT", 0, -44)

    book.empty = book:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    book.empty:SetJustifyH("CENTER")
    book.empty:SetWordWrap(true)

    function book:Refresh()
        self.count:SetText(("(%d)"):format(Notes.Count()))
    end

    function book:Layout(width)
        self:SetWidth(width)
        self.filterControl:Layout()
        self.searchBox:SetWidth(math.max(110, math.min(220, width - self.filterControl:GetWidth() - 30)))

        local list = Notes.List(self.filter, self.search)
        local nameWidth = math.floor(math.max(110, math.min(180, width * 0.3)))
        for index, entry in ipairs(list) do
            local row = self.rows[index]
            if not row then
                row = CreateRow(self)
                self.rows[index] = row
            end
            row:SetEntry(entry, nameWidth)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self, "TOPLEFT", 0, -(LIST_TOP + (index - 1) * ROW_HEIGHT))
            row:SetWidth(width)
            row:Show()
        end
        for index = #list + 1, #self.rows do
            self.rows[index]:Hide()
        end

        local height
        if #list == 0 then
            self.empty:SetText(Notes.Count() == 0 and L.NOTEBOOK_EMPTY or L.NOTEBOOK_NO_MATCH)
            self.empty:ClearAllPoints()
            self.empty:SetPoint("TOP", self, "TOP", 0, -(LIST_TOP + 16))
            self.empty:SetWidth(width - 40)
            self.empty:Show()
            height = LIST_TOP + 16 + self.empty:GetStringHeight() + 16
        else
            self.empty:Hide()
            height = LIST_TOP + #list * ROW_HEIGHT - 4
        end
        self:SetHeight(math.ceil(height))
    end

    table.insert(page.items, book)
end

ns:On("NOTES_CHANGED", function()
    if book then book.page.Relayout() end
end)

ns:On("LANGUAGE_CHANGED", function()
    if editor and editor:IsShown() then
        editor:SetWindowTitle(L.NOTES_EDITOR_TITLE)
        editor.rating:Layout()
    end
end)
