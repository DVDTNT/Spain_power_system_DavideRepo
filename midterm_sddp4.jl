# ============================================================
# Mid-term hydro-thermal scheduling by SDDP — 4-node hybrid system
#
# 4 zones ES / PT / FR / EU.  ES uses the SMS++/plan4res dataset that
# the downstream market chain runs on (Data/smspp_in + the EDF
# 37-climate-year profiles in Data/ts); PT, FR and EU use the real
# ~2024 system (Data/Generation.csv etc. with EMPIRE 2015–2019 hourly
# series) — the SMS++ PT is a future high-RES scenario that floods ES
# with cheap exports, so PT is modelled at 2024 instead.  Produces the same Bellman-cut /
# volume outputs as before, so [bellman] consumes them unchanged.
#
# Data
#   ES (SMS++/plan4res):
#     Data/smspp_in/TU_ThermalUnits.csv      thermal MW + VariableCost
#     Data/smspp_in/RES_RenewableUnits.csv   wind/PV MW, RoR MW + annual MWh
#     Data/smspp_in/SS_SeasonalStorage.csv   ES reservoir
#     Data/smspp_in/STS_ShortTermStorage.csv ES pumped storage
#     Data/smspp_in/ZV_ZoneValues.csv        ES annual demand [MWh]
#     Data/ts/EDF__*-ES / Profile-Iberia     37 climate years 1982–2018.
#   PT/FR/EU (real 2024):
#     Data/Generation.csv, Data/Transmission.csv, Data/Storage.csv,
#     Data/generation_cost_pypsa_2024.csv (+ defaults), thermal derated by
#     [midterm4.availability]; hourly EMPIRE series (Data/ts/EMPIRE).
#
# Model
#   • 78 weekly stages (Timestep 0..77) from [bellman].bgn_date,
#     block_hours-sized intra-week blocks.  The last stage carries a soft
#     end-of-horizon reservoir target (end_fill × v0, penalised at
#     end_penalty EUR/MWh) so the policy does not empty the reservoirs
#     into the horizon end; without it the zero terminal value function
#     makes water free after stage 78 and it is all spent.
#   • 3 reservoir states ES / FR / EU (ES size from SS_SeasonalStorage,
#     FR/EU from [midterm4.reservoir]); PT's small reservoir turbines a
#     weekly inflow budget (no state).  Pumped storage cycles within
#     the week, week-neutral.
#   • 37 scenarios = the EDF climate years; each is paired with a fixed
#     EMPIRE year (1982→2015, cycling) so a weekly sample is one joint
#     draw for all four zones.
#   • Writes Data/midterm4_effective_inputs.csv — the merged capacity /
#     cost table actually used, for inspection.
#
# Output: cuts (a_0 = FR slope, a_1 = ES slope, EU folded into b along
# its simulated trajectory) + hourly FR/ES volume trajectory.
#
# Run:   julia --project=. midterm_sddp4.jl          (train + export)
#        julia --project=. midterm_sddp4.jl resim    (reload cuts, write
#                                                     results/midterm4_diag.csv)
# ============================================================

using CSV, DataFrames, Dates, Printf, Random, Statistics, TOML
using JuMP, SDDP
import JSON

include("empire_scenario.jl")
include("fuel_prices.jl")

# ── configuration ────────────────────────────────────────────
# SPAIN_CONFIG points a run at an alternative config file, exactly as in
# run_market_chain.jl — the two must honour the same override or a scenario A/B lands
# the market chain on cuts trained for a different system.  Without this the
# env var was silently ignored here and the run retrained the tracked config's
# scenario while writing to the file names that config implies.
const CONFIG_PATH = get(ENV, "SPAIN_CONFIG", joinpath(@__DIR__, "config.toml"))
cfg  = TOML.parsefile(CONFIG_PATH)
CONFIG_PATH == joinpath(@__DIR__, "config.toml") ||
    println("Config         : $CONFIG_PATH")
mcfg = cfg["midterm4"]

# [scenario]: label != "2024" replaces capacities / costs / demand / NTCs /
# storage with the EMPIRE run at the configured period and suffixes every
# output file with "_<label>" (see empire_scenario.jl).
const SCEN_ACTIVE = empire_active(cfg)
const SCEN_SUFFIX = empire_suffix(cfg)
const EMP = SCEN_ACTIVE ? load_empire_scenario(cfg) : nothing

const BGN_DATE    = Date(cfg["bellman"]["bgn_date"])
const N_STAGES    = Int(mcfg["n_stages"])
const BLOCK_HOURS = Int(mcfg["block_hours"])
const NB          = div(168, BLOCK_HOURS)
const ITERATIONS  = Int(mcfg["iterations"])
const VOLL        = Float64(mcfg["voll"])
# End-of-horizon reservoir target: the last stage must reach END_FILL × v0 or
# pay END_PENALTY per missing MWh.  END_PENALTY = 0 disables it (zero terminal
# value → reservoirs drained by stage N_STAGES).
const END_FILL    = Float64(get(mcfg, "end_fill", 1.0))
const END_PENALTY = Float64(get(mcfg, "end_penalty", 150.0))
const SOLVER      = lowercase(String(mcfg["solver"]))
const SIM_YEAR    = Int(mcfg["sim_year"])
const CUTS_OUT    = joinpath(@__DIR__, empire_suffixed(mcfg["cuts_out"], cfg))
const VOLUME_OUT  = joinpath(@__DIR__, empire_suffixed(mcfg["volume_out"], cfg))
const TURBINE_OUT = joinpath(@__DIR__, empire_suffixed(
    get(mcfg, "turbine_out", "Data/TurbineSchedule_sddp4.csv"), cfg))
# Hourly ES-FR / ES-PT net position of the simulated policy (import into ES
# positive).  Consumed by the market chain only when [crossborder].source =
# "sddp"; written unconditionally so the two exchange sources can be compared.
const EXCHANGE_OUT = joinpath(@__DIR__, empire_suffixed(
    get(mcfg, "exchange_out", "Data/ExchangeSchedule_sddp4.csv"), cfg))
const DATA_DIR    = joinpath(@__DIR__, "Data")
const SMSPP_IN    = joinpath(DATA_DIR, "smspp_in")
const TS_DIR      = joinpath(DATA_DIR, "ts")
const EMPIRE_DIR  = joinpath(TS_DIR, "EMPIRE")

@assert 168 % BLOCK_HOURS == 0 && 24 % BLOCK_HOURS == 0 "block_hours must divide 24"
Random.seed!(Int(get(mcfg, "seed", 1234)))

const ZONES = ["ES", "FR", "PT", "EU"]
const RZ    = ["ES", "FR", "EU"]                 # reservoir state zones
zidx = Dict(z => i for (i, z) in enumerate(ZONES))

# ── solver ───────────────────────────────────────────────────
if SOLVER == "gurobi"
    using Gurobi
    const GRB_ENV = Gurobi.Env()
    optimizer() = optimizer_with_attributes(
        () -> Gurobi.Optimizer(GRB_ENV), "OutputFlag" => 0, "Threads" => 1)
else
    using HiGHS
    optimizer() = optimizer_with_attributes(HiGHS.Optimizer,
        "output_flag" => false, "threads" => 1)
end

