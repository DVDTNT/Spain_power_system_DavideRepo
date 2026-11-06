# Cross-border exports are already inside the Spanish load series

**Finding.** The hourly Spanish load the market chain runs on
(`Data/ES_old/load/<d_m_yyyy>.csv`, column `-12`) **already contains the net
cross-border export**. Exports must therefore be *relocated* to the border
buses, never *added* to the balance.

This note records the evidence, because getting it backwards costs ~60 GWh/day
of phantom demand and the mistake is not visible in the market-stage results —
only in the network stage and in the CCGT validation.

## Where the load comes from

Section 5 of the paper: *"The time series of total electricity consumption for
Spain has been gathered from ENTSO-E Transparency Platform for 2024."*

The ENTSO-E definition of Total Load is

```
Total Load = net generation + imports − exports − pumping
```

which reads as "exports are **not** in the load". That reading is wrong for this
dataset, and the check below is why.

## The evidence

`Data/OMIE/actual_generation_{July_8,Dec_2}.csv` is a demand-coverage table. Sum
**all** of its columns — the generation categories plus the two international
import columns — and compare against the load series the model uses:

| | 2024-07-08 | 2024-12-02 |
| --- | ---: | ---: |
| Load series used by the model | 737.3 GWh | 697.8 GWh |
| Sum of every OMIE column | 737.3 GWh | 697.8 GWh |
| Difference | **+0.0** | **+0.0** |

It balances to 0.0 GWh on both days, and **hour by hour**, with:

* the MIBEL (Portugal) import column at **0.000 in all 48 hours**, even though
  `Data/crossborder.csv` shows Spain exporting 692–3 899 MW to Portugal in every
  one of them;
* the non-MIBEL (France) import column at 0 in hours 15–20 of 8 July, exactly
  the six hours Spain was exporting to France.

Take 8 July hour 15: load 39 077 MW, OMIE generation columns 39 077 MW, imports
0 MW, exports 4 124 MW. The balance is already exact. If the export were an
additional obligation, Spanish generation would have to be 43 201 MW — adding
the export **breaks** a balance that closes perfectly without it.

### Confirmed by running it

Adding the export as extra demand (the first, wrong implementation) put
59–60 GWh/day into the day-ahead. Every MWh landed on CCGT, because everything
else is already at a cap — wind and solar at the forecast, hydro at the mid-term
budget, nuclear at its must-run floor, CHP at its block:

| DA CCGT energy | 8 Jul | 2 Dec |
| --- | ---: | ---: |
| OMIE cleared (reference) | **0.4 GWh** | **123.1 GWh** |
| model, export dropped | 2.7 GWh | 93.2 GWh |
| model, export **added** | 60.6 GWh | 152.8 GWh |

On 8 July the "fix" moved CCGT from 2.7 to 60.6 GWh against a cleared 0.4 GWh,
and flattened the day-ahead price to 78 EUR/MWh in all 24 hours (the base run
had five midday hours at 58.5). Both are symptoms of demand that is not there.

## What was still wrong, and the fix

The energy is right; its **location** is not. The load is spread over the 1 227
Spanish load buses in proportion to `Data/load.csv`, so the exported power is
consumed in Madrid/Barcelona/Valencia instead of leaving through the border.
The 5 Portuguese and 4 French buses in `Data/Bus_Data.csv` carry **zero** demand
share, and in an export hour `prepare_network` skipped the cross-border unit
entirely, leaving those buses completely idle.

Measured on the AC redispatch (sum of |flow| over the border lines, 8 July):

| hour | PT border lines | FR border lines | actual export to PT |
| ---: | ---: | ---: | ---: |
| 0 | 5.9 MW | 1 623 MW | 692 MW |
| 12 | 9.3 MW | 1 969 MW | 3 675 MW |
| 15 | 9.7 MW | **0.0 MW** | 3 386 MW |
| 20 | 8.1 MW | **0.0 MW** | 2 243 MW |

The Portuguese corridors carry 5–10 MW all day (just the parasitic flow of a
dead-end bus) against a real 0.7–3.9 GW, and the French corridors sit at exactly
zero in the export hours. Imports, by contrast, are reproduced exactly
(hour 0: 1 623 MW modelled vs 1 623.5 MW settled).

### `[crossborder].export_at_border = true`

The fix is a redistribution, not an addition:

```
load spread over ES buses  ←  load − net export
FR/PT terminal buses       ←  fixed withdrawal = net export
                              (split by line thermal rating)
```

The two cancel in the copper-plate power balance:

```
Σ domestic gen + imports − exports = (load − exports)
Σ domestic gen + imports          =  load                (unchanged)
```

so **DA, ID2, ID3, CID and BAL clear identically** — verified: day-ahead cost
8 639 253 EUR (8 Jul) and 19 639 555 EUR (2 Dec) to the euro with the flag off
and on. Only the AC redispatch, the one stage that cares where power leaves the
country, sees a difference.

Implemented as `xb_export_offset` in `run_market_chain.jl`, applied at the three network
builds (the copper-plate gates, the anchored hour-by-hour redispatch and the
multi-hour Bellman-coupled redispatch).

## Scope

Applies to the **2024 path only** (`[scenario].label = "2024"` with
`[crossborder].enabled = true`). In `[weeks]` mode the ES demand comes from
EMPIRE ScenarioData and does **not** contain the exchange — the joint 4-zone DA
clears it as a decision variable — so there the export is a genuine addition and
is always modelled. `xb_export_offset` returns 0 in that mode.
