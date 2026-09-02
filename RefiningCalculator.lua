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

-- Refining outcome is identical within a craft: the only thing that varies from
-- one material to the next is which ore maps to which ingot. Tempers therefore
-- hang off the craft, and a material is just a raw -> refined pair inside it.
-- Honing Stone is the same item whether you refine Iron or Rubedite.
--
-- Temper IDs verified against ArkadiusTradeToolsCraftingInfo.lua.
-- Material IDs generated from AwesomeGuildStore's ItemRequirementLevelRanges.lua
-- (which names every one), cross-checked against Dustman and LootDrop.
local CRAFTS = {
    {
        key = "BLACKSMITHING", label = "Blacksmithing", short = "BS",
        tempers = { green = 54170, blue = 54171, purple = 54172, gold = 54173 },
        materials = {
            { tier =  1, raw = 808   , refined = 5413   },
            { tier =  2, raw = 5820  , refined = 4487   },
            { tier =  3, raw = 23103 , refined = 23107  },
            { tier =  4, raw = 23104 , refined = 6000   },
            { tier =  5, raw = 23105 , refined = 6001   },
            { tier =  6, raw = 4482  , refined = 46127  },
            { tier =  7, raw = 23133 , refined = 46128  },
            { tier =  8, raw = 23134 , refined = 46129  },
            { tier =  9, raw = 23135 , refined = 46130  },
            { tier = 10, raw = 71198 , refined = 64489  },
        },
    },
    {
        key = "CLOTHING", label = "Clothing", short = "CL",
        tempers = { green = 54174, blue = 54175, purple = 54176, gold = 54177 },
        materials = {
            { tier =  1, raw = 812   , refined = 811    },
            { tier =  1, raw = 793   , refined = 794    },
            { tier =  2, raw = 4464  , refined = 4463   },
            { tier =  2, raw = 4448  , refined = 4447   },
            { tier =  3, raw = 23129 , refined = 23125  },
            { tier =  3, raw = 23095 , refined = 23099  },
            { tier =  4, raw = 23130 , refined = 23126  },
            { tier =  4, raw = 6020  , refined = 23100  },
            { tier =  5, raw = 23131 , refined = 23127  },
            { tier =  5, raw = 23097 , refined = 23101  },
            { tier =  6, raw = 33217 , refined = 46131  },
            { tier =  6, raw = 23142 , refined = 46135  },
            { tier =  7, raw = 33218 , refined = 46132  },
            { tier =  7, raw = 23143 , refined = 46136  },
            { tier =  8, raw = 33219 , refined = 46133  },
            { tier =  8, raw = 800   , refined = 46137  },
            { tier =  9, raw = 33220 , refined = 46134  },
            { tier =  9, raw = 4478  , refined = 46138  },
            { tier = 10, raw = 71200 , refined = 64504  },
            { tier = 10, raw = 71239 , refined = 64506  },
        },
    },
    {
        key = "WOODWORKING", label = "Woodworking", short = "WW",
        tempers = { green = 54178, blue = 54179, purple = 54180, gold = 54181 },
        materials = {
            { tier =  1, raw = 802   , refined = 803    },
            { tier =  2, raw = 521   , refined = 533    },
            { tier =  3, raw = 23117 , refined = 23121  },
            { tier =  4, raw = 23118 , refined = 23122  },
            { tier =  5, raw = 23119 , refined = 23123  },
            { tier =  6, raw = 818   , refined = 46139  },
            { tier =  7, raw = 4439  , refined = 46140  },
            { tier =  8, raw = 23137 , refined = 46141  },
            { tier =  9, raw = 23138 , refined = 46142  },
            { tier = 10, raw = 71199 , refined = 64502  },
        },
    },
    {
        key = "JEWELRY", label = "Jewelry", short = "JW",
        tempers = { green = 203631, blue = 203632, purple = 203633, gold = 203634 },
        materials = {
            { tier = 1, raw = 135137, refined = 135138 },
            { tier = 2, raw = 135139, refined = 135140 },
            { tier = 3, raw = 135141, refined = 135142 },
            { tier = 4, raw = 135143, refined = 135144 },
            { tier = 5, raw = 135145, refined = 135146 },
        },
    },
}

