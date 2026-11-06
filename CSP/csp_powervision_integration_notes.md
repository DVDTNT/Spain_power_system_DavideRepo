# CSP in PowerVision — integration assessment and change list

Date: 2026-10-26. Question: can CSP.jl be used as-is so that PowerVision (the
Spain_power_system market chain) takes CSP plants as inputs that run all
markets? Verdict first, evidence after.

## Verdict

NOT as-is. CSP.jl is a standalone, single-plant, price-taking LP: it
optimizes one plant against EXOGENOUS buy/sell prices, with its own TES
state, a single-cut TES continuation value, and demand/shortage/curtail
couplings that are placeholders fixed to zero (CSP.jl ~L326-331).
PowerVision's chain clears prices ENDOGENOUSLY from a fleet-wide LP whose
every participant is a unit inside the hourly PowerModels networks
(prepare_network), re-clears each gate as an anchored adjustment of the
previous gate, and finally makes the schedule network-feasible in the
redispatch OPF. A plant outside that LP cannot take part in the clearing; it
can only be studied beside it.

What survives almost 1:1 — CSP.jl already prototypes, in the chain's own
idioms, everything the embedded version needs:

- per-gate forecast vintages: `load_solar_forecast` reads exactly the
  chain's DA/ID2/ID3/CID/BE columns (Data/ES/Solar/<d_m_yyyy>.csv);
- TES continuation value: `SolarBellmanCut` / `build_solar_bellman_cut` is
  the same recentred-cut theta_future structure solve_da already uses for
  reservoir hydro (da.jl ~L166-195);
- thermal tank dynamics q[t+1] = (1-leak)*q[t] + eta_solar*field*cf
  - p_gen/eta_power (+ eta_charge*p_buy) (CSP.jl ~L287-321) — the one
  physics block the chain's storage idiom cannot yet express.

## How the chain runs markets (facts the integration must respect)

1. Stages per study day: DA (24 h, Bellman-coupled; joint ES/PT/FR/EU zonal
   clearing when [weeks] on) -> ID2 (all 24 h, anchored to DA) -> ID3 (hours
   12-23, anchored to ID2) -> CID (rolling gate 1 h before delivery, earlier
   hours frozen) -> BAL (all 24 h, "BE" realisation vintage, anchored to the
   latest gate) -> redispatch (AC/DC OPF anchored to BAL; frozen fuels
   pinned; BESS free within +/- rated and anchored to its schedule).
2. Units: everything is a generator in prepare_network's hourly networks,
   built from Data/generations.csv (+ scenario per-tech scaling, the BESS
   fleet, nodal greenfield units). RES availability per hour = national
   solar_mw distributed over Solar units pro rata (data_preparation.jl
   ~L541-546).
3. Storage idiom: a store is a generator with pmin = -pmax (negative pg =
   charging), "energy_mwh", "eta_rt"; solve_da adds a daily-neutral SOC
   window starting half-full (da.jl ~L197-246); eta_rt < 1 splits
   charge/discharge legs (pumped hydro, sqrt(eta_rt)).
4. Prices: duals of the ES balance in the cost solve, read BEFORE the
   min-movement lexicographic pass (da.jl ~L313-325).
5. Anchoring: run_copper_plate! (run_market_chain.jl ~L1255) maps
   tradable/frozen hours and hands solve_da free_hours/prev_sched/anchor;
   CID re-solves causally (run_cid_rolling! ~L1309).
6. 2035 scenarios: per-tech growth from EMPIRE genInstalledCap.tab; BESS
   from stor{PW,EN}InstalledCap.tab; nodal disaggregation (empire_nodal.jl).
   EMPIRE's tech set has NO CSP, and Data/generations.csv (2024) has no
   CSP/Solar-Thermal units either. But the chain<->EMPIRE tech map already
   reserves ("Solar","CSP") and ("Solar","Solar Thermal") ->
   ("Solar","CSP") (data_preparation.jl ~L44-45).
7. Mid-term SDDP prices reservoir hydro only; TES is a short-duration store
   and needs no mid-term policy. The chain has NO reserve or capacity-market
   stage — "all markets" = the five gates + redispatch.

## Gap list — why CSP.jl cannot be dropped in as-is

- G1 Price-taking vs clearing: CSP.jl needs prices as input; the chain
  computes them. solve_da has no per-unit bid-curve interface (flat offers).
- G2 No bus/location: the redispatch needs the plant on a network bus.
- G3 Storage idiom mismatch: the chain's store SHIFTS electricity with a
  daily-neutral SOC; CSP is a heat store with an exogenous thermal inflow,
  standing leak, floor, optional grid charging and an end-of-day value. The
  eta_rt SOC window cannot express the solar-thermal inflow.
- G4 No anchoring semantics: the gates adjust the previous schedule with
  minimum movement; a beside-the-chain optimiser knows nothing of that.
- G5 Single plant, hand-fed kwargs: no plant database, no config/CSV input,
  no multi-plant aggregation.
- G6 Profile data: CSP needs DNI-driven solar-thermal availability; the repo
  has only PV-shaped forecast factors (no CSP columns under Data/ES).