# ════════════════ ES — SMS++ dataset ═════════════════════════
read_smspp(f) = CSV.read(joinpath(SMSPP_IN, f), DataFrame; delim = ';')
df_tu  = read_smspp("TU_ThermalUnits.csv")
df_res = read_smspp("RES_RenewableUnits.csv")
df_ss  = read_smspp("SS_SeasonalStorage.csv")
df_sts = read_smspp("STS_ShortTermStorage.csv")
df_zv  = read_smspp("ZV_ZoneValues.csv")

# EDF profiles: columns = climate years; values are load factors (wind/PV)
# or per-hour fractions of the annual total (load / RoR daily / inflow weekly)
struct Profile
    res   :: Symbol                  # :hourly | :daily | :weekly
    years :: Vector{Int}
    data  :: Matrix{Float64}
end
function load_profile(fname, res)::Profile
    df = CSV.read(joinpath(TS_DIR, fname), DataFrame)
    Profile(res, [parse(Int, String(n)) for n in names(df)[2:end]],
            Matrix{Float64}(df[:, 2:end]))
end
prof_wind_es = load_profile("EDF__WindOnshore-LoadFactor-PresentClimate-ES__13082019__13082019__v1.csv", :hourly)
prof_pv_es   = load_profile("EDF__PV-LoadFactor-PresentClimate-ES__13082019__13082019__v1.csv",         :hourly)
prof_ror_es  = load_profile("EDF__RunOfRiver-HourlyCoefficient-PresentClimate-ES__18092019__18092019__v1.csv", :daily)
prof_inf_es  = load_profile("EDF__Inflow-HourlyCoefficient-PresentClimate-ES__18092019__18092019__v1.csv",     :weekly)
prof_load    = load_profile("Profile-Iberia.csv", :hourly)

const YEARS = sort(collect(intersect(Set(prof_wind_es.years), Set(prof_pv_es.years),
                                     Set(prof_ror_es.years),  Set(prof_inf_es.years),
                                     Set(prof_load.years))))
const NSCEN = length(YEARS)
ycol(p::Profile, y::Int) = findfirst(==(y), p.years)

# borrow an ES load-factor shape, rescaled (cap 1.0) to a target mean CF
function scaled_profile(base::Profile, target_cf::Float64)::Profile
    s = target_cf / max(mean(base.data), 1e-9)
    d = similar(base.data)
    for _ in 1:12
        @. d = min(1.0, s * base.data)
        m = mean(d)
        m ≥ target_cf - 1e-6 && break
        s *= target_cf / m
    end
    Profile(base.res, base.years, d)
end

# Iberian renewable units: (zone, cap MW, annual MWh for :energy kind, profile)
struct ResUnit
    zone::String; cap::Float64; annualE::Float64; kind::Symbol; prof::Profile
end
# ES wind/solar keep the smspp capacities but use the EMPIRE per-zone real
# weather shapes (the EDF LoadFactor CFs are ~0.17 vs the real fleet's ~0.23+,
# understating Spanish wind by ~15 TWh/yr); only run-of-river stays EDF.
res_units = ResUnit[]
es_wind_cap, es_pv_cap = 0.0, 0.0
for r in eachrow(df_res)
    zone, lname = String(r.Zone), lowercase(r.Name)
    zone == "ES" || continue
    cap = Float64(r.MaxPower) * r.NumberUnits
    if occursin("river", lname) || occursin("run_of_river", lname)
        # MaxPower holds annual energy [MWh], Capacity the MW limit
        push!(res_units, ResUnit(zone, Float64(r.Capacity) * r.NumberUnits,
                                 Float64(r.MaxPower), :energy, prof_ror_es))
    elseif occursin("wind", lname)
        global es_wind_cap += cap
    else
        global es_pv_cap += cap
    end
end

iberia_therm = [(zone = String(r.Zone), tech = String(r.Name),
                 pmax = Float64(r.MaxPower) * r.NumberUnits,
                 cost = Float64(r.VariableCost), src = "smspp")
                for r in eachrow(df_tu)
                if String(r.Zone) == "ES" && Float64(r.MaxPower) > 0.0]

iberia_sts = [(zone = String(r.Zone), pmax = Float64(r.MaxPower),
               vmax = Float64(r.MaxVolume), eta_t = Float64(r.TurbineEfficiency),
               eta_p = Float64(r.PumpingEfficiency), v0frac = 0.0)
              for r in eachrow(df_sts) if String(r.Zone) == "ES"]

ss_es = only(filter(r -> String(r.Zone) == "ES", eachrow(df_ss)))
demand_yr = Dict(String(r.Zone) => Float64(r.value) for r in eachrow(df_zv)
                 if String(r.Zone) == "ES")

# ════════════════ FR / EU — real 2024 dataset ════════════════
node_of(s::AbstractString) = s == "France" ? "FR" : s == "Portugal" ? "PT" :
                             s == "Spain"  ? "ES" : startswith(s, "ES") ? "ES" : String(s)

df_gen = CSV.read(joinpath(DATA_DIR, "Generation.csv"), DataFrame)
rename!(df_gen, names(df_gen)[1] => :Node, names(df_gen)[3] => :cap)
caps = Dict(z => Dict{String,Float64}() for z in ("FR", "PT", "EU"))
for r in eachrow(df_gen)
    z = node_of(String(r.Node))
    z in ("FR", "PT", "EU") || continue
    caps[z][String(r.GeneratorTechnology)] =
        get(caps[z], String(r.GeneratorTechnology), 0.0) + Float64(r.cap)
end

df_cost = CSV.read(joinpath(DATA_DIR, "generation_cost_pypsa_2024.csv"), DataFrame)
costrow(carrier, tech="") = only(df_cost[(df_cost.carrier .== carrier) .&
    (tech == "" .|| coalesce.(df_cost.technology, "") .== tech), :variable_total_eur_per_mwh])
const TECH_COST = Dict(
    "Bio"      => costrow("Biomass"),
    "Coal"     => costrow("Coal", "Hard Coal"),
    "Lignite"  => 80.0,
    "Gas CCGT" => costrow("Gas", "CCGT"),
    "Gas OCGT" => costrow("Gas", "OCGT"),
    "Nuclear"  => costrow("Nuclear"),
    "Oil"      => costrow("Oil", "Internal Combustion"),
    "Waste"    => 25.0,
    "Geo"      => 5.0)

# zone-specific 2024 gas SRMC ([midterm4.gas_cost]: Iberia on MIBGAS, FR/EU on
# TTF) — overrides the single pypsa CCGT/OCGT figure for all four zones
const GAS_CCGT = Dict(String(k) => Float64(v) for (k, v) in mcfg["gas_cost"]["ccgt"])
const GAS_OCGT = Dict(String(k) => Float64(v) for (k, v) in mcfg["gas_cost"]["ocgt"])
tech_cost(z, t) = t == "Gas CCGT" ? get(GAS_CCGT, z, TECH_COST[t]) :
                  t == "Gas OCGT" ? get(GAS_OCGT, z, TECH_COST[t]) : TECH_COST[t]

