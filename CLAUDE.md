# Working on this addon

Notes for future sessions. README.md covers what the addon does; this covers how
it is built and what has already bitten.

## The practice that matters most

**This is ESO Lua. There is no interpreter here and the game cannot be run from
this environment, so nothing is ever executed before it ships.** The only defence
is verifying every API against the ~100 other addons installed alongside this one
in `live/AddOns/`.

Before using any ESO global or API, check it appears in at least two other
addons:

```bash
cd ..; grep -rl "\bGetItemLinkStacks\b" --include=*.lua . | grep -v RefiningCalculator | wc -l
```

Sweep everything at once before committing:

```bash
cd ..; SYMS=$(cat RefiningCalculator/*.lua | grep -ohE "\b(EVENT_[A-Z_]+|SLOT_TYPE_[A-Z_]+|CT_[A-Z]+|ZO_[A-Za-z_]+|Get[A-Za-z]+|Set[A-Za-z]+)\b" | sort -u)
for s in $SYMS; do n=$(grep -rl "\b$s\b" --include=*.lua . 2>/dev/null | grep -v "^./RefiningCalculator/" | wc -l); [ "$n" -lt 2 ] && echo "$s only $n"; done
```

Anything reported should be a local function of ours, or already verified by
reading its definition directly. This has caught real bugs more than once.

The IDE's Lua diagnostics are configured for Lua 5.4, so they are noisy and
partly wrong here: `unpack` is correct (ESO is 5.1), and every ESO global reads
as undefined. **Do not dismiss the whole list** — a real `EVENT_ADDON_LOADED`
typo once hid among that noise for several commits.

## Layout

Three files, load order enforced by the manifest — both later files bind
`RefiningCalculator` at file scope:

| File | Holds |
| --- | --- |
| `RefiningCalculator.lua` | data, pricing, the model, `Evaluate`, chat output, slash commands, init |
| `RefiningCalculatorStats.lua` | observing real refines, saved variables |
| `RefiningCalculatorUI.lua` | the window: all three views |

The UI renders whatever `RC.Evaluate` / `RC.Stats.Summary` return and computes
nothing itself, so the model stays UI-agnostic.

### Data shape

`CRAFTS` is the single source of truth. Refining outcome is identical within a
craft — only the ore→ingot mapping varies — so **tempers hang off the craft** and
a material is just `{tier, raw, refined}` inside it. A flatten pass attaches
`mat.craft` so tempers travel with each material. Adding a tier is one line.

Display names come from `GetItemLinkName` at runtime. There are deliberately no
hand-typed material labels to drift or mistranslate.

## Traps already hit

**`EVENT_ADDON_LOADED` does not exist.** It is `EVENT_ADD_ON_LOADED` — `ADD_ON`,
two words. The wrong spelling is `nil`, `RegisterForEvent` accepts it silently,
and the addon simply never initialises with no error anywhere.

**`x and nil or y` is always `y` in Lua.** `x and nil` is falsy so the or-branch
always wins. This made every temper row render in the warning colour. Never use
the and/or idiom when the true-branch can be `nil` or `false`.

**`ItemTooltip:SetLink` loses TTC prices.** TTC hooks `SetLink` only on
`PopupTooltip`; on `ItemTooltip` it hooks `SetBagItem`/`SetLootItem`/etc.
instead. ATT hooks both. Use `PopupTooltip` or you silently get ATT's prices and
not TTC's.

**`GetItemQualityColor` returns different shapes** — a `ZO_ColorDef` on some
client versions, plain `r,g,b,a` on others. Handling one made every row fall back
to grey. (Item colouring is currently reverted; if it returns, handle both.)

**`LibPrice.ItemLinkToPriceGold` does not blend.** It walks its source list and
returns the *first* source with data. Pass a source key to restrict it; blending
is done here by averaging. It also prefers TTC's `SuggestedPrice`, which is
deliberately conservative and made every TTC figure read as the market floor —
hence reading `Avg` from `ItemLinkToPriceData` instead.

**LibPrice drops ATT's counts.** Its ATT normalizer literally reads
`-- TODO: Count`, so sales volume is queried from ATT directly via
`GetItemSalesInformation`.

**Indexing a table with a `nil` constant is a load-time error.** `MENU_SLOT_TYPES`
looks its slot types up by name through `_G` so a constant that disappears is
skipped rather than killing the file. A literal list would truncate at the first
`nil` instead, which is quieter and worse.

## Conventions

Everything is per `RC.BATCH` (200 raw) so materials stay comparable with each
other and with the guild store, where a stack is 200. Actual inventory enters
only in the stock line.

Comments explain **why**, not what — particularly where a non-obvious API or
ordering choice would otherwise look arbitrary and get "simplified" later.

Numbers shown should be checkable in game. Prices are the average, because that
is what TTC and ATT show in their own tooltips; `Listings` is `EntryCount` for
the same reason. Do not swap in a figure the player cannot see somewhere else.

## Verifying data, not just APIs

Item IDs were generated mechanically from
`AwesomeGuildStore/data/ItemRequirementLevelRanges.lua`, which names every
crafting material, then cross-checked against Dustman and LootDrop. **Do not
hand-type item IDs.** Transcription caught a real bug this way: 71200 is Raw
Ancestor Silk and 71239 is Rubedo Leather Scraps, and they had been swapped.

Temper IDs came from
`ArkadiusTradeTools/ArkadiusTradeToolsSales/ArkadiusTradeToolsCraftingInfo.lua`.

## Statistics

`EVENT_CRAFT_COMPLETED` says a craft finished but carries no results, so counts
are snapshotted at the station and diffed after each completion. It counts as a
refine only when **exactly one tracked raw material fell, by a whole number of
refinement stacks** — deconstruction consumes no raw material and crafting
consumes refined, so neither can be mistaken for one.

Counts sum bag + bank + craft bag: output goes to the craft bag with ESO Plus and
the backpack without.

Samples are bucketed by Meticulous Disassembly state, because expected rates
differ by 12.5% and pooling would make both comparisons wrong.

Saved variables are account-wide, per megaserver, version `1`. Bumping the
version discards existing data — leave it unless the shape must change
incompatibly. `BucketFor` backfills missing buckets so older files still load.

## Open items

- **Nothing here has been run.** Especially the statistics path — the event and
  diff detection is reasoned from the API, not observed.
- `RC.refinedPerRaw = 0.85` is player-supplied, not sourced. The statistics view
  exists to verify it.
- Statistics measure the *value* of output, not what it sold for. Tying recorded
  output to actual ATT sales would close that loop into a true ledger.
- Window position is not persisted across `/reloadui`.
- The window is a plain top-level control, so it does not hide with game scenes.
