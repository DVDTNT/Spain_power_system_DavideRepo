module CSP

using JuMP
using HiGHS
using CSV, DataFrames, Dates
using Statistics

export SolarBellmanCut, CSPMarketInputs, CSPMarketResult,
       CSPPlant, read_csp_plants, get_csp_plant, inputs_from_plant, with_grid_charging,
       load_solar_forecast, build_solar_bellman_cut,
       solve_csp_market_stage, adapt_csp_to_market_stage,
       solar_thermal_shape

# -----------------------------------------------------------------------------
# Standalone CSP + TES prototype for market-stage implementation
# -----------------------------------------------------------------------------
# This is intentionally self-contained and not yet connected to the rest of the
# repository. The aim is to provide a reusable structure that can later be used
# in DA, ID2, ID3, and BALANCING models.
#
# Modeling idea:
#   - solar field creates thermal energy,
#   - TES stores that thermal energy,
#   - the power block converts stored heat to electricity,
#   - electricity may be bought from the grid to increase TES if allowed,
#   - a Bellman-like cut prices the heat handed over to the next stage
#     (theta_future); the terminal TES level is floored, not pinned.
# -----------------------------------------------------------------------------

# -----------------------------
# Bellman-like cut for TES value
# -----------------------------
"""
    SolarBellmanCut(a1, b)

Affine approximation (a Bellman-style cut) of the future value of the thermal
energy left in TES at the end of the horizon, as a function of the final TES
level `q_end`:

    future_value <= b + a1 * q_end

`a1` is the slope [€/MWh_th] — the marginal continuation value of one more
MWh_th in store (non-negative: heat can always be burned in a later stage). `b`
is the intercept [€] (0 for the single cut built by `build_solar_bellman_cut`;
the field exists for a future multi-cut / piecewise value function, where
`theta_future` becomes the lower envelope of several cuts).

Sign convention: the cut enters the stage objective as `-theta_future` together
with the bound `theta_future <= b + a1 * q_end`. At the optimum the bound is
tight, `theta_future* = b + a1 * q_end`, so one extra MWh_th in store lowers
the stage cost by `a1` (dJ/dq_end = -a1): storing is rewarded iff `a1 > 0`.
A negative slope would make the model prefer an *empty* tank - which is why
`build_solar_bellman_cut` clamps the slope non-negative.
"""
struct SolarBellmanCut
    a1::Float64   # slope wrt final TES level [€/MWh_th]
    b::Float64    # intercept [€]
end

# Read the repository's solar forecast factors for a given date and market stage.
# These files are under Data/ES/Solar/*.csv and carry DA, ID2, ID3, CID, BE
# columns, exactly as used by the market-chain logic.
"""
    load_solar_forecast(date_str, stage; base_dir = joinpath(@__DIR__, "Data"))

Read the repository's per-unit solar forecast factors for `date_str` (e.g.
"2024-07-08") and market `stage` ("DA", "ID2", "ID3", "CID", "BE"). Returns a
24-element `Vector{Float64}`.

A missing file emits a **warning** and returns a zero profile — a stage run
should never silently pretend the sun was shining. An unknown stage column is
a hard error, since that is a code/data mismatch, not missing data.
"""
function load_solar_forecast(date_str::String, stage::String;
                            base_dir::String = joinpath(@__DIR__, "Data"))
    d = Date(date_str)
    fname = "$(day(d))_$(month(d))_$(year(d)).csv"
    path = joinpath(base_dir, "ES", "Solar", fname)
    if !isfile(path)
        @warn "Solar forecast file not found; returning a zero profile" path stage date_str
        return zeros(24)
    end
    df = CSV.read(path, DataFrame)
    stage_sym = Symbol(stage)
    if !hasproperty(df, stage_sym)
        error("Stage '$stage' not found in solar forecast file: $path")
    end
    return Float64.(df[!, stage_sym])
end

# -----------------------------------------------------------------------------
# Physical solar-thermal availability shape.
#
# The repository's Data/ES/Solar/<d_m_yyyy>.csv files are per-gate forecast-
# ACCURACY factors: the chain multiplies its real solar_mw profile by them
# (week_profiles.jl: solar_mw = es_solar[h] * factor[h]). The DA column is 1.0
# by construction (it is the reference vintage), and the other gates only
# deviate a few tens of percent around 1.0 — day and night alike. Treating
# those factors directly as per-unit thermal availability (as s_solar[t] <=
# solar_capacity * solar_forecast[t] does) therefore gives the field its full
# nameplate at midnight. The shape below supplies the missing physics: the
# sine of the solar elevation, exactly 0 whenever the sun is below the horizon.
# -----------------------------------------------------------------------------
"""
    solar_thermal_shape(date_str; lat = 40.0, lon = -3.7, tz = nothing) -> Vector{Float64}

Clear-sky solar-thermal collection shape for `date_str` (e.g. \"2024-07-08\"):
24 hourly values in [0, 1], each proportional to the sine of the solar
elevation at the hour's midpoint, and exactly 0 at night. This is the
geometric availability of a concentrating field on a clear day; multiply it by
the per-unit forecast factors (or a normalised real solar profile) to obtain a
physical hourly availability. `tz` overrides the hour offset of the profile
timestamps (default: Spain's DST rule, CEST +2 in summer, CET +1 in winter).
"""
function solar_thermal_shape(date_str::String; lat::Float64 = 40.0,
                             lon::Float64 = -3.7, tz::Union{Nothing,Float64} = nothing)
    d = Date(date_str)
    if tz === nothing
        y = year(d)
        # CEST (UTC+2) runs from the last Sunday of March to the last Sunday of October
        last_sunday = (m) -> begin
            e = Date(y, m, daysinmonth(Date(y, m, 1)))
            e - Day(dayofweek(e) - 1)
        end
        tz = (last_sunday(3) <= d < last_sunday(10)) ? 2.0 : 1.0
    end
    n  = dayofyear(d)
    δ  = deg2rad(-23.44 * cosd(360 / 365 * (n + 10)))   # solar declination
    φ  = deg2rad(lat)
    shape = zeros(24)
    for h in 0:23
        st = h + 0.5 - tz + lon / 15.0                  # solar time (UTC + lon/15)
        ha = deg2rad(15.0 * (st - 12.0))                # hour angle
        alt = sin(φ) * sin(δ) + cos(φ) * cos(δ) * cos(ha)  # sin of solar elevation
        shape[h + 1] = max(0.0, alt)
    end
    return shape
