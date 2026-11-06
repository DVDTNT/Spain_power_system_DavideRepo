# ============================================================
# Spain Power System — observed fuel and carbon prices
# ============================================================
# Short-run marginal cost of the gas fleet from the ACTUAL daily market prices,
# shared by the market chain (per study day) and the mid-term SDDP (per weekly
# stage), so both sides of the seam price gas from one series.
#
#   SRMC [EUR/MWh_el] = P_gas / eta  +  3.6 * content * P_CO2  +  VOM
#
# Inputs
#   Data/MIBGAS_Data_2024.csv       Trading day, Product (GDAES_D+1), EUR/MWh_th
#                                   Covers 2024-01-01 .. 2025-12-31.
#   Data/Carbon Emissions Price.csv Date, Price, ...  EUA EUR/tCO2, TRADING DAYS
#                                   ONLY (no weekends/holidays) — held forward.
#
# Parameters ([costs.gas_srmc] in config.toml) default to the EMPIRE input
# tables, which is where they came from:
#   eta          Generator_Efficiency.tab, period 1   CCGT 0.5600  OCGT 0.4250
#   co2_content  Generator_CO2Content.tab             CCGT 0.09735 OCGT 0.12805
#   vom          Generator_VariableOMCosts.tab        CCGT 4.68    OCGT 5.76
#
# CAUTION on `co2_content`: the EMPIRE column is tCO2 per GJ of ELECTRICITY —
# the efficiency is already divided in.  Multiplying it back by eta returns the
# textbook fuel emission factor for every fuel in the table (gas 0.0545, coal
# 0.0913, lignite 0.1077, oil 0.0740 tCO2/GJ_fuel), which is how we know.  The
# adder is therefore 3.6*content*price and must NOT be divided by eta again.
# (empire_scenario.jl and build_smspp_2035.py use the same 3.6*content*price
# convention, so the 2024 path, the scenario path and the SMS++ export all price
# carbon alike.  Both once divided by eta as well, which double-counted the
# efficiency and inflated coal ~1.3x more than gas; the bug was invisible while
# EMPIRE's General_CO2Price.tab was all zeros — those runs used an emission cap
# instead of a price.)
#
# Delivery-day convention: the MIBGAS product is GDAES_D+1, quoted on trading
# day D for delivery on D+1.  A generator burning gas on delivery day D bought
# it at the price quoted on D-1, and the electricity day-ahead for D clears on
# D-1 too, so both legs use the same information set.
# ============================================================

using CSV, DataFrames, Dates, Statistics

struct FuelPrices
    gas     :: Dict{Date,Float64}      # DELIVERY date  ⇒ EUR/MWh_th
    co2     :: Dict{Date,Float64}      # trading date   ⇒ EUR/tCO2
    co2_days:: Vector{Date}            # sorted, for the hold-forward lookup
    eta     :: Dict{Symbol,Float64}
    content :: Dict{Symbol,Float64}    # tCO2 / GJ_el  (efficiency already in)
    vom     :: Dict{Symbol,Float64}
end

_num(x) = x isa AbstractString ? parse(Float64, replace(strip(x), "," => "")) : Float64(x)

# MIBGAS: "Trading day" is D, the product delivers on D+1 → key by D+1.
function _read_mibgas(path::String)::Dict{Date,Float64}
    df  = CSV.read(path, DataFrame)
    out = Dict{Date,Float64}()
    pricecol = findfirst(n -> occursin("Price", String(n)), names(df))
    pricecol === nothing && error("$path: no price column")
    for r in eachrow(df)
        d = Date(strip(String(r[1])), dateformat"d/m/y")
        v = r[pricecol]
        (v === missing || (v isa AbstractString && isempty(strip(v)))) && continue
        out[d + Day(1)] = _num(v)
    end
    isempty(out) && error("$path: no usable rows")
    return out
end

function _read_carbon(path::String)::Dict{Date,Float64}
    df  = CSV.read(path, DataFrame)
    out = Dict{Date,Float64}()
    for r in eachrow(df)
        d = Date(strip(String(r[1])), dateformat"m/d/y")
        v = r.Price
        (v === missing || (v isa AbstractString && isempty(strip(v)))) && continue
        out[d] = _num(v)
    end
    isempty(out) && error("$path: no usable rows")
    return out
end

function load_fuel_prices(cfg; root = @__DIR__)::FuelPrices
    c   = get(get(cfg, "costs", Dict()), "gas_srmc", Dict())
    gasf = String(get(c, "mibgas_file", "Data/MIBGAS_Data_2024.csv"))
    co2f = String(get(c, "carbon_file", "Data/Carbon Emissions Price.csv"))
    sub(key, d) = Dict(Symbol(lowercase(String(k))) => Float64(v)
                       for (k, v) in get(c, key, d))
    gas = _read_mibgas(joinpath(root, gasf))
    co2 = _read_carbon(joinpath(root, co2f))
    FuelPrices(gas, co2, sort(collect(keys(co2))),
               sub("eta",         Dict("ccgt" => 0.5600, "ocgt" => 0.4250)),
               sub("co2_content", Dict("ccgt" => 0.09735482, "ocgt" => 0.12805375)),
               sub("vom",         Dict("ccgt" => 4.68, "ocgt" => 5.76)))
end

# Nearest quote at or before `d` (gas is daily and complete; the EUA series
# trades on business days only, so weekends hold Friday's settlement).
function _hold_forward(dict::Dict{Date,Float64}, d::Date; window::Int = 14)
    for k in 0:window
        haskey(dict, d - Day(k)) && return dict[d - Day(k)]
    end
    return nothing
end

gas_price(fp::FuelPrices, d::Date)    = _hold_forward(fp.gas, d)
carbon_price(fp::FuelPrices, d::Date) = _hold_forward(fp.co2, d)

"""
    gas_srmc(fp, tech, delivery_date) -> EUR/MWh_el

`tech` is `:ccgt` or `:ocgt`.  Both legs are taken on the information set of the
day-ahead clearing: the gas quote that delivers on `delivery_date`, and the last
EUA settlement on or before `delivery_date - 1`.
"""
function gas_srmc(fp::FuelPrices, tech::Symbol, d::Date)::Float64
    pg = gas_price(fp, d)
    pg === nothing && error("no MIBGAS quote for delivery $d")
    pc = carbon_price(fp, d - Day(1))
    pc === nothing && error("no EUA settlement on or before $(d - Day(1))")
    return pg / fp.eta[tech] + 3.6 * fp.content[tech] * pc + fp.vom[tech]
end

"""
    gas_srmc_mean(fp, tech, d0, d1) -> EUR/MWh_el

Mean daily SRMC over `d0:d1` inclusive — the weekly-stage figure for the
mid-term model, whose stages are 168 h long.
"""
function gas_srmc_mean(fp::FuelPrices, tech::Symbol, d0::Date, d1::Date)::Float64
    v = [gas_srmc(fp, tech, d) for d in d0:Day(1):d1]
    isempty(v) && error("empty date range $d0..$d1")
    return mean(v)
end

"""
    gas_srmc_stages(fp, tech, bgn_date, n_stages; stage_days = 7)

Per-stage mean SRMC for a weekly policy graph starting at `bgn_date`.
Returns a `Vector{Float64}` of length `n_stages`.
"""
function gas_srmc_stages(fp::FuelPrices, tech::Symbol, bgn::Date, n::Int;
                         stage_days::Int = 7)::Vector{Float64}
    [gas_srmc_mean(fp, tech, bgn + Day((t - 1) * stage_days),
                   bgn + Day(t * stage_days - 1)) for t in 1:n]
end