- G7 Solver: HiGHS standalone vs the chain's Gurobi/Ipopt (minor).
- G8 Inert placeholders: demand/shortage/curtail are fixed to 0, so the
  "market coupling" does not exist yet.
- G9 2035 path: EMPIRE has no CSP technology, so scenario capacity must be
  exogenous (config/inputs), not from the expansion output.
- G10 Day-to-day TES state: CSP.jl is single-stage (q0 in, q_end floored);
  the chain runs days sequentially and needs a q_end -> q0 hand-off.

## Recommended design — Option A: make CSP a chain-native unit

Represent each CSP plant the way BESS is represented (the proven pattern),
plus one new constraint family for the thermal balance:

1. config.toml [csp]: enabled; plants_file = "Data/csp_plants.csv";
   profile_source = "pv" (reuse Data/ES/Solar vintages) or "dni" (new
   series); TES value-cut policy. Keep [csp].enabled compiling CSP.jl as
   today (run_market_chain.jl ~L71-80).
2. Data/csp_plants.csv, one row per plant: plant_id, bus_id, block_mw,
   solar_field_mwth, tes_mwhth, tes_floor_mwhth, eta_solar, eta_power,
   eta_charge (0 = no grid charging), thermal_leak_rate, var_cost_eur_mwh.
3. data_preparation.jl: add a csp_units kwarg to prepare_network mirroring
   bess_units (~L243, ~L814-856): one generator per plant, name
   "CSP_<plant_id>", fuel "Solar", technology "CSP", pmax = block_mw,
   pmin = 0 (or -block_mw if grid charging), plus fields tes_mwhth,
   eta_power, eta_charge, leak, q_floor, solar_thermal_mw[t] (per-hour
   thermal availability), tes_q0. The ("Solar","CSP") tech-map entries then
   route costs/growth correctly with no further mapping work.
4. da.jl solve_da: next to the SOC-window block (~L197-246) add a CSP block
   per unit (by stable name via pg_by_name): q[t] = (1-leak)*q[t-1]
   + s_th[t] - pg[t]/eta_power (+ p_ch[t]*eta_charge if grid charging);
   s_th[t] <= solar_thermal_mw[t] (heat curtailment free); q in [floor,
   tes]; q[0] = tes_q0; theta_future >= cut per CSP.SolarBellmanCut
   (recentre like the hydro cuts, da.jl ~L166-195). Frozen hours participate
   through their fixed pg exactly as the BESS SOC window does.
5. run_market_chain.jl: build CSP_UNITS from config (2024: the CSV; 2035:
   config-declared capacity, since EMPIRE has no CSP) and pass it through
   build_da_nets -> prepare_network like BESS_UNITS (~L218, ~L1198); keep a
   per-day per-plant TES state dict (day d's q_end -> day d+1's tes_q0);
   export csp_tes.csv; in the redispatch, extend the "BESS_" prefix
   handling (~L1651/1666/1974) to "CSP_" names: free within +/- block,
   anchored to the BAL schedule. store_stage_result! then emits the plant
   into every stage's dispatch CSV automatically.

6. week_profiles.jl: add a CSP CF column when [weeks] is on (EMPIRE
   ScenarioData has none — approximate with the solar CF, or ship a DNI
   series under Data/ts/EMPIRE).
7. CSP.jl: keep as the standalone/verification tool, but factor the
   parameters into a CSPPlant struct + read_csp_plants so the chain and the
   standalone demo share one parameterisation; add a "run against cleared
   prices" mode (reads results/<label>/ prices) for post-hoc validation;
   accept a custom optimizer kwarg. CSP/csp_weekly_scenarios.jl stays valid
   unchanged.
8. test/csp_test.jl: add chain-side checks — a small solve_da solve with
   one CSP unit (TES balance, floor, cut), the day-to-day hand-off, and the
   anchor behaviour.

Option B (fallback, not the end state): run CSP.jl as an external
price-taker that consumes each gate's cleared prices and emits the plant
schedule after the fact. Cheap, but the plant influences nothing — no
participation in price formation, invisible to the redispatch. Good only as
a first sanity check.

## What needs NO change (already fits)

- Energy-only markets: no reserves/capacity stages exist, so CSP.jl's
  energy-only formulation maps cleanly onto all five gates.
- The recentred theta_future machinery in solve_da is structurally identical
  to SolarBellmanCut — the TES value-cut concept ports directly.
- The DA/ID2/ID3/CID/BE vintage columns CSP.jl already reads are exactly the
  chain's per-gate forecast convention.
- Copper-plate stages 1-5 need no network data; stage 6 follows the BESS
  precedent for anchoring a store.
- Foreign zones / NTC coupling: a CSP unit is just another ES unit there.

## Assumptions / limitations

- "All markets" = DA, ID2, ID3, CID, BAL, redispatch (this model has no
  reserve products or capacity market beyond these).
- PV-shaped factors approximate the solar-thermal profile until a DNI series
  is added; per-gate CSP forecast quality is then assumed equal to PV's.
