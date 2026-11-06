# ============================================================
# Hourly coordinated NTC capacity calculation
# ============================================================
#
# This file deliberately keeps the Spanish network OUT of the day-ahead
# clearing.  It uses an hourly DC reference case beforehand to reduce the four
# directional ES-FR / ES-PT transfer bounds to a jointly deliverable rectangle.
# The resulting scalar bounds are the only network information passed to DA.
#
# For every hour:
#   1. solve a zero-exchange DC reference dispatch;
#   2. use a fixed downward-headroom GSK for imports and an optimised
#      corrective-redispatch GSK for exports/opposite-direction transit;
#   3. maximise each of the four directional transfers separately;
#   4. test all four FR/PT corners and uniformly shrink the rectangle until
#      every corner is DC-feasible;
#   5. apply an additional reliability margin.
#
# Cross-border injections use either fixed rating-proportional boundary shares
# or the same sign-consistent free country-total split used by redispatch.  Any
# load shedding or fictitious slack needed by the domestic
# zero-exchange reference is frozen in every incremental transfer test, so it
# cannot manufacture NTC and remains visible in `base_emergency_mw`.  Real
# batteries stay available: their charging headroom is needed for a valid
# high-RES reference case (the DA itself enforces their daily SOC budget).

const NTC_DIRECTIONS = (
    (:fr_import_mw,  1.0,  0.0),
    (:fr_export_mw, -1.0,  0.0),
    (:pt_import_mw,  0.0,  1.0),
    (:pt_export_mw,  0.0, -1.0),
)
const NTC_CACHE_VERSION = 6

_ntc_ok(status) = string(status) in ("OPTIMAL", "LOCALLY_SOLVED")

function _ntc_quiet_optimizer()
    optimizer_with_attributes(
        () -> Gurobi.Optimizer(GRB_ENV),
        "OutputFlag" => 0,
    )
end

"""
Keep emergency resources in the zero-exchange reference so an existing
domestic pocket does not make the capacity calculation undefined.  They are
frozen at that minimum-cost reference value in every transfer test and
therefore cannot manufacture incremental NTC.
"""
function _ntc_disable_emergency_resources!(network)
    return network
end

"""Return zero-exchange reference dispatch [pu] and emergency use [MW]."""
function _ntc_reference_dispatch(network, optimizer)
    ref = deepcopy(network)
    for (_, g) in ref["gen"]
        if startswith(g["name"], "XB_")
            g["pmin"] = 0.0
            g["pmax"] = 0.0
            g["pg"]   = 0.0
        end
    end
    result = PowerModels.solve_dc_opf(ref, optimizer)
    _ntc_ok(result["termination_status"]) || return nothing
    sol = result["solution"]["gen"]
    pg = Dict(g["index"] => Float64(sol[string(g["index"])]["pg"])
              for (_, g) in ref["gen"])
    emergency_mw = sum(pg[g["index"]] * BASEMVA for (_, g) in ref["gen"]
                       if g["fuel"] in ("Slack", "LoadShed"); init = 0.0)
    return (pg = pg, emergency_mw = emergency_mw)
end

