-- RefiningCalculator -- window
--
-- Renders the result of RefiningCalculator.Evaluate() as an aligned table.
-- Columns are real anchored labels rather than padded text, so they line up
-- exactly; ESO chat could only ever approximate this with a proportional font.
--
-- Extension points, for the options planned later:
--   COLUMNS       -- add or reorder columns in one place
--   UI.header     -- area above the table, for a material dropdown
--   UI.footer     -- area below the summary, for scenario toggles
--   UI:SetTarget  -- swap material/quantity and redraw without rebuilding

local RC = RefiningCalculator
local UI = {}
RC.UI = UI

local WM = WINDOW_MANAGER

local WIN_NAME = "RefiningCalculatorWindow"
local WIDTH, PAD, ROW_H = 460, 12, 20
local HEADER_H = 30

-- width is the column box; align is where the text sits inside it.
local COLUMNS = {
    { key = "name",  width = 170, align = TEXT_ALIGN_LEFT  },
    { key = "src",   width =  46, align = TEXT_ALIGN_LEFT  },
    { key = "price", width =  70, align = TEXT_ALIGN_RIGHT },
    { key = "qty",   width =  66, align = TEXT_ALIGN_RIGHT },
    { key = "value", width =  84, align = TEXT_ALIGN_RIGHT },
}

local COLOR_DIM    = { 0.60, 0.60, 0.60, 1 }
local COLOR_TEXT   = { 0.90, 0.90, 0.90, 1 }
local COLOR_GOOD   = { 0.40, 1.00, 0.40, 1 }
local COLOR_BAD    = { 1.00, 0.35, 0.35, 1 }
local COLOR_WARN   = { 1.00, 0.68, 0.20, 1 }

--------------------------------------------------------------------------------
-- Control construction
--------------------------------------------------------------------------------

local function MakeLabel(parent, font, align, color)
    local label = WM:CreateControl(nil, parent, CT_LABEL)
    label:SetFont(font or "ZoFontGame")
    label:SetHorizontalAlignment(align or TEXT_ALIGN_LEFT)
    label:SetColor(unpack(color or COLOR_TEXT))
    return label
end

