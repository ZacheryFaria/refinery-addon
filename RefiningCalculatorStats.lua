-- RefiningCalculator -- observed refining statistics
--
-- Records what refining actually produced, so the model's numbers can be
-- checked against reality rather than taken on faith. The refined-per-raw
-- figure in particular has no published source; this is how it gets verified.
--
-- Method: EVENT_CRAFT_COMPLETED tells us a craft finished but carries no
-- results, so counts are snapshotted at the station and diffed after each
-- completion.
--
-- A completion counts as a refine only when exactly one tracked RAW material
-- fell, by a whole number of refinement stacks. That is a reliable signature:
-- deconstructing an item consumes no raw material, and crafting an item
-- consumes REFINED material, not raw. So neither can be mistaken for a refine.

local RC = RefiningCalculator
local Stats = {}
RC.Stats = Stats

local TIERS = { "green", "blue", "purple", "gold" }

local function NewBucket()
    return { refines = 0, raw = 0, refined = 0, green = 0, blue = 0, purple = 0, gold = 0 }
end

--------------------------------------------------------------------------------
-- Counting
--------------------------------------------------------------------------------

-- Bag, bank and craft bag together. Refined materials and tempers land in the
-- craft bag for ESO Plus subscribers and the backpack otherwise, so all three
-- have to be summed for the diff to be meaningful either way.
local function CountOf(itemLink)
    if not GetItemLinkStacks then return 0 end
    local backpack, bank, craftBag = GetItemLinkStacks(itemLink)
    return (backpack or 0) + (bank or 0) + (craftBag or 0)
end

-- Snapshot only the craft currently being used: its raws, refined and tempers.
local function Snapshot(craft)
    local snap = { raw = {}, refined = {}, tempers = {} }
    for _, mat in ipairs(craft.materials) do
        snap.raw[mat.raw] = CountOf(RC.RawLink(mat))
        snap.refined[mat.refined] = CountOf(RC.RefinedLink(mat))
    end
    for _, tier in ipairs(TIERS) do
        snap.tempers[tier] = CountOf(RC.TemperLink(craft, tier))
    end
    return snap
end

--------------------------------------------------------------------------------
-- Recording
--------------------------------------------------------------------------------

function Stats.Initialize()
    local defaults = { samples = {} }
    if ZO_SavedVars then
        Stats.data = ZO_SavedVars:NewAccountWide(
            "RefiningCalculatorStats", 1, nil, defaults, GetWorldName and GetWorldName() or nil)
    else
        Stats.data = defaults
    end
    return Stats.data
end

-- Samples are split by whether Meticulous Disassembly was active, because the
-- expected rates differ. Pooling them would make both comparisons wrong.
local function BucketFor(rawId, mdActive)
    local samples = Stats.data and Stats.data.samples
    if not samples then return nil end
    local perItem = samples[rawId]
    if not perItem then
        perItem = { md = NewBucket(), noMd = NewBucket() }
        samples[rawId] = perItem
    end
    local key = mdActive and "md" or "noMd"
    -- A saved file written before a field existed still needs the field.
    if not perItem[key] then perItem[key] = NewBucket() end
    return perItem[key]
end

function Stats.OnStationInteract(craftSkill)
    Stats.craft = nil
    Stats.snapshot = nil
    for _, craft in ipairs(RC.CRAFTS) do
        local craftingType = _G[craft.craftingTypeName]
        if craftingType and craftingType == craftSkill then
            Stats.craft = craft
            Stats.snapshot = Snapshot(craft)
            return
        end
    end
end

function Stats.OnStationEnd()
    Stats.craft = nil
    Stats.snapshot = nil
end

function Stats.OnCraftCompleted()
    local craft, before = Stats.craft, Stats.snapshot
    if not (craft and before) then return end

    local after = Snapshot(craft)
    Stats.snapshot = after

    -- Find the single raw material that fell.
    local usedMat, usedCount = nil, 0
    for _, mat in ipairs(craft.materials) do
        local delta = (before.raw[mat.raw] or 0) - (after.raw[mat.raw] or 0)
        if delta > 0 then
            if usedMat then return end  -- more than one fell; not a clean refine
            usedMat, usedCount = mat, delta
        end
    end
    if not usedMat then return end

    local perRefine = RC.StackSize and RC.StackSize() or 10
    if perRefine <= 0 then return end
    -- Must be a whole number of refinement stacks, or it was not a refine.
    local refines = usedCount / perRefine
    if refines < 1 or refines ~= math.floor(refines) then return end

    local gained = (after.refined[usedMat.refined] or 0) - (before.refined[usedMat.refined] or 0)
    if gained < 0 then gained = 0 end

    local md = RC.GetMD()
    local bucket = BucketFor(usedMat.raw, md.active)
    if not bucket then return end

    bucket.refines = bucket.refines + refines
    bucket.raw     = bucket.raw + usedCount
    bucket.refined = bucket.refined + gained

    for _, tier in ipairs(TIERS) do
        local delta = (after.tempers[tier] or 0) - (before.tempers[tier] or 0)
        if delta > 0 then bucket[tier] = bucket[tier] + delta end
    end
