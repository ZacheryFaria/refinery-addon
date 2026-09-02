-- RefiningCalculator
-- Answers one question: is this raw material worth more refined, or sold raw?

RefiningCalculator = {}
local RC = RefiningCalculator
RC.name = "RefiningCalculator"

local PREFIX = "|c66CCFF[RefineCalc]|r "

--------------------------------------------------------------------------------
-- Yield model
--------------------------------------------------------------------------------

-- Temper drop rates are PER REFINE. One refine consumes
-- GetRequiredSmithingRefinementStackSize() raw materials (normally 10).
--
-- Source: community refining survey, 9,962,230 raw materials sampled since the
-- 2021-03-08 Flames of Ambition patch that added the Meticulous Disassembly CP star.
--   Measured:  green 16.928%   blue 13.992%   purple 8.409%   gold 5.646%   (44.974% combined)
--   95% MoE:        +/-0.074%       +/-0.068%       +/-0.054%      +/-0.045%
--
-- The survey concludes Meticulous Disassembly is a flat +12.5% multiplier on the
-- pre-2021 rates. That hypothesis produces the exact values below, every one of
-- which sits inside the measured margin of error, so we use the clean theoretical
-- numbers rather than the raw sample means.
local TEMPER_RATES_MD    = { green = 0.16875, blue = 0.140625, purple = 0.084375, gold = 0.05625 } -- 45% combined
-- Meticulous Disassembly not slotted / not maxed -- the survey "Old Drop Rate" row.
local TEMPER_RATES_NO_MD = { green = 0.15,    blue = 0.125,    purple = 0.075,    gold = 0.05    } -- 40% combined

-- Refined materials produced per raw material refined: 85 ingots per 100 ore.
-- Player-supplied figure, not from the survey above -- that survey covers tempers
-- only and carries no refined-yield data. This is the one input in the model that
-- does not trace back to the sample, and it dominates the result, so the output
-- prints it every time.
--
-- Note this assumes maxed extraction passives (Metal Extraction / Unraveling /
-- Wood Extraction / Engraver). To re-measure: note your refined-material count,
-- refine an exact 1000 raw, then (gained / 1000) is your value.
RC.refinedPerRaw = 0.85

-- Guild store fees are NOT hardcoded -- GetTradingHousePostPriceInfo() asks the
-- game for the listing fee and trader cut on a given sale price, so the numbers
-- track whatever the current rates actually are. Set this false to compare pure
-- gross value instead.
RC.applyTax = true

--------------------------------------------------------------------------------
-- Material data
--------------------------------------------------------------------------------

-- Tempers are per CRAFT, not per material -- Honing Stone is the same item
-- whether you refine Iron or Rubedite.
-- Item IDs cross-verified against ArkadiusTradeToolsCraftingInfo.lua and Dustman.lua.
local CRAFT_TEMPERS = {
    BLACKSMITHING = { green = 54170,  blue = 54171,  purple = 54172,  gold = 54173  },
    CLOTHING      = { green = 54174,  blue = 54175,  purple = 54176,  gold = 54177  },
    WOODWORKING   = { green = 54178,  blue = 54179,  purple = 54180,  gold = 54181  },
    JEWELRY       = { green = 203631, blue = 203632, purple = 203633, gold = 203634 },
}

-- CP160 tier. raw/refined verified against the Dustman material whitelist.
local MATERIALS = {
    { key = "RUBEDITE",       label = "Rubedite",       craft = "BLACKSMITHING", raw = 71198,  refined = 64489  },
    { key = "ANCESTOR_SILK",  label = "Ancestor Silk",  craft = "CLOTHING",      raw = 71239,  refined = 64504  },
    { key = "RUBEDO_LEATHER", label = "Rubedo Leather", craft = "CLOTHING",      raw = 71200,  refined = 64506  },
    { key = "RUBY_ASH",       label = "Ruby Ash",       craft = "WOODWORKING",   raw = 71199,  refined = 64502  },
    { key = "PLATINUM",       label = "Platinum",       craft = "JEWELRY",       raw = 135145, refined = 135146 },
}

local BY_RAW_ID = {}
for _, mat in ipairs(MATERIALS) do BY_RAW_ID[mat.raw] = mat end

--------------------------------------------------------------------------------
-- Item links
--------------------------------------------------------------------------------

-- Field layout matches the material links ArkadiusTradeTools ships, so the links
-- built here hash the same way the price databases stored them.
local LINK_FMT = "|H1:item:%d:%d:1:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0:0|h|h"
local SUBTYPE  = { normal = 30, green = 31, blue = 32, purple = 33, gold = 34 }

local function Link(itemId, subtype)
    return string.format(LINK_FMT, itemId, subtype or SUBTYPE.normal)
end