end

# Build a Bellman-like continuation-value cut for the terminal TES state q_end.
# The idea: heat kept for the next stage can be discharged and sold there, so it
# is worth about eta_power * expected future price per MWhth - unless the
# expected future solar profile is rich, in which case the marginal stored MWhth
# only displaces free solar collection and its value is crowded toward zero:
#   future_value <= b + a1 * q_end
"""
    build_solar_bellman_cut(future_solar_forecast; sell_price, eta_power) -> SolarBellmanCut

Derive one affine continuation-value cut for the terminal TES level `q_end`:

    theta_future <= b + a1 * q_end,   a1 = eta_power * sell_price * crowding,   b = 0

* `eta_power * sell_price` is what one MWhth yields if discharged in the next
  stage [€/MWhth]: heat becomes electricity at `eta_power`, sold at the expected
  *future* price `sell_price`.
* `crowding = max(0, 1 - mean(future_solar_forecast))`: with a rich (per-unit
  close to 1) future solar supply the marginal stored MWhth only displaces free
  solar collection, so its value is crowded toward zero; with a dark forecast it
  keeps the full conversion value. The clamp keeps the slope non-negative, so
  stored heat can never be modelled as a liability.
* `b = 0` for this single homogeneous cut; the intercept field exists for a
  future multi-cut / piecewise value function (then `theta_future` is the lower
  envelope of all cuts).

`solve_csp_market_stage` calls this with persistence defaults (today's
`solar_forecast`, `mean(sell_price)`) unless `future_solar_forecast` /
`future_sell_price` are provided. With the terminal floor
`q_tes[T] >= q_end_target`, this cut decides whether ending above the floor
pays: the plant stores while `a1` exceeds today's marginal sale revenue
`eta_power * sell_price[t]`.
"""
function build_solar_bellman_cut(future_solar_forecast::Vector{Float64};
                                sell_price::Float64,
                                eta_power::Float64)
    # future_value <= b + a1 * q_end with a1 >= 0: the marginal continuation
    # value of stored heat, crowded toward zero by rich future solar.
    crowding = max(0.0, 1.0 - mean(future_solar_forecast))
    a1 = max(0.0, eta_power * sell_price * crowding)
    return SolarBellmanCut(a1, 0.0)
end

# -----------------------------
# Market-stage CSP/TES inputs
# -----------------------------
"""
    CSPMarketInputs(; kwargs...)

All the data one market stage needs. The field defaults live here — the single
source of truth — and `adapt_csp_to_market_stage` only forwards its keywords
here, so defaults cannot drift between the two.

`q_end_target` is a FLOOR on the terminal TES level (`q_tes[T] >= q_end_target`):
the minimum heat [MWhth] this stage must hand over to the next. Ending with
more is allowed; whether it pays is decided by `theta_future`, the
continuation value built from `future_solar_forecast` / `future_sell_price`
(persistence defaults: today's `solar_forecast`, `mean(sell_price)`).

`demand` is accepted for symmetry with the future market-stage coupling but
does not enter any constraint yet (no energy balance is modelled so far).
`solar_forecast` must be a concrete vector; use `adapt_csp_to_market_stage`
to load it from `Data/ES/Solar/` automatically.
"""
# -----------------------------------------------------------------------------
# The CSP plant overlay file — the single source of plant truth
# -----------------------------------------------------------------------------
# Like every other plant type in this repository (generations.csv for the
# fleet, power_unit_tech_params.csv for ramp rates, marginal_costs.csv for
# thermal fuel costs), CSP units get their data from a type-specific overlay
# file: Data/csp_plants.csv — one row per plant, columns
#
#   plant_id, bus_id, solar_capacity_mwth, pmax_e_mwe, tes_capacity_mwhth,
#   q0_start_mwhth, q_end_target_mwhth, eta_solar, eta_power, eta_charge,
#   thermal_leak_rate, pmax_charge_e_mwe, buy_from_grid, allow_sell,
#   grid_price_floor_eur_mwh, vom_eur_mwh
#
# EVERY CSP computation reads its plant from this file: Option B, the
# thermal-value SDDP, the standalone demos, the weekly scenarios and (when
# built) Option A. There is deliberately NO built-in default plant: a missing
# file, key or row is a hard error, never a silent fallback to remembered
# numbers. Change the plant by editing the file; study a variant by adding a
# row and pointing plant_id at it.
# -----------------------------------------------------------------------------

