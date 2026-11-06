# ============================================================
# Spain Power System — Data Preparation
# ============================================================
# Reads the six CSV data files and assembles the PowerModels.jl
# network dict in per-unit on a 100 MVA base.
#
# Usage (from run_market_chain.jl):
#   include("data_preparation.jl")
#   net = prepare_network()
#   # net.network, net.gens, net.branches, net.loads, net.bus_idx
# ============================================================

using CSV, DataFrames

const BASEMVA       = 100.0
const FREQ_HZ       = 50.0
const TOTAL_LOAD_MW = 35_000.0
const SLACK_BUS_ID  = "ES00029"
const DATA          = joinpath(@__DIR__, "Data")

const LOAD_SHED_COST_EUR_MWH = 10_000.0   # Value of Lost Load — shed only as absolute last resort

# ── Shunt reactors (EHV line-charging compensation) ──────────────────────────
# Installed peninsular shunt-reactor fleet, REE Boletín Mensual diciembre 2024:
#   https://www.ree.es/es/datos/publicaciones/boletines-mensuales/boletin-mensual-diciembre-2024
#   • 400 kV : 11 750 MVAr (80 units)
#   • ≤220 kV:  3 722 MVAr (55 units)
# The Balearic/Canary systems are non-synchronous and excluded (peninsular only).
# The fleet is disaggregated across buses in proportion to the AC line charging
# connected at each bus and cached in Data/reactors.csv (see add_reactor_shunts!).
const REACTOR_MVAR_400KV      = 11_750.0
const REACTOR_MVAR_LE220KV    =  3_722.0
const REACTOR_HV_THRESHOLD_KV = 380.0      # base_kv ≥ ⇒ "400 kV" group, else "≤220 kV"
const REACTOR_FILE            = joinpath(DATA, "reactors.csv")

# Round-trip efficiency of the pumped-storage fleet.  Unlike the Li-Ion BESS —
# where the loss is second order at the fleet sizes involved — Spain's ~8 GW of
# pumping cycles enough energy that a lossless store would be a free arbitrage
# machine.  0.75 is the usual planning figure for reversible hydro.
const PUMPED_ROUND_TRIP_EFF = 0.75

const COST_MAP = Dict(
    ("Solar",   "PV")             => ("Solar",               "PV"),
    ("Solar",   "CSP")            => ("Solar",               "CSP"),
    ("Solar",   "Solar Thermal")  => ("Solar",               "CSP"),
    ("Wind",    "Onshore")        => ("Wind",                "Onshore"),
    ("Wind",    "Offshore")       => ("Wind",                "Onshore"),
    ("Nuclear", "Nuclear")        => ("Nuclear",             ""),
    ("Gas",     "Combined_cycle") => ("Gas",                 "CCGT"),
    ("Gas",     "Gas_turbine")    => ("Gas",                 "OCGT"),
    ("Coal",    "Coal")           => ("Coal",                "Hard Coal"),
    ("Biomass", "Biomass")        => ("Biomass",             ""),
    ("Hydro",   "pumped_storage") => ("Electricity Storage", "Pumped Storage"),
    ("Hydro",   "Run_of_River")   => ("Hydro",               "Run of River"),
    ("Hydro",   "run_of_river")   => ("Hydro",               "Run of River"),
    ("Hydro",   "Reservoir")      => ("Hydro",               "Reservoir"),
    ("Hydro",   "reservoir")      => ("Hydro",               "Reservoir"),
    ("Oil",     "Combined_cycle") => ("Oil",                 "Internal Combustion"),
    ("Oil",     "Gas_turbine")    => ("Oil",                 "Internal Combustion"),
)

# ── Ramp rates (thermal units) ───────────────────────────────────────────────
# Data/power_unit_tech_params.csv gives a sustained ramp rate per technology as
# a PERCENT OF NAMEPLATE PER HOUR (Nuclear 20, Hard Coal 40, Gas CC 50,
# Gas OCGT 100, Oil 40).  It is applied per unit, so the fleet-level limit is the
# sum over units rather than a national aggregate.
#
# Only the technologies present in that file are limited.  Hydro (reservoir,
# pumped, run-of-river), wind, solar, biomass and the CHP blocks carry no entry
# and are therefore left free: hydro and inverter-based plant ramp far faster
# than the hourly resolution can resolve, and the CHP/waste/mini-hydro blocks are
# already pinned between their technical minimum and their block size.
const RAMP_FILE = joinpath(DATA, "power_unit_tech_params.csv")
const RAMP_MAP = Dict(
    ("Nuclear", "Nuclear")        => "Nuclear",
    ("Coal",    "Coal")           => "Hard Coal",
    ("Gas",     "Combined_cycle") => "Gas CC",
    ("Gas",     "Gas_turbine")    => "Gas OCGT",
    ("Oil",     "Combined_cycle") => "Oil",
    ("Oil",     "Gas_turbine")    => "Oil",
)

# (fuel, technology) ⇒ ramp rate as a fraction of nameplate per hour.
# Missing key ⇒ the unit is not ramp-limited.
function load_ramp_rates()::Dict{Tuple{String,String},Float64}
    isfile(RAMP_FILE) || return Dict{Tuple{String,String},Float64}()
    df  = CSV.read(RAMP_FILE, DataFrame)
    pct = Dict(strip(String(r.Technology)) => Float64(r.Ramping_pct_per_h) / 100.0
               for r in eachrow(df))
    out = Dict{Tuple{String,String},Float64}()
    for (key, tech) in RAMP_MAP
        haskey(pct, tech) && (out[key] = pct[tech])
    end
    return out
end

function q_limits(pmax_pu::Float64)::Tuple{Float64,Float64}
    return (pmax_pu, -pmax_pu)   # ±Pmax: conservative fallback ensuring reactive feasibility
end

