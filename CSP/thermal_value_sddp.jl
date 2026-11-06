# ==============================================================
# Thermal value for the CSP/TES plant — SDDP à la ReSDDP
# ==============================================================
# The hydropower water value of the PowerVision paper, recast for heat.
#
# In the paper (resddp_original/PowerVision_Paper.pdf), a long-term SDDP model
# (FanSi — in this codebase's pipeline the ReSDDP package, resddp_original/)
# computes WATER VALUES: "the dual value of the water balance constraint of
# the respective reservoir ... the benefit of an additional unit of water" —
# the opportunity cost of generating instead of saving water. The short-term
# market then bids hydro at C(P) = W·Q'(P): a unit sells when the price
# exceeds its water-value marginal cost.
#
# This module computes the same object for the CSP/TES plant, water → heat:
#
#   ReSDDP (hydro)                       this module (CSP thermal)
#   ----------------------------------  ----------------------------------
#   reservoir storage      [GWh]         TES tank level q      [MWh_th]
#   water inflow          [GWh/wk]      solar-thermal inflow  [MWh_th/day]
#   weekly stage (56 steps)             daily stage (24 hourly steps)
#   state dual of :rstate               dual of the TES state constraint
#   cut alpha >= CRHS + CCR·res         cut alpha >= b + a·q_end
#   BellmanValuesOUT_sddp4_*.csv        results/csp_sddp/cuts.csv
#   water value = -a1 of binding cut     THERMAL VALUE = -slope of binding cut
#   loaded by bellman.jl -> da.jl       for Option A's solve_da TES block
#                                       (option_A_chain_native_csp_design.md A.4/A.9)
#
# Algorithm — mirrors ReSDDP's train!/SolveFWD/SolveBWD (src/train.jl,
# solvefwd.jl, solvebwd.jl), compressed to one plant and daily stages:
#   * forward pass: sample day-type trajectories (n_scen), run the daily LP
#     with the current cuts, record visited TES states and simulated cost —
#     the mean is the statistical UPPER bound on the expected total cost;
#   * backward pass (stage n_stages:-1:2): for every visited state, solve the
#     daily LP once per scenario branch — the branch set is exhaustive, so
#     each cut is an EXACT expectation — and read the dual π of the TES state
#     constraint. One cut per (stage, forward scenario) per iteration:
#         alpha >= b + a·q_end,  a = E[π],  b = E[objective − π·q_visited]
#     (solvebwd.jl: CCR += bProb·shadow_price(rstate);
#                  CRHS += bProb·(rhs − rhsDelta))
#   * all cuts of a stage are kept forever (ReSDDP's CCR/CRHS grow by NScen
#     per iteration); the stage LP takes alpha = max over its stage's cuts;
#   * convergence: relative gap of the upper vs first-stage lower bound
#     below eps — ReSDDP's SumForward/SumBackward test.
#
# Sign convention — identical to bellman.jl: cuts lower-bound the expected
# future COST-to-go, slopes are <= 0, and the thermal value is
#     TV(q) = −slope of the binding cut at q   [EUR/MWh_th].
# The plant sells electricity in hour h iff  eta_power·price[h] >= TV(q_end):
# the heat's opportunity cost — the paper's C(P) = W·Q'(P) with Q' = 1/eta_power.
#
# Outputs (results/csp_sddp/ by default):
#   cuts.csv          stage, cut, slope, intercept (+ thermal value column)
#   value_curve.csv   V(q) and TV(q) on a tank grid — the "when to sell" lookup
#   convergence.csv   iteration, lower bound, upper bound, relative gap
#   apply_<date>.csv  study-day dispatch under the trained thermal value
#
# Usage:  julia --project=. CSP/thermal_value_sddp.jl --plants-file Data/csp_plants.csv --plant-id demo --archetypes
#         (SYNTHETIC demo branches; add --plants-file/--plant-id to pick the plant
#         row — there is no default plant)
#         julia --project=. CSP/thermal_value_sddp.jl --plants-file Data/csp_plants.csv --plant-id demo --scenarios F.csv
#         (your own branch set — columns name,prob,hour,price_eur_mwh,solar_avail_mwth,
#         24 rows per branch)
# Running with NO --plants-file/--plant-id, or with no scenario source, is an
# error: the demo refuses to guess the plant (no built-in default exists) or
# the branch data (synthetic vs real).
# ==============================================================

