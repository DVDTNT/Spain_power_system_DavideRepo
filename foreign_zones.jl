# ============================================================
# Spain Power System — foreign-zone DA aggregates (4-zone clearing)
# ============================================================
# Builds the per-day FR / PT / EU zone aggregates the joint 4-zone day-ahead
# clearing consumes (solve_da's `foreign` argument).  Each zone is a copper
# plate of per-tech aggregate units — the same representation the mid-term
# SDDP uses (midterm_sddp4.jl) — coupled to ES and to each other by
# NTC-bounded flow variables on the PT–ES–FR–EU chain:
#
#   thermal    : EMPIRE installed capacity × [midterm4.availability] derating,
#                EMPIRE marginal cost (CO2 adder included) — emp.caps/emp.costs
#   VRE + ROR  : zero-cost, hourly availability = ScenarioData CF of the
#                sampled week × EMPIRE installed capacity (foreign_week_series)
#   reservoir  : FR/EU dispatchable at the binding-cut water value of the
#                study day (FR slope a_0 of the day's binding Bellman cut; the
#                EU slope was folded into the intercept at export, so EU
#                borrows the FR water value — an approximation)
#   PT reservoir: zero-cost with a daily energy budget = the day's seasonal
#                inflow (hydroseasonal.csv), mirroring the weekly inflow
#                budget the mid-term model gives PT (no reservoir state)
#   storage    : PHS + Li-Ion BESS per zone, daily energy-neutral SOC window
#                starting half-full, lossless — the ES BESS treatment
#   load shed  : last-resort at the mid-term VOLL (3 000 EUR/MWh)
#
# All quantities are per-unit on BASEMVA with cost coefficients in
# EUR/MWh × BASEMVA, matching the ES generator convention in solve_da.
# ============================================================

const F4_ZONES     = ("FR", "PT", "EU")
const F4_VOLL      = 3000.0          # foreign unserved-energy cost [EUR/MWh]
const F4_WAVE_CF   = 0.25            # constant CF for the small Wave class

# Availability lookup from [midterm4.availability] (+ per-zone overrides),
# the same derating the mid-term SDDP applies to thermal capacity.
function foreign_availability(cfg)
    af_cfg = get(get(cfg, "midterm4", Dict()), "availability", Dict())
    af  = Dict(String(k) => Float64(v) for (k, v) in af_cfg if !(v isa AbstractDict))
    afz = Dict(String(z) => Dict(String(k) => Float64(v) for (k, v) in d)
               for (z, d) in af_cfg if d isa AbstractDict)
    return (z, t) -> get(get(afz, z, af), empire_avail_key(t), get(af, empire_avail_key(t), 1.0))
end

# FR water value of the study day: −a_0 of the binding cut at V_ES (the cut
# set already carries the a_0·V_FR fold in b, so the binding selection is the
# same one binding_water_value uses for ES).
function foreign_fr_water_value(cuts, v_es::Float64)::Float64
    isempty(cuts) && return 0.0
    best = argmax(c -> c.b + c.a1 * v_es, cuts)
    return -best.a0
end

