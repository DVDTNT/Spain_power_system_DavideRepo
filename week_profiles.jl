# ============================================================
# Spain Power System — sampled-week gate profiles ([weeks])
# ============================================================
# Builds the per-stage hourly ES profile tables (date, hour, load_mw,
# solar_mw, wind_mw — the exact shape run_market_chain.jl's 2024 path assembles from
# Data/ES_old × Data/ES) for the sampled-week horizon of week_sampling.jl,
# with the weather realisation taken from the EMPIRE ScenarioData series:
#
#   solar/wind : NUTS3 capacity-factor columns × the EMPIRE NUTS3 installed
#                capacities (EMP.caps_nuts), summed to the national MW the
#                downstream disaggregation expects.  Regions without a CF
#                column keep the covered regions' weighted CF (the total is
#                rescaled to the full installed capacity).
#   load       : sum of the NUTS3 load-shape columns, rescaled per climate
#                year so the year's energy equals the EMPIRE annual demand
#                (EMP.demand["ES"], MWh).
#
# Gate (forecast-vintage) factors: the ScenarioData week is the DA baseline
# (DA factor ≡ 1.0, as in the 2024 path); the ID2/ID3/CID/BE columns come
# from Data/ES/<resource>/<d_m_yyyy>.csv for the study date.  Data/ES covers
# 363 of the 366 days of 2024, and the study calendar runs on 2024 dates
# ([bellman].bgn_date), so every study day gets its own dated deviation
# vintages; only the missing days (Jan 1, Dec 30, Dec 31) fall back to the
# season-matched 2024 study day (Apr–Sep → 8_7_2024, Oct–Mar → 2_12_2024).
# The factors are 2024 forecast-error vintages applied to the scenario
# portfolio, i.e. forecast quality per MW is assumed to stay at 2024 levels.
#
# foreign_week_series assembles the FR/PT/EU hourly series (load MW rescaled
# to EMPIRE annual demand; solar/wind/offshore/ROR as capacity factors) for
# the same horizon — the input the 4-zone DA clearing consumes.
# ============================================================

using CSV, DataFrames, Dates

const ES_VINTAGE_DIR = joinpath(@__DIR__, "Data", "ES")
const GATE_STAGES    = ["DA", "ID2", "ID3", "CID", "BE"]

# Data/ES file naming, e.g. 2024-07-08 → "8_7_2024.csv" (no zero padding).
_vintage_filename(d::Date) = "$(day(d))_$(month(d))_$(year(d)).csv"

# 24×stages factor table for one resource and study date.  The Data/ES files
# are dated 2024, but the study calendar spans bgn_date + 52 weeks, so slots
# after New Year carry 2025 dates — those map to the same day/month of 2024
# (the deviation vintages are calendar-seasonal, not year-specific).  Only
# day/months with no 2024 file at all (Jan 1, Dec 30, Dec 31) fall back to
# the season-matched study day.
function _vintage_factors(resource::String, d::Date)::DataFrame
    dir = joinpath(ES_VINTAGE_DIR, resource)
    f   = joinpath(dir, _vintage_filename(d))
    isfile(f) || (f = joinpath(dir, _vintage_filename(Date(2024, month(d), day(d)))))
    isfile(f) || (f = joinpath(dir, month(d) in 4:9 ? "8_7_2024.csv" :
                                                      "2_12_2024.csv"))
    df = CSV.read(f, DataFrame)
    nrow(df) == 24 || error("$(basename(f)) ($resource): expected 24 rows")
    return df
end

# National ES MW series: NUTS3 CF columns weighted by the region's installed
# MW, rescaled so regions missing a CF column carry the covered-region CF.
function _es_cf_to_mw(df::DataFrame, caps::Dict{String,Float64},
                      what::String)::Vector{Float64}
    cols    = sort(intersect(names(df), collect(keys(caps))))
    covered = sum(caps[c] for c in cols; init = 0.0)
    total   = sum(values(caps))
    isempty(cols) && error("no ScenarioData column matches any $what NUTS3 region")
    covered / total < 0.95 &&
        @warn "$what: CF columns cover only $(round(100covered/total; digits=1)) % of installed MW"
    mw = zeros(nrow(df))
    for c in cols
        mw .+= caps[c] .* Float64.(df[!, c])
    end
    return mw .* (total / covered)
end

# Zone load series rescaled per climate year to the EMPIRE annual demand
# [MWh]: hours of climate year y are scaled by demand / Σ_y shape.
function _load_to_annual(shape::Vector{Float64}, times::Vector{DateTime},
                         annual_mwh::Float64)::Vector{Float64}
    yr    = year.(times)
    scale = Dict(y => annual_mwh / sum(shape[yr .== y]) for y in unique(yr))
    return [shape[t] * scale[yr[t]] for t in eachindex(shape)]
end

