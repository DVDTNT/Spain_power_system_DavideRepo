# Method — Nodal disaggregation of EMPIRE expansion results

How the EMPIRE investment results (generation, transmission, storage per
NUTS3 node) are mapped onto the bus-level Spanish grid for the market chain
and the redispatch stage.  Implementation: `empire_nodal.jl`; activated by
`config.toml → [scenario] disaggregation = "nodal"` (default for scenario
runs; `"zonal"` restores the original national per-tech scaling).

Standalone diagnostics (no market run needed):

```
julia --project=. empire_nodal.jl
```

writes `results/<label>/nodal/{unit_scale, new_units, gen_regions,
line_scale, new_lines, corridors, bess_units}.csv` and prints a national
consistency check (fleet totals must equal EMPIRE's per tech).

## Why the zonal method was not enough

The original loader (`empire_scenario.jl`) reduced everything to national
aggregates: one growth ratio per tech applied uniformly to every 2024 unit,
BESS split over the top-20 load buses countrywide, and **all 232 intra-ES
corridor rows of `transmissionInstalledCap.tab` discarded** (only zonal
ES/FR/PT/EU NTCs were kept).  Consequences:

* new capacity was sited proportionally to today's fleet, ignoring *where*
  EMPIRE actually built it;
* techs new to the system (BioCCS, Waste) were silently dropped;
* EMPIRE's internal-grid reinforcement never reached the bus-level `rate_a`,
  which is one reason the 2035 AC OPF redispatch was infeasible on the 2024
  network (see `method_grid_reinforcement_identification.md`).

## Step 1 — Bus → NUTS3 assignment

Every bus in `Data/Bus_Data.csv` (x = lon, y = lat) is placed in a NUTS3
polygon from `Data/nuts3_es.geojson` by even-odd ray casting (hole-correct,
multipolygon-aware).  Buses that miss every polygon (coastal substations)
snap to the region with the nearest polygon vertex.  Foreign border buses
keep their country code.  Result cached in `Data/bus_nuts3.csv` — delete it
(or call `bus_nuts3(refresh = true)`) after a `Bus_Data.csv` change.
GoRES check: 1217/1227 buses direct polygon hit, 10 coastal snaps.

## Step 2 — Generation

For each (NUTS3 region, EMPIRE tech) with target `T` = genInstalledCap at
the period and existing capacity `E` (2024 units mapped via their bus and
the `(fuel, technology) → EMPIRE tech` table `EMPIRE_UNIT_TECH`):

* `E > 0` → every unit in the region is scaled by `T / E` (regional match is
  exact, so national totals match by construction; `T = 0` retires the
  region's fleet);
* `E = 0`, tech buildable → greenfield units `NEW_<tech>_<region>_<k>` are
  created on the region's 3 highest-load buses, load-proportional;
* `E = 0`, tech site-bound (`Hydro regulated`, `Hydro run-of-the-river`,
  `Nuclear`) → the orphan target is spread uniformly over the existing
  national fleet of that tech (no greenfield hydro/nuclear);
* regions EMPIRE covers but the grid does not (off-grid islands) have their
  targets redistributed proportionally over the mapped regions first;
* techs EMPIRE retires entirely (absent from genInstalledCap) get factor 0.

Greenfield techs are priced through `empire_cost_override` (EMPIRE marginal
cost + CO2 adder — negative for BioCCS), via the extra
`EMPIRE_UNIT_TECH` entries for (Waste, BioCCS, CCS variants, …).

Pumped storage keeps the zonal treatment (national power match onto the 15
existing PHS units) — its energy constraint lives in the storage tabs, not
genInstalledCap.

VRE hourly availability remains the national profile shape (scaled by the
national growth ratio); what the nodal method changes is *where* the
capacity injects, which is what the redispatch feels.

## Step 3 — Transmission (the redispatch-critical part)

EMPIRE's intra-ES corridor capacities (NUTS3 pair → MW) become per-line
expansion factors:

* corridor factor `f = installed(period) / initial` (both tabs deduplicated
  with `max`, unordered pair key);
* every physical line — AC or HVDC — whose endpoints lie in the two regions
  is scaled by `f`, modelled as **f parallel circuits**: thermal rating and
  shunt charging × f, series impedance / f (implemented as an `nc`
  multiplier in `data_preparation.jl`, so it composes with
  `[network] line_rating_factor`);
* factors are floored at 1.0 (raw values < 1 are reported, not applied);
* **border-mismatch re-matching**: EMPIRE corridors with initial capacity
  but no directly-crossing line are re-matched to unclaimed cross-region
  line groups sharing one region, choosing the candidate whose aggregate
  nameplate rating is closest to the EMPIRE initial capacity.  (Example:
  the Sagunto HVDC converter of the Rómulo link lands in ES522 by polygon,
  while EMPIRE models the corridor as ES523–ES532; the re-match applies the
  4.75× Balearic reinforcement to LTGES0254.)
* corridors with initial ≈ 0 and installed ≥ 50 MW are **new corridors**: a
  synthetic 400 kV line is created between the two regions' anchor buses
  (strongest 400 kV bus by connected line rating), haversine distance
  × 1.3 detour, median 400 kV per-length parameters, Imax sized so
  √3·V·Imax equals the corridor capacity.

Corridors that still match nothing are listed in
`results/<label>/nodal/corridors.csv` with a note; with GoRES all of them
carry zero investment, so nothing is lost.

## Step 4 — Storage

Li-Ion BESS is sited per NUTS3 node from `stor{PW,EN}InstalledCap.tab`,
split over each region's 2 highest-load buses (previously: national top-20
split).  GoRES 2035: 13.9 GW / 27.8 GWh over 94 sites, dominated by ES511
(Barcelona, 4.1 GW) and ES300 (Madrid, 3.8 GW).

## Interpretation caveats

* Line scaling assumes reinforcement replicates the existing corridor
  (parallel-circuit model); EMPIRE says nothing about voltage level or
  routing of the new build.
* Greenfield siting on high-load buses is a neutral prior, not a siting
  study; swap `_region_site_buses` for a smarter rule if needed.
* EMPIRE's transport-model investment does not guarantee AC feasibility of
  the resulting nodal grid — if the redispatch is still infeasible, that is
  now a *finding* about the scenario (EMPIRE under-invests in the internal
  grid), not an artefact of ignored investments.  Quantify the residual gap
  with `method_grid_reinforcement_identification.md`.
