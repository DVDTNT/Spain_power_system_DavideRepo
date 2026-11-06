# Option A — chain-native CSP (a plant that CAN move the market): change list

Concrete, code-level change list for making CSP a chain-native unit, so its
dispatch co-optimises with — and can shift — every clearing
(DA → ID2 → ID3 → CID → BAL → redispatch), following the existing BESS pattern.

* Assessment and gap list: `CSP/csp_powervision_integration_notes.md`
* The price-taker fallback, implemented: `CSP/csp_option_b.jl` (Option B)
* Status: **IMPLEMENTED (A.1-A.5, A.7, A.8.1) — 2026-11-05.** `config.toml`
  `[csp].mode = "embedded"` runs the plant inside every market LP: the
  `embed_plant_ids` rows of the plants file become network units in every
  stage (their TES physics live in `solve_da`), the per-day hand-off is
  exported to `csp_tes.csv`, and the redispatch anchors them like storage.
  A.6 (weeks mode) is deliberately guarded with a hard error until the weeks
  tables gain a CSP column. Validation: the da.jl TES block reproduces the
  standalone LP exactly (test/csp_test.jl, 114 checks), and the first
  embedded run cleared prices byte-identical to the base run (a 35 MW_e
  unit cannot move a ~40 GW market) while its surplus midday heat — which
  Option B curtails — was dispatched by the co-optimised market.

## A.0 What Option A means

The plant stops being a post-processor and becomes a set of network units,
exactly like the BESS units before it:

* it has a bus, a technology `("Solar", "CSP")` (the tech-map entries are
  already reserved in data_preparation.jl) and zero marginal cost;
* it appears in every stage LP, so its production shifts the copper-plate
  balance and with it the cleared price — that is the whole point;
* it appears in `da/id2/id3/cid/bal_dispatch.csv` (via `store_stage_result!`),
  in the redispatch, and in `market_prices.csv` implicitly through the prices;
* Option B survives as the verification baseline: with the plant small enough
  to be a price taker, the embedded dispatch under the shifted prices must
  equal the Option B dispatch under the unshifted prices (A.8).

## A.1 `config.toml` → `[csp]` additions

```toml
[csp]
enabled        = true
mode           = "embedded"             # selects Option A
plants_file    = "Data/csp_plants.csv"  # per-plant parameters (A.2)
profile_source = "pv"                   # "pv" | "dni" — hourly thermal
                                        # availability factor source; see A.9
cut_policy     = "bellman"              # "bellman" | "floor" — terminal-TES
                                        # pricing in the stage LPs
```

Validation: `mode = "embedded"` requires `plants_file` to exist and every
unit's bus to exist in the network (checked in `read_csp_plants` /
`prepare_network`). All Option B keys (`gates`, plant parameters, ...)
stay valid — Option B remains runnable alongside the embedded mode for
verification.

## A.2 `Data/csp_plants.csv` — IMPLEMENTED (the plant overlay file)

One row per plant. 2035 capacity is exogenous by construction — EMPIRE has no
CSP technology and the 2024 `generations.csv` has no CSP either — so the file
is the single source of truth; CSP units are NOT scaled by `UNIT_SCALE`.

The file EXISTS and is LIVE: every CSP computation reads its plant from it —
Option B, the thermal-value SDDP, the standalone demos, the weekly scenarios
and, when built, the A.3-A.5 chain wiring. `config.toml [csp]` points at it
with `plants_file` + `plant_id`; the code contains NO plant data (the
CSPMarketInputs / ThermalPlant defaults were removed on purpose — a missing
file, key or row is a hard error, never a fallback):

```csv
plant_id,bus_id,solar_capacity_mwth,pmax_e_mwe,tes_capacity_mwhth,q0_start_mwhth,q_end_target_mwhth,eta_solar,eta_power,eta_charge,thermal_leak_rate,pmax_charge_e_mwe,buy_from_grid,allow_sell,grid_price_floor_eur_mwh,vom_eur_mwh
demo,ES00007,60.0,35.0,180.0,70.0,70.0,0.80,0.38,0.80,0.01,50.0,true,true,2.0,0.0
weekly,ES00007,60.0,35.0,180.0,70.0,70.0,0.80,0.38,0.80,0.0005,50.0,true,true,2.0,0.0
bigtes,ES00007,60.0,35.0,800.0,300.0,300.0,0.80,0.38,0.80,0.01,50.0,true,true,2.0,0.0
```