"""
    CSPPlant(; plant_id, bus_id, solar_capacity_mwth, pmax_e_mwe, ...)

One row of the plants overlay file (`read_csp_plants`). Physical and policy
parameters of one CSP/TES unit. `bus_id` locates it on the network (used by
Option A; the standalone LP ignores it) and `vom_eur_mwh` is its variable
O&M (Option A's marginal-cost input). The struct has no defaults — the data
lives in the file, not in the code.
"""
Base.@kwdef struct CSPPlant
    plant_id::String
    bus_id::String                  # network bus (Option A); unused by the standalone LP
    solar_capacity_mwth::Float64    # MW_th  solar field (thermal nameplate)
    pmax_e_mwe::Float64            # MW_e   power block
    tes_capacity_mwhth::Float64     # MWh_th salt tank capacity
    q0_start_mwhth::Float64         # MWh_th tank level at the start of a stream
    q_end_target_mwhth::Float64     # MWh_th daily terminal floor handed to the next stage
    eta_solar::Float64             # solar field -> TES
    eta_power::Float64             # TES -> electricity
    eta_charge::Float64            # grid electricity -> TES heat
    thermal_leak_rate::Float64     # proportional standing loss [per hour]
    pmax_charge_e_mwe::Float64      # MW_e  electric-heater rating
    buy_from_grid::Bool
    allow_sell::Bool
    grid_price_floor_eur_mwh::Float64   # risk floor on planned grid purchases [EUR/MWh]
    vom_eur_mwh::Float64            # variable O&M [EUR/MWh_e] (Option A's cost input)
end

const _CSP_PLANT_COLUMNS = ("plant_id", "bus_id", "solar_capacity_mwth", "pmax_e_mwe",
    "tes_capacity_mwhth", "q0_start_mwhth", "q_end_target_mwhth", "eta_solar",
    "eta_power", "eta_charge", "thermal_leak_rate", "pmax_charge_e_mwe",
    "buy_from_grid", "allow_sell", "grid_price_floor_eur_mwh", "vom_eur_mwh")

# Coerce a CSV cell to Float64 / Bool with a precise, file-anchored error.
function _plant_num(x, path, i, col)
    v = tryparse(Float64, strip(string(x)))
    v === nothing && throw(ArgumentError(
        "plants file $path, row $i: column '$col' is not a number (got '$x')"))
    return v
end
function _plant_bool(x, path, i, col)
    x isa Bool && return x
    s = lowercase(strip(string(x)))
    s == "true" && return true
    s == "false" && return false
    throw(ArgumentError(
        "plants file $path, row $i: column '$col' must be true/false (got '$x')"))
end

"""
    read_csp_plants(path) -> Vector{CSPPlant}

Load and validate every plant row of the overlay file. A missing file,
missing column, duplicate plant_id or out-of-range value is a hard
ArgumentError — there is NO default plant data in the code to fall back to.
"""
function read_csp_plants(path::AbstractString)
    isfile(path) || throw(ArgumentError(
        "CSP plants file not found: $path\n" *
        "  Plant data has no built-in default. Point [csp].plants_file in " *
        "config.toml at a plants file (or pass --plants-file/--plant-id to the " *
        "demos). Expected columns:\n    " * join(_CSP_PLANT_COLUMNS, ", ")))
    df = CSV.read(path, DataFrame)
    for col in _CSP_PLANT_COLUMNS
        hasproperty(df, Symbol(col)) || throw(ArgumentError(
            "plants file $path lacks column '$col' (expected: " *
            join(_CSP_PLANT_COLUMNS, ", ") * ")"))
    end
    plants = CSPPlant[]
    seen = Set{String}()
    for (i, r) in enumerate(eachrow(df))
        pid = strip(string(r.plant_id))
        isempty(pid) && throw(ArgumentError("plants file $path, row $i: empty plant_id"))
        pid in seen && throw(ArgumentError(
            "plants file $path: duplicate plant_id '$pid'"))
        push!(seen, pid)
        p = CSPPlant(
            plant_id = pid,
            bus_id = strip(string(r.bus_id)),
            solar_capacity_mwth = _plant_num(r.solar_capacity_mwth, path, i, :solar_capacity_mwth),
            pmax_e_mwe = _plant_num(r.pmax_e_mwe, path, i, :pmax_e_mwe),
            tes_capacity_mwhth = _plant_num(r.tes_capacity_mwhth, path, i, :tes_capacity_mwhth),
            q0_start_mwhth = _plant_num(r.q0_start_mwhth, path, i, :q0_start_mwhth),
            q_end_target_mwhth = _plant_num(r.q_end_target_mwhth, path, i, :q_end_target_mwhth),
            eta_solar = _plant_num(r.eta_solar, path, i, :eta_solar),
            eta_power = _plant_num(r.eta_power, path, i, :eta_power),
            eta_charge = _plant_num(r.eta_charge, path, i, :eta_charge),
            thermal_leak_rate = _plant_num(r.thermal_leak_rate, path, i, :thermal_leak_rate),
            pmax_charge_e_mwe = _plant_num(r.pmax_charge_e_mwe, path, i, :pmax_charge_e_mwe),
            buy_from_grid = _plant_bool(r.buy_from_grid, path, i, :buy_from_grid),
            allow_sell = _plant_bool(r.allow_sell, path, i, :allow_sell),
            grid_price_floor_eur_mwh = _plant_num(r.grid_price_floor_eur_mwh, path, i, :grid_price_floor_eur_mwh),
            vom_eur_mwh = _plant_num(r.vom_eur_mwh, path, i, :vom_eur_mwh))
        (0.0 < p.eta_solar <= 1.0 && 0.0 < p.eta_power < 1.0 && 0.0 < p.eta_charge <= 1.0) ||
            throw(ArgumentError("plants file $path, plant '$pid': " *
                "eta_* must lie in (0, 1] (eta_power strictly below 1)"))
        (0.0 <= p.thermal_leak_rate < 1.0) ||
            throw(ArgumentError("plants file $path, plant '$pid': " *
                "thermal_leak_rate must lie in [0, 1)"))
        (0.0 < p.solar_capacity_mwth && 0.0 < p.pmax_e_mwe && p.pmax_charge_e_mwe >= 0.0) ||
            throw(ArgumentError("plants file $path, plant '$pid': " *
                "field/block capacities must be positive (heater rating >= 0)"))
        (0.0 <= p.q_end_target_mwhth <= p.tes_capacity_mwhth) ||
            throw(ArgumentError("plants file $path, plant '$pid': " *
                "q_end_target_mwhth must lie in [0, tes_capacity_mwhth]"))
        (0.0 <= p.q0_start_mwhth <= p.tes_capacity_mwhth) ||
            throw(ArgumentError("plants file $path, plant '$pid': " *
                "q0_start_mwhth must lie in [0, tes_capacity_mwhth]"))
        (p.grid_price_floor_eur_mwh >= 0.0 && p.vom_eur_mwh >= 0.0) ||
            throw(ArgumentError("plants file $path, plant '$pid': " *
                "grid_price_floor and vom must be >= 0"))
        push!(plants, p)
    end
    isempty(plants) && throw(ArgumentError("plants file $path contains no plant rows"))
    return plants
