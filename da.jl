# ============================================================
# Stage 1 — Day-Ahead market (copper-plate economic dispatch)
# ============================================================
# Clears energy for the whole day at once with NO transmission or
# voltage limits (a single system-wide power balance per hour).
# Reservoir hydro is coupled across all 24 hours through the full
# Bellman cost-to-go, exactly as in the multi-network AC build:
# the recentred cuts give reservoir units their opportunity cost so
# the intra-day hydro schedule respects the long-term water value.
#
# Inputs are the per-hour networks already assembled by
# prepare_network (so RES availability, cross-border imports, the
# slack unit and the load-shed units are all included as ordinary
# generators).  Reservoir units must carry zero linear cost in those
# networks (build them with hydro_reservoir_cost = 0.0); their cost
# comes from the θ_future term instead.
#
# Returns the cleared per-unit schedule keyed by hour, which becomes
# the reference the redispatch stage is anchored to:
#     sched :: Dict{Int, Dict{String,Float64}}   hour ⇒ (unit ⇒ MW)
# together with `es_price :: Dict{Int,Float64}` — the marginal price
# (EUR/MWh) of the ES power balance at each hour the gate traded.
# ============================================================

using JuMP

# ── CSP/TES thermal-balance block (Option A; design doc A.4) ─────────────────
# The embedded CSP units already exist as ordinary generators in the assembled
# networks (data_preparation.jl, csp_units), so their pg sits in the copper-
# plate ES balance like any unit's — that is what lets CSP move the cleared
# price.  This function adds the physics the balance cannot see: the salt tank.
#
#   q[t] = (1 - leak)*q[t-1] + eta_solar*s_th[t] + eta_charge*chg[t] - dis[t]/eta_power
#
# with s_th <= the gate's availability profile [MW_th], q within [0, E], a
# terminal floor handed to the next day, and the terminal value priced by
# COST-form cuts (slope <= 0) — the trained thermal-value cut set of
# CSP/thermal_value_sddp.jl (or the persistence cut), i.e. the heat analog of
# the hydro θ_future above.  The cuts are recentred at the day's starting
# level q0 so the reported objective stays the dispatch cost plus the
# STORAGE delta (keeping heat above q0 makes θ NEGATIVE — that is the
# incentive, so θ is free, unlike the hydro θ_future it is not floored at 0).
#
# `csp` (built by run_market_chain.jl) is
#   units     :: plant rows (buy_from_grid already overridden by the chain)
#   q0        :: plant_id -> MWh_th at day start (per-day TES hand-off)
#   avail     :: plant_id -> H-entry MW_th availability for THIS gate's vintage
#   cuts      :: plant_id -> [(slope <= 0, intercept)] (cost form; [] = floor only)
#   s_th_pin  :: plant_id -> H-entry {nothing | MW_th}: collection of hours the
#                gate does NOT trade, pinned to the last settled gate's choice —
#                pg alone being fixed is not enough, the tank balance would let
#                history be re-collected retroactively.  A pin OVERRIDES the
#                availability bound: the hour is settled, the later gate's
#                forecast update is irrelevant to it.
#
# Returns Dict(unit name => (plant_id, theta, s_th, q)) with JuMP objects.
function _add_csp_tes_block!(model, pg_by_name, csp, H::Int)
    block = Dict{String,Any}()
    for u in csp.units
        name  = "CSP_" * u.plant_id
        avail = get(csp.avail, u.plant_id, nothing)
        avail === nothing &&
            error("solve_da: no CSP availability profile for unit $(u.plant_id)")
        length(avail) == H ||
            error("solve_da: CSP availability of $(u.plant_id) must have H=$H entries")
        q0 = Float64(get(csp.q0, u.plant_id, u.q0_start_mwhth))
        q = [JuMP.@variable(model, lower_bound = 0.0,
                            upper_bound = u.tes_capacity_mwhth) for _ in 0:H]
        JuMP.@constraint(model, q[1] == q0)
        s_th = [JuMP.@variable(model, lower_bound = 0.0,
                               upper_bound = avail[t]) for t in 1:H]
        pin  = get(csp.s_th_pin, u.plant_id, nothing)
        chg_ok = u.buy_from_grid && u.pmax_charge_e_mwe > 0
        for t in 1:H
            key = get(pg_by_name, (t, name), nothing)
            key === nothing &&
                error("solve_da: CSP unit $name missing from the network at hour $t")
            pg_mw = key * BASEMVA                    # pu -> MW (AffExpr)
            if chg_ok
                dis = JuMP.@variable(model, lower_bound = 0.0, upper_bound = u.pmax_e_mwe)
                chg = JuMP.@variable(model, lower_bound = 0.0,
                                     upper_bound = u.pmax_charge_e_mwe)
                JuMP.@constraint(model, pg_mw == dis - chg)
                draw = dis / u.eta_power - u.eta_charge * chg
            else
                draw = pg_mw / u.eta_power
            end
            JuMP.@constraint(model,
                q[t + 1] == (1 - u.thermal_leak_rate) * q[t] +
                            u.eta_solar * s_th[t] - draw)
            if pin !== nothing && pin[t] !== nothing
                JuMP.fix(s_th[t], Float64(pin[t]); force = true)
            end
        end
        JuMP.@constraint(model, q[H + 1] >= u.q_end_target_mwhth)   # daily hand-off floor
        # Terminal value: cost-form cuts (slope <= 0), recentred at q0.
        cuts = get(csp.cuts, u.plant_id, [])
        theta = JuMP.@variable(model)            # free: storing above q0 lowers it below 0
        theta_ref = isempty(cuts) ? 0.0 : maximum(b + a * q0 for (a, b) in cuts)
        for (a, b) in cuts
            JuMP.@constraint(model,
                theta >= (b + a * q0 - theta_ref) + a * (q[H + 1] - q0))
        end
        isempty(cuts) && JuMP.fix(theta, 0.0; force = true)
        block[name] = (plant_id = u.plant_id, theta = theta, s_th = s_th, q = q)
    end
    return block
