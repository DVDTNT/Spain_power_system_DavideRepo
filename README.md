# Spain Power System — public version

Multi-hour AC OPF of the Spanish peninsular transmission grid, driven by an
in-house market chain (day-ahead → intraday gates → continuous intraday →
balancing → network redispatch), coupled to a mid-term SDDP hydro policy and an
EMPIRE-based 2035 capacity expansion.

This branch is a trimmed, self-contained version of the research repository: the
model code, the data it reads, and the four workflows below. It carries two 2035
scenarios, **Trinity** and **NECPEssentials**.

## Requirements

- **Julia 1.9+**. `julia --project=. -e 'using Pkg; Pkg.instantiate()'` installs
  everything in `Manifest.toml`.
- **Gurobi** for the LP/QP stages (market clearing, DC redispatch, SDDP) — an
  academic licence is free.
- **Ipopt** for the AC redispatch. The HSL MA57 linear solver is strongly
  recommended; the default MUMPS converges much more slowly on this network.
- **Python 3.9+** with pandas and matplotlib, for `scripts/` and `plotting/`.

Everything is driven by `config.toml`. Two environment variables override where
a run reads and writes:

| Variable | Meaning | Default |
| -------- | ------- | ------- |
| `SPAIN_CONFIG` | config file to use | `config.toml` |
| `SPAIN_RESULTS` | results directory | `results/<label>/` |

## The four workflows

### 1. The 2024 validation case

Reproduces the observed 2024 Spanish market on two representative days
(8 July, 2 December) — this is the validation case for the market chain.

```bash
# in config.toml: [scenario] label = "2024",  [weeks] enabled = false
julia --project=. run_market_chain.jl
```

Writes `results/` — `da_dispatch.csv` … `bal_dispatch.csv` for the five market
stages, `gen_dispatch.csv` and `branch_flows.csv` for the redispatch, and
`summary.csv` with one row per hour. Compare against `Data/OMIE/` with
`plotting/paper_figures_2024.py`.

### 2. Mid-term SDDP (hydro water values)

Generates the Bellman cuts that price reservoir hydro in the market chain.

**The cuts are already in the repository**, for the 2024 case and for both
scenarios, so you do not need to run this before a chain run — it is here to
regenerate them, or to run a scenario of your own. Re-running overwrites the
tracked files in place:

```
Data/BellmanValuesOUT_sddp4[_<label>].csv    cut coefficients
Data/Volume_Scen0_OUT_sddp4[_<label>].csv    reservoir volume trajectory
Data/TurbineSchedule_sddp4[_<label>].csv     weekly release, the daily hydro budget
Data/ExchangeSchedule_sddp4[_<label>].csv    ES-FR / ES-PT net position
```

```bash
# in config.toml: set [scenario].label to Trinity or NECPEssentials
julia --project=. midterm_sddp4.jl
```

78 weekly stages, 4 zones (ES/PT/FR/EU), 3 reservoir states, 37 climate-year
scenarios. Takes roughly 40 minutes per scenario. Writes
`Data/BellmanValuesOUT_sddp4_<label>.csv` plus the volume, turbine and exchange
schedules, and `Data/midterm4_effective_inputs_<label>.csv` — the merged
capacity/cost table actually used, worth inspecting.

### 3. Market chain for 2035

```bash
# in config.toml: [scenario] label = "Trinity",  empire_dir = "Data/2035/Trinity"
#                 [weeks] enabled = true
julia --project=. run_market_chain.jl
```

Clears the five market stages and then the AC or DC redispatch
(`[redispatch].power_flow`) over the sampled multi-week horizon, with a joint
ES/PT/FR/EU day-ahead. Writes `results/<label>/`. Expect 1–3 hours.

Switch scenario by setting **both** `[scenario].label` and
`[scenario].empire_dir`.

### 4. Grid reinforcement

When the market stages clear but the redispatch reports `LOCALLY_INFEASIBLE`,
this turns the infeasibility into a ranked, sized list of lines to expand. The
method is documented in
[`docs/method_grid_reinforcement_identification.md`](docs/method_grid_reinforcement_identification.md).

One command runs the whole loop — diagnostic, sizing, and validation:

