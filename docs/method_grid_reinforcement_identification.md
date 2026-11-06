# Method — Identifying Transmission Reinforcements from an Infeasible AC OPF

A reusable workflow for turning an **infeasible AC OPF redispatch** into a **ranked, sized list of
lines to expand**. Developed 2026-07-07 on the EMPIRE 2035 NECPEssentials coupling (see
`results/NECPEssentials/feasibility_findings.md`), but applies to any scenario where a future
generation/demand portfolio is run on an existing network.

## When to use it
The market/energy stages clear, but the AC OPF (redispatch) reports `LOCALLY_INFEASIBLE` /
"converged to a point of local infeasibility" on some or all hours. You want to know **whether the grid
is the wall** and, if so, **which corridors to reinforce and by how much**.

## Steps

### 1. Confirm it's network-bound, not a setup bug
Relax the network limits generously in one run — raise `line_rating_factor` (thermal headroom over
nominal) and `voltage_band` — and re-solve.
- Feasibility jumps (e.g. 0/48 → 36/48) ⇒ network-capacity-bound, continue.
- Still 0/48 even wide-open ⇒ a structural/modelling problem (fixed injections, frozen units, data);
  diagnose that instead.

### 2. Isolate thermal vs. voltage — change ONE dimension at a time
Relax only the voltage side (e.g. `gen_bus_vmax` 1.03 → 1.08, or `gen_bus_voltage_control = false`).
- **Zero change in feasible-hour count ⇒ not voltage-bound.** (This is the decisive test — a real
  voltage limit would recover at least one hour.)
- If it helps, the residual is reactive/voltage; pursue reactive support (reactors, gen Q-limits)
  instead of thermal ratings.

Also read *which* hours fail: clustering at **low-load hours** with **low congestion counts** points to
a few long-distance export corridors (e.g. remote hydro/wind to load centres), not broad overload.

### 3. Solve with only intrazonal candidates uncongested
Keep the normal `line_rating_factor`. Apply `diagnostic_intra_nuts_multiplier` to branches whose
terminal buses are in the same Spanish NUTS3 region. By default, EMPIRE-derived inter-NUTS3 and
international capacity remains fixed. A bounded sensitivity can be run with
`diagnostic_inter_nuts_multiplier` (for example, 1.5 for 50% additional inter-NUTS3 capacity).
International links remain fixed in the reinforcement workflow. The separate
`diagnostic_international_multiplier` is reserved for controlled sensitivity tests and defaults
to 1.0. Raise the intrazonal multiplier until no eligible intrazonal branch binds.

Before interpreting a failed redispatch as a reinforcement need, derive hourly
network-consistent directional NTCs and use them in DA. The diagnostic runner
now does this with a 0.70 reliability margin and bypasses ID2/ID3/CID/BAL, so DA
feeds redispatch directly. This separates an infeasible static commercial
exchange schedule from a genuine internal reinforcement requirement. The NTC
calculation and redispatch both preserve each country's DA total while allowing
a sign-consistent allocation among its physical boundary buses.

### 4. Back out each line's required rating factor
For an eligible branch, `limit_mw = base_line_rating_factor × diagnostic_multiplier × nominal_rating`, and
`loading_pct = 100 · |flow| / limit_mw`. Therefore the minimum rating factor a line needs is:

```
req_factor(line) = max_over_hours( loading_pct ) × base_LRF × diagnostic_multiplier / 100
```

Equivalently `req_factor = peak(|flow|)/nominal`. Only rows marked
`reinforcement_eligible=true` enter the reinforcement list.

### 5. Rank and size
- **Minimum uncongested intrazonal diagnostic multiplier = max over eligible lines of
  `req_factor / base_LRF`** — set by the single worst intrazonal asset. Fixed EMPIRE corridors are
  excluded from this maximum.
- Reinforcement candidates = lines with `req_factor` above the current operating factor; rank
  descending. Count how many exceed 1.0× (nominal), 1.5×, 2.0× to show whether the need is targeted or
  systemic.

### 6. Validate
Re-run at (or just above) the system-minimum factor and confirm full feasibility. Because flows
**redistribute as limits bind**, the step-4 estimate from the uncongested solve is *first-order* — the
validation run is what confirms the sized list.

## Reference implementation (pandas)
```python
b = pd.read_csv('results/<scenario>/branch_peaks.csv')
req = b[b.reinforcement_eligible].copy()
req['req_factor'] = (req.loading_pct * req.base_line_rating_factor
                     * req.diagnostic_multiplier / 100.0)
req['minimum_diagnostic_multiplier'] = (req.req_factor /
                                        req.base_line_rating_factor)
req = req.sort_values('req_factor', ascending=False)
minimum_multiplier = req['minimum_diagnostic_multiplier'].max()
for t in (0.8, 1.0, 1.5, 2.0, 3.0):
    print(f'branches needing > {t}x:', int((req.req_factor > t).sum()))
```
Map it: draw branches (endpoints are 1-based bus indices into `Data/Bus_Data.csv`, x=lon/y=lat) colored
by `req_factor` — see the reinforcement-map cell in `results_plots_2035.ipynb`.

For a short or full-year diagnostic, use `cluster/run_reinforcement_diag.sh`, for example
`bash cluster/run_reinforcement_diag.sh NECPEssentials 10 2 1.5` for 336 hours with a 50%
inter-NUTS3 allowance. It enables
the memory-bounded `diagnostic_output` path: `run_market_chain.jl` writes one maximum row
per branch to `branch_peaks.csv` instead of materialising the full
hours-by-branches table. `cluster/derive_reinforcement.py` accepts either this
compact file or the legacy `branch_flows.csv` and refuses to size a list unless
every row in `summary.csv` solved successfully. Its second argument is the selective intrazonal
multiplier, not a global LRF. The runner keeps the base rating factor at 0.8;
an optional fifth argument applies a diagnostic international multiplier (for example, `2.0`
for +100%) while leaving the default international-fixed behavior unchanged. The emitted
`reinforcement.csv` stores `factor=req_factor`, the absolute required rating as a fraction of
nameplate; `run_market_chain.jl` applies the 0.8 security-margin conversion exactly once when loading it.
An optional sixth argument selects the boundary split. The default,
`country_total`, keeps each country's DA exchange exact during both hourly NTC
calculation and redispatch while allowing a sign-consistent reallocation among
its boundary buses. Pass `fixed` to retain every rating-proportional bus share.

## Caveats
- First-order: uncongested flows differ from constrained flows; always validate (step 6).
- Assumes symmetric thermal limits and that curtailment/redispatch freedom is the same across the sweep.
- Only meaningful once step 2 has confirmed the binding mechanism is thermal.