isdefined(Main, :CSP) || include(joinpath(@__DIR__, "..", "CSP.jl"))

using JuMP, HiGHS, CSV, DataFrames, Printf, Random, Statistics

# ---------------------------------------------------------------
# Plant and daily scenario branches
# ---------------------------------------------------------------

"""Physical/policy parameters of the CSP/TES plant.

The plant IS `CSP.CSPPlant` — one row of the plants overlay file
(Data/csp_plants.csv), the single source of plant truth shared with Option
B, the standalone demos and the weekly scenarios. There is no built-in
default plant: load it from the file (`CSP.get_csp_plant(path, id)`) or pass
every field explicitly (as the tests do)."""
const ThermalPlant = CSP.CSPPlant

"""One daily branch: probability, 24-h sell price [EUR/MWh_e] and 24-h field
availability [MW_th]. Price and solar-thermal availability are JOINTLY
uncertain (a sunny day is also a low-price day) — the analog of ReSDDP's
correlated inflow scenario."""
struct ThermalDayScenario
    name::String
    prob::Float64
    sell_price::Vector{Float64}
    solar_avail::Vector{Float64}
end

# --- the three weather archetypes of CSP/csp_weekly_scenarios.jl -----------

# Stylised Spanish summer DA day: night base, morning shoulder, midday PV-glut
# dip (scaled by dip_mult — deep in clear weather), evening peak, late ramp.
function _archetype_price(; dip_mult::Float64 = 1.0, peak_mult::Float64 = 1.0)
    p = fill(35.0, 24)                 # night base      h00-07, h17
    p[8:10]  .= 45.0                   # morning         h07-09
    p[11:17] .= 15.0 .* dip_mult       # PV-glut dip     h10-16
    p[18:19] .= 40.0                   # shoulder        h17-18
    p[20:22] .= 102.0 .* peak_mult     # evening peak    h19-21
    p[23:24] .= 55.0                   # late            h22-23
    return p
end

# Clear-sky geometric bell (CSP.solar_thermal_shape, normalised to its peak)
# scaled by the day type's clearness.
function _archetype_solar(plant::ThermalPlant; clearness::Float64)
    shape = CSP.solar_thermal_shape("2024-07-08")
    m = maximum(shape)
    m > 0 || return zeros(24)
    return plant.solar_capacity_mwth .* (shape ./ m) .* clearness
end

"""Default branch set — the three weather archetypes with July-like
probabilities. Replace with any Vector{ThermalDayScenario} (e.g. a DNI/price
dataset) to train on other data."""
function default_scenario_set(plant::ThermalPlant;
        probs = (clear = 0.45, mixed = 0.40, overcast = 0.15))
    total = probs.clear + probs.mixed + probs.overcast
    abs(total - 1.0) < 1e-9 ||
        error("scenario probabilities must sum to 1, got $total")
    return [
        ThermalDayScenario("clear",    probs.clear,
            _archetype_price(dip_mult = 0.55, peak_mult = 1.00),
            _archetype_solar(plant, clearness = 1.00)),
        ThermalDayScenario("mixed",    probs.mixed,
            _archetype_price(dip_mult = 1.00, peak_mult = 1.05),
            _archetype_solar(plant, clearness = 0.55)),
        ThermalDayScenario("overcast", probs.overcast,
            _archetype_price(dip_mult = 1.60, peak_mult = 1.20),
            _archetype_solar(plant, clearness = 0.15)),
    ]
end

# ---------------------------------------------------------------
# Cuts and the daily stage LP
# ---------------------------------------------------------------