```bash
bash scripts/run_reinforcement.sh NECPEssentials 10 2 1.0
#                                  scenario  intra n_weeks inter
```

It runs the uncongested-intrazonal DC diagnostic, derives
`reinforcement.csv` (each line's required rating as a fraction of nameplate),
then re-runs the chain with that list loaded and every diagnostic multiplier
back at 1.0, and reports the feasible-hour count. If hours remain unsolved it
prints them and exits non-zero — raise the intrazonal multiplier and repeat.

The validation step is not optional: flows redistribute once limits bind again,
so the sizing read off the uncongested solve is only first-order.

To run the pieces separately:

```bash
bash scripts/run_reinforcement_diag.sh NECPEssentials 10 2 1.0   # steps 1-5
julia --project=. scripts/make_validation_config.jl NECPEssentials <list.csv> 2 DC
```

`Data/trinity_line_reinforcement_gt0.8.csv` is a list previously derived **for
Trinity**. It is scenario-specific — applied elsewhere it reinforces lines that
scenario never overloaded. `[redispatch].extra_line_scale_file` defaults to
empty for this reason.

## Data

| Path | What |
| ---- | ---- |
| `Data/Bus_Data.csv`, `lines.csv`, `transformers_reactance.csv` | bus-level network topology |
| `Data/Generation.csv`, `Storage.csv`, `power_unit_tech_params.csv` | unit fleet, ramp rates, tech parameters |
| `Data/ES_old/{Solar,Wind,load}/` | 2024 MW baselines; column `-12` is the day-ahead vintage |
| `Data/ES/{Solar,Wind Onshore,load}/` | per-gate forecast-deviation factors (`DA,ID2,ID3,CID,BE`), 363 days of 2024 |
| `Data/ts/EDF__*-ES__*.csv` | EDF load factors and hydro coefficients, 37 climate years 1982–2018. The climate years these files share define the SDDP's scenario set. Run-of-river drives the ES RoR units; inflow is used only when `[midterm4].es_inflow_source = "edf"`. The wind and PV load-factor files are read for the climate-year set only — availability comes from the EMPIRE series below |
| `Data/ts/Profile-Iberia.csv` | ES load shape for the SDDP |
| `Data/ts/EMPIRE/` | hourly NUTS3 weather series the SDDP reads for every run, 2024 and scenario alike. Byte-identical to each scenario's own `ScenarioData/` copy, which is where the market chain takes the same series |
| `Data/2035/<scenario>/` | the EMPIRE run: installed capacity, marginal costs, NTCs, and the ScenarioData weather |
| `Data/OMIE/` | observed 2024 prices and generation, for validation |

Only the EMPIRE files the model actually reads are included (15 per scenario).
The full EMPIRE runs, and the GoRES and REPowerEU++ scenarios, are not on this
branch.

`results/` is gitignored — every workflow regenerates it.

## Known limitations

- **Renewable capacity factors are national, not regional.** The
  `ScenarioData/{solar,windonshore}.csv` files carry per-NUTS3 CF columns, and
  `week_profiles.jl` uses them to build the national MW series correctly
  (weighted by each region's installed capacity). But
  `data_preparation.jl:541` then spreads that national availability over buses
  pro-rata by installed capacity, so **within any hour every Spanish solar unit
  sees the same CF**, and likewise for wind. NUTS3 resolution survives in *where*
  capacity sits (`[scenario].disaggregation = "nodal"`), not in *when* it
  generates. Since spatially correlated renewables are a main driver of corridor
  loading, this likely understates congestion.
- The 2035 gate forecast factors are 2024 vintages, i.e. forecast quality per MW
  is assumed unchanged.
- The reinforcement sizing assumes symmetric thermal limits, and is only
  meaningful once the binding mechanism has been confirmed thermal rather than
  voltage — see step 2 of the method doc.

---

The sections below document the model itself: the market stages, cross-border
handling, storage, reactive compensation and the network model.

Multi-hour AC OPF of the Spanish peninsular transmission grid, driven by an
in-house market chain (day-ahead → intraday gates → continuous intraday →
balancing → network redispatch). Configuration lives in `config.toml`; the
network is assembled in `data_preparation.jl` and solved in `run_market_chain.jl`.

## Market chain stages

The day is cleared by a sequence of markets, each refining the previous one as
the load/wind/solar forecast is updated, and the final schedule is then made
network-feasible by the AC redispatch. Every market stage is a **copper-plate**
economic dispatch (one system-wide power balance per hour, no network limits)
with reservoir hydro coupled across the 24 hours through the Bellman cost-to-go;
the redispatch is the only stage with a full AC network.

| # | Stage | Forecast column | Formulation | `config.toml` |
| - | ----- | --------------- | ----------- | ------------- |
| 1 | **Day-ahead (DA)** | `DA` (= ES_old `-12` baseline) | clears all 24 h from scratch | `[da]` |
| 2 | **Intraday ID2** | `ID2` | re-clears all 24 h, anchored to DA | `[id2]` |
| 3 | **Intraday ID3** | `ID3` | re-clears the last 12 h (12–23), anchored to ID2 | `[id3]` |
| 4 | **Continuous intraday (CID)** | `CID` | rolling gates 1 h before delivery, anchored to ID3/ID2 | `[cid]` |
| 5 | **Balancing (BAL)** | `BE` | re-clears all 24 h, anchored to CID | `[balancing]` |
| 6 | **Redispatch (RD)** | — | AC or DC OPF (`[redispatch].power_flow`), anchored to BAL | `[redispatch]` |

The forecast columns live in the new `Data/ES/<resource>/` files; actual MW at
each stage is `ES_old "-12" baseline × stage scale-factor` (sampled-week
scenario runs instead use the EMPIRE ScenarioData weather as the DA baseline
with the dated `Data/ES` factors on top — see `[weeks]`).

**4-zone DA (sampled weeks)**: in `[weeks]` mode the day-ahead is a **joint
ES/PT/FR/EU clearing** (`foreign_zones.jl` + the `foreign` block in `da.jl`):
the foreign zones are per-tech aggregates of the EMPIRE scenario fleet coupled
on the PT–ES–FR–EU chain by NTC-bounded flow variables, with the ES–FR/ES–PT
limits calculated offline by `ntc_capacity.jl`. For every hour it solves a
zero-exchange DC reference case, applies a fixed downward-headroom GSK for
imports and an optimised corrective-redispatch GSK for exports/transit,
finds four asymmetric directional limits, and tests every joint ES–FR/ES–PT
corner to prevent an individually valid pair of limits from admitting an
undeliverable FR→ES→PT transit. A further `[weeks.ntc].reliability_margin` is
then applied. The DA still receives only four scalar NTC bounds—no Spanish
branch or PTDF constraint enters market clearing.

The cleared hourly ES–FR/ES–PT net positions are **fixed** for every later gate
and the redispatch. Their border-bus allocation is also fixed using the
scenario border ratings; border buses cannot reverse independently and there
is no countertrade feasibility slack. Capacity diagnostics are cached in
`results/<label>/hourly_ntc.csv`; exchange, the applied directional limits and
zonal prices are written to `results/<label>/xb_flows.csv`. Set
`[weeks.ntc].enabled=false` to use the legacy symmetric
`[weeks].xb_ntc_margin` fallback.

## Cross-border exchange (2024 path)

**The Spanish load series already contains the net export.** `Data/ES_old/load`
column `-12` is ENTSO-E total consumption for Spain, and
`Data/OMIE/actual_generation_*.csv` balances its generation columns plus the FR
import column against exactly that series — to 0.0 GWh, in all 48 study hours,
with no Portugal term at all. Exports must therefore be **relocated** to the
border, never **added** to the balance; adding them injects ~60 GWh/day of
demand that does not exist and dumps all of it on CCGT.

What was wrong was only the *location*: the export was spread over the 1 227
Spanish load buses in proportion to demand, so the AC redispatch saw 5–10 MW on
the Portuguese border lines against a real 0.7–3.9 GW export, and exactly 0 MW
on the French ones in the six export hours of 8 July.

`[crossborder].export_at_border = true` subtracts the export from the
distributed Spanish load and places it as a fixed withdrawal at the FR/PT
terminal buses, split by line thermal rating. Total load is unchanged, so the
copper-plate gates clear identically (verified to the euro) and only the
redispatch differs. Full derivation and evidence in
[`docs/method_export_relocation.md`](docs/method_export_relocation.md).

In `[weeks]` mode this does not apply: the ES demand comes from EMPIRE
ScenarioData and carries no exchange, so the 4-zone DA's cleared export is a
genuine addition.

## Nuclear availability

Thermal units carry no availability derating by default — `pmax = capacity_mw` —
so the nuclear fleet would otherwise sit on the bar at its full nameplate every
hour of every day. `[da].nuclear_availability` scales nuclear `pmax` by the
fraction of the fleet actually available (planned refuelling + forced outages);
`[da].nuclear_min_gen_frac` then acts as a floor on that *available* capacity
rather than on the nameplate.

Because a single annual factor cannot match two days that sat at very different
availability, `[da.nuclear_availability_by_date]` overrides it per study day:

```toml
[da]
nuclear_min_gen_frac = 0.8
nuclear_availability = 0.85          # default for unlisted days

[da.nuclear_availability_by_date]
"2024-07-08" = 0.93
"2024-12-02" = 0.69
```

The two 2024 figures are taken from the OMIE cleared programme against the
7 408 MW nameplate in `Data/generations.csv`. (TOML requires the sub-table to
come after every scalar key of `[da]`.)

## Storage (pumped hydro and Li-Ion BESS)

Both storage families are held to an **intra-day SOC window plus a daily energy
balance** in every market gate (`solve_da`, `da.jl`): starting half-full, the
state of charge must stay inside `[0, E]` and return to its opening level by the
end of the day. A store therefore only *shifts* energy within the day — it never
supplies net energy. This matters because a store's variable cost is near zero
(pumped hydro is 0.036 EUR/MWh in `generation_cost_pypsa_2024.csv`): without the
energy limit the LP runs the whole fleet flat out and it silently becomes the
cheapest baseload on the system.

| | Power bounds | Reservoir `E` | Round trip |
| - | - | - | - |
| Pumped hydro | `pmin = −pmax` (negative `pg` = pumping) | national figure from `Data/Storage.csv`, split pro-rata on unit power | `PUMPED_ROUND_TRIP_EFF` = 0.75 |
| Li-Ion BESS | `pmin = −pmax` | per-unit, from the EMPIRE scenario | lossless |

Units with a round-trip efficiency below 1 split `pg` into non-negative
discharge/charge legs so the loss is charged to the reservoir
(`drawdown = p_dis/η_d − p_chg·η_c`, `η_d = η_c = √η_rt`). Running both legs at
once always drains the reservoir on net, so the LP never does it and no
complementarity constraint is needed. Lossless units keep the original
single-variable form.

The **redispatch** stage has no SOC constraint — it solves hour by hour, so
storage there is free within its power band and held near its market schedule by
the anchor term only.

Each intraday and
balancing gate is an **adjustment** market, not a fresh re-clear: it minimises
dispatch cost first (merit order), then — among cost-optimal solutions —
minimises total movement from the previous gate's schedule, so flexible units
only move to cover the genuine net forecast change. Nuclear is frozen at its DA
dispatch from ID2 onward.

**Market prices** are written to `results/<label>/market_prices.csv` (long
format: `date, hour, stage, price_eur_mwh`) — the marginal price of the ES
copper-plate balance at each gate. They are read from the *cost* solve: the
lexicographic pass that follows replaces the objective with total movement, so
after it the same duals price a MW of movement rather than a MWh of energy. A
gate only prices the hours it actually trades, so ID3 contributes hours 12–23 and
each rolling CID gate contributes the single hour it commits.

**Balancing (stage 5)** is the final adjustment market, cleared after the
continuous intraday and just before the redispatch. It reads the probabilistic
`BE` column of the load/solar/wind files and adjusts the CID schedule with the
same anchored, minimum-movement formulation as the intraday gates. Its cleared
schedule — and its `BE` profiles — are what the redispatch is then anchored to
and built on (the redispatch falls back to CID when `[balancing].enabled =
false`). Per-stage cleared schedules and profiles are written to
`results/{da,id2,id3,cid,bal}_dispatch.csv` and `…_profiles.csv`.

## Shunt reactors (EHV line-charging compensation)

### Why
Every AC line is modelled as a full π-model with shunt charging susceptance
(`b_fr`/`b_to`, derived from each line's `c_per_length` in `data_preparation.jl`).
Across the ~48 000 km of 400/220 kV circuits this charging **generates roughly
21 GVAr** of reactive power at nominal voltage (≈ 17 GVAr from the 400 kV lines
alone). With nothing to absorb it, the OPF pushes that reactive power onto the
generators and bus voltages ride against the upper band — physically the job of
**shunt reactors**, which the real grid operates for exactly this purpose.

PowerModels reads shunts only from the network `shunt` component dict (bus-level
`gs`/`bs` fields are ignored), so the reactors are attached there as proper
shunt elements with **negative susceptance** (`bs < 0`), i.e. inductive /
reactive-absorbing.

### Installed fleet (data source)
The installed peninsular shunt-reactor capacity is taken from **Red Eléctrica de
España, Boletín Mensual de diciembre 2024**
(<https://www.ree.es/es/datos/publicaciones/boletines-mensuales/boletin-mensual-diciembre-2024>):

| Voltage group            | Installed | Units |
| ------------------------ | --------: | ----: |
| Peninsular 400 kV        | 11 750 MVAr | 80 |
| Peninsular ≤220 kV       |  3 722 MVAr | 55 |
| **Peninsular total**     | **15 472 MVAr** | **135** |

The Balearic and Canary systems are non-synchronous and **excluded** — only the
peninsular fleet is modelled, matching the network. (These totals are ~70 % of
the 400 kV charging and ~85 % of the ≤220 kV charging, consistent with the
standard EHV "≈80 % compensation" planning rule.)

### Disaggregation mechanism
The aggregate fleet is distributed to individual buses **in proportion to the AC
line charging connected at each bus** (`add_reactor_shunts!`):

1. Each bus is classified into a voltage group: `base_kv ≥ 380 kV` → **400 kV**,
   otherwise → **≤220 kV**.
2. The charging connected at a bus is the sum of the half-charging of its
   incident AC lines (`b_fr` at the from-bus, `b_to` at the to-bus). Transformers
   and HVDC links contribute nothing.
3. Within each group `g`, a bus receives
   `reactor = fleet[g] × (bus charging / total group charging)`, so the group
   totals reproduce the table above and reactors land where the charging is
   actually generated.

The per-bus **installed** result (the full 100 % fleet) is cached in
**`Data/reactors.csv`** with columns:

| column | meaning |
| --- | --- |
| `bus_id` | bus identifier |
| `base_kv` | bus nominal voltage |
| `voltage_group` | `400kV` or `<=220kV` |
| `connected_charging_mvar` | line charging connected at the bus (MVAr @ 1.0 pu) |
| `reactor_installed_mvar` | allocated installed reactor capacity (MVAr) |

On later runs the file is **read back as the model input** instead of being
recomputed — so the disaggregation is fixed and reproducible. **Delete
`Data/reactors.csv` to regenerate it** (e.g. after changing the line data or the
fleet totals in `data_preparation.jl`).

### Configuration
Controlled in `config.toml`:

```toml
[reactors]
enabled        = true     # attach the reactor shunts to the AC network
in_service_pct = 100.0    # percent of the installed fleet that is energised
```

`in_service_pct` is the single knob requested for studies: it scales every
bus's reactor before it is added to the network (`bs = -installed × pct/100 /
baseMVA`). `100` energises the full fleet, `0` disables it (equivalent to
`enabled = false`), and intermediate / >100 values let you sweep how much
compensation is in service — emulating switched reactors without turning the AC
OPF into a mixed-integer problem.

## Generator reactive capability (per fuel)

Reactive limits are technology-specific, enforced in every redispatch stage
(the anchored hour-by-hour solves and the Bellman-coupled multi-hour solve):

- **Synchronous units (Nuclear, Gas, Coal, Oil, Biomass, Hydro)** — apparent-power
  capability circle
  ```
  P_g² + Q_g² ≤ S_rated²,   S_rated = installed MVA / rated_power_factor
  ```
  `S_rated` is sized on **installed** nameplate MVA (a synchronous machine's MVA
  rating is fixed regardless of output, so it can supply reactive even at low MW).
  Convex (second-order cone) → Ipopt solves it as an NLP. This replaces the old
  `±Pmax` box that let a unit reach PF 0.707 at full output.

- **Inverter-based Wind / Solar** — a grid-code reactive cap tied to **actual**
  output:
  ```
  |Q_g| ≤ tan(acos(renewable_power_factor)) · P_g
  ```
  (linear). Sizing on actual P, not nameplate, prevents a heavily-derated farm
  (e.g. 38 MW out of 100 MW installed) from parking at a very low PF — which an
  installed-MVA circle would otherwise permit.

```toml
[generators]
apparent_power_limit   = true   # enforce the limits; false RELAXES to the ±Pmax box
rated_power_factor     = 0.90   # synchronous: S_rated = installed MVA / this
renewable_power_factor = 0.95   # wind/solar: |Q| ≤ tan(acos(this))·P
```

Set `apparent_power_limit = false` to drop all of these (revert to the `±Pmax`
box) if the full model becomes too hard to solve.

## Load reactive demand

Each load is given a reactive demand `qd = pd · tan(acos(power_factor))`, where
`power_factor` is the **net** power factor the transmission grid sees at the load
bus. Distribution-level PF correction (capacitor banks, large-consumer pf
requirements) is assumed already applied below the model boundary, so this is the
residual reactive the transmission network must carry.

```toml
[load]
power_factor = 1.0     # 1.0 ⇒ active-only load; 0.98 ⇒ small lagging draw; lower ⇒ more reactive
```

This interacts directly with the reactors: at `power_factor = 1.0` the loads draw
no reactive, leaving the full line charging for the **reactors** to absorb; at a
lower PF the load reactive (~11.5 GVAr at 0.95) soaks up much of the charging
itself, so less reactor capacity is needed. Tune `[load]` and `[reactors]`
together. (Reactive shunts must live in the network `shunt` dict — PowerModels
ignores bus-level `gs`/`bs`.)

## Generator AVR voltage band

### Why
A cost-/loss-minimising AC OPF has no incentive to keep voltages near nominal —
left to itself it rails almost every bus up to the upper voltage limit, because
higher voltage means lower current and lower losses. Real grids don't behave
that way: **synchronous machines are voltage-regulated** by their automatic
voltage regulators (AVRs), which hold the machine terminal (and hence the host
bus) to a setpoint near nominal. Modelling that regulation pulls the voltage
profile off the upper rail and onto realistic setpoints.

### Mechanism
Buses are split into two voltage bands (`make_pm_network` in
`data_preparation.jl`):

- **AVR-regulated buses** — the slack bus plus every bus hosting a **synchronous
  machine** (any unit whose `primary_fuel` is *not* Wind or Solar) are held to
  the tighter `[gen_bus_vmin, gen_bus_vmax]` band, emulating the AVR setpoint.
- **All other buses** — renewable-only buses (whose reactive is capped at low
  output, so they cannot firmly regulate voltage) and load buses keep the wider
  `±voltage_band`.

Renewable-only buses are deliberately left on the wide band: their reactive
capability is tied to actual output (see *Generator reactive capability* above),
so a derated wind/solar farm can't be relied on to hold a setpoint the way a
synchronous machine can. The band is applied in every stage that builds the
network (the anchored hour-by-hour solves and the Bellman-coupled multi-hour
solve); it changes only the feasible voltage range, **not the objective**.

Effect on the redispatch profile (full fleet, 48 h): mean bus voltage
**1.037 → 1.023 pu** and the share of buses sitting at `vmax` **7.8 % → 0.9 %**.

### Configuration
Controlled in the `[network]` section of `config.toml`:

```toml
[network]
voltage_band            = 0.05   # load / renewable-only buses: ±0.05 around 1.0
gen_bus_voltage_control = true   # hold synchronous + slack buses to a tighter band
gen_bus_vmin            = 0.98
gen_bus_vmax            = 1.03
```

Set `gen_bus_voltage_control = false` to relax this — every bus then uses
`±voltage_band` (the original behaviour where the profile rails to `vmax`).