local TIERS = { "green", "blue", "purple", "gold" }

--------------------------------------------------------------------------------
-- Meticulous Disassembly detection
--------------------------------------------------------------------------------

-- Champion skill 83. A slottable star only applies while it is on the champion
-- bar, so points spent alone is not enough -- both are checked.
local MET_DIS_ID = 83
local CHAMPION_BAR_SLOTS = 12

local function GetMeticulousDisassembly()
    local spent   = GetNumPointsSpentOnChampionSkill(MET_DIS_ID) or 0
    local maxPts  = GetChampionSkillMaxPoints(MET_DIS_ID) or 50
    local slotted = false
    for i = 1, CHAMPION_BAR_SLOTS do
        if GetSlotBoundId(i, HOTBAR_CATEGORY_CHAMPION) == MET_DIS_ID then
            slotted = true
            break
        end
    end
    return {
        spent   = spent,
        maxPts  = maxPts,
        slotted = slotted,
        active  = slotted and spent >= maxPts,
    }
end

-- Returns plain text plus a state key, so chat can wrap it in colour codes and
-- the window can colour the label instead. Neither has to parse the other.
function RC.DescribeMD(md)
    if md.active then
        return string.format("Meticulous Disassembly active (%d/%d, slotted)",
            md.spent, md.maxPts), "active"
    elseif md.slotted then
        return string.format("MD slotted but only %d/%d points -- using base rates, real yield is between the two",
            md.spent, md.maxPts), "partial"
    elseif md.spent >= md.maxPts then
        return string.format("MD maxed (%d/%d) but NOT slotted -- using base rates",
            md.spent, md.maxPts), "partial"
    end
    return string.format("MD not active (%d/%d, not slotted) -- using base rates",
        md.spent, md.maxPts), "inactive"
end

local MD_COLOR = { active = "|c00FF00", partial = "|cFFAA00", inactive = "|cFFAA00" }

--------------------------------------------------------------------------------
-- Pricing
--------------------------------------------------------------------------------

-- LibPrice blends Master Merchant / ATT / TTC and already handles TTC rows that
-- carry no SuggestedPrice by falling through to Avg.
local function GetPrice(itemLink)
    if not (LibPrice and LibPrice.ItemLinkToPriceGold) then return nil, "nolib" end
    local gold, source = LibPrice.ItemLinkToPriceGold(itemLink)
    if gold and gold > 0 then return gold, source end
    return nil, "nodata"
end

local function Gold(n)
    if ZO_CommaDelimitNumber then return ZO_CommaDelimitNumber(math.floor(n + 0.5)) end
    return string.format("%.0f", n)
end

local function ItemName(itemLink)
    local name = GetItemLinkName(itemLink)
    if not name or name == "" then return "?" end
    return zo_strformat(SI_TOOLTIP_ITEM_NAME, name)
end

-- Shared with the window (RefiningCalculatorUI.lua).
RC.FormatGold = Gold
RC.ItemName   = ItemName
RC.MATERIALS  = MATERIALS

-- Guild store fees, straight from the game rather than a hardcoded percentage.
-- Returns listingFee, houseCut, net -- or nil if the game would not tell us.
local function TaxOn(gross)
    if not RC.applyTax then return 0, 0, gross end
    if not GetTradingHousePostPriceInfo then return nil end
    local listingFee, houseCut, profit = GetTradingHousePostPriceInfo(math.floor(gross + 0.5))
    if not profit or profit <= 0 then return nil end
    return listingFee or 0, houseCut or 0, profit
end

--------------------------------------------------------------------------------
-- Calculation
--------------------------------------------------------------------------------

local function StackSize()
    if GetRequiredSmithingRefinementStackSize then
        local n = GetRequiredSmithingRefinementStackSize()
        if n and n > 0 then return n end
    end
    return 10
end