"""One affine lower bound of the expected cost-to-go as a function of the TES
level q at the END of stage `stage` (entering stage+1 — ReSDDP's CCR[t-1] /
CRHS[t-1] index):
    E[cost-to-go](q) >= intercept + slope·q ,   slope <= 0.
The thermal value is −slope of the binding cut (bellman.jl's water value)."""
struct ThermalValueCut
    stage::Int
    slope::Float64     # EUR per MWh_th, <= 0 (more heat -> less future cost)
    intercept::Float64 # EUR
end

"""Value of the cut set at TES level q — the max over cuts, i.e. the LP's alpha."""
function value_at(cuts::Vector{ThermalValueCut}, q::Float64)
    isempty(cuts) && return 0.0
    return maximum(c.intercept + c.slope * q for c in cuts)
end

"""Thermal value [EUR/MWh_th] = −slope of the binding cut at q — the direct
analog of bellman.jl's binding_water_value (and of the paper's water value:
the dual of the storage-balance state, the benefit of one more unit of heat)."""
function binding_thermal_value(cuts::Vector{ThermalValueCut}, q::Float64)
    isempty(cuts) && return 0.0
    best = argmax(c -> c.intercept + c.slope * q, cuts)
    return -best.slope
end

# Persistence terminal valuation for the last stage (CSP.jl's single-cut
# formula, cost convention): heat is worth eta_power·E[price] per MWh_th,
# crowded toward zero when the expected branch day is rich in solar.
function _persistence_terminal_value(plant::ThermalPlant,
                                     scenarios::Vector{ThermalDayScenario})
    e_price = sum(s.prob * mean(s.sell_price) for s in scenarios)
    e_solar = sum(s.prob * mean(s.solar_avail) for s in scenarios)
    crowding = max(0.0, 1.0 - e_solar / plant.solar_capacity_mwth)
    return plant.eta_power * e_price * crowding
end

"""Build one daily stage LP — the physics of CSP.jl's market stage, plus the
SDDP state and future-value machinery:
  * state   : q_tes[0] fixed by constraint :tes_state (rhs set per trial);
  * physics : field <= availability, block <= pmax_e, tank balance with the
    proportional leak, heater <= pmax_charge_e, floor q_tes[24] >= target;
  * future  : alpha >= intercept_c + slope_c·q_tes[24] over `next_cuts`
    (stage LPs take the cuts of their stage; the LAST stage is given a single
    terminal cut instead). With no cuts, alpha is fixed to 0.
Objective (min): sum(eff_buy·p_buy) − sum(price·p_gen) + alpha, where
eff_buy prices planned grid purchases at max(price, grid_price_floor) unless
the price is negative (then the plant is paid to consume)."""
function _build_stage_lp(plant::ThermalPlant, scenario::ThermalDayScenario,
                         next_cuts::Vector{ThermalValueCut})
    T = 24
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    p_gen   = @variable(model, 0 <= p_gen[1:T]   <= (plant.allow_sell ? plant.pmax_e_mwe : 0.0))
    p_buy   = @variable(model, 0 <= p_buy[1:T]   <= (plant.buy_from_grid ? plant.pmax_charge_e_mwe : 0.0))
    s_solar = @variable(model, 0 <= s_solar[1:T] <= plant.solar_capacity_mwth)
    q_tes   = @variable(model, 0 <= q_tes[0:T]  <= plant.tes_capacity_mwhth)
    q_dis   = @variable(model, 0 <= q_dis[1:T]  <= plant.pmax_e_mwe / plant.eta_power)
    q_ch    = @variable(model, 0 <= q_ch[1:T]   <= plant.pmax_charge_e_mwe)
    leak    = @variable(model, 0 <= leak[1:T]   <= plant.thermal_leak_rate * plant.tes_capacity_mwhth)
    alpha   = @variable(model, -1.0e12 <= alpha <= 1.0e12)
    for t in 1:T
        @constraint(model, s_solar[t] <= scenario.solar_avail[t])
        @constraint(model, p_gen[t] <= plant.eta_power * q_dis[t])
        @constraint(model, q_ch[t] == plant.eta_charge * p_buy[t])
        @constraint(model, leak[t] == plant.thermal_leak_rate * q_tes[t-1])
        @constraint(model, q_tes[t] == q_tes[t-1] + plant.eta_solar * s_solar[t]
                                   + q_ch[t] - q_dis[t] - leak[t])
    end
    @constraint(model, tes_state, q_tes[0] == 0.0)      # state entry (rhs per trial)
    @constraint(model, q_tes[T] >= plant.q_end_target_mwhth)  # daily hand-over floor
    # ReSDDP's AlphaMax trick: with no cuts yet, alpha stays FREE within its
    # big bounds (-> -1e12 in the min), which trivially under-approximates the
    # future cost-to-go — the first-stage lower bound stays valid. Fixing alpha
    # to 0 instead would OVER-approximate a profitable future and make the
    # gap test converge spuriously at iteration 1.
    for c in next_cuts
        @constraint(model, alpha - c.slope * q_tes[T] >= c.intercept)
    end
    eff_buy = [scenario.sell_price[t] < 0 ? scenario.sell_price[t] :
               max(scenario.sell_price[t], plant.grid_price_floor_eur_mwh) for t in 1:T]
    @objective(model, Min,
        sum(eff_buy[t] * p_buy[t] for t in 1:T)
        - sum(scenario.sell_price[t] * p_gen[t] for t in 1:T)
        + alpha)
    return model