# mean availability derating (maintenance + forced outages) — 2024 fleet only;
# [midterm4.availability.<zone>] tables override per zone (FR nuclear)
af_cfg = get(mcfg, "availability", Dict())
AF  = Dict(String(k) => Float64(v) for (k, v) in af_cfg if !(v isa AbstractDict))
AFZ = Dict(String(z) => Dict(String(k) => Float64(v) for (k, v) in d)
           for (z, d) in af_cfg if d isa AbstractDict)
avail(z, t) = get(get(AFZ, z, AF), t, get(AF, t, 1.0))
eur_therm = [(zone = z, tech = t, pmax = caps[z][t] * avail(z, t),
              cost = tech_cost(z, t), src = "2024")
             for z in ("FR", "PT", "EU") for t in sort(collect(keys(TECH_COST)))
             if get(caps[z], t, 0.0) > 0.0]

# ES thermal costs: one coherent 2024 fuel+CO2 world (same table the market
# chain prices ES units from in opf_spain.jl), replacing the mixed-vintage
# smspp VariableCost (coal 45 = ~2019 CO2, gas 161 = 2022 crisis).  Biomass
# gets a support-scheme effective bid (pure fuel cost would be ~85).
const ES_COST = Dict(
    "Coal"           => TECH_COST["Coal"],
    "Gas"            => tech_cost("ES", "Gas CCGT"),
    "Nuclear"        => TECH_COST["Nuclear"],
    "Biomass"        => 40.0,
    "Waste"          => TECH_COST["Waste"],
    "Oil"            => TECH_COST["Oil"],
    "Oil/Diesel"     => TECH_COST["Oil"],
    "Diesel"         => TECH_COST["Oil"],
    "Oil/Gas/Diesel" => TECH_COST["Oil"],
    "Oil/Gas"        => tech_cost("ES", "Gas OCGT"))
# ES coal carries the same availability derating as the market chain
# ([da].coal_availability): the smspp/generations 2 900 MW is the nameplate of a
# fleet that had largely closed by 2024.  It matters here for the same reason —
# once gas is priced seasonally the expensive weeks put coal in merit, and an
# underated fleet would run 2 900 MW against a real ~930 MW.
const ES_COAL_AVAIL = Float64(get(get(cfg, "da", Dict()), "coal_availability", 1.0))
iberia_therm = [(zone = u.zone, tech = u.tech,
                 pmax = u.tech == "Coal" ? u.pmax * ES_COAL_AVAIL : u.pmax,
                 cost = ES_COST[u.tech],
                 src = u.tech == "Coal" ?
                       @sprintf("smspp cap x %.3f avail / 2024 cost", ES_COAL_AVAIL) :
                       "smspp cap / 2024 cost")
                for u in iberia_therm]
# ES cogeneration / waste / mini-hydro — the OMIE "Cogeneración / Residuos /
# Mini hidráulica" market group, absent from both smspp_in and generations.csv.
# Sized and priced from the SAME [chp] config the market chain uses, so the
# water values this model produces are computed against the same residual
# demand the day-ahead stage will face.  The annual defaults are used here (the
# per-day [chp.by_date] overrides belong to the two study days only).
let chp = get(cfg, "chp", Dict())
    if get(chp, "enabled", false)
        for (key, tech) in (("gas", "Cogeneration"), ("waste", "Waste_CHP"),
                            ("minihydro", "Mini_hydro"))
            mw = Float64(get(chp, key * "_mw", 0.0))
            mw > 1e-6 || continue
            push!(iberia_therm,
                  (zone = "ES", tech = tech, pmax = mw,
                   cost = Float64(get(chp, key * "_cost_eur_mwh", 0.0)),
                   src  = "added ([chp] " * key * ")"))
        end
    end
end

therm = vcat(iberia_therm, eur_therm)

# ── Observed daily gas price → per-STAGE gas cost ([midterm4].gas_price_source)
# "mibgas" replaces the flat [midterm4.gas_cost] figure for the IBERIAN gas
# fleet with the weekly mean of the observed MIBGAS + EUA short-run marginal
# cost (fuel_prices.jl).  FR/EU buy on TTF, not MIBGAS, so they keep their
# config values.  The ES [chp] blocks are excluded: their offer price is a
# calibrated market bid, not a fuel cost.
#
# This is a DETERMINISTIC seasonal path — the cost of stage t is known, not a
# random variable — so the policy has perfect foresight of the 2024-25 gas
# market.  Declare that when reporting: a real operator did not know it.  The
# alternative (gas price as a stochastic, autocorrelated process) would need it
# as a STATE variable, taking the value function from 3 to 4 dimensions.
const GAS_SRC = lowercase(String(get(mcfg, "gas_price_source", "config")))
GAS_SRC in ("config", "mibgas") ||
    error("config.toml: [midterm4].gas_price_source must be \"config\" or \"mibgas\"")

# unit index ⇒ :ccgt | :ocgt for the Iberian gas fleet, `nothing` otherwise.
const GAS_KIND = [
    let z = therm[i].zone, t = therm[i].tech
        !(z in ("ES", "PT"))                      ? nothing :
        occursin("Cogeneration", t)               ? nothing :   # [chp] block
        t == "Gas" || occursin("CCGT", t)         ? :ccgt   :
        t == "Oil/Gas" || occursin("OCGT", t)     ? :ocgt   : nothing
    end for i in 1:length(therm)]

const GAS_STAGE = if GAS_SRC == "mibgas" && !SCEN_ACTIVE
    fp = load_fuel_prices(cfg)
    d = Dict(k => gas_srmc_stages(fp, k, BGN_DATE, N_STAGES) for k in (:ccgt, :ocgt))
    @printf("Iberian gas cost: observed MIBGAS+EUA, %d weekly stages — CCGT %.1f…%.1f (mean %.1f), OCGT %.1f…%.1f EUR/MWh\n",
            N_STAGES, minimum(d[:ccgt]), maximum(d[:ccgt]), mean(d[:ccgt]),
            minimum(d[:ocgt]), maximum(d[:ocgt]))
    d
else
    nothing
end

# Marginal cost of unit i at stage t.
therm_cost(i::Int, t::Int) =
    (GAS_STAGE === nothing || GAS_KIND[i] === nothing) ? therm[i].cost :
    GAS_STAGE[GAS_KIND[i]][t]

df_tr = CSV.read(joinpath(DATA_DIR, "Transmission.csv"), DataFrame)
lines = [(from = node_of(String(r[1])), to = node_of(String(r.ToNode)),
          fmax = Float64(r.Capacity_MW)) for r in eachrow(df_tr)]

df_st = CSV.read(joinpath(DATA_DIR, "Storage.csv"), DataFrame)
rename!(df_st, names(df_st)[1] => :Nodes)
eur_sts = [(zone = node_of(String(r.Nodes)), pmax = Float64(r.Capacity_MW),
            vmax = Float64(r.Energy_MWh), eta_t = 0.87, eta_p = 0.87, v0frac = 0.5)
           for r in eachrow(df_st) if node_of(String(r.Nodes)) in ("FR", "PT", "EU")]
sts = vcat(iberia_sts, eur_sts)