end

"""
    get_csp_plant(path, plant_id) -> CSPPlant

The row named `plant_id` of the plants file — an ArgumentError listing the
available ids if it is not there. No fallback, ever.
"""
function get_csp_plant(path::AbstractString, plant_id::AbstractString)
    plants = read_csp_plants(path)
    for p in plants
        p.plant_id == plant_id && return p
    end
    throw(ArgumentError("plant_id '$plant_id' not found in $path — available: " *
        join([p.plant_id for p in plants], ", ")))
end

"""
    with_grid_charging(u, flag) -> CSPPlant

A copy of plant row `u` with `buy_from_grid` set to `flag` — used by the
chain's embedded mode (Option A), which disables grid charging by default
(in the copper plate the heater would act as a free transmission-hiding
device; see the design doc A.9) without touching the plants file.
"""
function with_grid_charging(u::CSPPlant, flag::Bool)
    return CSPPlant(plant_id = u.plant_id, bus_id = u.bus_id,
        solar_capacity_mwth = u.solar_capacity_mwth, pmax_e_mwe = u.pmax_e_mwe,
        tes_capacity_mwhth = u.tes_capacity_mwhth, q0_start_mwhth = u.q0_start_mwhth,
        q_end_target_mwhth = u.q_end_target_mwhth, eta_solar = u.eta_solar,
        eta_power = u.eta_power, eta_charge = u.eta_charge,
        thermal_leak_rate = u.thermal_leak_rate, pmax_charge_e_mwe = u.pmax_charge_e_mwe,
        buy_from_grid = flag, allow_sell = u.allow_sell,
        grid_price_floor_eur_mwh = u.grid_price_floor_eur_mwh, vom_eur_mwh = u.vom_eur_mwh)
end

"""
    inputs_from_plant(plant; stage, date_str, demand, solar_forecast,
                      buy_price, sell_price, q0 = plant.q0_start_mwhth,
                      future_solar_forecast = nothing, future_sell_price = nothing)

Build `CSPMarketInputs` for one market stage from a `CSPPlant` row of the
plants file — the standard path from data file to LP: every plant parameter
comes from `plant` (the single source of truth), the hourly series are the
run's, and `q0` overrides the stream-start level (e.g. the day-to-day TES
hand-over in Option B).
"""
function inputs_from_plant(plant::CSPPlant;
        stage::String, date_str::String,
        demand::Vector{Float64}, solar_forecast::Vector{Float64},
        buy_price::Vector{Float64}, sell_price::Vector{Float64},
        q0::Float64 = plant.q0_start_mwhth,
        future_solar_forecast = nothing, future_sell_price = nothing)
    return CSPMarketInputs(stage = stage, date_str = date_str,
        demand = demand, solar_forecast = solar_forecast,
        buy_price = buy_price, sell_price = sell_price,
        future_solar_forecast = future_solar_forecast,
        future_sell_price = future_sell_price,
        solar_capacity = plant.solar_capacity_mwth,
        pmax_e = plant.pmax_e_mwe,
        tes_capacity = plant.tes_capacity_mwhth,
        q0 = q0,
        q_end_target = plant.q_end_target_mwhth,
        eta_solar = plant.eta_solar, eta_power = plant.eta_power,
        eta_charge = plant.eta_charge,
        thermal_leak_rate = plant.thermal_leak_rate,
        buy_from_grid = plant.buy_from_grid, allow_sell = plant.allow_sell,
        grid_price_floor = plant.grid_price_floor_eur_mwh,
        pmax_charge_e = plant.pmax_charge_e_mwe)