"""
    _ntc_transfer_scale(network, pg0, xb_fracs, pattern_fr, pattern_pt, optimizer)

Maximise `lambda in [0,1]` for the transfer pattern
`(f_FR, f_PT) = lambda * (pattern_fr, pattern_pt)` (all in pu).
Imports follow a fixed hourly downward-headroom GSK around `pg0`.  Exports and
opposite-direction transit patterns use an optimised corrective-redispatch GSK.
"""
function _ntc_transfer_scale(network, pg0, xb_fracs,
                             pattern_fr::Float64, pattern_pt::Float64,
                             optimizer;
                             crossborder_split::String = "fixed")::Float64
    pm = PowerModels.instantiate_model(
        network, PowerModels.DCPPowerModel, PowerModels.build_opf)
    JuMP.@variable(pm.model, 0.0 <= ntc_lambda <= 1.0)

    total_pattern = pattern_fr + pattern_pt
    non_xb = [g for (_, g) in network["gen"]
              if !startswith(g["name"], "XB_")]

    # A positive net border injection is an import and therefore reduces
    # Spanish generation; a negative one is an export and raises it.
    headroom = Dict{Int,Float64}()
    if total_pattern >= 0.0
        for g in non_xb
            headroom[g["index"]] = g["fuel"] in ("Slack", "LoadShed") ? 0.0 :
                max(pg0[g["index"]] - g["pmin"], 0.0)
        end
    else
        for g in non_xb
            headroom[g["index"]] = g["fuel"] in ("Slack", "LoadShed") ? 0.0 :
                max(g["pmax"] - pg0[g["index"]], 0.0)
        end
    end
    total_headroom = sum(values(headroom); init = 0.0)
    if abs(total_pattern) > 1e-10 && total_headroom <= 1e-10
        return 0.0
    end

    for g in non_xb
        pg = PowerModels.var(pm, :pg, g["index"])
        if g["fuel"] in ("Slack", "LoadShed")
            # Existing domestic emergency use is part of the reference case,
            # not a source of transfer capacity.
            JuMP.@constraint(pm.model, pg == pg0[g["index"]])
        elseif pattern_fr >= 0.0 && pattern_pt >= 0.0
            # Imports use the fixed downward headroom GSK.  This conservative
            # representation has been checked against the AC redispatch.
            beta = total_headroom > 0.0 ?
                headroom[g["index"]] / total_headroom : 0.0
            JuMP.@constraint(pm.model,
                pg == pg0[g["index"]] - beta * total_pattern * ntc_lambda)
        end
        # For exports and opposite-direction transit patterns, leave real
        # domestic units within their physical bounds.
        # The maximisation then identifies an hourly corrective-redispatch GSK
        # that can actually deliver the fixed border transfer.  This is an
        # offline TTC/NTC calculation; no network constraint enters DA.
    end

    xb_gens = [g for (_, g) in network["gen"] if startswith(g["name"], "XB_")]
    if crossborder_split == "country_total"
        # Let the physical grid choose the boundary-bus distribution, while
        # preserving the requested country total and forbidding counterflow.
        # The generator pmin/pmax values already carry each bus's derated
        # physical border capacity.
        for (country, pattern) in (("FR", pattern_fr), ("PT", pattern_pt))
            country_gens = [g for g in xb_gens if g["country"] == country]
            JuMP.@constraint(pm.model,
                sum(PowerModels.var(pm, :pg, g["index"]) for g in country_gens) ==
                pattern * ntc_lambda)
            for g in country_gens
                pg = PowerModels.var(pm, :pg, g["index"])
                pattern > 1e-10 ? JuMP.@constraint(pm.model, pg >= 0.0) :
                pattern < -1e-10 ? JuMP.@constraint(pm.model, pg <= 0.0) :
                                  JuMP.@constraint(pm.model, pg == 0.0)
            end
        end
    else
        # Fixed boundary distribution factors.  No border bus is allowed to
        # reverse independently or act as a free redispatch resource.
        for g in xb_gens
            bus = g["name"][4:end]
            country = g["country"]
            pattern = country == "FR" ? pattern_fr :
                      country == "PT" ? pattern_pt : 0.0
            share = get(get(xb_fracs, country, Dict{String,Float64}()), bus, 0.0)
            JuMP.@constraint(pm.model,
                PowerModels.var(pm, :pg, g["index"]) == share * pattern * ntc_lambda)
        end
    end

    JuMP.@objective(pm.model, Max, ntc_lambda)
    result = PowerModels.optimize_model!(pm; optimizer = optimizer)
    return _ntc_ok(result["termination_status"]) ?
           clamp(JuMP.value(ntc_lambda), 0.0, 1.0) : 0.0
end