end

# ---------------------------------------------------------------
# Training — forward/backward passes à la ReSDDP train!
# ---------------------------------------------------------------

"""SDDP training settings (ReSDDP examples/params.jl analog)."""
Base.@kwdef struct ThermalValueSettings
    n_stages::Int     = 14      # daily stages (ReSDDP: NStage weekly)
    n_scen::Int       = 30      # forward scenarios per iteration (ReSDDP: NScen)
    max_iter::Int     = 40      # MaxIter (ReSDDP: 50)
    conv_eps::Float64 = 1e-3    # ConvEps on the relative UB/LB gap
    seed::Int         = 12345
    terminal::Symbol  = :zero   # :zero | :persistence (valuation beyond horizon)
    verbose::Bool     = true
end

"""
    train_thermal_value(plant, scenarios, settings; q0) -> (cuts, convergence)

cuts[t] prices the END state of stage t (entering stage t+1); the last stage
gets no cuts (the terminal valuation is a single cut). Mirrors ReSDDP's
train!: forward pass first (statistical upper bound + visited trial states),
backward pass second — one cut per (stage, forward scenario) per iteration,
from the probability-weighted duals of the TES state constraint over ALL
branches — converged when the relative gap (UB−LB)/|LB| < conv_eps.
"""
function train_thermal_value(plant::ThermalPlant,
                             scenarios::Vector{ThermalDayScenario},
                             settings::ThermalValueSettings = ThermalValueSettings();
                             q0::Float64 = plant.q_end_target_mwhth)
    (plant.buy_from_grid || plant.q_end_target_mwhth <= 0.0) ||
        error("Without grid purchases a dark branch cannot refill the tank " *
              "to the floor, making stage LPs infeasible. Enable buy_from_grid, " *
              "set q_end_target = 0, or add ReSDDP-style feasibility cuts.")
    abs(sum(s.prob for s in scenarios) - 1.0) < 1e-9 ||
        error("scenario probabilities must sum to 1")
    NS = settings.n_stages
    n = length(scenarios)
    terminal_slope = settings.terminal === :zero ? 0.0 :
        settings.terminal === :persistence ?
            -_persistence_terminal_value(plant, scenarios) :
            error("settings.terminal must be :zero or :persistence")

    cuts = [Vector{ThermalValueCut}() for _ in 1:NS]  # cuts[t] -> end state of t
    rng = MersenneTwister(settings.seed)
    traj = zeros(settings.n_scen, NS)                 # visited end states
    iters = Int[]; lbs = Float64[]; ubs = Float64[]; gaps = Float64[]
    converged = false
    for it in 1:settings.max_iter
        # ---------------- forward pass (SolveFWD) ----------------
        paths = [rand(rng, 1:n, NS) for _ in 1:settings.n_scen]
        sim_cost = zeros(settings.n_scen)
        lb_vals  = zeros(settings.n_scen)
        for s in 1:settings.n_scen
            q = q0
            for t in 1:NS
                next_cuts = t < NS ? cuts[t] :
                    [ThermalValueCut(t, terminal_slope, 0.0)]
                model = _build_stage_lp(plant, scenarios[paths[s][t]], next_cuts)
                set_normalized_rhs(model[:tes_state], q)
                optimize!(model)
                termination_status(model) == MOI.OPTIMAL ||
                    error("forward LP not optimal (iter $it, scen $s, stage $t): " *
                          string(termination_status(model)))
                obj = objective_value(model)
                sim_cost[s] += obj - value(model[:alpha])
                t == 1 && (lb_vals[s] = obj)
                q = value(model[:q_tes][NS])
                traj[s, t] = q
            end
        end
        LB = mean(lb_vals); UB = mean(sim_cost)
        rel = abs(LB) > 1e-9 ? (UB - LB) / abs(LB) : UB - LB
        push!(iters, it); push!(lbs, LB); push!(ubs, UB); push!(gaps, rel)
        settings.verbose && @printf(
            "  SDDP iter %3d   lower %12.2f   upper %12.2f   rel.gap %9.5f\n",
            it, LB, UB, rel)
        if rel < settings.conv_eps
            converged = true
            break
        end
        # ---------------- backward pass (SolveBWD) ----------------
        for t in NS:-1:2
            a_acc = zeros(settings.n_scen); b_acc = zeros(settings.n_scen)
            next_cuts = t < NS ? cuts[t] :
                [ThermalValueCut(t, terminal_slope, 0.0)]
            for scen in scenarios
                model = _build_stage_lp(plant, scen, next_cuts)
                for s in 1:settings.n_scen
                    set_normalized_rhs(model[:tes_state], traj[s, t-1])
                    optimize!(model)
                    termination_status(model) == MOI.OPTIMAL ||
                        error("backward LP not optimal (iter $it, stage $t, " *
                              "scen $s): " * string(termination_status(model)))
                    dual = shadow_price(model[:tes_state])
                    a_acc[s] += scen.prob * dual
                    b_acc[s] += scen.prob *
                        (objective_value(model) - dual * traj[s, t-1])
                end
            end
            for s in 1:settings.n_scen
                push!(cuts[t-1], ThermalValueCut(t-1, a_acc[s], b_acc[s]))
            end
        end
    end
    settings.verbose && println(converged ?
        "  SDDP converged (relative gap < $(settings.conv_eps))" :
        "  SDDP stopped at max_iter = $(settings.max_iter)")
    return cuts, DataFrame(iteration = iters, lower_bound = lbs,
                           upper_bound = ubs, rel_gap = gaps)