_read_scen(cfg, file) = CSV.read(joinpath(_scenario_data_dir(cfg), file), DataFrame)

# Per-stage hourly ES tables for the sampled horizon:
#   Dict("DA"|"ID2"|"ID3"|"CID"|"BE" => DataFrame(date, hour, load_mw,
#                                                 solar_mw, wind_mw))
# Drop-in replacements for run_market_chain.jl's hourly_da … hourly_bal.
function week_stage_tables(cfg, emp, key::DataFrame)::Dict{String,DataFrame}
    times = scenario_time_axis(cfg)
    dfs   = _read_scen(cfg, "solar.csv")
    dfw   = _read_scen(cfg, "windonshore.csv")
    dfl   = _read_scen(cfg, "electricload.csv")
    for (f, df) in (("solar", dfs), ("windonshore", dfw), ("electricload", dfl))
        nrow(df) == length(times) ||
            error("$f.csv rows ($(nrow(df))) do not match the time axis ($(length(times)))")
    end

    es_solar = _es_cf_to_mw(dfs, emp.caps_nuts["Solar"],        "Solar")
    es_wind  = _es_cf_to_mw(dfw, emp.caps_nuts["Wind onshore"], "Wind onshore")
    es_cols  = [c for c in names(dfl) if startswith(c, "ES")]
    es_shape = vec(sum(Matrix{Float64}(dfl[!, es_cols]); dims = 2))
    es_load  = _load_to_annual(es_shape, times, emp.demand["ES"])

    rows_acc = Dict(s => NamedTuple[] for s in GATE_STAGES)
    for r in eachrow(key), d in 0:6
        date     = r.study_start + Day(d)
        date_str = Dates.format(date, "yyyy-mm-dd")
        rows     = (r.row_start + 24d):(r.row_start + 24d + 23)
        fl = _vintage_factors("load",         date)
        fs = _vintage_factors("Solar",        date)
        fw = _vintage_factors("Wind Onshore", date)
        for s in GATE_STAGES, h in 0:23
            push!(rows_acc[s],
                  (date     = date_str, hour = h,
                   load_mw  = es_load[rows[h+1]]  * Float64(fl[h+1, s]),
                   solar_mw = es_solar[rows[h+1]] * Float64(fs[h+1, s]),
                   wind_mw  = es_wind[rows[h+1]]  * Float64(fw[h+1, s])))
        end
    end
    return Dict(s => sort!(DataFrame(v), [:date, :hour]) for (s, v) in rows_acc)
end

# FR/PT/EU hourly series over the sampled horizon (4-zone DA input):
#   Dict(zone => DataFrame(date, hour, load_mw, solar_cf, windon_cf,
#                          windoff_cf, ror_cf, inflow_mw))
# Loads are MW at EMPIRE annual demand; the CF columns are 0–1 availability
# to be multiplied by the zone's installed capacity by the DA assembly.
# inflow_mw is the seasonal-reservoir inflow power (hydroseasonal.csv, MW) —
# the PT reservoir's daily energy budget in the 4-zone DA.
function foreign_week_series(cfg, emp, key::DataFrame)::Dict{String,DataFrame}
    times = scenario_time_axis(cfg)
    dfl   = _read_scen(cfg, "electricload.csv")
    dfi   = _read_scen(cfg, "hydroseasonal.csv")
    cf    = Dict("solar_cf"   => _read_scen(cfg, "solar.csv"),
                 "windon_cf"  => _read_scen(cfg, "windonshore.csv"),
                 "windoff_cf" => _read_scen(cfg, "windoffshore.csv"),
                 "ror_cf"     => _read_scen(cfg, "hydroror.csv"))
    out = Dict{String,DataFrame}()
    for z in ("FR", "PT", "EU")
        load = _load_to_annual(Float64.(dfl[!, z]), times, emp.demand[z])
        cols = Dict(k => z in names(df) ? Float64.(df[!, z]) :
                         zeros(length(times)) for (k, df) in cf)
        infl = z in names(dfi) ? Float64.(dfi[!, z]) : zeros(length(times))
        acc = NamedTuple[]
        for r in eachrow(key), d in 0:6
            date_str = Dates.format(r.study_start + Day(d), "yyyy-mm-dd")
            rows     = (r.row_start + 24d):(r.row_start + 24d + 23)
            for h in 0:23
                push!(acc, (date = date_str, hour = h,
                            load_mw    = load[rows[h+1]],
                            solar_cf   = cols["solar_cf"][rows[h+1]],
                            windon_cf  = cols["windon_cf"][rows[h+1]],
                            windoff_cf = cols["windoff_cf"][rows[h+1]],
                            ror_cf     = cols["ror_cf"][rows[h+1]],
                            inflow_mw  = infl[rows[h+1]]))
            end
        end
        out[z] = sort!(DataFrame(acc), [:date, :hour])
    end
    return out
end