# Disaggregate the installed shunt-reactor fleet across buses (∝ connected AC
# line charging) and attach it to the network as `shunt` components.  A reactor
# absorbs reactive power, so its susceptance is negative (bs < 0).
#
# The per-bus *installed* capacity (the full 100 % fleet) is cached in
# Data/reactors.csv so it can be reused as a model input on later runs; delete
# that file to regenerate the disaggregation (e.g. after changing the line
# data).  `in_service_pct` then scales how much of the installed fleet is
# energised at the operating point — set it in config.toml ([reactors]).
function add_reactor_shunts!(network, buses, branches, bus_idx;
                             enabled::Bool, in_service_pct::Float64)
    enabled || return
    BASE      = network["baseMVA"]
    installed = Dict{Int,Float64}()        # bus index ⇒ installed reactor [MVAr]

    if isfile(REACTOR_FILE)
        rdf = CSV.read(REACTOR_FILE, DataFrame)
        for row in eachrow(rdf)
            haskey(bus_idx, row.bus_id) || continue
            installed[bus_idx[row.bus_id]] = Float64(row.reactor_installed_mvar)
        end
    else
        # Connected line charging at each bus = Σ half-charging of the incident
        # AC lines (b_fr at the from-bus, b_to at the to-bus), as MVAr at 1.0 pu.
        # Transformers (b_fr = b_to = 0) and HVDC links contribute nothing.
        charging = Dict{Int,Float64}()
        for (_, br) in branches
            charging[br["f_bus"]] = get(charging, br["f_bus"], 0.0) + get(br, "b_fr", 0.0) * BASE
            charging[br["t_bus"]] = get(charging, br["t_bus"], 0.0) + get(br, "b_to", 0.0) * BASE
        end
        group(bi) = buses[string(bi)]["base_kv"] >= REACTOR_HV_THRESHOLD_KV ? "400kV" : "<=220kV"
        fleet = Dict("400kV" => REACTOR_MVAR_400KV, "<=220kV" => REACTOR_MVAR_LE220KV)
        ctot  = Dict("400kV" => 0.0,                "<=220kV" => 0.0)
        for (bi, c) in charging
            ctot[group(bi)] += c
        end
        rows = NamedTuple[]
        for (bi, c) in charging
            g = group(bi)
            ctot[g] > 0 || continue
            q = fleet[g] * c / ctot[g]     # ∝ share of group charging
            installed[bi] = q
            push!(rows, (bus_id                  = buses[string(bi)]["name"],
                         base_kv                 = buses[string(bi)]["base_kv"],
                         voltage_group           = g,
                         connected_charging_mvar = round(c; digits = 3),
                         reactor_installed_mvar  = round(q; digits = 3)))
        end
        sort!(rows; by = r -> -r.reactor_installed_mvar)
        CSV.write(REACTOR_FILE, DataFrame(rows))
        @info "Wrote shunt-reactor disaggregation to $REACTOR_FILE ($(length(rows)) buses)"
    end

    scale = in_service_pct / 100.0
    n = length(network["shunt"])        # append after any existing shunts
    for (bi, q_inst) in installed
        q = q_inst * scale
        q > 1e-9 || continue
        n += 1
        network["shunt"][string(n)] = Dict{String,Any}(
            "index"     => n,
            "shunt_bus" => bi,
            "gs"        => 0.0,
            "bs"        => -q / BASE,       # negative ⇒ inductive (absorbs reactive power)
            "status"    => 1,
        )
    end
    return
end

function marginal_cost(cost_df::DataFrame, fuel::String, tech::String)::Float64
    key = (fuel, tech)
    if !haskey(COST_MAP, key)
        @warn "No cost mapping for ($fuel, $tech) — defaulting to 60 €/MWh"
        return 60.0
    end
    (carrier, technology) = COST_MAP[key]
    for row in eachrow(cost_df)
        carrier_match = row.carrier == carrier
        tech_match    = technology == "" ||
                        (!ismissing(row.technology) && row.technology == technology)
        carrier_match && tech_match && return Float64(row.variable_total_eur_per_mwh)
    end
    @warn "Cost row not found for carrier=$carrier, tech=$technology — defaulting to 60 €/MWh"
    return 60.0
end