end

# The scenario set is DELIBERATELY required — refusing to guess beats silently
# training on synthetic branches nobody asked for.
function train_thermal_value(plant::ThermalPlant; kwargs...)
    error("train_thermal_value needs an explicit scenario set: pass a " *
          "Vector{ThermalDayScenario} (e.g. read_thermal_scenarios(\"file.csv\") " *
          "for real data), or default_scenario_set(plant) if you explicitly want " *
          "the SYNTHETIC clear/mixed/overcast archetypes")
end

# ---------------------------------------------------------------
# Export and application — the "when to sell" layer
# ---------------------------------------------------------------

"""
    read_thermal_scenarios(path) -> Vector{ThermalDayScenario}

Load a branch set from CSV — the "real data" entry point for the thermal-value
training. One row per (branch, hour), columns:
    name, prob, hour, price_eur_mwh, solar_avail_mwth
`name` groups 24 rows (hours 0..23); `prob` is the branch probability
(validated for consistency and for summing to 1). Any measured price/DNI
dataset can be tabulated here.
"""
function read_thermal_scenarios(path::AbstractString)
    isfile(path) || error("scenario file not found: $path — expected columns " *
        "name,prob,hour,price_eur_mwh,solar_avail_mwth (24 rows per branch)")
    df = CSV.read(path, DataFrame)
    for col in (:name, :prob, :hour, :price_eur_mwh, :solar_avail_mwth)
        hasproperty(df, col) ||
            error("scenario file $path lacks column '$col' (expected: " *
                  "name,prob,hour,price_eur_mwh,solar_avail_mwth)")
    end
    scen = ThermalDayScenario[]
    for g in groupby(df, :name)
        name = string(g[1, :name])
        idx = sortperm(Int.(g.hour))
        hours = Int.(g.hour[idx])
        hours == collect(0:23) ||
            error("branch '$name' must cover hours 0..23 exactly once (got $(hours[1])..$(hours[end]), $(length(hours)) rows)")
        prob = Float64(g[1, :prob])
        all(Float64.(g.prob) .== prob) ||
            error("branch '$name' has inconsistent probabilities")
        push!(scen, ThermalDayScenario(name, prob,
            Float64.(g.price_eur_mwh[idx]), Float64.(g.solar_avail_mwth[idx])))
    end
    isempty(scen) && error("scenario file $path contains no branches")
    total = sum(s.prob for s in scen)
    abs(total - 1.0) < 1e-9 ||
        error("branch probabilities of $path sum to $total — they must sum to 1")
    return scen