-- Hovering an item name shows the real ESO item tooltip, which is what TTC and
-- ATT decorate with their price lines.
--
-- PopupTooltip, not ItemTooltip, and that matters: TTC hooks SetLink only on
-- PopupTooltip (it hooks ItemTooltip's SetBagItem/SetLootItem/etc. instead),
-- while ATT hooks SetLink on both. So ItemTooltip:SetLink would show ATT's
-- prices and silently omit TTC's.
local function OnNameEnter(cell)
    if not cell.itemLink then return end
    InitializeTooltip(PopupTooltip, UI.window, RIGHT, -8, 0, LEFT)
    PopupTooltip:SetLink(cell.itemLink)
end

local function OnNameExit()
    ClearTooltip(PopupTooltip)
end

-- One table row: a cell per column, anchored left to right.
local function MakeRow(parent, index, font)
    local row = WM:CreateControl(nil, parent, CT_CONTROL)
    row:SetDimensions(WIDTH - PAD * 2, ROW_H)
    row:SetAnchor(TOPLEFT, parent, TOPLEFT, 0, (index - 1) * ROW_H)

    local cells, x = {}, 0
    for _, col in ipairs(COLUMNS) do
        local cell = MakeLabel(row, font, col.align)
        cell:SetDimensions(col.width, ROW_H)
        cell:SetAnchor(TOPLEFT, row, TOPLEFT, x, 0)
        if col.key == "name" then
            -- Handlers are attached once; itemLink is swapped per render, and
            -- is nil on summary rows so those simply do not raise a tooltip.
            cell:SetMouseEnabled(true)
            cell:SetHandler("OnMouseEnter", OnNameEnter)
            cell:SetHandler("OnMouseExit", OnNameExit)
        end
        cells[col.key] = cell
        x = x + col.width
    end
    return { control = row, cells = cells }
end

-- A ZO_ComboBox lives in a container control; the object driving it comes from
-- ZO_ComboBox_ObjectFromContainer. Entry callbacks receive (combo, text, entry),
-- so anything the handler needs is stashed on the entry table itself.
function UI:MakeDropdown(parent, x, width, onSelect)
    local container = WM:CreateControlFromVirtual(
        WIN_NAME .. "Dropdown" .. tostring(x), parent, "ZO_ComboBox")
    if not container then return nil end

    container:SetDimensions(width, 24)
    container:SetAnchor(TOPLEFT, parent, TOPLEFT, x, 0)

    local combo = ZO_ComboBox_ObjectFromContainer(container)
    combo:SetSortsItems(false)
    combo:SetSelectedItemFont("ZoFontGameSmall")
    combo:SetDropdownFont("ZoFontGameSmall")

    return { container = container, combo = combo, onSelect = onSelect }
end

-- Rebuilt on every render so availability reflects what is loaded right now.
-- SetSelectedItem can re-fire the selection callback, so the guard stops that
-- from looping back into Refresh while we are mid-populate.
function UI:PopulateDropdowns()
    if self.updatingDropdowns then return end
    self.updatingDropdowns = true

    if self.materialDropdown then
        local dd = self.materialDropdown
        dd.combo:ClearItems()
        local selected
        for _, craft in ipairs(RC.CRAFTS) do
            -- ZO_ComboBox has no real group headings, so a heading is an entry
            -- whose callback just restores the actual selection.
            local heading = dd.combo:CreateItemEntry("-- " .. craft.label .. " --", function()
                if UI.updatingDropdowns then return end
                UI:PopulateDropdowns()
            end)
            dd.combo:AddItem(heading)

            for _, mat in ipairs(craft.materials) do
                local label = "    " .. RC.MaterialLabel(mat)
                local entry = dd.combo:CreateItemEntry(label, dd.onSelect)
                entry.mat = mat
                dd.combo:AddItem(entry)
                if mat == self.mat then selected = label end
            end
        end
        if selected then dd.combo:SetSelectedItem(selected) end
    end

    if self.sourceDropdown then
        local dd = self.sourceDropdown
        dd.combo:ClearItems()
        local selected
        for _, src in ipairs(RC.PRICE_SOURCES) do
            -- Sources whose addon is not loaded stay selectable but say so,
            -- rather than silently returning nothing.
            local label = RC.SourceAvailable(src) and src.label
                or (src.label .. " (not loaded)")
            local entry = dd.combo:CreateItemEntry(label, dd.onSelect)
            entry.key = src.key
            dd.combo:AddItem(entry)
            if src.key == RC.priceSource then selected = label end
        end
        if selected then dd.combo:SetSelectedItem(selected) end
    end

    self.updatingDropdowns = false
end

function UI:Create()
    if self.window then return self.window end

    local win = WM:CreateTopLevelWindow(WIN_NAME)
    win:SetDimensions(WIDTH, 340)
    win:SetAnchor(CENTER, GuiRoot, CENTER, 0, 0)
    win:SetMouseEnabled(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:SetHidden(true)
    self.window = win

    -- Guarded: a missing virtual returns nil, and erroring here would take the
    -- whole file down with it, leaving RC.UI undefined.
    local bg = WM:CreateControlFromVirtual(WIN_NAME .. "BG", win, "ZO_DefaultBackdrop")
    if bg then bg:SetAnchorFill(win) end

    local close = WM:CreateControlFromVirtual(WIN_NAME .. "Close", win, "ZO_CloseButton")
    if close then
        close:SetAnchor(TOPRIGHT, win, TOPRIGHT, -6, 6)
        close:SetHandler("OnClicked", function() UI:Hide() end)
    end

    self.title = MakeLabel(win, "ZoFontWinH4", TEXT_ALIGN_LEFT)
    self.title:SetAnchor(TOPLEFT, win, TOPLEFT, PAD, PAD)
    self.title:SetText("Refining Profit")

    self.subtitle = MakeLabel(win, "ZoFontGame", TEXT_ALIGN_LEFT, COLOR_DIM)
    self.subtitle:SetAnchor(TOPLEFT, self.title, BOTTOMLEFT, 0, 2)

    self.header = WM:CreateControl(nil, win, CT_CONTROL)
    self.header:SetDimensions(WIDTH - PAD * 2, HEADER_H)
    self.header:SetAnchor(TOPLEFT, self.subtitle, BOTTOMLEFT, 0, 6)

    self.materialDropdown = self:MakeDropdown(self.header, 0, 200, function(_, _, entry)
        if UI.updatingDropdowns then return end
        UI:SetTarget(entry.mat)
    end)
    self.sourceDropdown = self:MakeDropdown(self.header, 212, 224, function(_, _, entry)
        if UI.updatingDropdowns then return end
        RC.priceSource = entry.key
        UI:Refresh()
    end)

    self.tableArea = WM:CreateControl(nil, win, CT_CONTROL)
    self.tableArea:SetDimensions(WIDTH - PAD * 2, ROW_H)
    self.tableArea:SetAnchor(TOPLEFT, self.header, BOTTOMLEFT, 0, 0)

    self.headerRow = MakeRow(self.tableArea, 1, "ZoFontGameSmall")
    for _, col in ipairs(COLUMNS) do
        self.headerRow.cells[col.key]:SetColor(unpack(COLOR_DIM))
    end

    self.rows = {}
    self.verdict = MakeLabel(win, "ZoFontGameBold", TEXT_ALIGN_LEFT)
    self.perBatch = MakeLabel(win, "ZoFontGame", TEXT_ALIGN_LEFT)
    self.note = MakeLabel(win, "ZoFontGameSmall", TEXT_ALIGN_LEFT, COLOR_DIM)

    -- Reserved for high/low/Meticulous scenario toggles later.
    self.footer = WM:CreateControl(nil, win, CT_CONTROL)
    self.footer:SetDimensions(WIDTH - PAD * 2, 0)

    return win
end

-- Rows are pooled: created once, reused, hidden when not needed.
function UI:GetRow(index)
    if not self.rows[index] then
        self.rows[index] = MakeRow(self.tableArea, index + 1, "ZoFontGame")
    end
    local row = self.rows[index]
    row.control:SetHidden(false)
    return row
end

-- itemLink is optional: pass it for real item rows, omit it on summary rows so
-- they do not raise a tooltip.
function UI:SetRow(index, values, color, itemLink)
    local row = self:GetRow(index)
    for _, col in ipairs(COLUMNS) do
        local cell = row.cells[col.key]
        cell:SetText(values[col.key] or "")
        cell:SetColor(unpack(color or COLOR_TEXT))
    end
    row.cells.name.itemLink = itemLink

    -- Item names take their in-game quality colour, so Dreugh Wax reads gold and
    -- Honing Stone green. Only when the row has no explicit colour override, so
    -- a "no data" warning still shows as a warning.
    if itemLink and not color then
        local quality = RC.QualityColor(itemLink)
        if quality then row.cells.name:SetColor(unpack(quality)) end
    end
    return row
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function UI:Render(r)
    self:Create()
    self:PopulateDropdowns()

    self.title:SetText(string.format("%s -- %s raw", RC.MaterialLabel(r.mat), RC.FormatGold(r.quantity)))
    local mdText, mdState = RC.DescribeMD(r.md)
    self.subtitle:SetText(mdText)
    self.subtitle:SetColor(unpack(mdState == "active" and COLOR_GOOD or COLOR_WARN))

    local h = self.headerRow.cells
    h.name:SetText("Item")
    h.src:SetText("Src")
    h.price:SetText("Price")
    h.qty:SetText("Qty")
    h.value:SetText("Value")

    local i = 0

    -- Item rows show the expected (mid) price; the spread is summarised below.
    i = i + 1
    self:SetRow(i, {
        name  = RC.ItemName(r.rawLink),
        src   = r.rawSource,
        price = RC.FormatGold(r.pRaw.mid),
        qty   = RC.FormatGold(r.quantity),
        value = RC.FormatGold(r.sellRawGross.mid),
    }, nil, r.rawLink)

    i = i + 1
    self:SetRow(i, { name = "-- or refine into --" }, COLOR_DIM)

    i = i + 1
    self:SetRow(i, {
        name  = RC.ItemName(r.refinedLink),
        src   = r.refinedSource,
        price = RC.FormatGold(r.pRefined.mid),
        qty   = string.format("%.1f", r.refinedQty),
        value = RC.FormatGold(r.refinedGold.mid),
    }, nil, r.refinedLink)

    for _, tier in ipairs(r.rows) do
        i = i + 1
        self:SetRow(i, {
            name  = RC.ItemName(tier.link),
            src   = tier.price and tier.source or "--",
            price = tier.price and RC.FormatGold(tier.price.mid) or "no data",
            qty   = string.format("%.2f", tier.count),
            value = tier.gold and RC.FormatGold(tier.gold.mid) or "0",
        -- nil colour when priced, so the name picks up its quality colour;
        -- an explicit warning colour only when the price is missing.
        }, tier.price and nil or COLOR_WARN, tier.link)
    end

    -- Summary across the three price scenarios.
    i = i + 1
    self:SetRow(i, { price = "Low", qty = "Expected", value = "High" }, COLOR_DIM)

    local function Band(label, t, color)
        i = i + 1
        self:SetRow(i, {
            name  = label,
            price = RC.FormatGold(t.low),
            qty   = RC.FormatGold(t.mid),
            value = RC.FormatGold(t.high),
        }, color)
    end

    Band("Sell raw (gross)", r.sellRawGross)
    Band("  after fees", r.rawNet, COLOR_DIM)
    Band("Refine (gross)", r.refineGross)
    Band("  after fees", r.refineNet, COLOR_DIM)

    local function Signed(v)
        return (v >= 0 and "+" or "-") .. RC.FormatGold(v >= 0 and v or -v)
    end
    i = i + 1
    self:SetRow(i, {
        name  = "Net",
        price = Signed(r.net.low),
        qty   = Signed(r.net.mid),
        value = Signed(r.net.high),
    }, r.net.mid >= 0 and COLOR_GOOD or COLOR_BAD)

    -- Hide any rows left over from a longer previous render.
    for j = i + 1, #self.rows do
        self.rows[j].control:SetHidden(true)
    end

    local tableHeight = (i + 1) * ROW_H
    self.tableArea:SetHeight(tableHeight)

    if r.net.mid >= 0 then
        self.verdict:SetText(string.format("=> REFINE, +%sg expected", RC.FormatGold(r.net.mid)))
        self.verdict:SetColor(unpack(COLOR_GOOD))
    else
        self.verdict:SetText(string.format("=> SELL RAW, refining loses %sg expected",
            RC.FormatGold(-r.net.mid)))
        self.verdict:SetColor(unpack(COLOR_BAD))
    end
    self.verdict:SetAnchor(TOPLEFT, self.tableArea, BOTTOMLEFT, 0, 8)

    local function SignedG(v)
        return (v >= 0 and "+" or "-") .. RC.FormatGold(v >= 0 and v or -v) .. "g"
    end
    self.perBatch:SetText(string.format("per 200 raw: %s   (low %s, high %s)",
        SignedG(RC.NetPer(r, 200)),
        SignedG(RC.NetPer(r, 200, "low")),
        SignedG(RC.NetPer(r, 200, "high"))))
    self.perBatch:SetColor(unpack(r.net.mid >= 0 and COLOR_GOOD or COLOR_BAD))
    self.perBatch:SetAnchor(TOPLEFT, self.verdict, BOTTOMLEFT, 0, 2)

    local note
    if not RC.applyTax then
        note = "Gross only -- fees disabled (RC.applyTax)."
    elseif r.taxed then
        note = "Fees = listing fee + trader cut, from the game."
    else
        note = "Gross only -- the game would not report guild store fees."
    end
    self.note:SetText(string.format("%s  Refined yield %.2f/raw.", note, RC.refinedPerRaw))
    self.note:SetAnchor(TOPLEFT, self.perBatch, BOTTOMLEFT, 0, 4)

    self.footer:SetAnchor(TOPLEFT, self.note, BOTTOMLEFT, 0, 6)
    -- title + subtitle, dropdown row, table, then verdict + per-batch + note.
    self.window:SetHeight(PAD * 2 + 44 + HEADER_H + 6 + tableHeight + 74)
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

-- Swap what the window is showing without rebuilding it. A material dropdown
-- added later should call this and nothing else.
function UI:SetTarget(mat, quantity)
    self.mat = mat or self.mat
    self.quantity = quantity or self.quantity or 200
    return self:Refresh()
end

function UI:Refresh()
    if not self.mat then return false end
    local r, err = RC.Evaluate(self.mat, self.quantity)
    if not r then
        self:Create()
        -- Keep the dropdowns live: picking a source with no data must not trap
        -- the user with no way to pick a different one.
        self:PopulateDropdowns()
        self.title:SetText(RC.MaterialLabel(self.mat))
        self.subtitle:SetText(err or "no data")
        self.subtitle:SetColor(unpack(COLOR_BAD))
        for _, row in ipairs(self.rows) do row.control:SetHidden(true) end
        self.verdict:SetText("")
        self.perBatch:SetText("")
        self.note:SetText("")
        self.window:SetHidden(false)
        return false
    end
    self:Render(r)
    self.window:SetHidden(false)
    return true
end

function UI:Show(mat, quantity)
    self:Create()
    return self:SetTarget(mat, quantity)
end

function UI:Hide()
    if self.window then self.window:SetHidden(true) end
end

function UI:Toggle(mat, quantity)
    self:Create()
    if not self.window:IsHidden() then
        self:Hide()
        return false
    end
    return self:Show(mat, quantity)
end