function _ntc_cache_prefix_valid(df::DataFrame, hourly_da::DataFrame,
                                 lrf::Float64, reliability::Float64,
                                 physical_caps::Dict{String,Float64},
                                 crossborder_split::String)::Bool
    required = Set(["date", "hour", "load_mw", "solar_mw", "wind_mw",
                    "line_rating_factor", "reliability_margin",
                    "cache_version", "crossborder_split",
                    "fr_commercial_cap_mw",
                    "pt_commercial_cap_mw", "base_emergency_mw",
                    "fr_import_mw", "fr_export_mw",
                    "pt_import_mw", "pt_export_mw", "joint_scale"])
    required ⊆ Set(names(df)) || return false
    0 < nrow(df) <= nrow(hourly_da) || return false
    all(abs.(Float64.(df.line_rating_factor) .- lrf) .< 1e-9) || return false
    all(abs.(Float64.(df.reliability_margin) .- reliability) .< 1e-9) || return false
    all(Int.(df.cache_version) .== NTC_CACHE_VERSION) || return false
    all(String.(df.crossborder_split) .== crossborder_split) || return false
    all(abs.(Float64.(df.fr_commercial_cap_mw) .- physical_caps["FR"]) .< 0.1) ||
        return false
    all(abs.(Float64.(df.pt_commercial_cap_mw) .- physical_caps["PT"]) .< 0.1) ||
        return false
    cached_profiles = select(df, :date, :hour, :load_mw, :solar_mw, :wind_mw)
    current_profiles = select(hourly_da[1:nrow(df), :],
                              :date, :hour, :load_mw, :solar_mw, :wind_mw)
    cached_profiles.date = string.(cached_profiles.date)
    current_profiles.date = string.(current_profiles.date)
    return all(cached_profiles.date .== current_profiles.date) &&
           all(Int.(cached_profiles.hour) .== Int.(current_profiles.hour)) &&
           all(abs.(cached_profiles.load_mw .- current_profiles.load_mw) .< 0.1) &&
           all(abs.(cached_profiles.solar_mw .- current_profiles.solar_mw) .< 0.1) &&
           all(abs.(cached_profiles.wind_mw .- current_profiles.wind_mw) .< 0.1)
end

function _ntc_cache_valid(df::DataFrame, hourly_da::DataFrame,
                          lrf::Float64, reliability::Float64,
                          physical_caps::Dict{String,Float64},
                          crossborder_split::String)::Bool
    return nrow(df) == nrow(hourly_da) &&
           _ntc_cache_prefix_valid(df, hourly_da, lrf, reliability,
                                   physical_caps, crossborder_split)
end