end

# nets               : Vector of prepare_network outputs, index h ⇒ hour (h-1)
# reservoir_gen_ids  : Int gen ids of Spanish reservoir hydro (stable across hours)
# cuts, v_es_0       : Bellman cuts and starting reservoir volume [MWh] for the day
#
# anchor : previous gate's schedule for the TRADABLE hours (net-idx ⇒ unit ⇒ MW).
#          When given, the gate is solved as an *adjustment* market: dispatch cost
#          is minimised first (cheapest units / merit order, exactly as the DA),
#          then — among all cost-optimal solutions — the total movement away from
#          the previous gate is minimised.  This removes the cost-degenerate
#          reshuffles (reservoir water reallocation, LP degeneracy) that otherwise
#          let flexible units drift in opposite directions, while leaving any
#          genuine merit-order change intact.  `nothing` ⇒ plain cost re-clear.
# foreign : per-day FR/PT/EU zone aggregates (foreign_zones.jl → foreign_day)
#           activating the joint 4-zone clearing: each foreign zone gets its own
#           copper-plate balance and aggregate units, coupled to ES through
#           NTC-bounded flow variables on the PT–ES–FR–EU chain.  The result
#           then carries `xb` (per-hour net imports into ES, MW) and `prices`
#           (per-zone marginal prices, EUR/MWh).  DA (all hours free) only.
function solve_da(nets, reservoir_gen_ids::Vector{Int}, cuts, v_es_0::Float64, optimizer;
                  free_hours::Union{Nothing,Set{Int}} = nothing,
                  prev_sched::Union{Nothing,Dict{Int,Dict{String,Float64}}} = nothing,
                  anchor::Union{Nothing,Dict{Int,Dict{String,Float64}}} = nothing,
                  foreign = nothing,
                  hydro_budget_mwh::Union{Nothing,Float64} = nothing,
                  csp = nothing)
    H     = length(nets)
    # Net indices (1-based) whose generation is tradable at this gate.  Hours not
    # in `free` are frozen at the previous gate's schedule (`prev_sched`, MW): they
    # carry NO power-balance constraint (their forecast error is left to a later
    # gate) but still consume their share of the reservoir, so the Bellman cost-to-
    # go only reallocates the water remaining after the frozen hours.
    free  = free_hours === nothing ? Set(1:H) : free_hours
    model = JuMP.Model(optimizer)

    # Per-hour, per-generator active power [pu].  Bounds and starts come straight
    # from the assembled network (fixed cross-border imports carry pmin == pmax,
    # so they enter the balance as a constant supply term automatically).
    pg = Dict{Tuple{Int,String},JuMP.VariableRef}()
    # Companion index keyed by (hour, unit NAME).  The integer dict key `k` is a
    # per-hour sequential counter that is NOT stable across hours: cross-border
    # (XB_*) generators are added only for import hours, so when a border's net
    # exchange flips sign within the day the count changes and every unit appended
    # afterwards (the BESS fleet) is re-keyed.  Any constraint that couples a unit
    # across hours (the battery SOC/energy-neutrality below) must therefore look
    # the variable up by its stable name, not by hour-1's integer key.
    pg_by_name = Dict{Tuple{Int,String},JuMP.VariableRef}()
    for h in 1:H
        frozen = !(h in free)
        ps     = (frozen && prev_sched !== nothing) ? get(prev_sched, h, nothing) : nothing
        for (k, g) in nets[h].gens
            v = JuMP.@variable(model, lower_bound = g["pmin"], upper_bound = g["pmax"])
            JuMP.set_start_value(v, g["pg"])
            pg[(h, k)] = v
            pg_by_name[(h, g["name"])] = v
            if frozen
                mw     = ps === nothing ? nothing : get(ps, g["name"], nothing)
                fixval = mw === nothing ? g["pg"] : mw / BASEMVA
                JuMP.fix(v, fixval; force = true)
            end
        end
    end

    # ── Foreign zones + NTC flows (4-zone DA only; foreign_zones.jl) ──────────
    # Flow sign conventions: f_fr / f_pt = net import INTO ES from FR / PT;
    # f_eufr = net flow EU → FR.  All in pu, bounded by the zone-total NTCs.
    f_fr = f_pt = f_eufr = nothing
    foreign_cost = JuMP.AffExpr(0.0)
    bal_foreign  = Dict{Tuple{String,Int},JuMP.ConstraintRef}()
    if foreign !== nothing
        free == Set(1:H) ||
            error("solve_da: the 4-zone clearing supports the DA gate only (all hours free)")
        f_fr   = [JuMP.@variable(model, lower_bound = foreign.ntc.fr_min[h],
                                 upper_bound = foreign.ntc.fr_max[h]) for h in 1:H]
        f_pt   = [JuMP.@variable(model, lower_bound = foreign.ntc.pt_min[h],
                                 upper_bound = foreign.ntc.pt_max[h]) for h in 1:H]
        f_eufr = [JuMP.@variable(model, lower_bound = -foreign.ntc.eufr, upper_bound = foreign.ntc.eufr) for _ in 1:H]
        # Hurdle cost on every corridor flow (|f| decomposition).  Without it
        # the exchange is degenerate whenever zonal prices tie (e.g. nuclear
        # marginal in every zone at night) and the LP parks arbitrary gross
        # wheeling flows on the borders — which the AC redispatch then cannot
        # carry.  A small hurdle (≪ genuine price spreads) breaks the ties
        # toward minimal exchange without distorting real trade.
        if foreign.hurdle > 0
            for f in (f_fr, f_pt, f_eufr), h in 1:H
                fp = JuMP.@variable(model, lower_bound = 0.0)
                fm = JuMP.@variable(model, lower_bound = 0.0)
                JuMP.@constraint(model, f[h] == fp - fm)
                JuMP.add_to_expression!(foreign_cost, foreign.hurdle, fp)
                JuMP.add_to_expression!(foreign_cost, foreign.hurdle, fm)
            end
        end
        for z in foreign.zones
            gvre = [JuMP.@variable(model, lower_bound = 0.0, upper_bound = foreign.vre[z][h]) for h in 1:H]
            gth  = Dict(u.name => [JuMP.@variable(model, lower_bound = 0.0, upper_bound = u.pmax) for _ in 1:H]
                        for u in foreign.therm[z])
            gres = [JuMP.@variable(model, lower_bound = 0.0, upper_bound = foreign.resv[z].pmax) for _ in 1:H]
            shed = [JuMP.@variable(model, lower_bound = 0.0, upper_bound = foreign.load[z][h]) for h in 1:H]
            isfinite(foreign.resv[z].budget) &&
                JuMP.@constraint(model, sum(gres) <= foreign.resv[z].budget)
            # storage: lossless daily-neutral SOC window starting half-full
            # (the ES BESS treatment); positive = discharge.
            psts = JuMP.VariableRef[]
            sts_net = [JuMP.AffExpr(0.0) for _ in 1:H]
            for s in foreign.sts[z]
                p = [JuMP.@variable(model, lower_bound = -s.pmax, upper_bound = s.pmax) for _ in 1:H]
                soc0 = 0.5 * s.e
                for h in 1:H
                    JuMP.@constraint(model, 0.0 <= soc0 - sum(p[j] for j in 1:h) <= s.e)
                    JuMP.add_to_expression!(sts_net[h], p[h])
                end
                JuMP.@constraint(model, sum(p) == 0.0)
                append!(psts, p)
            end
            for h in 1:H
                xb = z == "FR" ? f_eufr[h] - f_fr[h] :
                     z == "PT" ? -f_pt[h] : -f_eufr[h]
                bal_foreign[(z, h)] = JuMP.@constraint(model,
                    gvre[h] + sum(gth[u.name][h] for u in foreign.therm[z]; init = JuMP.AffExpr(0.0)) +
                    gres[h] + sts_net[h] + shed[h] + xb == foreign.load[z][h])
                JuMP.add_to_expression!(foreign_cost, foreign.resv[z].cost, gres[h])
                JuMP.add_to_expression!(foreign_cost, foreign.shed_cost, shed[h])
                for u in foreign.therm[z]
                    JuMP.add_to_expression!(foreign_cost, u.cost, gth[u.name][h])
                end
            end
        end
    end

    # System-wide ES power balance per hour (copper plate): Σ generation
    # (+ net NTC imports in the 4-zone clearing) == Σ load.  Frozen hours are
    # carried verbatim from the previous gate (no re-balancing).
    bal_es = Dict{Int,JuMP.ConstraintRef}()
    for h in 1:H
        h in free || continue
        load_pu = sum(l["pd"] for l in values(nets[h].loads); init = 0.0)
        imports = foreign === nothing ? JuMP.AffExpr(0.0) : f_fr[h] + f_pt[h]
        bal_es[h] = JuMP.@constraint(model,
            sum(pg[(h, k)] for k in keys(nets[h].gens)) + imports == load_pu)
    end

    # ── Reservoir hydro coupled across the day via the Bellman cost-to-go ──────
    # Mirrors build_mn_bellman in run_market_chain.jl: energy is carried in pu·h so the
    # volume variables sit at the same scale as pg, the cuts are recentred about
    # the starting volume v_es_0 (dropping the dispatch-independent constant), and
    # both auxiliary variables are lower-bounded with interior starts.
    v_es_0_puh = v_es_0 / BASEMVA
    total_hydro_puh = isempty(reservoir_gen_ids) ? JuMP.AffExpr(0.0) :
        sum(pg[(h, string(gid))] for h in 1:H for gid in reservoir_gen_ids)

    JuMP.@variable(model, V_ES_puh >= 0)   # reservoir volume at end of day [pu·h]
    JuMP.@variable(model, θ_future >= 0)   # future cost relative to its value at v_es_0 [EUR]
    JuMP.set_start_value(V_ES_puh, v_es_0_puh)
    JuMP.set_start_value(θ_future, 1.0e3)
    JuMP.@constraint(model, V_ES_puh == v_es_0_puh - total_hydro_puh)

    # Daily reservoir energy budget handed down by the mid-term model
    # (bellman.jl → reservoir_day_budget).  The cuts price water but do not bind
    # a single day, so without this the day-ahead turbines to the fleet's
    # nameplate whenever the water value undercuts gas.  A cap rather than an
    # equality: the day may still use less water if it is not economic.
    if hydro_budget_mwh !== nothing && !isempty(reservoir_gen_ids)
        JuMP.@constraint(model, total_hydro_puh <= hydro_budget_mwh / BASEMVA)
    end

    θ_ref = isempty(cuts) ? 0.0 : maximum(c.b + c.a1 * v_es_0 for c in cuts)
    for cut in cuts
        const_term = cut.b + cut.a1 * v_es_0 - θ_ref
        JuMP.@constraint(model,
            θ_future >= const_term + cut.a1 * BASEMVA * (V_ES_puh - v_es_0_puh))
    end

    # ── Storage: intra-day SOC window (Li-Ion BESS and pumped hydro) ──────────
    # Storage units carry pmin = −pmax (negative pg ⇒ charging/pumping) and an
    # "energy_mwh" reservoir.  Starting from half-full, the running state of
    # charge must stay inside [0, E] and return to soc0 at end of day, so the
    # unit only SHIFTS energy within the day instead of supplying it.  Without
    # this a store with a near-zero variable cost is dispatched as free baseload.
    # Frozen hours participate through their fixed pg, so rolling CID gates
    # cannot reallocate energy backwards in time.
    #
    # Units with a round-trip efficiency below 1 (pumped hydro) split pg into
    # non-negative discharge/charge legs so the loss is charged to the
    # reservoir: drawdown_h = p_dis_h/η_d − p_chg_h·η_c with η_d = η_c = √η_rt.
    # Running both legs at once always drains the reservoir on net, so the LP
    # never does it and no complementarity constraint is needed.  Lossless units
    # (the EMPIRE BESS) keep the original single-variable form, leaving the 2035
    # scenario LPs unchanged.
    for (_, g) in nets[1].gens
        haskey(g, "energy_mwh") || continue
        name   = g["name"]                        # stable across hours (unlike key k)
        e_puh  = g["energy_mwh"] / BASEMVA
        e_puh > 0 || continue
        soc0   = 0.5 * e_puh
        eta_rt = Float64(get(g, "eta_rt", 1.0))
        if eta_rt >= 1.0
            draw = [pg_by_name[(j, name)] for j in 1:H]
        else
            eta = sqrt(eta_rt)
            # Both legs are bounded by NAMEPLATE, not by the hour's pmax: in a
            # rolling CID gate an already-committed hour has pmin = pmax = its
            # frozen set-point, and bounding the legs by that would make the
            # split infeasible for any hour frozen away from zero.  The real
            # power limit is enforced on pg itself, which the legs must equal.
            p_nom = Float64(get(g, "installed_mw", 0.0)) / BASEMVA
            draw  = JuMP.AffExpr[]
            for j in 1:H
                dis = JuMP.@variable(model, lower_bound = 0.0, upper_bound = p_nom)
                chg = JuMP.@variable(model, lower_bound = 0.0, upper_bound = p_nom)
                JuMP.@constraint(model, pg_by_name[(j, name)] == dis - chg)
                push!(draw, dis / eta - chg * eta)
            end
        end
        for h in 1:H
            JuMP.@constraint(model, 0.0 <= soc0 - sum(draw[j] for j in 1:h) <= e_puh)
        end
        JuMP.@constraint(model, sum(draw) == 0.0)
    end

    # ── CSP/TES: the embedded solar-thermal units' salt-tank balance ─────────
    # (Option A — see _add_csp_tes_block! above; nothing when the chain runs
    # without embedded CSP, so the pre-Option-A results are bit-identical.)
    csp_block = csp === nothing ? nothing : _add_csp_tes_block!(model, pg_by_name, csp, H)

    # ── Thermal ramp limits ───────────────────────────────────────────────────
    # |pg[h] − pg[h−1]| ≤ ramp_mw_per_h for every unit carrying the field
    # (attached in prepare_network from Data/power_unit_tech_params.csv when
    # [da].ramp_limits = true).  Looked up by the unit's stable NAME, not by the
    # per-hour integer key, which is not stable across hours.
    #
    # Three deliberate choices:
    #   • No constraint into hour 0 — the model has no predecessor day, and the
    #     DA clears a calendar day from scratch.  Consecutive study days are not
    #     coupled, so hour 0 keeps its unconstrained merit-order position.
    #   • Frozen hours participate through their fixed pg, so a rolling CID gate
    #     cannot ramp away from an already-committed hour faster than the plant
    #     can.  Every gate applies the same limits, so the schedule a gate
    #     inherits is already ramp-feasible and this cannot make it infeasible.
    #   • The limit is per unit and sized on nameplate (see prepare_network), so
    #     a derated fleet still ramps at plant rates rather than at derated ones.
    if !isempty(nets)
        for (_, g) in nets[1].gens
            haskey(g, "ramp_mw_per_h") || continue
            r_puh = g["ramp_mw_per_h"] / BASEMVA
            r_puh > 0 || continue
            name = g["name"]
            for h in 2:H
                p_now  = get(pg_by_name, (h, name),     nothing)
                p_prev = get(pg_by_name, (h - 1, name), nothing)
                (p_now === nothing || p_prev === nothing) && continue
                JuMP.@constraint(model, -r_puh <= p_now - p_prev <= r_puh)
            end
        end
    end

    # Primary objective: linear generation cost (reservoir cost is 0 here) + future
    # cost (+ the foreign zones' dispatch cost in the 4-zone clearing).  This
    # sets the merit order and therefore which units clear.
    op = JuMP.AffExpr(0.0)
    for h in 1:H, (k, g) in nets[h].gens
        JuMP.add_to_expression!(op, g["cost"][1], pg[(h, k)])
    end
    csp_theta_expr = JuMP.AffExpr(0.0)
    if csp_block !== nothing
        for (name, b) in csp_block
            JuMP.add_to_expression!(csp_theta_expr, 1.0, b.theta)
        end
    end
    cost_expr = op + θ_future + foreign_cost + csp_theta_expr

    # ── Minimum-movement anchor (intraday gates only) ─────────────────────────
    # For every tradable-hour unit that has a previous-gate set-point, add L1
    # deviation variables d_up/d_down with  pg − p_prev = d_up − d_down.  Their
    # sum is the secondary objective; the lexicographic solve below holds the
    # dispatch cost at its optimum first, so the cheapest units are still used.
    move_expr  = JuMP.AffExpr(0.0)
    has_anchor = anchor !== nothing && any(!isempty(v) for v in values(anchor))
    if has_anchor
        for h in 1:H
            h in free || continue
            ap = get(anchor, h, nothing)
            ap === nothing && continue
            for (k, g) in nets[h].gens
                mw = get(ap, g["name"], nothing)
                mw === nothing && continue
                p_ref = mw / BASEMVA
                du = JuMP.@variable(model, lower_bound = 0.0)
                dd = JuMP.@variable(model, lower_bound = 0.0)
                JuMP.@constraint(model, pg[(h, k)] - p_ref == du - dd)
                JuMP.add_to_expression!(move_expr, du)
                JuMP.add_to_expression!(move_expr, dd)
            end
        end
    end

    JuMP.@objective(model, Min, cost_expr)
    JuMP.optimize!(model)
    status = string(JuMP.termination_status(model))

    # ── Market price of the ES copper-plate balance ───────────────────────────
    # Read here, from the COST solve, and never later: the lexicographic pass
    # below swaps the objective for total movement, so after it the duals of
    # bal_es price a MW of movement, not a MWh of energy.  JuMP duals of an ==
    # balance in a Min problem are ∂obj/∂load [EUR per pu·h]; ÷BASEMVA →
    # EUR/MWh.  Keyed by net index; frozen hours carry no balance constraint and
    # therefore no price (ID3 hours 0–11, the CID hours already committed).
    es_price = Dict{Int,Float64}()
    if status in ("OPTIMAL", "LOCALLY_SOLVED") && JuMP.has_duals(model)
        for (h, c) in bal_es
            es_price[h] = JuMP.dual(c) / BASEMVA
        end
    end

    # Lexicographic pass 2: pin the dispatch cost at its optimum (within a tiny
    # tolerance so the merit order is preserved), then minimise total movement
    # from the previous gate.  Among cost-equal solutions this picks the one
    # closest to the previous schedule, so flexible units only move to cover the
    # net load/RES change — and in a single direction.
    if has_anchor && status in ("OPTIMAL", "LOCALLY_SOLVED")
        c_star   = JuMP.objective_value(model)
        cost_tol = 1e-6 * abs(c_star) + 1e-3
        JuMP.@constraint(model, cost_expr <= c_star + cost_tol)
        JuMP.@objective(model, Min, move_expr)
        JuMP.optimize!(model)
        status = string(JuMP.termination_status(model))
    end

    sched = Dict{Int,Dict{String,Float64}}()
    objval = NaN
    xb     = nothing
    prices = nothing
    csp_out = nothing
    if status in ("OPTIMAL", "LOCALLY_SOLVED")
        # Always report the dispatch cost, even after the pass-2 movement solve.
        objval = JuMP.value(cost_expr)
        if csp_block !== nothing
            csp_out = Dict{String,Any}()
            for (name, b) in csp_block
                csp_out[name] = (plant_id = b.plant_id,
                                 s_th = Float64.(JuMP.value.(b.s_th)),
                                 q = Float64.(JuMP.value.(b.q)),
                                 theta_eur = JuMP.value(b.theta))
            end
        end
        for h in 1:H
            d = Dict{String,Float64}()
            for (k, g) in nets[h].gens
                d[g["name"]] = JuMP.value(pg[(h, k)]) * BASEMVA
            end
            sched[h] = d
        end
        if foreign !== nothing
            # Cleared exchange (MW, import into ES positive) and zonal prices.
            # JuMP duals of the == balances in a Min problem are ∂obj/∂load
            # [EUR per pu·h]; ÷BASEMVA → EUR/MWh.
            xb = [(FR = JuMP.value(f_fr[h]) * BASEMVA,
                   PT = JuMP.value(f_pt[h]) * BASEMVA,
                   EUFR = JuMP.value(f_eufr[h]) * BASEMVA) for h in 1:H]
            prices = [(ES = es_price[h],
                       FR = JuMP.dual(bal_foreign[("FR", h)]) / BASEMVA,
                       PT = JuMP.dual(bal_foreign[("PT", h)]) / BASEMVA,
                       EU = JuMP.dual(bal_foreign[("EU", h)]) / BASEMVA) for h in 1:H]
        end
    end
    return (sched = sched, status = status, objective = objval, xb = xb,
            prices = prices, es_price = es_price, csp = csp_out)
end