end

"""Write the cut set in the BellmanValuesOUT convention (stage, slope,
intercept — cf. bellman.jl's Timestep/a_1/b) plus a thermal-value column."""
function save_cuts(cuts::Vector{Vector{ThermalValueCut}}, path::AbstractString)
    mkpath(dirname(abspath(path)))
    df = DataFrame(stage = Int[], cut = Int[], slope_eur_per_mwhth = Float64[],
                   intercept_eur = Float64[], thermal_value_eur_per_mwhth = Float64[])
    for t in eachindex(cuts), (c, cut) in enumerate(cuts[t])
        push!(df, (cut.stage, c, cut.slope, cut.intercept, -cut.slope))
    end
    CSV.write(path, df)
    return path
end

"""Thermal-value curve of a stage on a tank grid: V(q) = max over cuts (the
expected cost-to-go) and TV(q) = −slope of the binding cut — the heat analog
of a hydro water-value curve. Read it as: with the tank at q at end of day,
one more MWh_th is worth TV(q), so sell in hour h iff
eta_power·price[h] >= TV(q)."""
function thermal_value_curve(cuts::Vector{ThermalValueCut}, plant::ThermalPlant;
                             n_grid::Int = 37)
    qs = collect(range(0.0, plant.tes_capacity_mwhth; length = n_grid))
    return DataFrame(q_mwhth = qs,
        value_eur = [value_at(cuts, q) for q in qs],
        thermal_value_eur_per_mwhth =
            [binding_thermal_value(cuts, q) for q in qs])
end

"""DA prices [EUR/MWh_e] of one day from the chain's market_prices.csv."""
function _da_prices_for_day(price_file::AbstractString, day::AbstractString)
    isfile(price_file) || return Float64[]
    df = CSV.read(price_file, DataFrame)
    rows = filter(r -> string(r.date) == day && string(r.stage) == "DA", df)
    sort!(rows, :hour)
    return Float64.(rows.price_eur_mwh)
end