"""
    derive_hourly_ntcs(hourly_da, network_builder, xb_fracs, physical_caps;
                       ...)

Return `(lookup, rows)`, where `lookup[(date,hour)]` contains four positive
directional NTCs in MW.  `network_builder(row)` must return a `prepare_network`
result containing free XB units at all boundary buses.
"""
function derive_hourly_ntcs(hourly_da::DataFrame, network_builder,
                            xb_fracs::Dict{String,Dict{String,Float64}},
                            physical_caps::Dict{String,Float64};
                            line_rating_factor::Float64,
                            reliability_margin::Float64 = 0.90,
                            crossborder_split::String = "fixed",
                            cache_file::Union{Nothing,String} = nothing,
                            reuse::Bool = true,
                            optimizer = _ntc_quiet_optimizer())
    rows = NamedTuple[]
    start_idx = 1
    if reuse && cache_file !== nothing && isfile(cache_file)
        cached = CSV.read(cache_file, DataFrame)
        if _ntc_cache_valid(cached, hourly_da, line_rating_factor,
                            reliability_margin, physical_caps,
                            crossborder_split)
            println("  Hourly directional NTCs: reused $(nrow(cached)) rows from $(basename(cache_file))")
            lookup = Dict((string(r.date), Int(r.hour)) =>
                (fr_import_mw = Float64(r.fr_import_mw),
                 fr_export_mw = Float64(r.fr_export_mw),
                 pt_import_mw = Float64(r.pt_import_mw),
                 pt_export_mw = Float64(r.pt_export_mw),
                 joint_scale  = Float64(r.joint_scale))
                for r in eachrow(cached))
            return lookup, cached
        elseif _ntc_cache_prefix_valid(cached, hourly_da, line_rating_factor,
                                       reliability_margin, physical_caps,
                                       crossborder_split)
            append!(rows, NamedTuple.(eachrow(cached)))
            start_idx = nrow(cached) + 1
            println("  Hourly directional NTCs: resuming after $(nrow(cached))/$(nrow(hourly_da)) cached rows")
        else
            println("  Hourly directional NTC cache is stale; recomputing")
        end
    end

    # These are commercial upper bounds.  The DC calculation can only reduce
    # them; it can never create more capacity than EMPIRE or the physical border.
    cap_fr = physical_caps["FR"] / BASEMVA
    cap_pt = physical_caps["PT"] / BASEMVA
    n = nrow(hourly_da)
    for idx in start_idx:n
        ts = hourly_da[idx, :]
        date_str, hour = string(ts.date), Int(ts.hour)
        assembled = network_builder(ts)
        network = _ntc_disable_emergency_resources!(deepcopy(assembled.network))
        reference = _ntc_reference_dispatch(network, optimizer)

        if reference === nothing
            @printf "  NTC [%d/%d] %s h%02d: zero-exchange DC reference infeasible; all bounds set to zero\n" idx n date_str hour
            vals = Dict(k => 0.0 for (k, _, _) in NTC_DIRECTIONS)
            joint_scale = 0.0
            base_emergency_mw = NaN
        else
            pg0 = reference.pg
            base_emergency_mw = reference.emergency_mw
            vals = Dict{Symbol,Float64}()
            for (name, sfr, spt) in NTC_DIRECTIONS
                pattern_fr = sfr * cap_fr
                pattern_pt = spt * cap_pt
                scale = _ntc_transfer_scale(
                    network, pg0, xb_fracs, pattern_fr, pattern_pt, optimizer;
                    crossborder_split = crossborder_split)
                cap = name in (:fr_import_mw, :fr_export_mw) ? cap_fr : cap_pt
                vals[name] = cap * scale * BASEMVA
            end

            # Independent border maxima can still admit infeasible France-Spain-
            # Portugal transit.  Reduce only the two directional bounds belonging
            # to an unsafe corner; a single bad FR-import/PT-export combination
            # must not erase capacity in the two opposite directions.
            independent = copy(vals)
            corners = (
                (:fr_export_mw, :pt_export_mw, -1.0, -1.0),
                (:fr_export_mw, :pt_import_mw, -1.0,  1.0),
                (:fr_import_mw, :pt_export_mw,  1.0, -1.0),
                (:fr_import_mw, :pt_import_mw,  1.0,  1.0),
            )
            for _ in 1:4
                changed = false
                for (fr_key, pt_key, sfr, spt) in corners
                    scale = _ntc_transfer_scale(
                        network, pg0, xb_fracs,
                        sfr * vals[fr_key] / BASEMVA,
                        spt * vals[pt_key] / BASEMVA, optimizer;
                        crossborder_split = crossborder_split)
                    if scale < 1.0 - 1e-6
                        vals[fr_key] *= scale
                        vals[pt_key] *= scale
                        changed = true
                    end
                end
                changed || break
            end
            reductions = [independent[k] > 1e-6 ? vals[k] / independent[k] : 1.0
                          for k in keys(vals)]
            joint_scale = minimum(reductions; init = 1.0)
            for name in keys(vals)
                vals[name] *= reliability_margin
            end
            emergency = base_emergency_mw > 0.05 ?
                @sprintf(" | base emergency %.0f MW", base_emergency_mw) : ""
            @printf "  NTC [%d/%d] %s h%02d: FR +%.0f/-%.0f | PT +%.0f/-%.0f MW (joint %.2f)%s\n" idx n date_str hour vals[:fr_import_mw] vals[:fr_export_mw] vals[:pt_import_mw] vals[:pt_export_mw] joint_scale emergency
        end

        push!(rows, (
            date = date_str, hour = hour,
            load_mw = Float64(ts.load_mw),
            solar_mw = Float64(ts.solar_mw),
            wind_mw = Float64(ts.wind_mw),
            line_rating_factor = line_rating_factor,
            reliability_margin = reliability_margin,
            cache_version = NTC_CACHE_VERSION,
            crossborder_split = crossborder_split,
            fr_commercial_cap_mw = physical_caps["FR"],
            pt_commercial_cap_mw = physical_caps["PT"],
            base_emergency_mw = base_emergency_mw,
            fr_import_mw = vals[:fr_import_mw],
            fr_export_mw = vals[:fr_export_mw],
            pt_import_mw = vals[:pt_import_mw],
            pt_export_mw = vals[:pt_export_mw],
            joint_scale = joint_scale,
        ))
        if cache_file !== nothing && (idx % 24 == 0 || idx == n)
            CSV.write(cache_file, DataFrame(rows))
        end
    end

    df = DataFrame(rows)
    lookup = Dict((string(r.date), Int(r.hour)) =>
        (fr_import_mw = Float64(r.fr_import_mw),
         fr_export_mw = Float64(r.fr_export_mw),
         pt_import_mw = Float64(r.pt_import_mw),
         pt_export_mw = Float64(r.pt_export_mw),
         joint_scale  = Float64(r.joint_scale))
        for r in eachrow(df))
    return lookup, df
end