Loader (implemented in CSP.jl, fully validated — value ranges, duplicate
ids, missing columns): `read_csp_plants(path) -> Vector{CSPPlant}` and
`get_csp_plant(path, id) -> CSPPlant`. `bus_id` locates the unit on the
network for A.3; `vom_eur_mwh` feeds Option A's marginal cost. For the real
Option A fleet, add one row per unit (the 53 "Solar Thermal" units of
generations.csv are the natural candidates).
## A.3 `data_preparation.jl` — `csp_units` kwarg in `prepare_network`

Mirror `bess_units` (kwarg at ~L243, the BESS window at ~L814-856):

```julia
# prepare_network(load, solar, wind; ..., csp_units = nothing)
for u in csp_units                              # Vector{CSPPlant} or nothing
    push!(gens, (id = u.unit_id, bus = u.bus, tech = ("Solar", "CSP"),
                 pmax = u.pmax_e, pmin = 0.0, cost = 0.0, ...))
    # per-unit TES state handed in per day by run_market_chain.jl (A.5)
end
```

* Technology `("Solar", "CSP")` — the tech-map entries are already reserved.
* Validation: unknown bus, `pmax_e <= 0`, `q0` outside `[0, tes_capacity]` →
  `error(...)` with the unit id, like the BESS validation.
* The units appear in the copper-plate energy balance like any generator, so
  the TES/power-block constraints below are the ONLY additional physics.

## A.4 `da.jl` — the CSP thermal-balance block in `solve_da`

Next to the BESS SOC window (~L197-246), one block per CSP unit:

```julia
# TES dynamics: q[t] = (1 - leak) q[t-1] + s_th[t] - pg[t]/eta_power
#                              + eta_charge * p_ch[t]        (only if allowed)
@constraint(m, [t = 1:T],
    q[t] == (1 - u.thermal_leak_rate) * q[t-1] + s_th[t]
            - pg[t] / u.eta_power + u.eta_charge * p_ch[t])
@constraint(m, [t = 1:T], s_th[t] <= u.solar_capacity * cf[hour(t)])  # availability
@constraint(m, [t = 1:T], 0 <= q[t] <= u.tes_capacity)
@constraint(m, q[T] >= u.q_floor)                    # daily hand-off floor
cut_policy == "bellman" &&                           # SolarBellmanCut ported 1:1
    @constraint(m, theta_csp >= a1 * q[T])           # a1 from the next-day profile
```