end

Base.@kwdef struct CSPMarketInputs
    stage::String
    date_str::String
    demand::Vector{Float64}
    solar_forecast::Vector{Float64}
    future_solar_forecast::Union{Nothing, Vector{Float64}} = nothing  # next stage's per-unit solar profile (nothing = persistence: today's)
    buy_price::Vector{Float64}     # electricity purchase price [€/MWh] — required, no default
    sell_price::Vector{Float64}    # electricity sale price [€/MWh] — required, no default
    future_sell_price::Union{Nothing, Float64} = nothing  # expected next-stage sale price [€/MWh] (nothing = mean(sell_price))
    # Plant parameters have NO defaults: they come from a CSPPlant row of the
    # plants file (read_csp_plants / get_csp_plant) via the `plant` keyword of
    # adapt_csp_to_market_stage or via inputs_from_plant. There is no
    # built-in default plant — every field below must be provided.
    solar_capacity::Float64        # installed solar field capacity [MWth]
    pmax_e::Float64                # max electric output [MWe]
    tes_capacity::Float64          # TES max thermal storage [MWhth]
    q0::Float64                    # initial TES [MWhth]
    q_end_target::Float64          # minimum terminal TES level handed to the next stage (floor) [MWhth]
    eta_solar::Float64             # solar field -> TES efficiency
    eta_power::Float64             # TES -> electric power block efficiency
    eta_charge::Float64            # grid electricity -> TES thermal efficiency
    thermal_leak_rate::Float64     # proportional TES standing loss [per hour]; the only standing-loss channel
    buy_from_grid::Bool
    allow_sell::Bool
    # Risk floor on PLANNED grid purchases [€/MWh]: a purchase the LP schedules
    # for a later hour cannot count on the cleared price still being (near) zero
    # then — real intraday prices hardly sit at zero. Effective buy price:
    #   price < 0          -> kept (the plant is PAID to consume: prefer grid)
    #   price >= floor     -> unchanged (genuine arbitrage still possible)
    #   0 <= price < floor -> lifted to the floor, so the free SUN is preferred
    #                         over "free" grid power and the tank is not filled
    #                         late on a possibly-transient zero-price hour.
    # 0.0 disables the floor (pure price-taker on the cleared prices).
    grid_price_floor::Float64
    # Electric-heater rating [MWe]: caps grid purchases per hour. Physically
    # the TES heater has a size; without this cap negative prices make the LP
    # unbounded (buy infinite power, dump the heat through the block).
    pmax_charge_e::Float64
end

"""
    CSPMarketResult(; kwargs...)

Outcome of one market-stage solve. If the LP does not terminate optimally,
`solved` is `false`, the dispatch vectors are empty and `objective` is `NaN` —
and `termination` carries the JuMP termination status (e.g. "OPTIMAL",
"INFEASIBLE") so callers can tell *why* instead of just receiving `nothing`.
On success `q_tes` has `T+1` entries (states 0:T).
"""
Base.@kwdef struct CSPMarketResult
    solved::Bool
    termination::String
    objective::Float64
    stage::String
    date_str::String
    p_gen::Vector{Float64}
    p_buy::Vector{Float64}
    s_solar::Vector{Float64}
    q_tes::Vector{Float64}         # TES state, length T+1 (0:T)
    q_discharge::Vector{Float64}
    q_charge_th::Vector{Float64}
    leak_th::Vector{Float64}
    theta_future::Float64
    shortage::Vector{Float64}
    curtail::Vector{Float64}
end

# Reject inconsistent inputs up front with a readable message — otherwise a
# length mismatch would fail deep inside JuMP with a confusing index error.
function _validate_inputs(inputs::CSPMarketInputs)
    T = length(inputs.demand)
    for (name, v) in (("solar_forecast", inputs.solar_forecast),
                      ("buy_price", inputs.buy_price),
                      ("sell_price", inputs.sell_price))
        if length(v) != T
            throw(ArgumentError("length($name) = $(length(v)) does not match length(demand) = $T"))
        end
    end
    if inputs.future_solar_forecast !== nothing && length(inputs.future_solar_forecast) != T
        throw(ArgumentError("length(future_solar_forecast) = $(length(inputs.future_solar_forecast)) does not match length(demand) = $T"))
    end
    for (name, v) in (("q0", inputs.q0), ("q_end_target", inputs.q_end_target))
        if !(0.0 <= v <= inputs.tes_capacity)
            throw(ArgumentError("$name = $v is outside [0, tes_capacity = $(inputs.tes_capacity)]"))
        end
    end
    return nothing
end

