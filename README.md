# Refining Profit Calculator

An Elder Scrolls Online addon that answers three questions about refining raw
crafting materials:

- **Should I refine this or sell it raw?** — a full breakdown per material.
- **Which ore is worth buying?** — a ranking of every material by margin.
- **Did refining actually pay?** — recorded results from your own refining,
  checked against the model.

Covers all 45 materials across Blacksmithing, Clothing, Woodworking and Jewelry.

## Install

Clone into your AddOns folder so the repository root *is* the addon folder:

```
.../Elder Scrolls Online/live/AddOns/RefiningCalculator/
```

Enable it in the in-game Add-Ons menu, then `/reloadui`.

### Dependencies

| Addon | Required | Why |
| --- | --- | --- |
| [LibCustomMenu](https://www.esoui.com/downloads/info1146) | yes | inventory right-click entry |
| [LibPrice](https://www.esoui.com/downloads/info2187) | in practice | all price lookups |
| Master Merchant / ATT / TTC | at least one | LibPrice reads prices from these |

Without LibPrice there are no prices and the addon says so rather than showing
nothing. LibPrice itself is often flagged out of date — tick **Allow out of date
add-ons**, which you likely need for TTC anyway.

## Using it

Right-click any raw material in your bag, bank or craft bag and pick
**Refining profit**. Or:

| Command | Does |
| --- | --- |
| `/refinecalc [qty] [material]` | opens the window, e.g. `/refinecalc silk` |
| `/refinebest` | opens the ranking |
| `/refinestats` | opens recorded statistics |
| `/refinestats reset` | clears recorded statistics |
| `/refinetest [qty] [craft]` | prints a sweep to chat |

The window has three views, cycled by the top-left button.

### Detail

One material, per 200 raw. Every input is listed — raw price, refined price, and
each temper with its expected quantity — then the two options with guild store
fees as a separate line, and the net between them. Your actual holdings appear
only in the stock line at the bottom; everything above is per 200 so materials
stay comparable.

Prices come from Master Merchant, Arkadius' Trade Tools, Tamriel Trade Centre, or
a blend of whichever have data. The source used is shown per row. Hovering an
item name raises its normal tooltip, so the price shown can be checked against
what TTC and ATT report themselves.

### Find best

Every material ranked for a buyer:

| Column | Meaning |
| --- | --- |
| Market | current price per raw |
| Pay up to | most you can pay per raw and still break even |
| Margin | return on gold spent at the current market price |
| Listings | how many listings or sales back that price |

**Pay up to** is the number for spotting a deal — see an ore under it, buy it.
It is also the farming number: if you gathered the material, the raw is free, so
that figure is what each node is worth refined.

Materials with fewer than 50 listings are hidden by default, because a fat margin
on two stale listings is not an opportunity. The threshold cycles 0 to 250.

### Statistics

Refining results are recorded automatically and compared against the model.
The overview tab shows, per craft, what the raw you consumed would have sold for
against what the output is worth. Each craft tab breaks that down: refined yield
and every temper, as real counts and as rates, against expected.

Samples are split by whether Meticulous Disassembly was active, since the
expected rates differ. Gold values both sides at today's prices, so it answers
"was refining the right call" rather than "what did I bank that day".

Statistics persist across sessions, account-wide, per megaserver.

## Where the numbers come from

Temper drop rates are from a community refining survey of 9,962,230 raw
materials, which concludes Meticulous Disassembly is a flat +12.5% on the
pre-2021 rates:

| | green | blue | purple | gold | combined |
| --- | --- | --- | --- | --- | --- |
| MD active | 16.875% | 14.063% | 8.438% | 5.625% | 45.00% |
| MD inactive | 15.000% | 12.500% | 7.500% | 5.000% | 40.00% |

Guild store fees are not hardcoded — `GetTradingHousePostPriceInfo` is asked for
the listing fee and trader cut, so they track whatever the current rates are.

**One number has no published source**: `refinedPerRaw`, the refined materials
produced per raw, set to `0.85`. It also depends on your extraction passives.
The statistics view exists largely to verify it against your own refining.

## License

MIT. See [LICENSE](LICENSE).