- Adding CSP to the 2035 EXPANSION (EMPIRE investing in CSP) is an
  EMPIRE-side change, outside this repository; here CSP capacity is
  exogenous.
- One affine TES cut per plant per day to start; a piecewise/multi-cut value
  function is a later refinement (SolarBellmanCut already reserves the b
  field for it).

## Validation plan

1. Unit tests: extend test/csp_test.jl (plant struct, CSV reader, chain
   block).
2. Single-day equivalence: embed one plant for 2024-07-08 and re-derive the
   standalone CSP.jl dispatch from the chain's cleared DA prices — the tank
   dynamics must match exactly wherever prices are flat.
3. Chain regression: [csp] disabled must reproduce current results
   bit-for-bit (the switch already exists: run_market_chain.jl ~L71-80).
4. Weekly: re-run the CSP/csp_weekly_scenarios.jl logic against the embedded
   plant over a sampled week and compare TES trajectories and revenues.

---

**Status update (2026-10-26).** Option B is implemented and enabled by default:
`CSP/csp_option_b.jl` re-dispatches the plant on the chain's cleared prices
whenever `[csp] enabled = true, mode = "postprocess"` — a pure price taker
run automatically by run_market_chain.jl section 9 (after "8. Save
results"), also covered by test/csp_test.jl. The concrete, code-level change
list for Option A now lives in `CSP/option_A_chain_native_csp_design.md`.

**Status update (2026-11-04).** The terminal-value piece of Option A (open
question A.9) is now implemented: `CSP/thermal_value_sddp.jl` adapts the
uploaded ReSDDP package (resddp_original/, the SDDP engine behind the
PowerVision paper's FanSi water values) to the CSP/TES plant. Daily stages,
TES state, exhaustive weather/price branches; the forward/backward passes and
the free-alpha (AlphaMax) trick mirror ReSDDP's train!/SolveFWD/SolveBWD;
cuts are exported in the BellmanValuesOUT convention
(results/csp_sddp/cuts.csv, slope <= 0, thermal value = -slope of the
binding cut). Demo: TV ~ 17.24 EUR/MWh_th on the July-like branch set, vs
2.74-16.00 from the persistence cut. Covered by test/csp_test.jl. No silent
defaults: the scenario source is explicit everywhere — the trainer requires a
branch vector (`default_scenario_set` must be *asked for*),
`read_thermal_scenarios(path)` loads any real price/irradiance dataset from
CSV, and the standalone demo refuses to run without `--archetypes`
(synthetic, warns loudly) or `--scenarios <file.csv>`.

**Status update (2026-11-05).** The plant data now has a single source of
truth: `Data/csp_plants.csv`, the type-specific overlay file in the same
spirit as generations.csv / power_unit_tech_params.csv / marginal_costs.csv.
CSP.jl defines `CSPPlant` + `read_csp_plants` / `get_csp_plant` (validated,
exported); every consumer reads the file — Option B via
`[csp].plants_file` + `[csp].plant_id`, the thermal-value SDDP demo via
`--plants-file/--plant-id`, the weekly scenarios via the "weekly" row, and
the viewers' publishers from the same rows. All built-in plant defaults
were REMOVED (`CSPMarketInputs` and the SDDP's `ThermalPlant` — now an
alias of `CSP.CSPPlant` — have none): a missing file, key or row is a hard
error; the code never substitutes remembered numbers for missing data.
Variants are rows: the big-TES study is the "bigtes" row, dispatched with
`--plant-id bigtes` / `[csp].plant_id = "bigtes"`. Smoke tests: 107 checks
(was 89), including reader validation and the no-default-plant errors.

**Status update (2026-11-05, later).** **Option A is implemented.**
`[csp].mode = "embedded"` now runs the plant INSIDE every market LP:
`embed_plant_ids` rows of the plants file become network generators in every
stage (`prepare_network(...; csp_units = ...)`); `_add_csp_tes_block!` in
da.jl adds the TES balance, the gate-vintage availability (factor × physical
day shape), the daily floor and the terminal value — the trained thermal-value
cuts of `results/csp_sddp/cuts.csv` in cost form, recentred at the day's q0
(`cut_policy = "cuts" | "bellman" | "floor"`); settled hours' collection is
pinned across adjustment gates; the day's BAL q_end hands the tank to the
next study day (`csp_tes.csv`); the redispatch anchors `CSP_` units like
storage; section 9 runs Option B after an embedded run as the A.8 baseline.
Grid charging is OFF when embedded by default (`embedded_buy_from_grid`).
First embedded run (demo row, cut policy "cuts"): all gates OPTIMAL,
48/48 redispatch hours solved, cleared prices BYTE-IDENTICAL to the base run
(a 35 MW_e unit cannot move a ~40 GW market — the exact expected
price-taker-scale result), TES 70 → 70 both days under the trained TV
17.24 EUR/MWh_th, and the market DISPATCHED the plant's surplus midday heat
(12-18 MW at ~zero prices) that the Option-B counterfactual curtails — the
co-optimisation working as designed. Smoke tests: 114 checks. Weeks mode
hard-errors until A.6.