# -----------------------------
# Solve one market stage
# -----------------------------
"""
    solve_csp_market_stage(inputs::CSPMarketInputs) -> CSPMarketResult

Build and solve the per-stage LP. The objective [€] is

    sum_t buy_price[t] * p_buy[t]     cost of grid electricity bought to charge the TES
  - sum_t sell_price[t] * p_gen[t]     revenue from exporting power-block output
  + shortage/curtail penalties         placeholders for the market-chain coupling; inert while standalone (both variables are fixed to 0)
  - theta_future                      continuation value of the heat handed over

`theta_future` is a Bellman-style affine approximation of the value of ending
the stage with `q_tes[T]` MWhth in store (see `build_solar_bellman_cut`).
Because it enters with a minus sign, the solver pushes it to its cut bound,
`theta_future = a1 * q_tes[T]`, and the slope `a1` [€/MWhth] becomes the price
the plant is willing to forgo *today* for one more MWhth *tomorrow*: the
marginal heat is sold unless `eta_power * sell_price[t]` beats `a1`. The
terminal level is only floored (`q_tes[T] >= q_end_target`), so the plant
stores above the floor whenever that trade is favourable.

Physical model: the solar field collects heat (limited by the forecast times
`solar_capacity`), the TES stores it (standing loss modelled by the proportional leak
`thermal_leak_rate`, the single standing-loss channel), the power block converts heat to
electricity sold at `sell_price`, and electricity may be bought at `buy_price`
to charge the TES (`buy_from_grid`).

Throws `ArgumentError` if the hourly vectors disagree in length or the TES
levels fall outside `[0, tes_capacity]`.
"""
function solve_csp_market_stage(inputs::CSPMarketInputs)
    _validate_inputs(inputs)
    T = length(inputs.demand)
    # HiGHS deliberately: unlike the repository's Gurobi it needs no licence
    # file, which suits a standalone prototype. Swap for Gurobi.Optimizer if
    # this module is ever embedded in the market chain.
    model = Model(HiGHS.Optimizer)
    set_silent(model)

    # Electric market variables
    @variable(model, p_gen[1:T] >= 0)      # power-block output exported to market [MW]
    @variable(model, p_buy[1:T] >= 0)      # electricity bought for TES charging [MW]

    # Solar thermal field variables
    @variable(model, s_solar[1:T] >= 0)    # thermal energy captured by solar field [MWth]

    # Thermal storage variables
    @variable(model, q_discharge[1:T] >= 0)  # heat discharged to power block [MWth]
    @variable(model, q_charge_th[1:T] >= 0)  # heat added to TES from solar/grid [MWth]
    @variable(model, q_tes[0:T] >= 0)         # TES state at each hour [MWhth]
    @variable(model, leak_th[1:T] >= 0)       # thermal leak [MWth], linked to q_tes below

    # Bellman-like final value of remaining TES.
    @variable(model, theta_future >= 0)

    # Optional balance/risk variables (reserved for the market-chain coupling)
    @variable(model, shortage[1:T] >= 0)
    @variable(model, curtail[1:T] >= 0)

    # Proportional thermal leak: the leak grows with the amount of heat stored.
    # (Modelled as a constraint — fix() can only pin a variable to a number,
    # never to an expression.)
    for t in 1:T
        @constraint(model, leak_th[t] == inputs.thermal_leak_rate * q_tes[t-1])
    end

    # Solar profile is the repository forecast. It is the thermal input available
    # to the CSP plant at this market stage.
    for t in 1:T
        @constraint(model, s_solar[t] <= inputs.solar_capacity * inputs.solar_forecast[t])
    end

    # Power block capacity and conversion limits. The heat intake of the block
    # is capped by its electric rating (a full-power hour draws pmax_e/eta_power
    # of heat), so the plant cannot "dump" unlimited heat through the block.
    for t in 1:T
        @constraint(model, p_gen[t] <= inputs.pmax_e)
        @constraint(model, p_gen[t] <= inputs.eta_power * q_discharge[t])
        @constraint(model, q_discharge[t] <= inputs.pmax_e / inputs.eta_power)
    end

    # The electric heater that charges the TES from the grid has its own rating:
    # purchases are bounded per hour (without this, negative prices make the
    # price-taker LP unbounded - buy infinite, dump the heat).
    if inputs.buy_from_grid
        for t in 1:T
            @constraint(model, p_buy[t] <= inputs.pmax_charge_e)
        end
    end

    # Thermal storage dynamics.
    # q_tes[t] = previous TES + solar heat + electric-charging heat - discharge - leak
    # Standing loss enters exactly once, through the proportional leak `leak_th`
    # above (thermal_leak_rate); an extra multiplicative retention factor here
    # would double-count it.
    # The user asked for the option to buy electricity to increase TES. This is the
    # grid-to-heat charging path.
    for t in 1:T
        solar_heat_in = inputs.eta_solar * s_solar[t]
        grid_heat_in  = inputs.eta_charge * p_buy[t]
        @constraint(model, q_charge_th[t] == solar_heat_in + grid_heat_in)
        @constraint(model, q_tes[t] == q_tes[t-1] + q_charge_th[t] - q_discharge[t] - leak_th[t])
        @constraint(model, q_tes[t] <= inputs.tes_capacity)
    end

    # Initial TES level, and a FLOOR on the terminal level: the stage must hand
    # over at least q_end_target MWhth to the next stage. Ending with more is
    # allowed — whether it pays is decided by theta_future below.
    @constraint(model, q_tes[0] == inputs.q0)
    @constraint(model, q_tes[T] >= inputs.q_end_target)

    # The power block output is exported directly to the market. Electricity
    # bought from the grid is separate and is used only for TES charging.
    #
    # shortage / curtail are deliberate placeholders for the market-chain
    # coupling: once this stage is connected they will price unserved demand
    # and curtailed solar. Standalone, they are inert (fixed to 0).
    for t in 1:T
        fix(shortage[t], 0.0; force = true)
        fix(curtail[t], 0.0; force = true)
    end

    # If the model is not allowed to buy power, forbid charging from grid.
    if !inputs.buy_from_grid
        for t in 1:T
            fix(p_buy[t], 0.0; force = true)
        end
    end

    # If the model is not allowed to sell power, forbid exports.
    if !inputs.allow_sell
        for t in 1:T
            fix(p_gen[t], 0.0; force = true)
        end
    end

    # Continuation value of the heat handed over to the next stage:
    # theta_future <= b + a1 * q_tes[T] with a1 >= 0, so more stored heat RAISES
    # the bound (and with it the reward -theta_future in the objective). At the
    # optimum theta_future = a1 * q_tes[T]; the plant stores above the floor
    # whenever a1 beats today's marginal sale revenue eta_power * sell_price[t].
    # Persistence defaults: tomorrow looks like today.
    if inputs.future_solar_forecast === nothing
        fut_solar = inputs.solar_forecast
    else
        fut_solar = inputs.future_solar_forecast
    end
    if inputs.future_sell_price === nothing
        fut_price = mean(inputs.sell_price)
    else
        fut_price = inputs.future_sell_price
    end
    cut = build_solar_bellman_cut(fut_solar;
                                  sell_price = fut_price,
                                  eta_power = inputs.eta_power)
    @constraint(model, theta_future <= cut.b + cut.a1 * q_tes[T])

    # Grid purchases are priced with the risk floor above: free SUN beats
    # "free" grid power at ~zero prices (they are a perfect-foresight artifact),
    # while genuinely negative prices (paid to consume) still favour buying.
    buy_eff = [inputs.buy_price[t] < 0.0 ? inputs.buy_price[t] :
               max(inputs.buy_price[t], inputs.grid_price_floor) for t in 1:T]

    # Objective [€]: cost of grid electricity bought for TES charging
    #   - revenue from exported power-block output
    #   + (inert) shortage / curtailment penalties — deliberate placeholders for the market-chain coupling, fixed to 0 while standalone
    #   - theta_future, the continuation value of the terminal TES level: more
    #     valuable stored heat -> the plant keeps it instead of selling cheap.
    @objective(model, Min,
        sum(buy_eff[t] * p_buy[t] for t in 1:T)
        - sum(inputs.sell_price[t] * p_gen[t] for t in 1:T)
        + 500.0 * sum(shortage[t] for t in 1:T)
        + 0.01 * sum(curtail[t] for t in 1:T)
        - theta_future)

    optimize!(model)
    status = termination_status(model)
    if status != MOI.OPTIMAL && status != MOI.LOCALLY_SOLVED
        # Failure returns a typed result instead of `nothing`, so callers can
        # see *why* the stage did not solve (dispatch vectors stay empty).
        return CSPMarketResult(
            solved = false,
            termination = string(status),
            objective = NaN,
            stage = inputs.stage,
            date_str = inputs.date_str,
            p_gen = Float64[],
            p_buy = Float64[],
            s_solar = Float64[],
            q_tes = Float64[],
            q_discharge = Float64[],
            q_charge_th = Float64[],
            leak_th = Float64[],
            theta_future = NaN,
            shortage = Float64[],
            curtail = Float64[],
        )
    end

    return CSPMarketResult(
        solved = true,
        termination = string(status),
        objective = objective_value(model),
        stage = inputs.stage,
        date_str = inputs.date_str,
        p_gen = value.(p_gen) .+ 0.0,  # .+ 0.0 normalizes IEEE-754 negative zeros (HiGHS)
        p_buy = value.(p_buy),
        s_solar = value.(s_solar),
        q_tes = value.(q_tes),
        q_discharge = value.(q_discharge),
        q_charge_th = value.(q_charge_th),
        leak_th = value.(leak_th),
        theta_future = value(theta_future) + 0.0,  # + 0.0 normalizes IEEE-754 negative zero
        shortage = value.(shortage),
        curtail = value.(curtail),
    )