# ── seasonal reservoirs (states) ─────────────────────────────
vmax_twh = Dict(String(k) => Float64(v) for (k, v) in mcfg["reservoir"]["vmax_twh"])
fill0    = Dict(String(k) => Float64(v) for (k, v) in mcfg["reservoir"]["fill0"])
reservoirs = Dict(
    "ES" => (pmax = Float64(ss_es.MaxPower) * ss_es.NumberUnits,
             vmax = Float64(ss_es.MaxVolume), v0 = Float64(ss_es.InitialVolume),
             inflow_yr = Float64(ss_es.Inflows)),
    "FR" => (pmax = caps["FR"]["Hydro regulated"], vmax = vmax_twh["FR"] * 1e6,
             v0 = fill0["FR"] * vmax_twh["FR"] * 1e6, inflow_yr = NaN),
    "EU" => (pmax = caps["EU"]["Hydro regulated"], vmax = vmax_twh["EU"] * 1e6,
             v0 = fill0["EU"] * vmax_twh["EU"] * 1e6, inflow_yr = NaN))

# ════════════════ [scenario] — EMPIRE future system ═════════════
# Replaces the 2024 capacity / cost / demand / NTC / storage tables (all four
# zones) with the EMPIRE run at the configured period.  Kept at 2024: every
# hourly shape (EDF climate years, EMPIRE 2015–2019 weather), the reservoir
# volumes / initial fills / inflows, and the ES CHP block.
if SCEN_ACTIVE
    println("Scenario $(EMP.label): EMPIRE period $(EMP.period), CO2 " *
            "$(round(EMP.co2_price; digits = 1)) EUR/t ($(EMP.co2_src)) — " *
            "overriding 2024 system")

    # zone × tech capacities (model tech names) for FR/PT/EU lookups below
    for z in ("FR", "PT", "EU")
        caps[z] = copy(EMP.caps[z])
    end

    # thermal fleet: EMPIRE capacities × [midterm4.availability], EMPIRE costs
    # (marginal_costs + CO2 adder); ES cogeneration kept as in 2024 (EMPIRE has
    # no CHP class — near-baseload heat-driven output with heat-credited cost).
    therm = [(zone = z, tech = t,
              pmax = EMP.caps[z][t] * avail(z, empire_avail_key(t)),
              cost = EMP.costs[t], src = "EMPIRE $(EMP.label)")
             for z in ZONES for t in EMPIRE_THERMAL_TECHS
             if get(EMP.caps[z], t, 0.0) > 0.0]
    push!(therm, (zone = "ES", tech = "Cogeneration", pmax = 2400.0, cost = 50.0,
                  src = "added (REE 2024 CHP)"))

    # ES VRE: EMPIRE capacities, EMPIRE real-weather shapes; run-of-river keeps
    # the EDF daily profile with capacity and annual energy scaled by the
    # EMPIRE growth (constant capacity factor).
    es_wind_cap = get(EMP.caps["ES"], "Wind onshore", 0.0)
    es_pv_cap   = get(EMP.caps["ES"], "Solar",        0.0)
    ror_new = get(EMP.caps["ES"], "Hydro run-of-the-river", 0.0)
    ror_old = sum(u.cap for u in res_units; init = 0.0)
    if ror_old > 1e-3 && ror_new > 0.0
        ror_f     = ror_new / ror_old
        res_units = [ResUnit(u.zone, u.cap * ror_f, u.annualE * ror_f, u.kind, u.prof)
                     for u in res_units]
    end

    # seasonal reservoirs: EMPIRE turbine capacity; volumes / initial fill /
    # inflows unchanged (reservoir stock barely changes by 2035)
    reservoirs = Dict(
        "ES" => (pmax = EMP.caps["ES"]["Hydro regulated"],
                 vmax = Float64(ss_es.MaxVolume), v0 = Float64(ss_es.InitialVolume),
                 inflow_yr = Float64(ss_es.Inflows)),
        "FR" => (pmax = EMP.caps["FR"]["Hydro regulated"], vmax = vmax_twh["FR"] * 1e6,
                 v0 = fill0["FR"] * vmax_twh["FR"] * 1e6, inflow_yr = NaN),
        "EU" => (pmax = EMP.caps["EU"]["Hydro regulated"], vmax = vmax_twh["EU"] * 1e6,
                 v0 = fill0["EU"] * vmax_twh["EU"] * 1e6, inflow_yr = NaN))

    # cross-zone NTCs at the EMPIRE period (2024 line orientation preserved)
    lines = [(from = f, to = t, fmax = c) for ((f, t), c) in sort(collect(EMP.ntc))]

    # short-term storage: EMPIRE pumped hydro + Li-Ion BESS (week-neutral)
    sts = vcat(
        [(zone = z, pmax = EMP.storage[z].phs_mw, vmax = EMP.storage[z].phs_mwh,
          eta_t = 0.87, eta_p = 0.87, v0frac = 0.5)
         for z in ZONES if EMP.storage[z].phs_mw > 1e-3],
        [(zone = z, pmax = EMP.storage[z].bess_mw, vmax = EMP.storage[z].bess_mwh,
          eta_t = 0.95, eta_p = 0.95, v0frac = 0.5)
         for z in ZONES if EMP.storage[z].bess_mw > 1e-3])

    # ES annual demand (FR/PT/EU are rescaled on the hourly EMPIRE shapes below)
    demand_yr["ES"] = EMP.demand["ES"]
end

# ── effective-inputs table (for inspection) ──────────────────
eff = DataFrame(zone = String[], tech = String[], pmax_MW = Float64[],
                cost_eur_mwh = Float64[], source = String[])
for u in therm
    push!(eff, (u.zone, u.tech, round(u.pmax, digits = 1), round(u.cost, digits = 2), u.src))
end
for u in res_units
    push!(eff, (u.zone, u.kind == :cf ? "VRE (wind/PV)" : "Run-of-river",
                round(u.cap, digits = 1), 0.0, SCEN_ACTIVE ? "EMPIRE growth × smspp" : "smspp"))
end
push!(eff, ("ES", "Wind onshore", round(es_wind_cap, digits = 1), 0.0,
            SCEN_ACTIVE ? "EMPIRE $(EMP.label)" : "smspp cap / EMPIRE shape"))
push!(eff, ("ES", "Solar",        round(es_pv_cap,   digits = 1), 0.0,
            SCEN_ACTIVE ? "EMPIRE $(EMP.label)" : "smspp cap / EMPIRE shape"))
for z in ("FR", "PT", "EU"), t in ("Solar", "Wind onshore", "Wind offshore grounded",
                             "Wind offshore floating", "Hydro run-of-the-river", "Wave")
    get(caps[z], t, 0.0) > 0.0 && push!(eff, (z, t, round(caps[z][t], digits = 1), 0.0,
                                              SCEN_ACTIVE ? "EMPIRE $(EMP.label)" : "2024"))
end
for (z, r) in reservoirs
    push!(eff, (z, "Reservoir hydro (state)", round(r.pmax, digits = 1), 0.0,
                z == "ES" ? "smspp" : "2024"))
end
push!(eff, ("PT", "Reservoir hydro (weekly budget)",
            round(caps["PT"]["Hydro regulated"], digits = 1), 0.0, "2024"))
for s in sts
    push!(eff, (s.zone, "Pumped storage / battery", s.pmax, 0.0,
                SCEN_ACTIVE ? "EMPIRE $(EMP.label)" : (s.zone == "ES" ? "smspp" : "2024")))