"""
    foreign_day(cfg, emp, fws, date_str, bv; border_mw) -> NamedTuple

One study day's foreign-zone aggregates for the 4-zone DA (`solve_da`'s
`foreign` argument).  `fws` is foreign_week_series' output, `bv` the day's
Bellman tuple (cuts, v_es) from run_market_chain's pre-compute.

When `ntc_override` is supplied, it contains four asymmetric hourly limits
calculated offline by `derive_hourly_ntcs`; the DA still receives only scalar
zonal bounds.  Otherwise `border_mw` (country ⇒ physical border nameplate)
provides the legacy symmetric static limit using `[weeks].xb_ntc_margin`.
"""
function foreign_day(cfg, emp, fws::Dict{String,DataFrame}, date_str::String, bv;
                     border_mw::Union{Dict{String,Float64},Nothing} = nothing,
                     ntc_override = nothing)
    avail = foreign_availability(cfg)
    fr_wv = foreign_fr_water_value(bv.cuts, bv.v_es)

    load  = Dict{String,Vector{Float64}}()
    vre   = Dict{String,Vector{Float64}}()
    therm = Dict{String,Vector{NamedTuple}}()
    resv  = Dict{String,NamedTuple}()
    sts   = Dict{String,Vector{NamedTuple}}()
    for z in F4_ZONES
        day = filter(r -> r.date == date_str, fws[z])
        nrow(day) == 24 || error("foreign_day: $z has $(nrow(day)) rows for $date_str")
        sort!(day, :hour)
        caps = emp.caps[z]

        load[z] = Float64.(day.load_mw) ./ BASEMVA
        vre[z]  = (Float64.(day.solar_cf)   .* get(caps, "Solar", 0.0) .+
                   Float64.(day.windon_cf)  .* get(caps, "Wind onshore", 0.0) .+
                   Float64.(day.windoff_cf) .* (get(caps, "Wind offshore grounded", 0.0) +
                                                get(caps, "Wind offshore floating", 0.0)) .+
                   Float64.(day.ror_cf)     .* get(caps, "Hydro run-of-the-river", 0.0) .+
                   F4_WAVE_CF                * get(caps, "Wave", 0.0)) ./ BASEMVA

        therm[z] = [(name = t,
                     pmax = caps[t] * avail(z, t) / BASEMVA,
                     cost = emp.costs[t] * BASEMVA)
                    for t in EMPIRE_THERMAL_TECHS if get(caps, t, 0.0) > 1e-3]

        res_mw = get(caps, "Hydro regulated", 0.0)
        resv[z] = z == "PT" ?
            (pmax = res_mw / BASEMVA, cost = 0.0,
             budget = sum(Float64.(day.inflow_mw)) / BASEMVA) :       # daily inflow [pu·h]
            (pmax = res_mw / BASEMVA, cost = fr_wv * BASEMVA, budget = Inf)

        stor = emp.storage[z]
        sts[z] = [(name = n, pmax = p / BASEMVA, e = e / BASEMVA)
                  for (n, p, e) in (("PHS",  stor.phs_mw,  stor.phs_mwh),
                                    ("BESS", stor.bess_mw, stor.bess_mwh)) if p > 1e-3]
    end

    lrf    = Float64(get(get(cfg, "network", Dict()), "line_rating_factor", 0.70))
    margin = Float64(get(get(cfg, "weeks", Dict()), "xb_ntc_margin", 0.9))
    cap(c) = border_mw === nothing ? Inf : border_mw[c] * lrf * margin
    if ntc_override === nothing
        # Legacy/static symmetric bounds.
        fr = min(get(emp.ntc, ("ES", "FR"), 0.0), cap("FR")) / BASEMVA
        pt = min(get(emp.ntc, ("PT", "ES"), 0.0), cap("PT")) / BASEMVA
        ntc = (
            fr_min = fill(-fr, 24), fr_max = fill(fr, 24),
            pt_min = fill(-pt, 24), pt_max = fill(pt, 24),
            eufr   = get(emp.ntc, ("EU", "FR"), 0.0) / BASEMVA,
        )
    else
        hourly = [get(ntc_override, (date_str, h), nothing) for h in 0:23]
        any(isnothing, hourly) &&
            error("foreign_day: missing hourly NTC for $date_str")
        ntc = (
            # f_fr/f_pt are positive for imports into Spain.
            fr_min = [-x.fr_export_mw / BASEMVA for x in hourly],
            fr_max = [ x.fr_import_mw / BASEMVA for x in hourly],
            pt_min = [-x.pt_export_mw / BASEMVA for x in hourly],
            pt_max = [ x.pt_import_mw / BASEMVA for x in hourly],
            eufr   = get(emp.ntc, ("EU", "FR"), 0.0) / BASEMVA,
        )
    end

    hurdle = Float64(get(get(cfg, "weeks", Dict()), "xb_hurdle_eur_mwh", 0.5))
    return (zones = F4_ZONES, load = load, vre = vre, therm = therm,
            resv = resv, sts = sts, ntc = ntc,
            shed_cost = F4_VOLL * BASEMVA, fr_wv = fr_wv,
            hurdle = hurdle * BASEMVA)
end