-- Flattened, each entry carrying a reference back to its craft so the tempers
-- travel with it. Display names come from the game at runtime, so there are no
-- hand-typed labels to drift or mistranslate.
local MATERIALS = {}
local BY_RAW_ID = {}
for _, craft in ipairs(CRAFTS) do
    for _, mat in ipairs(craft.materials) do
        mat.craft = craft
        MATERIALS[#MATERIALS + 1] = mat
        BY_RAW_ID[mat.raw] = mat
    end
end

RC.CRAFTS = CRAFTS

-- Opening on Iron would be a poor first impression; the top tier is the case
-- people actually weigh up.
RC.DEFAULT_MATERIAL = MATERIALS[1]
for _, mat in ipairs(CRAFTS[1].materials) do
    if mat.tier > RC.DEFAULT_MATERIAL.tier then RC.DEFAULT_MATERIAL = mat end
end

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

-- The three price scenarios carried through every calculation.
local BANDS = { "low", "mid", "high" }
RC.BANDS = BANDS

function RC.RawLink(mat)     return Link(mat.raw) end
function RC.RefinedLink(mat) return Link(mat.refined) end
function RC.TemperLink(craft, tier) return Link(craft.tempers[tier], SUBTYPE[tier]) end

--------------------------------------------------------------------------------
-- Meticulous Disassembly detection
--------------------------------------------------------------------------------

-- Champion skill 83. A slottable star only applies while it is on the champion
-- bar, so points spent alone is not enough -- both are checked.
local MET_DIS_ID = 83
local CHAMPION_BAR_SLOTS = 12

local function GetMeticulousDisassembly()
    local spent    = GetNumPointsSpentOnChampionSkill(MET_DIS_ID) or 0
    local maxPts   = GetChampionSkillMaxPoints(MET_DIS_ID) or 50
    local invested = spent >= maxPts

    -- Ask the game whether this star is slottable rather than assuming it is.
    -- A passive star applies from invested points alone; only a slottable one
    -- has to be on the champion bar to do anything.
    local slottable = false
    if GetChampionSkillType and CanChampionSkillTypeBeSlotted then
        slottable = CanChampionSkillTypeBeSlotted(GetChampionSkillType(MET_DIS_ID)) and true or false
    end

    local slotted = false
    if slottable then
        for i = 1, CHAMPION_BAR_SLOTS do
            if GetSlotBoundId(i, HOTBAR_CATEGORY_CHAMPION) == MET_DIS_ID then
                slotted = true
                break
            end
        end
    end

    return {
        spent     = spent,
        maxPts    = maxPts,
        invested  = invested,
        slottable = slottable,
        slotted   = slotted,
        active    = invested and (not slottable or slotted),
    }
end

-- Returns plain text plus a state key, so chat can wrap it in colour codes and
-- the window can colour the label instead. Neither has to parse the other.
function RC.DescribeMD(md)
    if md.active then
        return string.format("Meticulous Disassembly active (%d/%d%s)",
            md.spent, md.maxPts, md.slottable and ", slotted" or ""), "active"
    elseif md.invested and md.slottable and not md.slotted then
        return string.format("MD maxed (%d/%d) but NOT slotted -- using base rates",
            md.spent, md.maxPts), "partial"
    elseif md.spent > 0 then
        return string.format("MD only %d/%d points -- using base rates, real yield is between the two",
            md.spent, md.maxPts), "partial"
    end
    return string.format("MD not invested (%d/%d) -- using base rates",
        md.spent, md.maxPts), "inactive"
end

local MD_COLOR = { active = "|c00FF00", partial = "|cFFAA00", inactive = "|cFFAA00" }

RC.GetMD = GetMeticulousDisassembly

--------------------------------------------------------------------------------
-- Pricing
--------------------------------------------------------------------------------

-- LibPrice does NOT blend: ItemLinkToPriceGold walks its source list and returns
-- the first source that has data, so "whatever LibPrice felt like" was really
-- Master Merchant, then ATT, then TTC. Passing a source key restricts it to that
-- one, which is what lets us offer them explicitly and average them ourselves.
--
-- It still handles TTC rows with no SuggestedPrice by falling through to Avg.
--
-- Deliberately excludes LibPrice's npc / crown / rolis / furc sources: an NPC
-- vendor price is not a market price and would wreck an average.
RC.MARKET_SOURCES = { "mm", "att", "ttc" }

RC.PRICE_SOURCES = {
    { key = "blend", label = "Blended (average)" },
    { key = "mm",    label = "Master Merchant",   probe = "CanMMPrice"  },
    { key = "att",   label = "Arkadius (ATT)",    probe = "CanATTPrice" },
    { key = "ttc",   label = "Trade Centre (TTC)", probe = "CanTTCPrice" },
}

RC.priceSource = "blend"

-- True if the addon behind a source is actually loaded and ready.
function RC.SourceAvailable(entry)
    if not LibPrice then return false end
    if not entry.probe then return true end
    local probe = LibPrice[entry.probe]
    return probe ~= nil and probe() and true or false
end

-- One source's low / mid / high, from the raw per-source data rather than
-- ItemLinkToPriceGold. That matters because ItemLinkToPriceGold prefers TTC's
-- SuggestedPrice, which is a deliberately conservative figure -- it was making
-- every TTC number look like the bottom of the market.
--
-- TTC carries a real spread (Min / Avg / Max). MM and ATT report a single
-- average, so for them low = mid = high and they simply do not widen the range.
local function SourceRange(itemLink, key)
    local data = LibPrice.ItemLinkToPriceData(itemLink, key)
    local info = data and data[key]
    if not info then return nil end

    if key == "ttc" then
        local mid = info.Avg or info.SuggestedPrice
        if not mid or mid <= 0 then return nil end
        return {
            low  = info.Min or info.SuggestedPrice or mid,
            mid  = mid,
            high = info.Max or mid,
        }
    end

    local avg = info.avgPrice or info.Avg or info.price
    if not avg or avg <= 0 then return nil end
    return { low = avg, mid = avg, high = avg }
end

-- Ranking evaluates every material at once, which asks about ~106 distinct
-- items. ATT answers each by scanning its sales history twice (a 3-day window,
-- then a 90-day one), so doing that uncached would stutter badly. Cached for the
-- session; the window's Refresh button and any source change clear it.
local priceCache = {}

function RC.ClearPriceCache()
    priceCache = {}
end

-- Returns a {low, mid, high} table plus a source label, or nil.
local function GetPrice(itemLink)
    if not (LibPrice and LibPrice.ItemLinkToPriceData) then return nil, "nolib" end

    local cacheKey = RC.priceSource .. "\t" .. itemLink
    local hit = priceCache[cacheKey]
    if hit ~= nil then
        if hit == false then return nil, "nodata" end
        return hit.price, hit.source
    end

    local keys
    if RC.priceSource == "blend" then
        keys = RC.MARKET_SOURCES
    else
        keys = { RC.priceSource }
    end

    -- Unweighted mean across whichever sources have data. Equal weighting is
    -- deliberate: sale counts are not comparable across these addons.
    local low, mid, high, count, used = 0, 0, 0, 0, {}
    for _, key in ipairs(keys) do
        local r = SourceRange(itemLink, key)
        if r then
            low, mid, high = low + r.low, mid + r.mid, high + r.high
            count = count + 1
            used[#used + 1] = key
        end
    end
    if count == 0 then
        priceCache[cacheKey] = false
        return nil, "nodata"
    end

    local price = {
        low  = low / count,
        mid  = mid / count,
        high = high / count,
    }
    local source = table.concat(used, "+")
    priceCache[cacheKey] = { price = price, source = source }
    return price, source
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

-- Item quality colour, so a Dreugh Wax row reads gold and a Honing Stone green.
-- ZO_ColorDef:New(GetItemQualityColor(q)) is ATT's proven call shape.
function RC.QualityColor(itemLink)
    local getQuality = GetItemLinkDisplayQuality or GetItemLinkQuality
    if not (getQuality and GetItemQualityColor and ZO_ColorDef) then return nil end
    local quality = getQuality(itemLink)
    if not quality then return nil end
    local color = ZO_ColorDef:New(GetItemQualityColor(quality))
    if not (color and color.UnpackRGBA) then return nil end
    local r, g, b, a = color:UnpackRGBA()
    if not r then return nil end
    return { r, g, b, a or 1 }
end

-- Names come from the game, so they are correct and localised without a table
-- of hand-typed labels. Cached because the dropdown asks for all 45 at once.
local labelCache = {}
function RC.MaterialLabel(mat)
    local cached = labelCache[mat.refined]
    if cached then return cached end
    local name = ItemName(RC.RefinedLink(mat))
    if not name or name == "" or name == "?" then
        name = string.format("%s tier %d", mat.craft.label, mat.tier)
    end
    labelCache[mat.refined] = name
    return name
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
    local craft     = mat.craft

    local rawLink     = RC.RawLink(mat)
    local refinedLink = RC.RefinedLink(mat)

    local pRaw,     rawSrc     = GetPrice(rawLink)
    local pRefined, refinedSrc = GetPrice(refinedLink)

    if not pRaw then
        return nil, string.format("no price data for %s", rawLink)
    end
    if not pRefined then
        return nil, string.format("no price data for %s", refinedLink)
    end

    local rows, missing = {}, {}
    local temperGold = { low = 0, mid = 0, high = 0 }
    for _, tier in ipairs(TIERS) do
        local link       = RC.TemperLink(craft, tier)
        local price, src = GetPrice(link)
        local count      = quantity * (rates[tier] / perRefine)
        if price then
            for _, band in ipairs(BANDS) do
                temperGold[band] = temperGold[band] + count * price[band]
            end
        else
            missing[#missing + 1] = link
        end
        rows[#rows + 1] = {
            tier = tier, link = link, price = price, source = src, count = count,
            gold = price and {
                low = count * price.low, mid = count * price.mid, high = count * price.high,
            } or nil,
        }
    end

    local refinedQty = quantity * RC.refinedPerRaw

    -- Three parallel scenarios. Everything is gross until TaxOn, which is
    -- applied once per option per band at the very end.
    local sellRawGross, refineGross, refinedGold = {}, {}, {}
    local rawNet, refineNet, net = {}, {}, {}
    local rawFee, rawCut, refineFee, refineCut = {}, {}, {}, {}
    local taxed = true

    for _, band in ipairs(BANDS) do
        refinedGold[band]  = refinedQty * pRefined[band]
        sellRawGross[band] = quantity * pRaw[band]
        refineGross[band]  = refinedGold[band] + temperGold[band]

        local rf, rc, rn = TaxOn(sellRawGross[band])
        local ff, fc, fn = TaxOn(refineGross[band])
        if rn == nil or fn == nil then
            taxed = false
            rn, fn = sellRawGross[band], refineGross[band]
        end
        rawFee[band], rawCut[band], rawNet[band] = rf or 0, rc or 0, rn
        refineFee[band], refineCut[band], refineNet[band] = ff or 0, fc or 0, fn
        net[band] = fn - rn
    end

    return {
        mat = mat, quantity = quantity, md = md, perRefine = perRefine,
        rawLink = rawLink, refinedLink = refinedLink,
        pRaw = pRaw, rawSource = rawSrc,
        pRefined = pRefined, refinedSource = refinedSrc,
        refinedQty = refinedQty, refinedGold = refinedGold,
        rows = rows, missing = missing, temperGold = temperGold,
        sellRawGross = sellRawGross, refineGross = refineGross,
        taxed = taxed,
        rawFee = rawFee, rawCut = rawCut, rawNet = rawNet,
        refineFee = refineFee, refineCut = refineCut, refineNet = refineNet,
        net = net,
        -- Net scales linearly with quantity, so a per-batch figure is just a
        -- rescale. Useful because "your whole stock" is not a comparable unit
        -- between materials or between sessions.
        netPerRaw = quantity > 0 and (net.mid / quantity) or 0,
    }
end

-- Net gain/loss for a standard batch, from an already-evaluated result.
function RC.NetPer(r, batch, band)
    if r.quantity <= 0 then return 0 end
    return r.net[band or "mid"] / r.quantity * batch
end

-- Two different questions, so both are reported and either can sort:
--
--   net    -- refining beats selling the raw. The right measure when you
--             already hold the material and are deciding what to do with it.
--   refine -- what the refined output is worth, full stop. The right measure
--             when you are farming nodes, because then the raw cost is sunk and
--             "would it have sold for more raw" does not enter into it.
--
-- A material can rank high on one and poorly on the other.
RC.RANK_SORTS = {
    { key = "net",    label = "Sort: net gain" },
    { key = "refine", label = "Sort: refined value" },
}

-- Evaluates every material. Returns a list of entries, unsorted.
function RC.RankAll(batch)
    batch = batch or 200
    local list = {}
    for _, mat in ipairs(MATERIALS) do
        local r = RC.Evaluate(mat, batch)
        if r then
            list[#list + 1] = {
                mat    = mat,
                result = r,
                net    = r.net.mid,
                refine = r.refineNet.mid,
                netLow = r.net.low,
                netHigh = r.net.high,
            }
        end
    end
    return list
end

function RC.SortRanking(list, sortKey)
    local key = (sortKey == "refine") and "refine" or "net"
    table.sort(list, function(a, b)
        if a[key] ~= b[key] then return a[key] > b[key] end
        return RC.MaterialLabel(a.mat) < RC.MaterialLabel(b.mat)
    end)
    return list
end

function RC.Report(mat, quantity)
    local r, err = RC.Evaluate(mat, quantity)
    if not r then
        d(PREFIX .. "|cFF6666" .. err .. "|r")
        if not (LibPrice and LibPrice.ItemLinkToPriceData) then
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
    d(string.format("|cFFFF00=== %s (%s) -- %s raw ===|r",
        RC.MaterialLabel(r.mat), r.mat.craft.label, Gold(r.quantity)))
    d("  " .. MD_COLOR[mdState] .. mdText .. "|r")
    d("|c888888" .. Row("Item", "Src", "Price", "Qty", "Value") .. "|r")
    d(Row(ItemName(r.rawLink), r.rawSource, Gold(r.pRaw.mid),
        Gold(r.quantity), Gold(r.sellRawGross.mid)))

    d("|c888888  -- or refine into --|r")
    d(Row(ItemName(r.refinedLink), r.refinedSource, Gold(r.pRefined.mid),
        string.format("%.1f", r.refinedQty), Gold(r.refinedGold.mid)))

    for _, row in ipairs(r.rows) do
        if row.price then
            d(Row(ItemName(row.link), row.source, Gold(row.price.mid),
                string.format("%.2f", row.count), Gold(row.gold.mid)))
        else
            d(Row(ItemName(row.link), "--", "|cFF6666no data|r",
                string.format("%.2f", row.count), "0"))
        end
    end

    -- Summary spans the three price scenarios instead of one figure.
    d("|c888888" .. Row("", "", "Low", "Expected", "High") .. "|r")

    local function Band(label, t)
        return string.format(FMT, label, "", Gold(t.low), Gold(t.mid), Gold(t.high))
    end
    d(Band("Sell raw (gross)", r.sellRawGross))
    d(Band("  after fees", r.rawNet))
    d(Band("Refine (gross)", r.refineGross))
    d(Band("  after fees", r.refineNet))

    local function Signed(v)
        return (v >= 0 and "+" or "-") .. Gold(v >= 0 and v or -v) .. "g"
    end
    d(string.format(FMT, "Net", "", Signed(r.net.low), Signed(r.net.mid), Signed(r.net.high)))

    if r.net.mid >= 0 then
        d(string.format("  |c00FF00=> REFINE, +%sg expected|r", Gold(r.net.mid)))
    else
        d(string.format("  |cFF4444=> SELL RAW, refining loses %sg expected|r", Gold(-r.net.mid)))
    end
    d(string.format("  |c888888per 200 raw: %s (low %s, high %s)|r",
        Signed(RC.NetPer(r, 200)), Signed(RC.NetPer(r, 200, "low")), Signed(RC.NetPer(r, 200, "high"))))

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
-- Sweeping all 45 materials would be several hundred chat lines, so the default
-- is the top tier of each craft. Name a craft to sweep every tier of that one:
--   /refinetest 200 clothing
local function OnSlashTest(args)
    args = args or ""
    local quantity = tonumber(args:match("(%d+)")) or 200
    local want = args:gsub("%d+", ""):gsub("^%s*(.-)%s*$", "%1"):lower()

    local list, what = {}, ""
    if want ~= "" then
        for _, craft in ipairs(CRAFTS) do
            if craft.label:lower():find(want, 1, true) then
                list, what = craft.materials, craft.label .. ", all tiers"
                break
            end
        end
        if #list == 0 then
            d(PREFIX .. "|cFF6666no craft matching '" .. want .. "'|r")
            return
        end
    else
        for _, craft in ipairs(CRAFTS) do
            local top
            for _, mat in ipairs(craft.materials) do
                if not top or mat.tier > top.tier then top = mat end
            end
            -- Clothing's top tier is two materials (cloth and leather).
            for _, mat in ipairs(craft.materials) do
                if mat.tier == top.tier then list[#list + 1] = mat end
            end
        end
        what = "top tier of each craft"
    end

    d(PREFIX .. string.format("Evaluating %s at %d raw each...", what, quantity))
    for _, mat in ipairs(list) do
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
            if RC.MaterialLabel(m):lower():find(name, 1, true) then mat = m break end
        end
        if not mat then
            d(PREFIX .. "|cFF6666no material matching '" .. name .. "'|r")
            return
        end
    end

    RC.UI:Toggle(mat or RC.UI.mat or RC.DEFAULT_MATERIAL, quantity)
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local menuRegistered = false

local function OnPlayerActivated()
    EVENT_MANAGER:UnregisterForEvent(RC.name .. "_Activated", EVENT_PLAYER_ACTIVATED)

    d(PREFIX .. "loaded. Right-click a raw material, /refinecalc [qty] [material], or /refinebest to rank everything.")
    if not menuRegistered then
        d(PREFIX .. "|cFF6666LibCustomMenu missing -- context menu disabled.|r")
    end
    if not (LibPrice and LibPrice.ItemLinkToPriceData) then
        d(PREFIX .. "|cFF6666LibPrice not loaded -- no prices available. Enable LibPrice and tick Allow out of date add-ons.|r")
    end
end

local function OnAddOnLoaded(event, addonName)
    if addonName ~= RC.name then return end
    EVENT_MANAGER:UnregisterForEvent(RC.name, EVENT_ADD_ON_LOADED)

    SLASH_COMMANDS["/refinetest"] = OnSlashTest
    SLASH_COMMANDS["/refinecalc"] = OnSlashCalc
    SLASH_COMMANDS["/refinebest"] = function()
        if RC.UI then RC.UI:ShowRanking() end
    end
    menuRegistered = RegisterContextMenu()

    -- Chat is not reliably up during add-on load, and ATT does not populate its
    -- sales data until EVENT_PLAYER_ACTIVATED, so greet there instead.
    EVENT_MANAGER:RegisterForEvent(RC.name .. "_Activated", EVENT_PLAYER_ACTIVATED, OnPlayerActivated)
end

EVENT_MANAGER:RegisterForEvent(RC.name, EVENT_ADD_ON_LOADED, OnAddOnLoaded)