end
CSV.write(joinpath(DATA_DIR, "midterm4_effective_inputs$(SCEN_SUFFIX).csv"), eff)

# ════════════════ time series → per-block arrays ═════════════
# EMPIRE hourly series (FR/EU), one 8760-column per EMPIRE year
const EMP_YEARS = collect(2015:2019)
emp_col(w) = 1 + (w - 1) % length(EMP_YEARS)     # scenario w → EMPIRE year column

function read_empire(fname)::DataFrame
    df = CSV.read(joinpath(EMPIRE_DIR, fname), DataFrame)
    df.time = DateTime.(String.(df.time), dateformat"dd/mm/yyyy HH:MM")
    df
end
function year_matrix(df::DataFrame, vals::AbstractVector{<:Real})::Matrix{Float64}
    out = Matrix{Float64}(undef, 8760, length(EMP_YEARS))
    for (k, y) in enumerate(EMP_YEARS)
        keep = (year.(df.time) .== y) .& .!((month.(df.time) .== 2) .& (day.(df.time) .== 29))
        v = vals[keep]
        length(v) == 8760 || error("EMPIRE year $y: $(length(v)) rows")
        out[:, k] = v
    end
    out
end

df_ld = read_empire("electricload.csv");  df_so = read_empire("solar.csv")
df_wn = read_empire("windonshore.csv");   df_wf = read_empire("windoffshore.csv")
df_rr = read_empire("hydroror.csv");      df_hs = read_empire("hydroseasonal.csv")

# capacity-weighted ES shapes from the per-NUTS-zone EMPIRE columns
# (scenario runs weight by the EMPIRE per-NUTS capacities at the period)
es_zone_caps = Dict{String,Dict{String,Float64}}()
if SCEN_ACTIVE
    for (t, zc) in EMP.caps_nuts
        es_zone_caps[t] = copy(zc)
    end
else
    for r in eachrow(df_gen)
        startswith(String(r.Node), "ES") || continue
        zc = get!(es_zone_caps, String(r.GeneratorTechnology), Dict{String,Float64}())
        zc[String(r.Node)] = get(zc, String(r.Node), 0.0) + Float64(r.cap)
    end
end
function es_weighted(df::DataFrame, tech::String)::Matrix{Float64}
    zc   = es_zone_caps[tech]
    cols = [c for c in names(df) if startswith(c, "ES") && get(zc, c, 0.0) > 0.0]
    w    = [zc[c] for c in cols]
    year_matrix(df, Matrix{Float64}(df[:, cols]) * w ./ sum(w))
end
EMP_ES_WIND = es_weighted(df_wn, "Wind onshore")
EMP_ES_PV   = es_weighted(df_so, "Solar")

EMP_LOAD = Dict(z => year_matrix(df_ld, Float64.(df_ld[:, z])) for z in ("FR", "PT", "EU"))
# scenario: rescale every weather-year column to the EMPIRE annual demand of
# the period (shape preserved, level replaced)
if SCEN_ACTIVE
    for z in ("FR", "PT", "EU"), k in 1:length(EMP_YEARS)
        col = @view EMP_LOAD[z][:, k]
        col .*= EMP.demand[z] / sum(col)
    end
end
EMP_INF  = Dict(z => year_matrix(df_hs, Float64.(df_hs[:, z])) for z in ("FR", "PT", "EU"))
# ES seasonal inflow from EMPIRE: unlike FR/PT/EU it is reported per NUTS3, so
# the national series is the sum of the ES columns.  Only used when
# [midterm4].es_inflow_source selects it — see ES_INFLOW_SRC below.
let es_hs = [c for c in names(df_hs) if startswith(String(c), "ES")]
    EMP_INF["ES"] = year_matrix(df_hs,
        vec(sum(Matrix{Float64}(df_hs[:, es_hs]), dims = 2)))
end
EMP_VRE  = Dict{String,Matrix{Float64}}()
for z in ("FR", "PT", "EU")
    m  = year_matrix(df_so, Float64.(df_so[:, z])) .* caps[z]["Solar"]
    m .+= year_matrix(df_wn, Float64.(df_wn[:, z])) .* caps[z]["Wind onshore"]
    if z in names(df_wf)
        m .+= year_matrix(df_wf, Float64.(df_wf[:, z])) .*
              (get(caps[z], "Wind offshore grounded", 0.0) + get(caps[z], "Wind offshore floating", 0.0))
    end
    m .+= year_matrix(df_rr, Float64.(df_rr[:, z])) .* caps[z]["Hydro run-of-the-river"]
    m .+= get(caps[z], "Wave", 0.0) * 0.25
    EMP_VRE[z] = m
end

# calendar mapping (no Feb 29 in the Jul-2024..Dec-2025 window)
function profile_row(res::Symbol, k::Int)::Int
    dt  = DateTime(BGN_DATE) + Hour(k)
    doy = dayofyear(Date(2023, month(dt), day(dt)))
    res == :hourly && return (doy - 1) * 24 + hour(dt) + 1
    res == :daily  && return doy
    return min(div(doy - 1, 7) + 1, 53)
end
edf_block(p::Profile, w, t, b) = sum(p.data[profile_row(p.res, (t-1)*168 + (b-1)*BLOCK_HOURS + j),
                                            ycol(p, YEARS[w])] for j in 0:BLOCK_HOURS-1) / BLOCK_HOURS
emp_block(M::Matrix{Float64}, w, t, b) =
    sum(M[profile_row(:hourly, (t-1)*168 + (b-1)*BLOCK_HOURS + j), emp_col(w)]
        for j in 0:BLOCK_HOURS-1) / BLOCK_HOURS

println("Mid-term SDDP (4 nodes, hybrid$(SCEN_ACTIVE ? ", scenario " * EMP.label : "")): " *
        "$(N_STAGES) weekly stages × $(NB) blocks of $(BLOCK_HOURS) h,")
println("  $(NSCEN) scenarios = EDF climate years $(first(YEARS))–$(last(YEARS)) (ES/PT), each paired")
println("  with EMPIRE year 2015+(i-1)%5 (FR/EU); solver=$(SOLVER)")
println(END_PENALTY > 0 ?
    @sprintf("  end-of-horizon target: %.0f%% of the initial volume, penalty %.0f EUR/MWh",
             100 * END_FILL, END_PENALTY) :
    "  end-of-horizon target: none (zero terminal value → reservoirs drained)")

# ── ES seasonal inflow: which dataset ────────────────────────
# The two sources disagree on BOTH level and seasonality, and the seasonality
# decides whether the policy releases any water in summer:
#
#            Jun   Jul   Aug   Sep  |  Jun-Sep   annual
#   EDF      5.3%  3.0%  1.5%  2.2% |   12.0%   27.08 TWh/yr
#   EMPIRE   7.4%  7.8%  5.0%  5.3% |   25.5%   21.86 TWh/yr
#
# Under EDF's near-dry summer a reservoir starting 30 % full refuses to release
# any water from July to late October, which leaves the market chain's
# day-ahead with zero reservoir hydro on 8 July 2024 against ~74 GWh actually
# generated.  "empire_scaled" keeps EMPIRE's seasonality but rescales to the
# SS_SeasonalStorage annual total, so the shape can be tested on its own.
const ES_INFLOW_SRC = lowercase(String(get(mcfg, "es_inflow_source", "edf")))
ES_INFLOW_SRC ∈ ("edf", "empire", "empire_scaled") ||
    error("config.toml: [midterm4].es_inflow_source must be " *
          "\"edf\", \"empire\" or \"empire_scaled\"")