"""
    solve_day_with_thermal_value(plant, cuts, sell_price, solar_avail; q0)

One-day dispatch under a trained cut set: the daily LP with the cuts pricing
the end state — exactly what Option A's solve_da TES block will do with
cuts.csv. Returns the hourly dispatch, the end state and the thermal value at
the end state (the plant's marginal heat cost for the day).
"""
function solve_day_with_thermal_value(plant::ThermalPlant,
                                      cuts::Vector{ThermalValueCut},
                                      sell_price::Vector{Float64},
                                      solar_avail::Vector{Float64};
                                      q0::Float64 = plant.q_end_target_mwhth)
    (length(sell_price) == 24 && length(solar_avail) == 24) ||
        error("sell_price and solar_avail must have 24 hourly entries")
    scen = ThermalDayScenario("apply", 1.0, sell_price, solar_avail)
    model = _build_stage_lp(plant, scen, cuts)
    set_normalized_rhs(model[:tes_state], q0)
    optimize!(model)
    termination_status(model) == MOI.OPTIMAL ||
        error("day LP not optimal: " * string(termination_status(model)))
    q_end = value(model[:q_tes][24])
    eff_buy = [sell_price[t] < 0 ? sell_price[t] :
               max(sell_price[t], plant.grid_price_floor_eur_mwh) for t in 1:24]
    return (status = "OPTIMAL",
        objective = objective_value(model),
        net_cash_eur = sum(sell_price[t] * value(model[:p_gen][t]) for t in 1:24)
                     - sum(eff_buy[t] * value(model[:p_buy][t]) for t in 1:24),
        p_gen   = collect(value.(model[:p_gen])) .+ 0.0,
        p_buy   = collect(value.(model[:p_buy])) .+ 0.0,
        s_solar = collect(value.(model[:s_solar])) .+ 0.0,
        q_tes   = [value(model[:q_tes][i]) for i in 0:24],  # 25 entries: [1] = h0 start
        q_end   = q_end,
        thermal_value_end = binding_thermal_value(cuts, q_end))
end

# ---------------------------------------------------------------
# Demo — train, export, apply to the Trinity study days
# ---------------------------------------------------------------

"""
Resolve the demo's branch source from its command-line arguments. Explicit by
design: synthetic archetypes need `--archetypes`, a real dataset needs
`--scenarios <file.csv>`; with no arguments the demo refuses to guess — the
archetypes must never run as a silent default.
"""
function _demo_scenarios(args::Vector{String}, plant::ThermalPlant)
    isempty(args) && error(
        "no scenario source given — the thermal-value demo refuses to guess.\n" *
        "  julia --project=. CSP/thermal_value_sddp.jl --archetypes\n" *
        "      SYNTHETIC demo branches (clear/mixed/overcast) — illustrative July-like\n" *
        "      profiles, NOT measured data.\n" *
        "  julia --project=. CSP/thermal_value_sddp.jl --scenarios F.csv\n" *
        "      your own branch set: columns name,prob,hour,price_eur_mwh,\n" *
        "      solar_avail_mwth, 24 rows per branch (hours 0..23).")
    if args[1] == "--archetypes"
        @warn "training on the SYNTHETIC archetype branches (clear/mixed/overcast) — " *
              "illustrative July-like profiles, NOT measured data. Pass " *
              "--scenarios <file.csv> to train on real prices/irradiance."
        return default_scenario_set(plant), "SYNTHETIC archetypes"
    elseif args[1] == "--scenarios"
        length(args) >= 2 || error("--scenarios needs a file path")
        return read_thermal_scenarios(args[2]), args[2]
    else
        error("unknown option '$(args[1])' — use --archetypes or --scenarios <file.csv>")
    end
end

"""Parse the demo's --plants-file/--plant-id and return (plant, remaining
args). Both are REQUIRED — there is no built-in default plant."""
function _demo_plant(args::Vector{String})
    file = nothing
    pid = nothing
    rest = String[]
    i = 1
    while i <= length(args)
        if args[i] == "--plants-file" && i < length(args)
            file = args[i + 1]; i += 2
        elseif args[i] == "--plant-id" && i < length(args)
            pid = args[i + 1]; i += 2
        else
            push!(rest, args[i]); i += 1
        end
    end
    (file === nothing || pid === nothing) && error(
        "the thermal-value demo needs the plant explicitly — there is no default plant.\n" *
        "  julia --project=. CSP/thermal_value_sddp.jl --plants-file Data/csp_plants.csv --plant-id demo --archetypes")
    return CSP.get_csp_plant(String(file), String(pid)), rest
end