end

function Stats.Reset()
    if Stats.data then Stats.data.samples = {} end
end

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

-- Aggregated observations for one Meticulous Disassembly state.
-- Returns per-craft totals, an overall total, and the expected rates to compare
-- against. Temper rates are game-wide so they aggregate across every craft;
-- refined yield does not, because each craft line has its own extraction
-- passive, so it is reported per craft.
function Stats.Summary(mdActive)
    local key = mdActive and "md" or "noMd"
    local samples = (Stats.data and Stats.data.samples) or {}

    local byCraft, overall = {}, NewBucket()
    local grandRaw, grandOut, anyPriced = 0, 0, false

    for _, craft in ipairs(RC.CRAFTS) do
        local total = NewBucket()
        -- Money has to be valued per material: every tier prices differently, so
        -- a craft-level quantity could not be valued meaningfully.
        local rawGold, outGold, priced = 0, 0, false

        for _, mat in ipairs(craft.materials) do
            local perItem = samples[mat.raw]
            local bucket = perItem and perItem[key]
            if bucket and (bucket.refines or 0) > 0 then
                total.refines = total.refines + (bucket.refines or 0)
                total.raw     = total.raw + (bucket.raw or 0)
                total.refined = total.refined + (bucket.refined or 0)
                for _, tier in ipairs(TIERS) do
                    total[tier] = total[tier] + (bucket[tier] or 0)
                end

                local pRaw = RC.PriceOf(RC.RawLink(mat))
                local pRef = RC.PriceOf(RC.RefinedLink(mat))
                if pRaw then
                    rawGold = rawGold + (bucket.raw or 0) * pRaw
                    priced = true
                end
                if pRef then
                    outGold = outGold + (bucket.refined or 0) * pRef
                    priced = true
                end
            end
        end

        -- Tempers are shared across the craft, so they are valued once here.
        for _, tier in ipairs(TIERS) do
            local count = total[tier]
            if count > 0 then
                local p = RC.PriceOf(RC.TemperLink(craft, tier))
                if p then
                    outGold = outGold + count * p
                    priced = true
                end
            end
        end

        -- Fees land on whichever side is actually sold, exactly as the detail
        -- view applies them, so the two sides stay comparable.
        local rawNet = RC.NetAfterFees(rawGold)
        local outNet = RC.NetAfterFees(outGold)

        byCraft[#byCraft + 1] = {
            craft = craft, total = total,
            priced = priced,
            rawGold = rawNet, outGold = outNet, profit = outNet - rawNet,
        }

        grandRaw = grandRaw + rawNet
        grandOut = grandOut + outNet
        anyPriced = anyPriced or priced

        overall.refines = overall.refines + total.refines
        overall.raw     = overall.raw + total.raw
        overall.refined = overall.refined + total.refined
        for _, tier in ipairs(TIERS) do
            overall[tier] = overall[tier] + total[tier]
        end
    end

    return {
        mdActive = mdActive,
        byCraft  = byCraft,
        overall  = overall,
        expected = RC.ExpectedRates(mdActive),
        tiers    = TIERS,
        priced   = anyPriced,
        rawGold  = grandRaw,
        outGold  = grandOut,
        profit   = grandOut - grandRaw,
    }
end

-- Total refines recorded in the other bucket, so the view can say when samples
-- are sitting under a different Meticulous Disassembly state.
function Stats.CountFor(mdActive)
    local key = mdActive and "md" or "noMd"
    local samples = (Stats.data and Stats.data.samples) or {}
    local n = 0
    for _, perItem in pairs(samples) do
        local bucket = perItem[key]
        if bucket then n = n + (bucket.refines or 0) end
    end
    return n
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

function Stats.Register(addonName)
    Stats.Initialize()

    EVENT_MANAGER:RegisterForEvent(addonName .. "_StationIn",
        EVENT_CRAFTING_STATION_INTERACT, function(_, craftSkill)
            Stats.OnStationInteract(craftSkill)
        end)

    if EVENT_END_CRAFTING_STATION_INTERACT then
        EVENT_MANAGER:RegisterForEvent(addonName .. "_StationOut",
            EVENT_END_CRAFTING_STATION_INTERACT, Stats.OnStationEnd)
    end

    EVENT_MANAGER:RegisterForEvent(addonName .. "_Crafted",
        EVENT_CRAFT_COMPLETED, Stats.OnCraftCompleted)
end