# mean MW over every hour of the EMPIRE series ⇒ its implied annual MWh
const ES_INFLOW_SCALE = if ES_INFLOW_SRC == "empire_scaled"
    emp_yr = mean(EMP_INF["ES"]) * 8760
    emp_yr > 0 ? reservoirs["ES"].inflow_yr / emp_yr : 1.0
else
    1.0
end
if ES_INFLOW_SRC == "edf"
    @printf "ES seasonal inflow: edf  (%.2f TWh/yr × EDF weekly coefficient)\n" (reservoirs["ES"].inflow_yr / 1e6)
else
    @printf "ES seasonal inflow: %s  (EMPIRE hydroseasonal, %.2f TWh/yr, scale ×%.3f)\n" ES_INFLOW_SRC (ES_INFLOW_SCALE * mean(EMP_INF["ES"]) * 8760 / 1e6) ES_INFLOW_SCALE
end

DEM = Array{Float64}(undef, N_STAGES, NSCEN, length(ZONES), NB)
AVL = Array{Float64}(undef, N_STAGES, NSCEN, length(ZONES), NB)
INF = Array{Float64}(undef, N_STAGES, NSCEN, length(RZ), NB)
INFPT = Array{Float64}(undef, N_STAGES, NSCEN)          # PT weekly inflow budget [MWh]
for t in 1:N_STAGES, w in 1:NSCEN
    for b in 1:NB
        DEM[t, w, zidx["ES"], b] = demand_yr["ES"] * edf_block(prof_load, w, t, b)
        DEM[t, w, zidx["PT"], b] = emp_block(EMP_LOAD["PT"], w, t, b)
        DEM[t, w, zidx["FR"], b] = emp_block(EMP_LOAD["FR"], w, t, b)
        DEM[t, w, zidx["EU"], b] = emp_block(EMP_LOAD["EU"], w, t, b)
        a_es = es_wind_cap * emp_block(EMP_ES_WIND, w, t, b) +
               es_pv_cap   * emp_block(EMP_ES_PV,   w, t, b)
        for u in res_units                            # ES run-of-river (EDF)
            m = edf_block(u.prof, w, t, b)
            a_es += u.kind == :cf ? u.cap * m : min(u.cap, u.annualE * m)
        end
        AVL[t, w, zidx["ES"], b] = a_es
        AVL[t, w, zidx["PT"], b] = emp_block(EMP_VRE["PT"], w, t, b)
        AVL[t, w, zidx["FR"], b] = emp_block(EMP_VRE["FR"], w, t, b)
        AVL[t, w, zidx["EU"], b] = emp_block(EMP_VRE["EU"], w, t, b)
        INF[t, w, 1, b] = ES_INFLOW_SRC == "edf" ?
            reservoirs["ES"].inflow_yr * edf_block(prof_inf_es, w, t, b) * BLOCK_HOURS :
            ES_INFLOW_SCALE * emp_block(EMP_INF["ES"], w, t, b) * BLOCK_HOURS
        INF[t, w, 2, b] = emp_block(EMP_INF["FR"], w, t, b) * BLOCK_HOURS
        INF[t, w, 3, b] = emp_block(EMP_INF["EU"], w, t, b) * BLOCK_HOURS
    end
    INFPT[t, w] = sum(emp_block(EMP_INF["PT"], w, t, b) for b in 1:NB) * BLOCK_HOURS
end
const PT_RES_PMAX = caps["PT"]["Hydro regulated"]

# ── SDDP model ───────────────────────────────────────────────
model = SDDP.LinearPolicyGraph(;
    stages = N_STAGES, sense = :Min, lower_bound = 0.0, optimizer = optimizer(),
) do sp, t
    Δh = BLOCK_HOURS
    @variable(sp, 0 <= vres[r in RZ] <= reservoirs[r].vmax,
              SDDP.State, initial_value = reservoirs[r].v0)
    @variable(sp, 0 <= vtraj[r in RZ, b in 0:NB] <= reservoirs[r].vmax)
    @variable(sp, 0 <= turb[r in RZ, 1:NB] <= reservoirs[r].pmax)
    @variable(sp, spill[RZ, 1:NB] >= 0)
    @constraint(sp, [r in RZ], vtraj[r, 0] == vres[r].in)
    @constraint(sp, vdyn[r in RZ, b in 1:NB],
        vtraj[r, b] - vtraj[r, b-1] + Δh * (turb[r, b] + spill[r, b]) == 0.0)  # RHS ← inflow
    @constraint(sp, [r in RZ], vres[r].out == vtraj[r, NB])

    # PT reservoir: weekly inflow budget, no state
    @variable(sp, 0 <= turbpt[1:NB] <= PT_RES_PMAX)
    @constraint(sp, ptbudget, Δh * sum(turbpt) <= 0.0)                          # RHS ← inflow

    @variable(sp, 0 <= gth[i in 1:length(therm), 1:NB] <= therm[i].pmax)
    @variable(sp, gres[z in 1:length(ZONES), 1:NB] >= 0)

    ns = length(sts)
    @variable(sp, 0 <= sturb[j in 1:ns, 1:NB] <= sts[j].pmax)
    @variable(sp, 0 <= spump[j in 1:ns, 1:NB] <= sts[j].pmax)
    @variable(sp, 0 <= svol[j in 1:ns, 0:NB] <= sts[j].vmax)
    @constraint(sp, [j in 1:ns], svol[j, 0]  == sts[j].v0frac * sts[j].vmax)
    @constraint(sp, [j in 1:ns], svol[j, NB] == sts[j].v0frac * sts[j].vmax)
    @constraint(sp, [j in 1:ns, b in 1:NB],
        svol[j, b] == svol[j, b-1] + Δh * (sts[j].eta_p * spump[j, b] - sturb[j, b] / sts[j].eta_t))

    @variable(sp, -lines[l].fmax <= flow[l in 1:length(lines), 1:NB] <= lines[l].fmax)
    @variable(sp, shed[1:length(ZONES), 1:NB] >= 0)

    @constraint(sp, bal[zi in 1:length(ZONES), b in 1:NB],
        sum(gth[i, b] for i in 1:length(therm) if zidx[therm[i].zone] == zi)
      + gres[zi, b]
      + sum(turb[r, b] for r in RZ if zidx[r] == zi)
      + (ZONES[zi] == "PT" ? turbpt[b] : 0.0)
      + sum(sturb[j, b] - spump[j, b] for j in 1:ns if zidx[sts[j].zone] == zi)
      + sum(flow[l, b] * (lines[l].to == ZONES[zi] ? 1 : lines[l].from == ZONES[zi] ? -1 : 0)
            for l in 1:length(lines))
      + shed[zi, b] == 0.0)                                                     # RHS ← demand

    cost = BLOCK_HOURS * (
        sum(therm_cost(i, t) * gth[i, b] for i in 1:length(therm), b in 1:NB)
      + VOLL * sum(shed))

    # Soft end-of-horizon target: penalise only the shortfall, so a dry final
    # week stays feasible instead of forcing load shedding to refill.
    if t == N_STAGES && END_PENALTY > 0
        @variable(sp, vdef[r in RZ] >= 0)                          # shortfall [MWh]
        @constraint(sp, [r in RZ],
            vres[r].out + vdef[r] >= END_FILL * reservoirs[r].v0)
        @stageobjective(sp, cost + END_PENALTY * sum(vdef[r] for r in RZ))
    else
        @stageobjective(sp, cost)
    end

    SDDP.parameterize(sp, 1:NSCEN) do w
        for zi in 1:length(ZONES), b in 1:NB
            set_normalized_rhs(bal[zi, b], DEM[t, w, zi, b])
            set_upper_bound(gres[zi, b], AVL[t, w, zi, b])
        end
        for (ri, r) in enumerate(RZ), b in 1:NB
            set_normalized_rhs(vdyn[r, b], INF[t, w, ri, b])
        end
        set_normalized_rhs(ptbudget, INFPT[t, w])
    end