end

# -----------------------------
# A helper for all market stages
# -----------------------------
"""
    adapt_csp_to_market_stage(stage, date_str; plant = <CSPPlant>, kwargs...) -> CSPMarketResult

Convenience entry point for one market stage (`stage` is one of "DA", "ID2",
"ID3", "CID", "BE"; `date_str` e.g. "2024-07-08").

The plant's physical/policy parameters have NO defaults. Pass `plant` — a
`CSPPlant` loaded from the plants file (`get_csp_plant` / `read_csp_plants`)
— and every parameter is taken from that row (the single source of truth).
An explicitly passed keyword still wins, which tests and one-field
experiments use. Without `plant`, every plant keyword must be given
explicitly. Unknown keywords are an error rather than a silent no-op.
`demand`, `buy_price`, `sell_price` are required; `solar_forecast` omitted
(or `nothing`) loads from `Data/ES/Solar/` for the date and stage. Pass
`future_solar_forecast` / `future_sell_price` to give the continuation value
`theta_future` explicit next-stage expectations (default: persistence —
today's profile and the mean sale price).
"""
function adapt_csp_to_market_stage(stage::String, date_str::String; kwargs...)
    kw = Dict{Symbol, Any}(kwargs)
    kw[:stage] = stage
    kw[:date_str] = date_str
    if haskey(kw, :plant)
        plant = pop!(kw, :plant)::CSPPlant
        # Fill every plant parameter from the row unless the caller set it.
        for (src, dst) in (:solar_capacity_mwth      => :solar_capacity,
                           :pmax_e_mwe              => :pmax_e,
                           :tes_capacity_mwhth      => :tes_capacity,
                           :q_end_target_mwhth      => :q_end_target,
                           :pmax_charge_e_mwe       => :pmax_charge_e,
                           :grid_price_floor_eur_mwh => :grid_price_floor)
            haskey(kw, dst) || (kw[dst] = getproperty(plant, src))
        end
        for f in (:eta_solar, :eta_power, :eta_charge, :thermal_leak_rate,
                  :buy_from_grid, :allow_sell)
            haskey(kw, f) || (kw[f] = getproperty(plant, f))
        end
        haskey(kw, :q0) || (kw[:q0] = plant.q0_start_mwhth)
    end
    if !haskey(kw, :demand)
        throw(ArgumentError("demand (hourly demand series [MW]) is required"))
    end
    if get(kw, :solar_forecast, nothing) === nothing
        kw[:solar_forecast] = load_solar_forecast(date_str, stage)
    end
    return solve_csp_market_stage(CSPMarketInputs(; pairs(kw)...))