function prepare_network(total_load_mw::Float64 = TOTAL_LOAD_MW,
                         solar_avail_mw::Float64 = Inf,
                         wind_avail_mw::Float64  = Inf;
                         hydro_reservoir_cost::Union{Float64,Nothing} = nothing,
                         crossborder_inj::Union{Dict{String,Float64},Nothing} = nothing,
                         crossborder_exports::Bool = false,
                         # bus ⇒ nameplate MW of its border lines.  When given,
                         # XB units are free within ±rating×line_rating_factor.
                         # This is used by the OFFLINE hourly NTC capacity
                         # calculation and, optionally, by country-total
                         # redispatch of fixed DA exchange.
                         crossborder_bus_caps::Union{Dict{String,Float64},Nothing} = nothing,
                         # With bus caps enabled, restrict every bus to the sign
                         # of its DA country exchange. This permits spatial
                         # redistribution without artificial simultaneous import
                         # and export. The offline NTC probe leaves this false so
                         # it can test either transfer direction from zero.
                         crossborder_same_direction::Bool = false,
                         da_dispatch::Union{Dict{String,Float64},Nothing} = nothing,
                         nuclear_da_dispatch::Union{Dict{String,Float64},Nothing} = nothing,
                         nuclear_min_frac::Float64   = 0.0,
                         # Fraction of nuclear nameplate actually available on the
                         # study day (planned + forced outages).  Applied to pmax,
                         # so nuclear_min_frac remains a floor on what is
                         # available rather than on the nameplate.  1.0 = fully
                         # available (the previous, implicit behaviour).
                         nuclear_availability::Float64 = 1.0,
                         # Same idea for the coal fleet.  generations.csv still
                         # carries the full 2 900 MW nameplate, but most of the
                         # Spanish fleet had closed by 2024 — on 2 Dec it peaked
                         # at 933 MW (OMIE) / 1 024 MW (ENTSO-E).  Without this
                         # the whole 2 900 MW runs flat whenever coal is in
                         # merit, which a daily gas price makes happen.
                         coal_availability::Float64 = 1.0,
                         voltage_band::Float64       = 0.05,
                         line_rating_factor::Float64 = 0.70,
                         reactors_enabled::Bool      = true,
                         reactor_in_service_pct::Float64 = 100.0,
                         load_power_factor::Float64      = 1.0,
                         apparent_power_limit::Bool      = true,
                         rated_power_factor::Float64     = 0.90,
                         renewable_power_factor::Float64 = 0.95,
                         gen_bus_voltage_control::Bool   = false,
                         gen_bus_vmin::Float64           = 0.98,
                         gen_bus_vmax::Float64           = 1.03,
                         # [scenario] overrides (EMPIRE future system; see
                         # empire_scenario.jl — all `nothing` for the 2024 run):
                         #   unit_scale    : (fuel, technology) ⇒ capacity factor the
                         #                   existing unit fleet is scaled by
                         #   cost_override : (fuel, technology) ⇒ EUR/MWh replacing the
                         #                   pypsa-2024 marginal-cost table
                         #   bess_units    : [(bus_id, power_mw, energy_mwh), …] Li-Ion
                         #                   BESS fleet placed on the grid
                         unit_scale::Union{Dict{Tuple{String,String},Float64},Nothing} = nothing,
                         cost_override::Union{Dict{Tuple{String,String},Float64},Nothing} = nothing,
                         bess_units = nothing,
                         # Embedded CSP/TES units ([csp] mode = "embedded",
                         # Option A): Vector of plants-file rows (CSP.CSPPlant;
                         # see Data/csp_plants.csv and CSP.read_csp_plants) —
                         # one network generator per row; the TES physics are
                         # enforced in solve_da (da.jl).
                         csp_units = nothing,
                         # nodal disaggregation (empire_nodal.jl; all `nothing`
                         # for the 2024 run and for disaggregation = "zonal"):
                         #   unit_scale_by_id : unit_id ⇒ factor, takes precedence
                         #                      over the (fuel, tech) unit_scale
                         #   extra_units      : greenfield units appended to the
                         #                      generations.csv fleet
                         #   line_scale       : line_id ⇒ expansion factor ≥ 1,
                         #                      applied as parallel circuits
                         #   extra_lines      : synthetic lines appended to lines.csv
                         unit_scale_by_id::Union{Dict{String,Float64},Nothing} = nothing,
                         extra_units = nothing,
                         line_scale::Union{Dict{String,Float64},Nothing} = nothing,
                         #   rating_scale     : line/transformer id ⇒ THERMAL
                         #                      uprate factor.  Unlike line_scale
                         #                      this touches ONLY rate_a/b/c —
                         #                      series impedance and shunt
                         #                      charging are left alone, i.e. a
                         #                      reconductoring rather than a new
                         #                      parallel circuit.  Adding parallel
                         #                      circuits would also multiply the
                         #                      line's charging Mvar and cut its
                         #                      reactance, perturbing the reactive
                         #                      balance and the flow pattern —
                         #                      the opposite of what a targeted
                         #                      "this branch needs more MVA"
                         #                      reinforcement study wants.
                         rating_scale::Union{Dict{String,Float64},Nothing} = nothing,
                         extra_lines = nothing,
                         # Industrial cogeneration / waste / mini-hydro fleet
                         # ([chp]; see the build block below).  Each entry is a
                         # NamedTuple (tag, fuel, technology, power_mw, min_frac,
                         # cost_eur_mwh) describing one national block, spread
                         # over the largest demand buses.
                         chp_blocks = nothing,
                         chp_siting_buses::Int = 100,
                         # Thermal ramp limits ([da].ramp_limits).  When true,
                         # each unit whose (fuel, technology) appears in
                         # Data/power_unit_tech_params.csv carries a
                         # "ramp_mw_per_h" field; solve_da turns it into an
                         # hour-to-hour bound on |Δpg|.  The network build itself
                         # is unaffected — a ramp rate is not a network property.
                         ramp_limits::Bool = false,
                         # Stage-6 redispatch freeze set ([redispatch].frozen_fuels
                         # in config.toml).  A bare "Fuel" entry (e.g. "Nuclear")
                         # freezes every technology under that fuel; "Fuel:technology"
                         # (e.g. "Hydro:run_of_river") freezes only that technology,
                         # for fuels with more than one (Hydro's reservoir / pumped
                         # storage / run-of-river split).  Only matters when
                         # da_dispatch is also given (Stage 6); ignored otherwise.
                         frozen_fuels = ("Nuclear", "Biomass", "Coal"))
    bus_df   = CSV.read(joinpath(DATA, "Bus_Data.csv"),                      DataFrame)
    line_df  = CSV.read(joinpath(DATA, "lines.csv"),                         DataFrame)
    gen_df   = CSV.read(joinpath(DATA, "generations.csv"),                   DataFrame)
    load_df  = CSV.read(joinpath(DATA, "load.csv"),                          DataFrame)
    cost_df  = CSV.read(joinpath(DATA, "generation_cost_pypsa_2024.csv"),    DataFrame)
    xfmr_df  = CSV.read(joinpath(DATA, "transformers_reactance.csv"),        DataFrame)
    ramp_rt  = ramp_limits ? load_ramp_rates() : Dict{Tuple{String,String},Float64}()

    # nodal scenario: greenfield units / synthetic corridor lines join the
    # 2024 tables before anything downstream (totals, siting, network build).
    if extra_units !== nothing && nrow(DataFrame(extra_units)) > 0
        allowmissing!(gen_df)
        for r in eachrow(DataFrame(extra_units))
            push!(gen_df, (unit_id = r.unit_id, bus_id = r.bus_id,
                           primary_fuel = r.primary_fuel, technology = r.technology,
                           name = r.name, capacity_mw = r.capacity_mw);
                  cols = :subset)
        end
    end
    if extra_lines !== nothing && nrow(DataFrame(extra_lines)) > 0
        line_df = vcat(line_df, DataFrame(extra_lines); cols = :intersect)
    end

    bus_idx  = Dict(row.bus_id => i for (i, row) in enumerate(eachrow(bus_df)))
    gen_buses = Set(gen_df.bus_id)
    # Buses hosting a SYNCHRONOUS machine (strong AVR voltage regulation).  Only
    # these (plus the slack) get the tighter voltage band — renewable-only buses,
    # whose reactive is capped at low output, keep the wider load-bus band.
    synchronous_gen_buses = Set(row.bus_id for row in eachrow(gen_df)
                                if !(row.primary_fuel == "Wind" || row.primary_fuel == "Solar"))

    # Total installed capacity of modelled solar/wind generators (for proportional scaling)
    # Per-unit capacity scale factor from the scenario: the nodal per-unit
    # factor wins where present; the zonal (fuel, tech) growth is the fallback.
    uscale(row) = begin
        if unit_scale_by_id !== nothing && haskey(unit_scale_by_id, String(row.unit_id))
            unit_scale_by_id[String(row.unit_id)]
        elseif unit_scale !== nothing
            get(unit_scale, (String(row.primary_fuel), String(row.technology)), 1.0)
        else
            1.0
        end
    end
    # Per-line corridor expansion factor (nodal scenario): f parallel copies of
    # the line — series impedance /f, shunt charging and thermal rating ×f.
    lscale(line_id) = line_scale === nothing ? 1.0 :
                      get(line_scale, String(line_id), 1.0)
    # Pure thermal uprate (see `rating_scale` above): multiplies rate_a only.
    rscale(branch_id) = rating_scale === nothing ? 1.0 :
                        get(rating_scale, String(branch_id), 1.0)
    total_solar_mw = sum(Float64(row.capacity_mw) * uscale(row) for row in eachrow(gen_df)
                         if row.primary_fuel == "Solar" && haskey(bus_idx, row.bus_id);
                         init = 0.0)
    total_wind_mw  = sum(Float64(row.capacity_mw) * uscale(row) for row in eachrow(gen_df)
                         if row.primary_fuel == "Wind" && haskey(bus_idx, row.bus_id);
                         init = 0.0)

    # ── Buses ────────────────────────────────────────────────
    buses = Dict{String,Any}()
    for row in eachrow(bus_df)
        i  = bus_idx[row.bus_id]
        vn = Float64(row.voltage)
        bus_type = if row.bus_id == SLACK_BUS_ID; 3
                   elseif row.bus_id in gen_buses;  2
                   else;                            1  end
        # AVR-regulated buses (synchronous machine or slack) get the tighter band,
        # so the profile follows realistic setpoints instead of railing to vmax.
        avr_bus = gen_bus_voltage_control &&
                  (bus_type == 3 || row.bus_id in synchronous_gen_buses)
        vmax_b  = avr_bus ? gen_bus_vmax : 1.0 + voltage_band
        vmin_b  = avr_bus ? gen_bus_vmin : 1.0 - voltage_band
        buses[string(i)] = Dict{String,Any}(
            "index"    => i,  "bus_i"    => i,
            "bus_type" => bus_type,
            "name"     => row.bus_id,
            "base_kv"  => vn,
            "vm"       => 1.0,  "va"   => 0.0,
            "vmax"     => vmax_b, "vmin" => vmin_b,
            "gs"       => 0.0,  "bs"   => 0.0,
            "zone"     => 1,    "area" => 1,
        )
    end

    # ── Branches: AC lines ───────────────────────────────────
    branches  = Dict{String,Any}()
    br_count  = 0
    for row in eachrow(line_df)
        haskey(bus_idx, row.bus0) || continue
        haskey(bus_idx, row.bus1) || continue
        String(row.dc) == "t"    && continue   # HVDC handled below as a dcline
        vn     = Float64(row.voltage)
        L      = Float64(row.length)
        z_base = vn^2 / BASEMVA
        # N identical circuits in parallel: series R,X divide by N; shunt B and
        # thermal rating (√3·V·Imax per circuit) multiply by N.  The corridor
        # expansion factor of the nodal scenario acts as extra parallel circuits.
        nc     = max(Float64(row.circuits), 1.0) * lscale(row.line_id)
        r_pu   = (Float64(row.r_per_length) * L) / z_base / nc
        x_pu   = max((Float64(row.x_per_length) * L) / z_base / nc, 1e-4)
        c_F    = Float64(row.c_per_length) * 1e-9 * L
        b_C_pu = 2π * FREQ_HZ * c_F * vn^2 / BASEMVA * nc
        rate   = sqrt(3) * vn * Float64(row.Imax) / BASEMVA * line_rating_factor * nc *
                 rscale(row.line_id)
        br_count += 1
        branches[string(br_count)] = Dict{String,Any}(
            "index"     => br_count,
            "f_bus"     => bus_idx[row.bus0],
            "t_bus"     => bus_idx[row.bus1],
            "name"      => String(row.line_id),
            "br_r"      => r_pu,   "br_x"  => x_pu,
            "g_fr"      => 0.0,    "g_to"  => 0.0,
            "b_fr"      => b_C_pu/2, "b_to" => b_C_pu/2,
            "rate_a"    => rate,   "rate_b" => rate, "rate_c" => rate,
            "tap"       => 1.0,    "shift"  => 0.0,
            "br_status" => 1,
            "angmin"    => -π/3,   "angmax" => π/3,
        )
    end

    # ── Branches: transformers ───────────────────────────────
    for row in eachrow(xfmr_df)
        haskey(bus_idx, row.bus0) || continue
        haskey(bus_idx, row.bus1) || continue
        imva   = Float64(row.installed_MVA)
        # `lscale` (nodal corridor expansion + [redispatch].extra_line_scale_file)
        # was applied to AC lines/HVDC above but NOT here, so a transformer named
        # in a manual/EMPIRE reinforcement list was silently ignored — its rating
        # never changed no matter how large the requested factor. Treated the same
        # as parallel AC circuits: nc extra transformer capacity multiplies the
        # thermal rating and divides the reactance.
        nc     = lscale(row.transformer_id)
        x_pu   = max(Float64(row.X_pu_on_installed_base) * (BASEMVA / imva), 1e-4) / nc
        rate   = imva / BASEMVA * line_rating_factor * nc * rscale(row.transformer_id)
        br_count += 1
        branches[string(br_count)] = Dict{String,Any}(
            "index"     => br_count,
            "f_bus"     => bus_idx[row.bus0],
            "t_bus"     => bus_idx[row.bus1],
            "name"      => String(row.transformer_id),
            "br_r"      => 0.0,    "br_x"  => x_pu,
            "g_fr"      => 0.0,    "g_to"  => 0.0,
            "b_fr"      => 0.0,    "b_to"  => 0.0,
            "rate_a"    => rate,   "rate_b" => rate, "rate_c" => rate,
            "tap"       => 1.0,    "shift"  => 0.0,
            "br_status" => 1,
            "angmin"    => -π/3,   "angmax" => π/3,
        )
    end

    # ── DC lines (HVDC) ──────────────────────────────────────
    # HVDC links are modelled as PowerModels `dcline` components — a
    # controllable converter pair rather than an AC impedance branch.
    # (Treating them as AC branches caused solver errors, since x≈0.)
    # The active-power transfer is a decision variable bounded by the
    # converter rating; each converter may also exchange reactive power
    # with its terminal bus.  Converters are modelled lossless.
    dclines  = Dict{String,Any}()
    dc_count = 0
    for row in eachrow(line_df)
        String(row.dc) == "t" || continue          # AC lines handled above
        haskey(bus_idx, row.bus0) || continue
        haskey(bus_idx, row.bus1) || continue
        vn   = Float64(row.voltage)
        # Rating from terminal voltage and current limit (same voltage/Imax
        # columns as AC lines), expressed in per-unit on the system base.
        # Parallel circuits — and the nodal corridor expansion factor — scale
        # the converter power rating (no series R/X here).
        nc   = max(Float64(row.circuits), 1.0) * lscale(row.line_id)
        rate = sqrt(3) * vn * Float64(row.Imax) / BASEMVA * line_rating_factor * nc *
               rscale(row.line_id)
        dc_count += 1
        dclines[string(dc_count)] = Dict{String,Any}(
            "index"     => dc_count,
            "f_bus"     => bus_idx[row.bus0],
            "t_bus"     => bus_idx[row.bus1],
            "name"      => String(row.line_id),
            "br_status" => 1,
            # Active-power flow variables (bidirectional, ±rate)
            "pf"    => 0.0,   "pt"    => 0.0,
            "pminf" => -rate, "pmaxf" => rate,
            "pmint" => -rate, "pmaxt" => rate,
            # Reactive-power capability at each converter (±rate)
            "qf"    => 0.0,   "qt"    => 0.0,
            "qminf" => -rate, "qmaxf" => rate,
            "qmint" => -rate, "qmaxt" => rate,
            # Terminal voltage setpoints
            "vf"    => 1.0,   "vt"    => 1.0,
            # Lossless converter model: p_fr + p_to == loss0 + loss1*p_fr
            "loss0" => 0.0,   "loss1" => 0.0,
            # No explicit cost on DC transfer
            "model" => 2, "ncost" => 2, "cost" => [0.0, 0.0],
            "startup" => 0.0, "shutdown" => 0.0,
        )
    end

    # ── Remove buses with no branch connections (isolated buses) ──
    connected_buses = Set{Int}()
    for br in values(branches)
        push!(connected_buses, br["f_bus"])
        push!(connected_buses, br["t_bus"])
    end
    for dc in values(dclines)                       # keep HVDC terminal buses
        push!(connected_buses, dc["f_bus"])
        push!(connected_buses, dc["t_bus"])
    end
    for k in collect(keys(buses))
        buses[k]["index"] ∉ connected_buses && delete!(buses, k)
    end

    # ── Generators ───────────────────────────────────────────
    # Pumped-storage reservoir sizing.  These units are a STORE, not a source:
    # without an energy limit the LP runs the whole fleet flat out at its
    # 0.036 EUR/MWh variable cost and it silently supplies ~26 % of Spanish
    # demand as free baseload, crowding out gas and the Bellman-priced
    # reservoir hydro.  The national usable energy comes from Data/Storage.csv
    # (the same figure the mid-term SDDP uses) and is split across the fleet in
    # proportion to unit power, so the country total is preserved rather than
    # invented.  solve_da then enforces the SOC window + daily energy balance.
    pumped_total_mw = sum((Float64(r.capacity_mw) * uscale(r)
                           for r in eachrow(gen_df)
                           if String(r.primary_fuel) == "Hydro" &&
                              lowercase(String(r.technology)) == "pumped_storage");
                          init = 0.0)
    pumped_total_mwh = let f = joinpath(DATA, "Storage.csv")
        if isfile(f)
            sdf = CSV.read(f, DataFrame)
            rows = filter(r -> String(r.Nodes) == "Spain", sdf)
            isempty(rows) ? 0.0 : Float64(rows[1, :Energy_MWh])
        else
            0.0
        end
    end

    # Split frozen_fuels once into bare-fuel and (fuel, technology) matchers —
    # see the keyword doc above.  Technology is matched case-insensitively.
    _frozen_bare  = Set(String(f) for f in frozen_fuels if !occursin(':', String(f)))
    _frozen_pairs = Set(let p = split(String(f), ':'; limit = 2)
                             (p[1], lowercase(p[2]))
                         end for f in frozen_fuels if occursin(':', String(f)))
    is_fuel_frozen(fuel, tech) = fuel in _frozen_bare || (fuel, lowercase(tech)) in _frozen_pairs

    gens      = Dict{String,Any}()
    gen_count = 0
    for row in eachrow(gen_df)
        haskey(bus_idx, row.bus_id) || continue
        cap_mw = Float64(row.capacity_mw) * uscale(row)
        cap_mw > 1e-6 || continue          # tech fully retired in the scenario
        pmax_pu = if row.primary_fuel == "Solar" && isfinite(solar_avail_mw) && total_solar_mw > 0
            min(cap_mw, solar_avail_mw * cap_mw / total_solar_mw) / BASEMVA
        elseif row.primary_fuel == "Wind" && isfinite(wind_avail_mw) && total_wind_mw > 0
            min(cap_mw, wind_avail_mw * cap_mw / total_wind_mw) / BASEMVA
        elseif String(row.primary_fuel) == "Nuclear"
            cap_mw * nuclear_availability / BASEMVA
        elseif String(row.primary_fuel) == "Coal"
            cap_mw * coal_availability / BASEMVA
        else
            cap_mw / BASEMVA
        end
        is_reservoir = String(row.primary_fuel) == "Hydro" &&
                       lowercase(String(row.technology)) == "reservoir"
        is_pumped    = String(row.primary_fuel) == "Hydro" &&
                       lowercase(String(row.technology)) == "pumped_storage"
        c1 = if is_reservoir && !isnothing(hydro_reservoir_cost)
            hydro_reservoir_cost * BASEMVA
        elseif cost_override !== nothing &&
               haskey(cost_override, (String(row.primary_fuel), String(row.technology)))
            cost_override[(String(row.primary_fuel), String(row.technology))] * BASEMVA
        else
            marginal_cost(cost_df, String(row.primary_fuel), String(row.technology)) * BASEMVA
        end
        # Reactive capability is sized on installed capacity, independent of any
        # active-power freeze applied below.
        (qmax_pu, qmin_pu) = q_limits(pmax_pu)

        # Reactive capability (enforced in the OPF build via add_gen_capability!):
        #   • Synchronous units (thermal/hydro): MVA capability circle
        #     P² + Q² ≤ S²,  S = installed MVA / rated_power_factor  (nameplate,
        #     not the hourly-derated Pmax); the reactive box is widened to ±S.
        #   • Inverter-based Wind/Solar: a grid-code reactive cap tied to *actual*
        #     output, |Q| ≤ tan(acos(renewable_power_factor))·P  (so a derated
        #     farm cannot park at a very low PF); the box is the value at full
        #     available output.
        # When apparent_power_limit = false, both fall back to the ±Pmax box.
        smax_pu  = Inf      # MVA circle radius [pu]   (synchronous only)
        qp_ratio = Inf      # |Q|/P cap                (renewables only)
        if apparent_power_limit
            if row.primary_fuel == "Wind" || row.primary_fuel == "Solar"
                qp_ratio = tan(acos(renewable_power_factor))
                qmax_pu, qmin_pu = qp_ratio * pmax_pu, -qp_ratio * pmax_pu
            else
                smax_pu = cap_mw > 0 ? (cap_mw / BASEMVA) / rated_power_factor : Inf
                isfinite(smax_pu) && ((qmax_pu, qmin_pu) = (smax_pu, -smax_pu))
            end
        end

        # ── Anchor to the day-ahead schedule (redispatch stage) ──────────────
        # When a DA dispatch is supplied, warm-start every unit from it and
        # *freeze* the units in [redispatch].frozen_fuels at their DA set-point
        # (pmin = pmax = P_DA).  Everything else stays free; the anchor
        # objective keeps it near P_DA.  (Run-of-river hydro used to be frozen
        # by default: an EMPIRE-scenario region can inflate an existing
        # run-of-river unit's nameplate several-fold — the nodal disaggregation
        # has nowhere else to put a region's growth once a tech is site-bound,
        # see empire_nodal.jl — and a hard pmin=pmax on that inflated MW then
        # makes the local network infeasible with no way to relieve it. The
        # default frozen_fuels no longer includes it.)
        da_pu = (!isnothing(da_dispatch) && haskey(da_dispatch, String(row.unit_id))) ?
                da_dispatch[String(row.unit_id)] / BASEMVA : nothing
        # Nuclear DA dispatch is carried unchanged into all subsequent market stages.
        # When nuclear_da_dispatch is provided the unit is frozen regardless of da_dispatch.
        nuc_pu = (String(row.primary_fuel) == "Nuclear" &&
                  !isnothing(nuclear_da_dispatch) &&
                  haskey(nuclear_da_dispatch, String(row.unit_id))) ?
                 nuclear_da_dispatch[String(row.unit_id)] / BASEMVA : nothing
        is_frozen = nuc_pu !== nothing ||
                    (da_pu !== nothing &&
                     is_fuel_frozen(String(row.primary_fuel), String(row.technology)))
        frozen_pu = nuc_pu !== nothing ? nuc_pu : da_pu
        # Nuclear must-run floor: when not frozen (the DA clear), hold nuclear at
        # >= nuclear_min_frac·Pmax so baseload can't be shut down at the solar peak.
        nuc_floor = (nuclear_min_frac > 0.0 && String(row.primary_fuel) == "Nuclear") ?
                    nuclear_min_frac * pmax_pu : 0.0
        # Pumped storage is bidirectional: negative pg = pumping (consumption).
        # Its floor is therefore −Pmax, not 0 — with a 0 floor the unit can only
        # ever generate, which is what let it run as free baseload.
        pmin_free = is_pumped ? -pmax_pu : nuc_floor
        pmin_g  = is_frozen ? frozen_pu : pmin_free
        pmax_g  = is_frozen ? frozen_pu : pmax_pu
        pg_strt = frozen_pu !== nothing ? clamp(frozen_pu, pmin_free, pmax_pu) :
                  nuc_floor > 0.0       ? pmax_pu :
                  is_pumped             ? 0.0     : pmax_pu/2

        gen_count += 1
        gens[string(gen_count)] = Dict{String,Any}(
            "index"         => gen_count,
            "gen_bus"       => bus_idx[row.bus_id],
            "name"          => String(row.unit_id),
            "fuel"          => String(row.primary_fuel),
            "technology"    => String(row.technology),
            "installed_mw"  => cap_mw,           # fixed installed capacity
            "pmax"          => pmax_g,   "pmin" => pmin_g,
            "pg0"           => (frozen_pu !== nothing ? frozen_pu :
                               da_pu     !== nothing ? da_pu     : pmax_pu/2),
            "qmax"          => qmax_pu,   "qmin" => qmin_pu,
            "smax"          => smax_pu,    # MVA circle radius [pu] (Inf ⇒ none)
            "qp_ratio"      => qp_ratio,   # |Q|/P cap (Inf ⇒ none, renewables)
            "pg"         => pg_strt,   "qg"   => 0.0,
            "vg"         => 1.0,
            "mbase"      => BASEMVA,
            "gen_status" => 1,
            "model"      => 2,  "ncost" => 2,
            "cost"       => [c1, 0.0],
            "startup"    => 0.0,  "shutdown" => 0.0,
        )
        # Sustained ramp limit [MW/h] = nameplate × the technology's percent per
        # hour.  Sized on the INSTALLED capacity, not the hourly-derated pmax:
        # a machine's ramp rate is a property of the plant, not of how much of it
        # happens to be available that day.  Absent key ⇒ no limit.
        let rr = get(ramp_rt, (String(row.primary_fuel), String(row.technology)), nothing)
            rr === nothing || (gens[string(gen_count)]["ramp_mw_per_h"] = rr * cap_mw)
        end
        # Pumped storage carries its usable reservoir and round-trip efficiency
        # so solve_da can hold it to an SOC window and a daily energy balance.
        # Sized pro-rata on unit power out of the national Data/Storage.csv
        # figure, so the fleet total matches the mid-term model's assumption.
        if is_pumped && pumped_total_mw > 0 && pumped_total_mwh > 0
            gens[string(gen_count)]["energy_mwh"] =
                pumped_total_mwh * cap_mw / pumped_total_mw
            gens[string(gen_count)]["eta_rt"] = PUMPED_ROUND_TRIP_EFF
        end
    end

    # ── Industrial cogeneration / waste / mini-hydro ([chp]) ──
    # OMIE clears these units inside one market group, "Cogeneración / Residuos
    # / Mini hidráulica", which generations.csv does not represent at all (493 MW
    # of Biomass against a 3.4–3.9 GW cleared block on the 2024 study days).
    # ENTSO-E splits the same fleet by FUEL, which is how the block is sized:
    # its gas-fired CHP half lands in "Fossil Gas" together with the CCGTs, the
    # waste/biomass half in "Biomass"+"Waste", and mini-hydro inside "Hydro".
    #
    # The gas CHP block burns gas (fuel = "Gas", so emissions accounting sees
    # it) but offers far BELOW its fuel cost: the steam is sold to the host
    # industrial process, so most of the fuel is charged to heat rather than to
    # electricity, and RECORE remuneration lowers the break-even pool price
    # further.  This is why it cleared 3 115 MW at 32 EUR/MWh on 8 July while
    # every real CCGT was at zero.  Modelling it at the CCGT cost would shut it
    # down; modelling it as strictly must-run would deny the (weak) price
    # response actually observed, so it is a cheap price-taking block with a
    # technical-minimum floor set by the process steam demand.
    #
    # Siting: the largest `chp_siting_buses` demand buses, weighted by demand.
    # Industrial CHP sits at industrial sites, so concentrating it on the big
    # load buses is closer to reality than spreading it over all 1 057 of them —
    # and it keeps the LP from growing by thousands of units.
    if chp_blocks !== nothing && !isempty(chp_blocks)
        sites = sort([(String(r.bus_id), Float64(r.demand)) for r in eachrow(load_df)
                      if haskey(bus_idx, String(r.bus_id)) && Float64(r.demand) > 0.0];
                     by = last, rev = true)
        n_site = min(chp_siting_buses, length(sites))
        sites  = sites[1:n_site]
        w_sum  = sum(last, sites; init = 0.0)
        for blk in chp_blocks
            (blk.power_mw > 1e-6 && w_sum > 0.0) || continue
            for (bus_id, w) in sites
                p_mw = blk.power_mw * w / w_sum
                p_mw > 1e-6 || continue
                name  = String(blk.tag) * "_" * bus_id
                p_pu  = p_mw / BASEMVA
                lo_pu = Float64(blk.min_frac) * p_pu
                # CHP follows process heat, not price signals, and mini-hydro
                # follows the river: neither provides redispatch, so both are
                # frozen at the cleared DA set-point in every later stage —
                # the same treatment biomass and run-of-river already get.
                da_pu = (!isnothing(da_dispatch) && haskey(da_dispatch, name)) ?
                        da_dispatch[name] / BASEMVA : nothing
                s_pu  = apparent_power_limit ? p_pu / rated_power_factor : p_pu
                gen_count += 1
                gens[string(gen_count)] = Dict{String,Any}(
                    "index"        => gen_count,
                    "gen_bus"      => bus_idx[bus_id],
                    "name"         => name,
                    "fuel"         => String(blk.fuel),
                    "technology"   => String(blk.technology),
                    "installed_mw" => p_mw,
                    "pmax"         => da_pu === nothing ? p_pu  : da_pu,
                    "pmin"         => da_pu === nothing ? lo_pu : da_pu,
                    "pg0"          => da_pu === nothing ? p_pu  : da_pu,
                    "pg"           => da_pu === nothing ? p_pu  : da_pu,
                    "qmax"         => s_pu,   "qmin" => -s_pu,
                    "smax"         => s_pu,   "qp_ratio" => Inf,
                    "qg"           => 0.0,
                    "vg"           => 1.0,
                    "mbase"        => BASEMVA,
                    "gen_status"   => 1,
                    "model"        => 2,  "ncost" => 2,
                    "cost"         => [Float64(blk.cost_eur_mwh) * BASEMVA, 0.0],
                    "startup"      => 0.0,  "shutdown" => 0.0,
                )
            end
        end
    end

    # Slack generator (balancing unit, very high cost)
    gen_count += 1
    gens[string(gen_count)] = Dict{String,Any}(
        "index"        => gen_count,
        "gen_bus"      => bus_idx[SLACK_BUS_ID],
        "name"         => "SLACK",
        "fuel"         => "Slack",
        "technology"   => "Slack",
        "installed_mw" => 9999.0 * BASEMVA,
        "pmax"         =>  9999.0,  "pmin" => 0.0,
        "qmax"       =>  9999.0,  "qmin" => -9999.0,
        "pg"         => 0.0,      "qg"   => 0.0,
        "vg"         => 1.0,
        "mbase"      => BASEMVA,
        "gen_status" => 1,
        "model"      => 2,  "ncost" => 2,
        "cost"       => [1_000.0 * BASEMVA, 0.0],
        "startup"    => 0.0,  "shutdown" => 0.0,
    )

    # ── Cross-border exchange (fixed market-cleared injections) ──
    # crossborder_exports = false (legacy crossborder.csv / SMS++-anchor path):
    # only positive net injections (imports into Spain) are modelled as fixed
    # generators.  Negative values (Spanish exports, e.g. to Portugal) are skipped:
    # the SMS++ intraday market clearing (used as the redispatch anchor) cleared
    # Spanish generators against domestic load + FR imports only — it placed the
    # cross-border obligation for PT exports on the Portuguese side of MIBEL.
    # Injecting the PT export as a fixed withdrawal would create a 1–4 GW gap
    # between the OPF's required generation and the anchor's reference schedule,
    # forcing the optimizer to massively deviate from the market dispatch.
    # crossborder_exports = true (4-zone DA source): the ES market cleared WITH
    # the exchange as a decision, so exports must bind too — negative injections
    # become fixed withdrawals (pmin = pmax < 0) at the border buses, and the
    # XB generators exist in every hour (stable generator keys across hours).
    if !isnothing(crossborder_inj)
        bus_country = Dict(String(r.bus_id) => String(r.country) for r in eachrow(bus_df))
        for (bus_id, mw) in crossborder_inj
            haskey(bus_idx, bus_id) || continue
            (crossborder_exports || mw > 0) || continue   # legacy: skip exports
            p_pu  = mw / BASEMVA
            # Free-split mode: bounds = ±(border-line rating, derated); the
            # reactive box follows the active bound.
            cap_pu = crossborder_bus_caps === nothing ? nothing :
                     get(crossborder_bus_caps, bus_id, 0.0) * line_rating_factor / BASEMVA
            lo, hi = if cap_pu === nothing
                (p_pu, p_pu)
            elseif crossborder_same_direction && p_pu > 1e-9
                (0.0, cap_pu)
            elseif crossborder_same_direction && p_pu < -1e-9
                (-cap_pu, 0.0)
            elseif crossborder_same_direction
                (0.0, 0.0)
            else
                (-cap_pu, cap_pu)
            end
            qb = cap_pu === nothing ? abs(p_pu) : cap_pu
            gen_count += 1
            gens[string(gen_count)] = Dict{String,Any}(
                "index"        => gen_count,
                "gen_bus"      => bus_idx[bus_id],
                "name"         => "XB_" * bus_id,
                "fuel"         => "CrossBorder",
                "technology"   => "Interconnector",
                "country"      => get(bus_country, bus_id, "?"),
                "installed_mw" => abs(mw),
                "pmax"       => hi,     "pmin" => lo,
                "qmax"       => qb,     "qmin" => -qb,
                "pg"         => p_pu,   "qg"   => 0.0,
                "vg"         => 1.0,
                "mbase"      => BASEMVA,
                "gen_status" => 1,
                "model"      => 2,  "ncost" => 2,
                "cost"       => [0.0, 0.0],
                "startup"    => 0.0,  "shutdown" => 0.0,
            )
        end
    end

    # ── Li-Ion BESS fleet ([scenario] only) ──────────────────
    # Each battery is a generator with pmin = −pmax: positive output discharges,
    # negative charges.  In the copper-plate market stages the daily energy
    # balance / SOC window is enforced in solve_da (da.jl) via the "energy_mwh"
    # field.  In the redispatch stage the unit stays FREE within ±rated power
    # and is ANCHORED to its cleared market schedule by the redispatch
    # objective (see solve_anchored_opf), like any other redispatchable unit —
    # freezing it (pmin = pmax) made hours hard-infeasible whenever the market
    # cleared a battery beyond what its bus's lines can carry.  The hourly
    # anchor deviation is not energy-constrained; the market SOC window only
    # holds for the anchored schedule itself.  Units missing from the schedule
    # are anchored to 0 MW in the objective, so a stale saved schedule cannot
    # turn a battery into a free energy source.
    if bess_units !== nothing
        for b in bess_units
            haskey(bus_idx, b.bus_id) || continue
            p_pu   = b.power_mw / BASEMVA
            name   = "BESS_" * b.bus_id
            da_pu  = (!isnothing(da_dispatch) && haskey(da_dispatch, name)) ?
                     da_dispatch[name] / BASEMVA : nothing
            gen_count += 1
            gens[string(gen_count)] = Dict{String,Any}(
                "index"        => gen_count,
                "gen_bus"      => bus_idx[b.bus_id],
                "name"         => name,
                "fuel"         => "Battery",
                "technology"   => "Li-Ion",
                "installed_mw" => b.power_mw,
                "energy_mwh"   => b.energy_mwh,
                "pmax"         =>  p_pu,
                "pmin"         => -p_pu,
                "pg"           => da_pu !== nothing ? clamp(da_pu, -p_pu, p_pu) : 0.0,
                "qmax"         => p_pu,   "qmin" => -p_pu,
                "qg"           => 0.0,
                "vg"           => 1.0,
                "mbase"        => BASEMVA,
                "gen_status"   => 1,
                "model"        => 2,  "ncost" => 2,
                "cost"         => [0.0, 0.0],
                "startup"      => 0.0,  "shutdown" => 0.0,
            )
        end
    end

    # ── Embedded CSP/TES units ([csp] mode = "embedded", Option A) ──────────
    # One network generator per plants-file row (CSPPlant, loaded and validated
    # by CSP.read_csp_plants).  pmin = 0 unless grid charging is allowed (then
    # the unit may draw up to its heater rating — negative pg enters the ES
    # balance as consumption, and the TES balance in solve_da converts it into
    # stored heat).  The linear cost is the row's VOM (typically 0: the heat is
    # free — the opportunity cost of KEEPING heat is priced by the thermal-value
    # cuts in solve_da, exactly as hydro's water value prices reservoir water).
    if csp_units !== nothing
        for u in csp_units
            haskey(bus_idx, u.bus_id) ||
                error("CSP unit $(u.plant_id): bus $(u.bus_id) not found in the network")
            u.pmax_e_mwe > 0 ||
                error("CSP unit $(u.plant_id): pmax_e_mwe must be positive")
            chg_pu = u.buy_from_grid ? u.pmax_charge_e_mwe / BASEMVA : 0.0
            p_pu   = u.pmax_e_mwe / BASEMVA
            name   = "CSP_" * u.plant_id
            da_pu  = (!isnothing(da_dispatch) && haskey(da_dispatch, name)) ?
                     da_dispatch[name] / BASEMVA : nothing
            gen_count += 1
            gens[string(gen_count)] = Dict{String,Any}(
                "index"        => gen_count,
                "gen_bus"      => bus_idx[u.bus_id],
                "name"         => name,
                "fuel"         => "Solar",
                "technology"   => "CSP",
                "installed_mw" => u.pmax_e_mwe,
                "csp_plant_id" => u.plant_id,
                "pmax"         => p_pu,
                "pmin"         => -chg_pu,
                "pg"           => da_pu !== nothing ? clamp(da_pu, -chg_pu, p_pu) : 0.0,
                "qmax"         => p_pu,   "qmin" => -p_pu,
                "qg"           => 0.0,
                "vg"           => 1.0,
                "mbase"        => BASEMVA,
                "gen_status"   => 1,
                "model"        => 2,  "ncost" => 2,
                "cost"         => [u.vom_eur_mwh * BASEMVA, 0.0],
                "startup"      => 0.0, "shutdown" => 0.0,
            )
        end
    end

    # ── Loads ────────────────────────────────────────────────
    # `load_power_factor` is the NET power factor the transmission grid sees at
    # each load bus (distribution-level PF correction is assumed already applied
    # below the model boundary).  qd = pd · tan(acos(pf)); pf = 1.0 ⇒ active only.
    demand_sum   = sum(skipmissing(load_df.demand))
    const_qd     = tan(acos(load_power_factor))
    loads        = Dict{String,Any}()
    load_count   = 0
    for row in eachrow(load_df)
        haskey(bus_idx, row.bus_id) || continue
        row.demand == 0.0 && continue
        pd_pu = Float64(row.demand) / demand_sum * total_load_mw / BASEMVA
        qd_pu = pd_pu * const_qd
        load_count += 1
        bus_i = bus_idx[row.bus_id]
        loads[string(load_count)] = Dict{String,Any}(
            "index"    => load_count,
            "load_bus" => bus_i,
            "name"     => String(row.bus_id) * "_load",
            "pd"       => pd_pu,
            "qd"       => qd_pu,
            "status"   => 1,
        )
    end

    # ── Load-shedding generators ──────────────────────────────
    # One curtailable unit per load bus priced at VoLL (10 000 EUR/MWh).
    # pg ∈ [0, pd] reduces net demand at the bus; qg ∈ [−pd, pd] provides
    # matching reactive relief.  Dispatches only when no feasible network
    # solution exists within the thermal/voltage limits.
    for (_, load) in loads
        bus_i  = load["load_bus"]
        pd_pu  = load["pd"]
        gen_count += 1
        gens[string(gen_count)] = Dict{String,Any}(
            "index"        => gen_count,
            "gen_bus"      => bus_i,
            "name"         => "LS_" * buses[string(bus_i)]["name"],
            "fuel"         => "LoadShed",
            "technology"   => "LoadShed",
            "installed_mw" => pd_pu * BASEMVA,
            "pmax"         => pd_pu,   "pmin" => 0.0,
            "qmax"         => pd_pu,   "qmin" => -pd_pu,
            "pg"           => 0.0,     "qg"   => 0.0,
            "vg"           => 1.0,
            "mbase"        => BASEMVA,
            "gen_status"   => 1,
            "model"        => 2,  "ncost" => 2,
            "cost"         => [LOAD_SHED_COST_EUR_MWH * BASEMVA, 0.0],
            "startup"      => 0.0,  "shutdown" => 0.0,
        )
    end

    # ── Assemble PowerModels dict ────────────────────────────
    network = Dict{String,Any}(
        "name"     => "Spain_Power_System",
        "baseMVA"  => BASEMVA,
        "per_unit" => true,
        "bus"      => buses,
        "branch"   => branches,
        "gen"      => gens,
        "load"     => loads,
        "dcline"   => dclines,
        "shunt"    => Dict{String,Any}(),
        "storage"  => Dict{String,Any}(),
        "switch"   => Dict{String,Any}(),
    )

    # Attach the disaggregated shunt-reactor fleet (absorbs EHV line charging).
    add_reactor_shunts!(network, buses, branches, bus_idx;
                        enabled        = reactors_enabled,
                        in_service_pct = reactor_in_service_pct)

    return (
        network  = network,
        bus_idx  = bus_idx,
        bus_df   = bus_df,
        gen_df   = gen_df,
        gens     = gens,
        branches = branches,
        dclines  = dclines,
        loads    = loads,
    )
end