end

# ── resim mode: reload cuts, dump zonal diagnostics ──────────
if "resim" in ARGS
    SDDP.read_cuts_from_file(model, joinpath(@__DIR__, "results", "midterm4_cuts$(SCEN_SUFFIX).json"))
    # thermal buckets by marginal cost (base ≤30 < mid ≤100 < peak)
    bucket_of(i) = therm[i].cost <= 30 ? 1 : therm[i].cost <= 100 ? 2 : 3
    gth_bucket(sp, zi, u, b) = sum((JuMP.value(sp[:gth][i, b]) for i in 1:length(therm)
                                    if zidx[therm[i].zone] == zi && bucket_of(i) == u); init = 0.0)
    rec = Dict{Symbol,Function}(
        :price => sp -> [JuMP.dual(sp[:bal][zi, b]) for zi in 1:4, b in 1:NB],
        :flow  => sp -> [JuMP.value(sp[:flow][l, b]) for l in 1:length(lines), b in 1:NB],
        :turb  => sp -> [JuMP.value(sp[:turb][r, b]) for r in RZ, b in 1:NB],
        :tpt   => sp -> [JuMP.value(sp[:turbpt][b]) for b in 1:NB],
        :res   => sp -> [JuMP.value(sp[:gres][zi, b]) for zi in 1:4, b in 1:NB],
        :gth   => sp -> [gth_bucket(sp, zi, u, b) for zi in 1:4, u in 1:3, b in 1:NB],
        :sts   => sp -> [sum((JuMP.value(sp[:sturb][j, b]) - JuMP.value(sp[:spump][j, b])
                              for j in 1:length(sts) if zidx[sts[j].zone] == zi); init = 0.0)
                         for zi in 1:4, b in 1:NB],
        :shed  => sp -> [sum(JuMP.value(sp[:shed][zi, b]) for zi in 1:4) for b in 1:NB],
        :dem   => sp -> [normalized_rhs(sp[:bal][zi, b]) for zi in 1:4, b in 1:NB])
    nrep = 20
    dsims = SDDP.simulate(model, nrep, Symbol[]; custom_recorders = rec)
    li  = Dict((l.from, l.to) => k for (k, l) in enumerate(lines))
    ri  = Dict(r => k for (k, r) in enumerate(RZ))
    diag = DataFrame()
    for (k, sim) in enumerate(dsims), (t, st) in enumerate(sim), b in 1:NB
        row = Dict{Symbol,Any}(:rep => k, :t => t, :b => b,
            :fEUFR => st[:flow][li[("EU", "FR")], b],
            :fPTES => st[:flow][li[("PT", "ES")], b],
            :fESFR => st[:flow][li[("ES", "FR")], b],
            :shed  => st[:shed][b])
        for z in ZONES
            zi = zidx[z]
            row[Symbol(:p, z)]    = st[:price][zi, b]
            row[Symbol(:d, z)]    = st[:dem][zi, b]
            row[Symbol(:res, z)]  = st[:res][zi, b]
            row[Symbol(:base, z)] = st[:gth][zi, 1, b]
            row[Symbol(:mid, z)]  = st[:gth][zi, 2, b]
            row[Symbol(:peak, z)] = st[:gth][zi, 3, b]
            row[Symbol(:sts, z)]  = st[:sts][zi, b]
            row[Symbol(:turb, z)] = z == "PT" ? st[:tpt][b] : st[:turb][ri[z], b]
        end
        push!(diag, row; cols = :union)
    end
    out_diag = joinpath(@__DIR__, "results", "midterm4_diag$(SCEN_SUFFIX).csv")
    CSV.write(out_diag, diag)
    println("Wrote $(nrow(diag)) diagnostic rows ($nrep replications) → $out_diag")
    exit(0)
end

# ── train ────────────────────────────────────────────────────
# `cont` arg: warm-start from the cuts of a previous (shorter) run, so long
# trainings can be split into stages that each stay under ~30 min.
if "cont" in ARGS && isfile(joinpath(@__DIR__, "results", "midterm4_cuts$(SCEN_SUFFIX).json"))
    SDDP.read_cuts_from_file(model, joinpath(@__DIR__, "results", "midterm4_cuts$(SCEN_SUFFIX).json"))
    println("Warm-started from results/midterm4_cuts$(SCEN_SUFFIX).json")
end
# `export` arg: reload the trained cuts and go straight to the simulate/export
# section, skipping training.  Used to regenerate the exported schedules (cuts,
# volumes, turbine, exchange) after a change to the exporters alone.
if "export" in ARGS
    SDDP.read_cuts_from_file(model, joinpath(@__DIR__, "results", "midterm4_cuts$(SCEN_SUFFIX).json"))
    println("Export-only: reloaded results/midterm4_cuts$(SCEN_SUFFIX).json, skipping training")
else
    SDDP.train(model; iteration_limit = ITERATIONS,
               log_file = joinpath(@__DIR__, "results", "midterm4_sddp$(SCEN_SUFFIX).log"))
    lb = SDDP.calculate_bound(model)
    @printf "Training done: %d iterations, lower bound %.4e EUR\n" ITERATIONS lb
end

# ── simulate (volume trajectories, also folds the EU slope) ──
w_sim = findfirst(==(SIM_YEAR), YEARS)
w_sim === nothing && error("sim_year $SIM_YEAR not among climate years $YEARS")
scheme = SDDP.Historical([(t, w_sim) for t in 1:N_STAGES])
recorders = Dict{Symbol,Function}(
    Symbol("v", lowercase(r)) => let rr = r
        sp -> JuMP.value.([sp[:vtraj][rr, b] for b in 0:NB])
    end for r in RZ)
# Turbine schedule per block [MW].  This is the mid-term model's own decision on
# how much water to release, and it is what the market chain's day-ahead uses as
# a daily energy budget: the Bellman cuts alone do not bind a single day (a day's
# draw is ~1 % of the reservoir, over which the cuts are essentially flat), so
# without it the DA runs reservoir hydro to its nameplate whenever the water
# value undercuts gas.
for r in RZ
    recorders[Symbol("turb", lowercase(r))] =
        let rr = r
            sp -> JuMP.value.([sp[:turb][rr, b] for b in 1:NB])
        end