* `cf[hour(t)]` — the gate's vintage of the per-unit solar factors
  (`Data/ES/Solar/<d_m_yyyy>.csv`, columns DA/ID2/ID3/CID/BE — same source and
  same vintage mapping as Option B's `OPTION_B_SOLAR_STAGE`).
* `a1` from `CSP.build_solar_bellman_cut` on the next calendar day's profile
  at the same gate (persistence), scaled by the expected next-day price.
* `pg` is the unit's generator variable in the copper-plate balance — this is
  what lets CSP shift the cleared price, and it requires nothing beyond the
  unit existing in the model (A.3).
* Later gates: ID2/ID3/CID/BAL all re-solve `solve_da` with anchoring — add
  the CSP `pg` to the existing min-movement anchor terms exactly like BESS,
  and pass the gate's own vintage of the factors.
## A.5 `run_market_chain.jl` wiring

1. Const next to `BESS_UNITS` (~L218):
   `const CSP_UNITS = CSP_ENABLED && CSP_MODE == "embedded" ? read_csp_plants(...) : nothing`
2. `build_da_nets` (~L1165): forward `csp_units = CSP_UNITS` to `prepare_network`
   (A.3) — every gate inherits it because they all build networks through it.
3. Per-day TES hand-off: `csp_state = Dict{String,Float64}()` (unit_id -> q_end of
   the previous study day). Pass each day's `q0 = get(csp_state, id, plant.q0)`
   into the DA solve; after the BAL (anchor) stage of the day, update
   `csp_state[id] = q_end` — the hand-off always follows the FINAL schedule,
   never an intermediate gate.
4. Export `results/<label>/csp_tes.csv` (date, unit_id, q0, q_end, theta_csp)
   next to `market_prices.csv`.
5. Redispatch: extend the `"BESS_"` prefix handling (~L1651/1666/1974) to
   `"CSP_"` names — free within ±pmax_e around the BAL schedule, i.e. the same
   "storage-like unit anchored to its market schedule" treatment.
6. `store_stage_result!` then emits the plant into every stage's dispatch CSV
   automatically — no writer changes.

## A.6 `week_profiles.jl` — CSP column for `[weeks]` mode

The `[weeks]` gate tables need one CSP capacity-factor column when
`[weeks].enabled && csp embedded`: the same per-unit solar factors
(`profile_source = "pv"`), one column per gate table (DA/ID2/ID3/CID/BE),
scaled by nothing (the plant file already carries MW_th). Without it the
weeks mode must hard-error, not silently run a zero-CSP day.

## A.7 `CSP.jl` refactor (keep it standalone-capable)

* `Base.@kwdef struct CSPPlant` — `unit_id::String`, `bus::String`, plus the
  physical parameters of `CSPMarketInputs`; `read_csp_plants(path)` (A.2).
* `solve_csp_market_stage(...; optimizer = HiGHS.Optimizer)` kwarg so the
  chain can reuse `GRB_ENV` instead of HiGHS.
* Keep the standalone "cleared-prices" mode: it IS `CSP/csp_option_b.jl` —
  after embedding, Option B remains the verification baseline (A.8), so the
  two must stay API-compatible (`CSPPlant` -> `CSPMarketInputs` conversion).
## A.8 Tests and validation plan

1. **Unit tests** (`test/csp_test.jl`): `read_csp_plants` round-trip on a
   fixture file; the da.jl thermal block extracted into a function and
   compared against `solve_csp_market_stage` on identical inputs (same
   objective, same TES trajectory).
2. **Single-day equivalence** (the strongest check): embed one small plant for
   2024-07-08, feed the chain's cleared prices back into Option B, and verify
   that the embedded plant's dispatch matches the Option B BAL stream within
   tolerance — a price taker must behave identically whether it is inside or
   outside the LP.
3. **Chain regression**: `[csp] enabled = false` (or `mode = "off"`) must
   reproduce today's results bit-for-bit: da/id2/id3/cid/bal_dispatch.csv,
   market_prices.csv, summary.csv. The gate for this already exists — the
   embedded code path must be strictly behind `mode = "embedded"`.
4. **Weekly scenario**: run `[weeks]` mode with the plant embedded and compare
   TES trajectories/revenues against the Option B streams over the same week.

## A.9 Open questions (decide before implementing)

* **Thermal profile source.** No DNI dataset exists in the repository; PV-shaped
  per-unit factors approximate solar-thermal availability (`profile_source =
  "pv"`). If real DNI arrives, add `Data/DNI/` and a `profile_source = "dni"`
  branch — nothing else changes.
* **2035 CSP capacity.** Exogenous by construction (EMPIRE has none). Where
  should the installed MW come from — the plant file only (current design), or
  a scenario table keyed by `[scenario].label`?
* **Terminal value.** RESOLVED — `CSP/thermal_value_sddp.jl` implements the
  water-value analog of the paper/ReSDDP pipeline: a daily-stage SDDP (TES
  state, exhaustive day-type branches) trains the thermal-value cut set
  (slopes ≤ 0; thermal value = −slope of the binding cut) and exports
  `results/csp_sddp/cuts.csv` in the BellmanValuesOUT convention. Option A's
  solve_da block consumes it exactly as da.jl consumes the hydro cuts:
  `theta_future >= b + a·q_end` for every cut of the day's stage — the plant
  then sells in every hour whose `eta_power·price` clears the thermal value.
  The persistence cut remains the fallback when no cut file exists. (The demo
  training stops at max_iter with a ~9 % gap over 14 July-like days — more
  stages, more branches or a real DNI/price dataset tighten it.)
* **Grid charging when embedded.** Physically real for some plants, but in the
  copper plate it lets the plant act as a "free" transmission-hiding device.
  Default `buy_from_grid = false` when `mode = "embedded"`, keep it configurable.
* **Anchoring weight.** The CSP `pg` joins the existing min-movement anchor
  objective — confirm the anchor weight treats MW_e storage-like units the
  same way it treats BESS MW.