if abspath(PROGRAM_FILE) == @__FILE__
    println("=" ^ 68)
    println("CSP thermal value — SDDP à la ReSDDP (water value for heat)")
    println("=" ^ 68)
    plant, scen_args = _demo_plant(ARGS)
    scen, source = _demo_scenarios(scen_args, plant)
    settings = ThermalValueSettings()
    @printf("plant   : %s (bus %s) — %.0f MW_th field, %.0f MW_e block, %.0f MWh_th tank (floor %.0f)\n",
        plant.plant_id, plant.bus_id, plant.solar_capacity_mwth, plant.pmax_e_mwe,
        plant.tes_capacity_mwhth, plant.q_end_target_mwhth)
    @printf("branches: %s (probs %s)\n   source: %s\n",
        join([string(s.name) for s in scen], ", "),
        join([@sprintf("%.2f", s.prob) for s in scen], "/"), source)
    @printf("SDDP    : %d daily stages, %d forward scenarios, max %d iterations\n\n",
        settings.n_stages, settings.n_scen, settings.max_iter)

    t0 = time()
    cuts, conv = train_thermal_value(plant, scen, settings)
    @printf("\ntrained in %.1f s — %d cuts at stage 1, %d total\n",
        time() - t0, length(cuts[1]), sum(length(c) for c in cuts))

    out_dir = joinpath(@__DIR__, "..", "results", "csp_sddp")
    mkpath(out_dir)
    save_cuts(cuts, joinpath(out_dir, "cuts.csv"))
    CSV.write(joinpath(out_dir, "convergence.csv"), conv)
    curve = thermal_value_curve(cuts[1], plant)
    CSV.write(joinpath(out_dir, "value_curve.csv"), curve)

    println("\nthermal value curve, stage 1 (the DA day):")
    println("   tank [MWh_th]   cost-to-go [EUR]   TV [EUR/MWh_th]")
    for i in [1, round(Int, plant.q_end_target_mwhth / plant.tes_capacity_mwhth * 36) + 1, 19, 37]
        i <= nrow(curve) || continue
        @printf("   %10.1f      %12.2f        %8.2f\n",
            curve.q_mwhth[i], curve.value_eur[i],
            curve.thermal_value_eur_per_mwhth[i])
    end

    price_file = joinpath(@__DIR__, "..", "results", "Trinity", "market_prices.csv")
    if isfile(price_file)
        println("\nstudy days under the trained thermal value vs the persistence cut:")
        println("   (persistence = CSP.jl's single-cut formula: TV fixed at " *
                "eta_power·E[price]·crowding)")
        for day in ("2024-07-08", "2024-12-02")
            price = _da_prices_for_day(price_file, day)
            isempty(price) && continue
            avail = plant.solar_capacity_mwth .*
                CSP.load_solar_forecast(day, "DA") .* CSP.solar_thermal_shape(day)
            r_sddp = solve_day_with_thermal_value(plant, cuts[1], price, avail)
            v_pers = plant.eta_power * mean(price) *
                max(0.0, 1.0 - mean(avail) / plant.solar_capacity_mwth)
            r_pers = solve_day_with_thermal_value(plant,
                [ThermalValueCut(1, -v_pers, 0.0)], price, avail)
            @printf("   %s  net SDDP %9.2f EUR (TV at end %6.2f)   net persistence %9.2f EUR (TV %6.2f)\n",
                day, r_sddp.net_cash_eur, r_sddp.thermal_value_end,
                r_pers.net_cash_eur, v_pers)
            disp = DataFrame(hour = 0:23, price_eur_mwh = price,
                p_gen_mw = r_sddp.p_gen, p_buy_mw = r_sddp.p_buy,
                s_solar_mwth = r_sddp.s_solar,
                tes_start_mwhth = r_sddp.q_tes[1:24],
                tes_end_mwhth = r_sddp.q_tes[2:25])
            CSV.write(joinpath(out_dir, "apply_$day.csv"), disp)
        end
    else
        println("\n(no results/Trinity/market_prices.csv — skipped the study-day application)")
    end
    @printf("\noutputs : %s\n", abspath(out_dir))
    println("cuts.csv (BellmanValuesOUT convention), value_curve.csv, " *
            "convergence.csv, apply_<date>.csv")
end