end

# -----------------------------
# Example usage (standalone)
# -----------------------------
function _print_result(result::CSPMarketResult)
    if !result.solved
        println("No feasible solution found (termination: ", result.termination, ").")
        return nothing
    end
    println("Stage: ", result.stage)
    println("Final TES = ", result.q_tes[end])
    println("Theta future = ", round(result.theta_future, digits = 4))
    println("Grid power for TES charging = ", round.(result.p_buy, digits = 2))
    println("Exported power = ", round.(result.p_gen, digits = 2))
    return nothing
end

"""
Run the standalone examples for 2024-07-08 with an explicitly given plant (a
`CSPPlant` row of the plants file — there is no default plant):

    julia --project=. CSP.jl --plants-file Data/csp_plants.csv --plant-id demo

Scenario 1 — "sell through a sunny day": the DA forecast is rich, so the
crowding factor crowds the continuation value of stored heat to zero
(`theta_future` = 0) and the plant sells everything it can down to the
terminal floor of the plant's row.

Scenario 2 — "store for a dark, valuable tomorrow": today's sale price is
low, the expected future price is 70 €/MWh and tomorrow's profile is dark,
so each stored MWhth (worth `eta_power * 70` = 26.6 € for the demo row)
beats selling it today (0.38 * 10 = 3.8 €): the TES fills from its floor up
to its capacity before the surplus heat is exported.
"""
function example_run(plant::CSPPlant)
    T = 24
    d = 20.0 .* ones(T)
    forecast = load_solar_forecast("2024-07-08", "DA")
    if all(forecast .== 0.0)
        # fallback synthetic profile if files are absent in a local test environment
        forecast = collect(range(0.0, stop = 1.0, length = T))
    end

    println("Plant   : ", plant.plant_id, " (bus ", plant.bus_id, ") — ",
        plant.solar_capacity_mwth, " MW_th field, ", plant.pmax_e_mwe,
        " MW_e block, ", plant.tes_capacity_mwhth, " MWh_th tank")
    println("=== Scenario 1: sunny today - crowded-out storage value, sell down to the floor ===")
    result = adapt_csp_to_market_stage("DA", "2024-07-08";
        plant = plant,
        demand = d,
        solar_forecast = forecast,
        buy_price = 60.0 .* ones(T),
        sell_price = 70.0 .* ones(T))
    _print_result(result)

    println()
    println("=== Scenario 2: dark and valuable tomorrow - storing beats selling today ===")
    stored = adapt_csp_to_market_stage("DA", "2024-07-08";
        plant = plant,
        demand = d,
        solar_forecast = forecast,
        buy_price = 100.0 .* ones(T),
        sell_price = 10.0 .* ones(T),
        future_solar_forecast = zeros(T),
        future_sell_price = 70.0)
    _print_result(stored)
end

"""Parse the demo's --plants-file/--plant-id. No arguments is an error —
there is no built-in default plant."""
function _demo_plant_args(args::Vector{String})
    file = nothing
    pid = nothing
    i = 1
    while i <= length(args)
        if args[i] == "--plants-file" && i < length(args)
            file = args[i + 1]; i += 2
        elseif args[i] == "--plant-id" && i < length(args)
            pid = args[i + 1]; i += 2
        else
            error("unknown or incomplete option '$(args[i])' — expected " *
                  "--plants-file <path> and --plant-id <id>")
        end
    end
    (file === nothing || pid === nothing) && error(
        "the standalone demo needs the plant explicitly — there is no default plant.\n" *
        "  julia --project=. CSP.jl --plants-file Data/csp_plants.csv --plant-id demo")
    return get_csp_plant(String(file), String(pid))
end

# Executing the file directly runs the standalone example:
#     julia --project=. CSP.jl --plants-file Data/csp_plants.csv --plant-id demo
# Including it elsewhere (e.g. run_market_chain.jl behind [csp].enabled) only
# defines this module; call CSP.example_run(plant) explicitly if you want the demo.
if !isempty(PROGRAM_FILE) && abspath(PROGRAM_FILE) == @__FILE__
    example_run(_demo_plant_args(ARGS))
end

end # module
