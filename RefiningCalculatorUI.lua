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

UI.mode = "detail"       -- "detail" | "ranking" | "stats"
UI.sortKey = "net"       -- see RC.RANK_SORTS
UI.page = 1              -- ranking page, 1-based
UI.statsTab = "overview" -- "overview", or a craft key

local WM = WINDOW_MANAGER

local WIN_NAME = "RefiningCalculatorWindow"
local WIDTH, PAD, ROW_H = 500, 12, 20
local HEADER_H = 58       -- two rows: dropdowns, then buttons
local TAB_ROW_H = 30      -- the statistics view adds a third row of tabs

-- Ranking lists every material; showing all 45 would make the window taller
-- than many screens, and the point of the view is the top of the list.
local RANK_LIMIT = 20

-- width is the column box; align is where the text sits inside it.
-- Widths total WIDTH - 2*PAD. The last column is only used by the ranking view;
-- the detail view leaves it empty.
local COLUMNS = {
    { key = "name",  width = 170, align = TEXT_ALIGN_LEFT  },
    { key = "src",   width =  40, align = TEXT_ALIGN_LEFT  },
    { key = "price", width =  66, align = TEXT_ALIGN_RIGHT },
    { key = "qty",   width =  66, align = TEXT_ALIGN_RIGHT },
    { key = "value", width =  66, align = TEXT_ALIGN_RIGHT },
    { key = "vol",   width =  68, align = TEXT_ALIGN_RIGHT },
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

-- Ranking rows are clickable: click one to open its detail view. The handler is
-- attached once and reads a per-render field, like the tooltip link above.
local function OnNameClick(cell)
    if cell.onClick then cell.onClick() end
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
            cell:SetHandler("OnMouseUp", OnNameClick)
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

-- y defaults to 30, the header's second row; the paging buttons pass 0.
-- Control names must be unique, so they include the parent's name.
function UI:MakeButton(parent, x, width, height, onClick, y)
    local button = WM:CreateControlFromVirtual(
        WIN_NAME .. "Button" .. tostring(x) .. "_" .. tostring(y or 30),
        parent, "ZO_DefaultButton")
    if not button then return nil end
    button:SetDimensions(width, height)
    button:SetAnchor(TOPLEFT, parent, TOPLEFT, x, y or 30)
    button:SetHandler("OnClicked", onClick)
    return button
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
        -- Cached prices are keyed per source, but clearing keeps memory bounded
        -- and guarantees a source switch reflects fresh data.
        RC.ClearPriceCache()
        UI:Refresh()
    end)

    -- Detail -> Find best -> Stats -> Detail.
    local MODE_CYCLE = { detail = "ranking", ranking = "stats", stats = "detail" }
    self.modeButton = self:MakeButton(self.header, 0, 120, 28, function()
        UI.mode = MODE_CYCLE[UI.mode] or "detail"
        UI.page = 1
        UI:Refresh()
    end)
    self.sortButton = self:MakeButton(self.header, 128, 140, 28, function()
        -- Cycle through RC.RANK_SORTS rather than hardcoding the order here.
        local sorts = RC.RANK_SORTS
        local at = 1
        for index, s in ipairs(sorts) do
            if s.key == UI.sortKey then at = index break end
        end
        UI.sortKey = sorts[(at % #sorts) + 1].key
        UI:Refresh()
    end)
    self.volumeButton = self:MakeButton(self.header, 274, 110, 28, function()
        RC.minVolume = RC.NextVolumeStep(RC.minVolume)
        UI.page = 1
        UI:Refresh()
    end)
    self.refreshButton = self:MakeButton(self.header, 390, 86, 28, function()
        RC.ClearPriceCache()
        UI:Refresh()
    end)

    -- Statistics tabs: an overview plus one per craft. Created once; which are
    -- shown, and where, is decided per render in UpdateStatsTabs.
    self.tabs = {}
    local function AddTab(key, label)
        -- Distinct creation x keeps the control names unique; the real position
        -- is set per render, since hidden tabs must not leave gaps.
        local button = self:MakeButton(self.header, #self.tabs * 90, 90, 26, function()
            UI.statsTab = key
            UI:Refresh()
        end, 60)
        if button then
            self.tabs[#self.tabs + 1] = { key = key, label = label, button = button }
        end
    end
    AddTab("overview", "Overview")
    for _, craft in ipairs(RC.CRAFTS) do
        AddTab(craft.key, craft.label)
    end

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

    -- Paging lives below the table, where the list it moves through is.
    self.prevButton = self:MakeButton(self.footer, 0, 80, 26, function()
        UI:SetPage(UI.page - 1)
    end, 0)
    self.pageLabel = MakeLabel(self.footer, "ZoFontGameSmall", TEXT_ALIGN_CENTER, COLOR_DIM)
    self.pageLabel:SetDimensions(140, 26)
    self.pageLabel:SetAnchor(TOPLEFT, self.footer, TOPLEFT, 88, 4)
    self.nextButton = self:MakeButton(self.footer, 232, 80, 26, function()
        UI:SetPage(UI.page + 1)
    end, 0)

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
    row.cells.name.onClick = nil
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

    -- "Qty /200" and "Value" spell out that the value column is an extended
    -- total: expected count over 200 raw multiplied by the unit price. Price is
    -- the figure to check against a TTC or ATT tooltip; Value is derived from it.
    local h = self.headerRow.cells
    h.name:SetText("Item")
    h.src:SetText("Src")
    h.price:SetText("Price ea")
    h.qty:SetText("Qty /200")
    h.value:SetText("Value")
    h.vol:SetText("")

    local i = 0

    -- Item rows show the expected (mid) price; the spread is summarised below.
    i = i + 1
    self:SetRow(i, {
        name  = RC.ItemName(r.rawLink),
        src   = r.rawSource,
        price = RC.FormatGold(r.pRaw),
        qty   = RC.FormatGold(r.quantity),
        value = RC.FormatGold(r.sellRawGross),
    }, nil, r.rawLink)

    i = i + 1
    self:SetRow(i, { name = "-- or refine into --" }, COLOR_DIM)

    i = i + 1
    self:SetRow(i, {
        name  = RC.ItemName(r.refinedLink),
        src   = r.refinedSource,
        price = RC.FormatGold(r.pRefined),
        qty   = string.format("%.1f", r.refinedQty),
        value = RC.FormatGold(r.refinedGold),
    }, nil, r.refinedLink)

    for _, tier in ipairs(r.rows) do
        i = i + 1
        self:SetRow(i, {
            name  = RC.ItemName(tier.link),
            src   = tier.price and tier.source or "--",
            price = tier.price and RC.FormatGold(tier.price) or "no data",
            qty   = string.format("%.2f", tier.count),
            value = tier.gold and RC.FormatGold(tier.gold) or "0",
        -- Plain text when priced. Written out rather than as
        -- "tier.price and nil or COLOR_WARN", which is always COLOR_WARN in Lua:
        -- "x and nil" is falsy, so the or-branch always wins. That is why every
        -- temper row was orange.
        }, (not tier.price) and COLOR_WARN or nil, tier.link)
    end

    i = i + 1
    self:SetRow(i, { price = "Gross", qty = "Fees", value = "Net" }, COLOR_DIM)

    local function Fees(fee, cut)
        if fee + cut > 0 then return "-" .. RC.FormatGold(fee + cut) end
        return "--"
    end

    i = i + 1
    self:SetRow(i, {
        name  = "Sell raw",
        price = RC.FormatGold(r.sellRawGross),
        qty   = Fees(r.rawFee, r.rawCut),
        value = RC.FormatGold(r.rawNet),
    })

    i = i + 1
    self:SetRow(i, {
        name  = "Refine + sell",
        price = RC.FormatGold(r.refineGross),
        qty   = Fees(r.refineFee, r.refineCut),
        value = RC.FormatGold(r.refineNet),
    })

    local function Signed(v)
        return (v >= 0 and "+" or "-") .. RC.FormatGold(v >= 0 and v or -v)
    end
    i = i + 1
    self:SetRow(i, {
        name  = string.format("Net per %d raw", r.quantity),
        value = Signed(r.net),
    }, r.net >= 0 and COLOR_GOOD or COLOR_BAD)

    -- Hide any rows left over from a longer previous render.
    for j = i + 1, #self.rows do
        self.rows[j].control:SetHidden(true)
    end

    local tableHeight = (i + 1) * ROW_H
    self.tableArea:SetHeight(tableHeight)

    if r.net >= 0 then
        self.verdict:SetText(string.format("=> REFINE, +%sg expected", RC.FormatGold(r.net)))
        self.verdict:SetColor(unpack(COLOR_GOOD))
    else
        self.verdict:SetText(string.format("=> SELL RAW, refining loses %sg expected",
            RC.FormatGold(-r.net)))
        self.verdict:SetColor(unpack(COLOR_BAD))
    end
    self.verdict:SetAnchor(TOPLEFT, self.tableArea, BOTTOMLEFT, 0, 8)

    -- The only place your actual holdings enter the picture; everything above is
    -- per RC.BATCH so materials stay comparable.
    local stock = RC.StockCount(r.mat)
    if stock > 0 then
        local total = r.netPerRaw * stock
        self.perBatch:SetText(string.format("Your stock: %s raw  =>  %s%sg total",
            RC.FormatGold(stock), total >= 0 and "+" or "-",
            RC.FormatGold(total >= 0 and total or -total)))
        self.perBatch:SetColor(unpack(total >= 0 and COLOR_GOOD or COLOR_BAD))
    else
        self.perBatch:SetText("Your stock: none")
        self.perBatch:SetColor(unpack(COLOR_DIM))
    end
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

    self:UpdatePaging()
    self.footer:SetAnchor(TOPLEFT, self.note, BOTTOMLEFT, 0, 6)
    self.footer:SetHeight(0)
    -- title + subtitle, dropdown row, table, then verdict + per-batch + note.
    self.window:SetHeight(PAD * 2 + 44 + HEADER_H + 6 + tableHeight + 74)
end

--------------------------------------------------------------------------------
-- Ranking view
--------------------------------------------------------------------------------

function UI:RenderRanking()
    self:Create()
    self:PopulateDropdowns()

    local batch = RC.BATCH
    local list, filtered = RC.RankAll(batch)
    RC.SortRanking(list, self.sortKey)

    -- Clamp after sorting: the page count changes when the filter or the source
    -- changes, and page 4 of a now-2-page list must not render empty.
    local pages = math.max(1, math.ceil(#list / RANK_LIMIT))
    if self.page > pages then self.page = pages end
    if self.page < 1 then self.page = 1 end
    local first = (self.page - 1) * RANK_LIMIT

    self.title:SetText("Worth buying to refine?")
    local mdText, mdState = RC.DescribeMD(RC.GetMD())
    self.subtitle:SetText(mdText)
    self.subtitle:SetColor(unpack(mdState == "active" and COLOR_GOOD or COLOR_WARN))

    local h = self.headerRow.cells
    h.name:SetText("Raw material")
    h.src:SetText("Craft")
    h.price:SetText("Market")
    h.qty:SetText("Pay up to")
    h.value:SetText("Margin")
    h.vol:SetText("Listings")

    local i = 0
    for offset = 1, RANK_LIMIT do
        local entry = list[first + offset]
        if not entry then break end
        i = i + 1
        -- The RAW item here, not the refined one: this is the thing you buy.
        local link = RC.RawLink(entry.mat)
        local row = self:SetRow(i, {
            name  = RC.ItemName(link),
            src   = entry.mat.craft.short,
            price = RC.FormatGold(entry.rawPrice),
            qty   = RC.FormatGold(entry.breakEven),
            value = string.format("%+.0f%%", entry.margin * 100),
            vol   = RC.FormatGold(entry.volume),
        }, nil, link)

        -- Thin markets only appear when the filter is off; flag them so a
        -- tempting margin on two stale listings is not mistaken for a find.
        if entry.volume < RC.minVolume then
            row.cells.vol:SetColor(unpack(COLOR_WARN))
        else
            row.cells.vol:SetColor(unpack(COLOR_DIM))
        end

        -- Colour the margin cell only, so the name keeps its item colour.
        row.cells.value:SetColor(unpack(entry.margin >= 0 and COLOR_GOOD or COLOR_BAD))
        -- Break-even above market means it is worth buying right now.
        row.cells.qty:SetColor(unpack(entry.breakEven >= entry.rawPrice and COLOR_GOOD or COLOR_DIM))

        local mat = entry.mat
        row.cells.name.onClick = function()
            UI.mode = "detail"
            UI:SetTarget(mat)
        end
    end

    for j = i + 1, #self.rows do
        self.rows[j].control:SetHidden(true)
    end

    local tableHeight = (i + 1) * ROW_H
    self.tableArea:SetHeight(tableHeight)

    if filtered > 0 then
        self.verdict:SetText(string.format("%d materials traded, %d hidden below %d listings.",
            #list, filtered, RC.minVolume))
    else
        self.verdict:SetText(string.format("%d materials. Click a row for detail.", #list))
    end
    self.verdict:SetColor(unpack(COLOR_TEXT))
    self.verdict:SetAnchor(TOPLEFT, self.tableArea, BOTTOMLEFT, 0, 8)

    self.perBatch:SetText("Pay up to = most per raw to break even, after fees.")
    self.perBatch:SetColor(unpack(COLOR_DIM))

    self.pages = pages
    self.perBatch:SetAnchor(TOPLEFT, self.verdict, BOTTOMLEFT, 0, 2)

    self.note:SetText(string.format("Refined yield %.2f/raw. Prices cached -- use Refresh for fresh data.",
        RC.refinedPerRaw))
    self.note:SetAnchor(TOPLEFT, self.perBatch, BOTTOMLEFT, 0, 4)

    self:UpdatePaging()
    self.footer:SetAnchor(TOPLEFT, self.note, BOTTOMLEFT, 0, 6)
    self.footer:SetHeight(30)
    self.window:SetHeight(PAD * 2 + 44 + HEADER_H + 6 + tableHeight + 74 + 30)
end

-- Paging controls only mean anything in the ranking view, and only when there is
-- more than one page to move between.
function UI:UpdatePaging()
    local pages = self.pages or 1
    -- Both the ranking and the statistics view page; only the detail view does not.
    local show = (self.mode == "ranking" or self.mode == "stats") and pages > 1

    if self.pageLabel then
        self.pageLabel:SetText(string.format("Page %d of %d", self.page, pages))
        self.pageLabel:SetHidden(not show)
    end
    if self.prevButton then
        self.prevButton:SetText("< Prev")
        self.prevButton:SetHidden(not show)
        self.prevButton:SetEnabled(self.page > 1)
    end
    if self.nextButton then
        self.nextButton:SetText("Next >")
        self.nextButton:SetHidden(not show)
        self.nextButton:SetEnabled(self.page < pages)
    end
end

function UI:SetPage(page)
    self.page = math.max(1, page)
    self:Refresh()
end

--------------------------------------------------------------------------------
-- Statistics view
--------------------------------------------------------------------------------

local function Pct(v) return string.format("%.2f%%", v * 100) end

local function Signed(v)
    return (v >= 0 and "+" or "-") .. RC.FormatGold(v >= 0 and v or -v)
end

-- Observed versus expected for one measure. Green when within 5%, which at
-- small sample sizes means little -- the view says so separately.
local function Compare(label, observed, expected, samples, isRate)
    local diff = expected ~= 0 and ((observed - expected) / expected) or 0
    local color = COLOR_DIM
    if samples > 0 then
        color = (math.abs(diff) <= 0.05) and COLOR_GOOD or COLOR_WARN
    end
    local function Fmt(v) return isRate and Pct(v) or string.format("%.3f", v) end
    return {
        name  = label,
        price = samples > 0 and Fmt(observed) or "--",
        qty   = Fmt(expected),
        value = samples > 0 and string.format("%+.1f%%", diff * 100) or "--",
        vol   = RC.FormatGold(samples),
    }, color
end

-- Page 1 is the money question: per craft, did refining beat selling the raw?
function UI:RenderStatsMoney(s, i)
    local h = self.headerRow.cells
    h.name:SetText("Craft")
    h.src:SetText("N")
    h.price:SetText("Yield")
    h.qty:SetText("Raw worth")
    h.value:SetText("Output")
    h.vol:SetText("Profit")

    for _, entry in ipairs(s.byCraft) do
        local t = entry.total
        i = i + 1
        if t.refines == 0 then
            self:SetRow(i, { name = entry.craft.label, src = "0", price = "--",
                qty = "--", value = "--", vol = "--" }, COLOR_DIM)
        else
            local row = self:SetRow(i, {
                name  = entry.craft.label,
                src   = RC.FormatGold(t.refines),
                price = string.format("%.3f", t.raw > 0 and (t.refined / t.raw) or 0),
                qty   = RC.FormatGold(entry.rawGold),
                value = RC.FormatGold(entry.outGold),
                vol   = Signed(entry.profit),
            })
            row.cells.vol:SetColor(unpack(entry.profit >= 0 and COLOR_GOOD or COLOR_BAD))
        end
    end

    i = i + 1
    local totalRow = self:SetRow(i, {
        name  = "All crafts",
        src   = RC.FormatGold(s.overall.refines),
        price = string.format("%.3f", s.overall.raw > 0 and (s.overall.refined / s.overall.raw) or 0),
        qty   = RC.FormatGold(s.rawGold),
        value = RC.FormatGold(s.outGold),
        vol   = Signed(s.profit),
    })
    totalRow.cells.vol:SetColor(unpack(s.profit >= 0 and COLOR_GOOD or COLOR_BAD))
    return i
end

-- Later pages are one craft each: its yield against the model, and its own
-- temper drop rates rather than a pooled figure.
function UI:RenderStatsCraft(s, i, entry)
    local h = self.headerRow.cells
    h.name:SetText(entry.craft.label)
    h.src:SetText("")
    h.price:SetText("Observed")
    h.qty:SetText("Expected")
    h.value:SetText("Diff")
    h.vol:SetText("Refines")

    local t = entry.total
    local yield = t.raw > 0 and (t.refined / t.raw) or 0
    i = i + 1
    self:SetRow(i, (Compare("refined per raw", yield, RC.refinedPerRaw, t.refines, false)))

    i = i + 1
    self:SetRow(i, { name = "-- temper drops per refine --" }, COLOR_DIM)

    for _, tier in ipairs(s.tiers) do
        local observed = t.refines > 0 and (t[tier] / t.refines) or 0
        local values, color = Compare(tier, observed, s.expected[tier], t.refines, true)
        i = i + 1
        self:SetRow(i, values, color)
    end

    i = i + 1
    self:SetRow(i, { name = "-- gold, at today's prices --" }, COLOR_DIM)

    i = i + 1
    self:SetRow(i, { name = "raw worth", price = RC.FormatGold(entry.rawGold) })
    i = i + 1
    self:SetRow(i, { name = "refined + tempers", price = RC.FormatGold(entry.outGold) })
    i = i + 1
    local row = self:SetRow(i, { name = "profit", price = Signed(entry.profit) })
    row.cells.price:SetColor(unpack(entry.profit >= 0 and COLOR_GOOD or COLOR_BAD))

    return i
end

-- A craft only gets a tab once something of that type has been refined, so the
-- row shows what you have actually done rather than every craft in the game.
-- Positions are assigned here because hidden tabs must not leave gaps.
function UI:UpdateStatsTabs(s)
    if not self.tabs then return end

    local hasData = {}
    for _, entry in ipairs(s.byCraft) do
        hasData[entry.craft.key] = entry.total.refines > 0
    end

    local visible = {}
    for _, tab in ipairs(self.tabs) do
        if tab.key == "overview" or hasData[tab.key] then
            visible[#visible + 1] = tab
        else
            tab.button:SetHidden(true)
        end
    end

    -- Selection can point at a craft that no longer has samples, after a reset.
    local stillValid = false
    for _, tab in ipairs(visible) do
        if tab.key == self.statsTab then stillValid = true break end
    end
    if not stillValid then self.statsTab = "overview" end

    local gap, count = 4, #visible
    local width = math.floor(((WIDTH - PAD * 2) - gap * (count - 1)) / count)
    for index, tab in ipairs(visible) do
        tab.button:SetHidden(false)
        tab.button:SetDimensions(width, 26)
        tab.button:ClearAnchors()
        tab.button:SetAnchor(TOPLEFT, self.header, TOPLEFT, (index - 1) * (width + gap), 60)
        tab.button:SetText(tab.label)
        -- The active tab is the one you cannot click, which marks it without
        -- needing a toggle state ZO_DefaultButton does not have.
        tab.button:SetEnabled(tab.key ~= self.statsTab)
    end
end

function UI:RenderStats()
    self:Create()
    self:PopulateDropdowns()

    local md = RC.GetMD()
    local s = RC.Stats.Summary(md.active)
    local other = RC.Stats.CountFor(not md.active)

    self:UpdateStatsTabs(s)

    local entry
    for _, e in ipairs(s.byCraft) do
        if e.craft.key == self.statsTab then entry = e break end
    end

    self.pages = 1  -- tabs replace paging here
    self.title:SetText(entry and ("Refining statistics -- " .. entry.craft.label)
        or "Refining statistics")

    local mdText, mdState = RC.DescribeMD(md)
    self.subtitle:SetText(mdText .. " -- showing samples recorded in this state")
    self.subtitle:SetColor(unpack(mdState == "active" and COLOR_GOOD or COLOR_WARN))

    local i = 0
    if entry then
        i = self:RenderStatsCraft(s, i, entry)
    else
        i = self:RenderStatsMoney(s, i)
    end

    for j = i + 1, #self.rows do
        self.rows[j].control:SetHidden(true)
    end

    local tableHeight = (i + 1) * ROW_H
    self.tableArea:SetHeight(tableHeight)

    local total = s.overall.refines
    if total == 0 then
        self.verdict:SetText("No refines recorded yet in this state.")
        self.verdict:SetColor(unpack(COLOR_WARN))
    elseif s.priced then
        self.verdict:SetText(string.format("%s refines, %s raw consumed. Overall %sg.",
            RC.FormatGold(total), RC.FormatGold(s.overall.raw), Signed(s.profit)))
        self.verdict:SetColor(unpack(s.profit >= 0 and COLOR_GOOD or COLOR_BAD))
    else
        self.verdict:SetText(string.format("%s refines, %s raw consumed. No prices available.",
            RC.FormatGold(total), RC.FormatGold(s.overall.raw)))
        self.verdict:SetColor(unpack(COLOR_WARN))
    end
    self.verdict:SetAnchor(TOPLEFT, self.tableArea, BOTTOMLEFT, 0, 8)

    -- Both sides are valued now, not at the time of each refine, so this answers
    -- "was refining the right call" rather than "what did I bank that day".
    if total < 100 then
        self.perBatch:SetText("Small samples swing widely -- expect a few hundred refines before rates settle.")
    else
        self.perBatch:SetText("Gold values both sides at today's prices, after fees.")
    end
    self.perBatch:SetColor(unpack(COLOR_DIM))
    self.perBatch:SetAnchor(TOPLEFT, self.verdict, BOTTOMLEFT, 0, 2)

    if other > 0 then
        self.note:SetText(string.format(
            "%s more refines recorded with MD %s; those are kept separate.",
            RC.FormatGold(other), md.active and "off" or "on"))
    else
        self.note:SetText("Recorded automatically while refining. /refinestats reset clears them.")
    end
    self.note:SetAnchor(TOPLEFT, self.perBatch, BOTTOMLEFT, 0, 4)

    self:UpdatePaging()
    self.footer:SetAnchor(TOPLEFT, self.note, BOTTOMLEFT, 0, 6)
    self.footer:SetHeight(0)
    self.window:SetHeight(PAD * 2 + 44 + HEADER_H + TAB_ROW_H + 6 + tableHeight + 74)
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

-- Swap what the window is showing without rebuilding it. A material dropdown
-- added later should call this and nothing else.
function UI:SetTarget(mat, quantity)
    self.mat = mat or self.mat
    self.quantity = quantity or self.quantity or RC.BATCH
    return self:Refresh()
end

-- Button captions track state, so they say what clicking will do.
function UI:UpdateButtons()
    -- The tab row exists only in the statistics view; the header grows to make
    -- room for it, and everything below reflows because it anchors to the header.
    local statsMode = (self.mode == "stats")
    if self.header then
        self.header:SetHeight(statsMode and (HEADER_H + TAB_ROW_H) or HEADER_H)
    end
    if self.tabs and not statsMode then
        for _, tab in ipairs(self.tabs) do tab.button:SetHidden(true) end
    end

    if self.modeButton then
        -- The caption names the view the click will take you to.
        local next = { detail = "Find best", ranking = "Statistics", stats = "Detail" }
        self.modeButton:SetText(next[self.mode] or "Detail")
    end
    if self.sortButton then
        local label = "Sort"
        for _, s in ipairs(RC.RANK_SORTS) do
            if s.key == self.sortKey then label = s.label break end
        end
        self.sortButton:SetText(label)
        self.sortButton:SetHidden(self.mode ~= "ranking")
    end
    if self.volumeButton then
        self.volumeButton:SetText(RC.minVolume <= 0
            and "Listings: any" or ("Listings: " .. RC.minVolume .. "+"))
        self.volumeButton:SetHidden(self.mode ~= "ranking")
    end
    if self.refreshButton then
        self.refreshButton:SetText("Refresh")
    end
end

function UI:Refresh()
    self:Create()
    self:UpdateButtons()

    if self.mode == "ranking" then
        self:RenderRanking()
        self.window:SetHidden(false)
        return true
    end

    if self.mode == "stats" then
        self:RenderStats()
        self.window:SetHidden(false)
        return true
    end

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

-- Asking for a specific material means the detail view, even if the window was
-- last left showing the ranking.
function UI:Show(mat, quantity)
    self:Create()
    if mat then self.mode = "detail" end
    return self:SetTarget(mat, quantity)
end

function UI:ShowRanking()
    self:Create()
    self.mode = "ranking"
    self.page = 1
    self:Refresh()
    self.window:SetHidden(false)
    return true
end

function UI:ShowStats()
    self:Create()
    self.mode = "stats"
    self:Refresh()
    self.window:SetHidden(false)
    return true
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