-- Returns a result table, or nil plus a reason string.
function RC.Evaluate(mat, quantity)
    quantity = quantity or 200

    local md        = GetMeticulousDisassembly()
    local rates     = md.active and TEMPER_RATES_MD or TEMPER_RATES_NO_MD
    local perRefine = StackSize()
    local tempers   = CRAFT_TEMPERS[mat.craft]

    local rawLink     = Link(mat.raw)
    local refinedLink = Link(mat.refined)

    local pRaw,     rawSrc     = GetPrice(rawLink)
    local pRefined, refinedSrc = GetPrice(refinedLink)

    if not pRaw then
        return nil, string.format("no price data for %s", rawLink)
    end
    if not pRefined then
        return nil, string.format("no price data for %s", refinedLink)
    end

    local rows, missing = {}, {}
    local temperGold = 0
    for _, tier in ipairs(TIERS) do
        local link       = Link(tempers[tier], SUBTYPE[tier])
        local price, src = GetPrice(link)
        local count      = quantity * (rates[tier] / perRefine)
        if price then
            temperGold = temperGold + count * price
        else
            missing[#missing + 1] = link
        end
        rows[#rows + 1] = {
            tier = tier, link = link, price = price, source = src,
            count = count, gold = price and (count * price) or 0,
        }
    end

    -- Everything above is gross. Fees are applied once, at the end, per option.
    local refinedQty     = quantity * RC.refinedPerRaw
    local refinedGold    = refinedQty * pRefined
    local sellRawGross   = quantity * pRaw
    local refineGross    = refinedGold + temperGold

    local rawFee,    rawCut,    rawNet    = TaxOn(sellRawGross)
    local refineFee, refineCut, refineNet = TaxOn(refineGross)

    local taxed = rawNet ~= nil and refineNet ~= nil
    if not taxed then
        rawNet, refineNet = sellRawGross, refineGross
    end

    return {
        mat = mat, quantity = quantity, md = md, perRefine = perRefine,
        rawLink = rawLink, refinedLink = refinedLink,
        pRaw = pRaw, rawSource = rawSrc,
        pRefined = pRefined, refinedSource = refinedSrc,
        refinedQty = refinedQty, refinedGold = refinedGold,
        rows = rows, missing = missing,
        sellRawGross = sellRawGross, refineGross = refineGross,
        taxed = taxed,
        rawFee = rawFee or 0, rawCut = rawCut or 0, rawNet = rawNet,
        refineFee = refineFee or 0, refineCut = refineCut or 0, refineNet = refineNet,
        net = refineNet - rawNet,
    }
end

function RC.Report(mat, quantity)
    local r, err = RC.Evaluate(mat, quantity)
    if not r then
        d(PREFIX .. "|cFF6666" .. err .. "|r")
        if not (LibPrice and LibPrice.ItemLinkToPriceGold) then
            d(PREFIX .. "|cFF6666LibPrice is not loaded -- no price source available.|r")
        end
        return
    end

    -- ESO chat uses a proportional font, so space padding aligns approximately
    -- rather than exactly. Fixed widths still keep the columns scannable.
    local FMT = "  %-20.20s %-4.4s %9s %8s %11s"
    local function Row(name, src, price, qty, value)
        return string.format(FMT, name, src, price, qty, value)
    end

    local mdText, mdState = RC.DescribeMD(r.md)
    d(string.format("|cFFFF00=== %s -- %s raw ===|r", r.mat.label, Gold(r.quantity)))
    d("  " .. MD_COLOR[mdState] .. mdText .. "|r")
    d("|c888888" .. Row("Item", "Src", "Price", "Qty", "Value") .. "|r")
    d(Row(ItemName(r.rawLink), r.rawSource, Gold(r.pRaw), Gold(r.quantity), Gold(r.sellRawGross)))

    d("|c888888  -- or refine into --|r")
    d(Row(ItemName(r.refinedLink), r.refinedSource, Gold(r.pRefined),
        string.format("%.1f", r.refinedQty), Gold(r.refinedGold)))

    for _, row in ipairs(r.rows) do
        if row.price then
            d(Row(ItemName(row.link), row.source, Gold(row.price),
                string.format("%.2f", row.count), Gold(row.gold)))
        else
            d(Row(ItemName(row.link), "--", "|cFF6666no data|r",
                string.format("%.2f", row.count), "0"))
        end
    end

    d("|c888888" .. Row("", "", "Gross", "Fees", "Net") .. "|r")

    local function Option(label, gross, fee, cut, net)
        local deduct = (fee + cut > 0) and ("-" .. Gold(fee + cut)) or "--"
        return string.format(FMT, label, "", Gold(gross), deduct, Gold(net))
    end
    d(Option("Sell raw", r.sellRawGross, r.rawFee, r.rawCut, r.rawNet))
    d(Option("Refine + sell", r.refineGross, r.refineFee, r.refineCut, r.refineNet))

    if r.net >= 0 then
        d(string.format("  |c00FF00=> REFINE, +%sg|r", Gold(r.net)))
    else
        d(string.format("  |cFF4444=> SELL RAW, refining loses %sg|r", Gold(-r.net)))
    end

    local note
    if not RC.applyTax then
        note = "|cFFAA00Gross only -- fees disabled (RC.applyTax).|r |c888888"
    elseif r.taxed then
        note = "|c888888Fees = listing fee + trader cut from the game API. "
    else
        note = "|cFFAA00Gross only -- the game would not report guild store fees.|r |c888888"
    end
    d(string.format("  %sRefined yield %.2f/raw.|r", note, RC.refinedPerRaw))
end

--------------------------------------------------------------------------------
-- Context menu
--------------------------------------------------------------------------------

-- Looked up by name: indexing a table with a nil constant is a load-time error,
-- and a literal list would silently truncate at the first missing one. This way
-- a slot type a future API drops is skipped and the rest still work.
local MENU_SLOT_TYPES = {}
for _, name in ipairs({
    "SLOT_TYPE_ITEM",
    "SLOT_TYPE_BANK_ITEM",
    "SLOT_TYPE_GUILD_BANK_ITEM",
    "SLOT_TYPE_CRAFT_BAG_ITEM",
    "SLOT_TYPE_CRAFTING_COMPONENT",
    "SLOT_TYPE_PENDING_CRAFTING_COMPONENT",
}) do
    local slotType = _G[name]
    if slotType ~= nil then
        MENU_SLOT_TYPES[slotType] = true
    end
end

local function RegisterContextMenu()
    if not LibCustomMenu then return false end

    LibCustomMenu:RegisterContextMenu(function(inventorySlot, slotActions)
        local slotType = ZO_InventorySlot_GetType(inventorySlot)
        if not MENU_SLOT_TYPES[slotType] then return end

        local bagId, slotIndex = ZO_Inventory_GetBagAndIndex(inventorySlot)
        if not bagId or not slotIndex then return end

        local itemLink = GetItemLink(bagId, slotIndex)
        if not itemLink or itemLink == "" then return end

        local mat = BY_RAW_ID[GetItemLinkItemId(itemLink)]
        if not mat then return end

        -- Price the stack the player actually holds, across bag, bank and craft bag.
        local backpack, bank, craftBag = GetItemLinkStacks(itemLink)
        local quantity = (backpack or 0) + (bank or 0) + (craftBag or 0)
        if quantity < 1 then quantity = 200 end

        AddCustomMenuItem(string.format("Refining profit (%d)", quantity), function()
            if RC.UI then
                RC.UI:Show(mat, quantity)
            else
                RC.Report(mat, quantity)
            end
        end)
        ShowMenu()
    end, LibCustomMenu.CATEGORY_SECONDARY)

    return true
end

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

-- Chat sweep across every material -- the window shows one at a time.
local function OnSlashTest(args)
    local quantity = tonumber(args and args:match("(%d+)")) or 200
    d(PREFIX .. string.format("Evaluating all CP160 materials at %d raw each...", quantity))
    for _, mat in ipairs(MATERIALS) do
        RC.Report(mat, quantity)
    end
end

-- Opens the window. Accepts an optional quantity and a material name fragment,
-- e.g. "/refinecalc 400 silk".
local function OnSlashCalc(args)
    if not RC.UI then
        d(PREFIX .. "|cFF6666window unavailable -- RefiningCalculatorUI.lua did not load.|r")
        return
    end
    args = args or ""
    local quantity = tonumber(args:match("(%d+)"))
    local name = args:gsub("%d+", ""):gsub("^%s*(.-)%s*$", "%1"):lower()

    local mat
    if name ~= "" then
        for _, m in ipairs(MATERIALS) do
            if m.label:lower():find(name, 1, true) then mat = m break end
        end
        if not mat then
            d(PREFIX .. "|cFF6666no material matching '" .. name .. "'|r")
            return
        end
    end

    RC.UI:Toggle(mat or RC.UI.mat or MATERIALS[1], quantity)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local menuRegistered = false

local function OnPlayerActivated()
    EVENT_MANAGER:UnregisterForEvent(RC.name .. "_Activated", EVENT_PLAYER_ACTIVATED)

    d(PREFIX .. "loaded. Right-click a raw material, or /refinecalc [qty] [material]. /refinetest sweeps all to chat.")
    if not menuRegistered then
        d(PREFIX .. "|cFF6666LibCustomMenu missing -- context menu disabled.|r")
    end
    if not (LibPrice and LibPrice.ItemLinkToPriceGold) then
        d(PREFIX .. "|cFF6666LibPrice not loaded -- no prices available. Enable LibPrice and tick Allow out of date add-ons.|r")
    end
end

local function OnAddOnLoaded(event, addonName)
    if addonName ~= RC.name then return end
    EVENT_MANAGER:UnregisterForEvent(RC.name, EVENT_ADD_ON_LOADED)

    SLASH_COMMANDS["/refinetest"] = OnSlashTest
    SLASH_COMMANDS["/refinecalc"] = OnSlashCalc
    menuRegistered = RegisterContextMenu()

    -- Chat is not reliably up during add-on load, and ATT does not populate its
    -- sales data until EVENT_PLAYER_ACTIVATED, so greet there instead.
    EVENT_MANAGER:RegisterForEvent(RC.name .. "_Activated", EVENT_PLAYER_ACTIVATED, OnPlayerActivated)
end

EVENT_MANAGER:RegisterForEvent(RC.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)