end
# Cleared cross-zone exchange per block [MW], for the ES borders only.  Sign is
# flipped to the market chain's convention (import INTO Spain positive):
# flow[ES→FR] > 0 is a Spanish export, flow[PT→ES] > 0 is a Spanish import.
let l_esfr = findfirst(l -> l.from == "ES" && l.to == "FR", lines),
    l_ptes = findfirst(l -> l.from == "PT" && l.to == "ES", lines)
    l_esfr === nothing && error("no ES→FR line in Data/Transmission.csv")
    l_ptes === nothing && error("no PT→ES line in Data/Transmission.csv")
    recorders[:impfr] = sp -> [-JuMP.value(sp[:flow][l_esfr, b]) for b in 1:NB]
    recorders[:imppt] = sp -> [ JuMP.value(sp[:flow][l_ptes, b]) for b in 1:NB]
end
sims = SDDP.simulate(model, 1, Symbol[]; sampling_scheme = scheme,
                     custom_recorders = recorders)
veu_out = [sims[1][t][:veu][NB + 1] for t in 1:N_STAGES]

# ── export cuts in BellmanValuesOUT format ───────────────────
cuts_json = joinpath(@__DIR__, "results", "midterm4_cuts$(SCEN_SUFFIX).json")
SDDP.write_cuts_to_file(model, cuts_json)
nodes = JSON.parsefile(cuts_json)

key(r) = "vres[$r]"
raw = Dict{Int,Vector{Any}}(parse(Int, nd["node"]) => nd["single_cuts"] for nd in nodes)

b_abs(c) = c["intercept"]
b_rel(c) = c["intercept"] - sum(c["coefficients"][k] * c["state"][k]
                                for k in keys(c["coefficients"]))
maxcut(cuts, bfun, v) =
    maximum(bfun(c) + sum(c["coefficients"][key(r)] * v[r] for r in RZ) for c in cuts)

bfun = let v = Dict(r => reservoirs[r].v0 for r in RZ)
    V    = SDDP.ValueFunction(model; node = 1)
    vref = SDDP.evaluate(V, Dict(key(r) => v[r] for r in RZ))[1]
    da   = abs(vref - maxcut(raw[1], b_abs, v))
    dr   = abs(vref - maxcut(raw[1], b_rel, v))
    @printf "Cut intercept convention: |Δ| absolute %.3e, relative %.3e → using %s\n" da dr (da <= dr ? "absolute" : "relative")
    min(da, dr) > 1e-3 * max(abs(vref), 1.0) &&
        error("Neither cut-intercept convention matches SDDP.ValueFunction (ref $vref)")
    da <= dr ? b_abs : b_rel
end

out = DataFrame(Timestep = Int[], a_0 = Float64[], a_1 = Float64[], b = Float64[])
for (t, cuts) in raw
    t == N_STAGES && continue
    for c in cuts
        push!(out, (t - 1, c["coefficients"][key("FR")], c["coefficients"][key("ES")],
                    bfun(c) + c["coefficients"][key("EU")] * veu_out[t]))
    end
end
push!(out, (N_STAGES - 1, 0.0, 0.0, 0.0))
sort!(out, :Timestep)
CSV.write(CUTS_OUT, out)
println("Wrote $(nrow(out)) cuts → $CUTS_OUT")

# ── volume trajectory (hourly, linear interpolation in blocks) ──
nH = N_STAGES * 168
vol = DataFrame(Timestep = 0:nH,
                var"Hydro|Reservoir_FR_0" = zeros(nH + 1),
                var"Hydro|Reservoir_ES_0" = zeros(nH + 1),
                var"Hydro|Pumped Storage_ES_0" = zeros(nH + 1),
                var"Hydro|Pumped Storage_FR_0" = zeros(nH + 1),
                var"Battery|Lithium-Ion_FR_0"  = zeros(nH + 1),
                var"Battery|Lithium-Ion_PT_0"  = zeros(nH + 1))
for (t, stage) in enumerate(sims[1]), (col, k) in
        (("Hydro|Reservoir_FR_0", :vfr), ("Hydro|Reservoir_ES_0", :ves))
    v = stage[k]
    for b in 1:NB, j in 0:BLOCK_HOURS-1
        h = (t - 1) * 168 + (b - 1) * BLOCK_HOURS + j
        vol[h + 1, col] = v[b] + (v[b+1] - v[b]) * j / BLOCK_HOURS
    end
    t == N_STAGES && (vol[nH + 1, col] = v[NB + 1])
end
CSV.write(VOLUME_OUT, vol)
println("Wrote volume trajectory (climate year $SIM_YEAR) → $VOLUME_OUT")

# ── reservoir turbine schedule (hourly, MW) ──────────────────
# Piecewise-constant within a block (a release rate, not a stock, so it is held
# rather than interpolated).  The market chain integrates the 24 hours of a
# study day into that day's reservoir energy budget.
turb_cols = Dict("ES" => "Turbine_ES_MW", "FR" => "Turbine_FR_MW",
                 "EU" => "Turbine_EU_MW")
tsched = DataFrame(Timestep = 0:nH)
for r in RZ
    tsched[!, turb_cols[r]] = zeros(nH + 1)
end
for (t, stage) in enumerate(sims[1]), r in RZ
    p = stage[Symbol("turb", lowercase(r))]
    for b in 1:NB, j in 0:BLOCK_HOURS-1
        h = (t - 1) * 168 + (b - 1) * BLOCK_HOURS + j
        tsched[h + 1, turb_cols[r]] = p[b]
    end
    t == N_STAGES && (tsched[nH + 1, turb_cols[r]] = p[NB])
end
CSV.write(TURBINE_OUT, tsched)
@printf "Wrote turbine schedule → %s  (ES mean %.0f MW = %.1f GWh/day)\n" TURBINE_OUT mean(tsched.Turbine_ES_MW) (24 * mean(tsched.Turbine_ES_MW) / 1e3)

# ── cross-border exchange schedule (hourly, MW, import into ES positive) ─────
# Piecewise-constant within a block, like the turbine schedule.  Read by the
# market chain when [crossborder].source = "sddp".
xsched = DataFrame(Timestep = 0:nH, Import_FR_MW = zeros(nH + 1),
                   Import_PT_MW = zeros(nH + 1))
for (t, stage) in enumerate(sims[1]), (col, k) in
        (("Import_FR_MW", :impfr), ("Import_PT_MW", :imppt))
    p = stage[k]
    for b in 1:NB, j in 0:BLOCK_HOURS-1
        xsched[(t - 1) * 168 + (b - 1) * BLOCK_HOURS + j + 1, col] = p[b]
    end
    t == N_STAGES && (xsched[nH + 1, col] = p[NB])
end
CSV.write(EXCHANGE_OUT, xsched)
@printf "Wrote exchange schedule → %s  (mean FR %+.0f MW | PT %+.0f MW, + = import to ES)\n" EXCHANGE_OUT mean(xsched.Import_FR_MW) mean(xsched.Import_PT_MW)
println("\nTo use these cuts in the market chain, point [bellman] in config.toml at:")
println("  bellman_file = \"$(mcfg["cuts_out"])\"")
println("  volume_file  = \"$(mcfg["volume_out"])\"")
