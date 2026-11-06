# ============================================================
# Spain Power System — sampled-week study horizon ([weeks])
# ============================================================
# Turns the market chain's study horizon from the two fixed 2024 TARGET_DAYS
# into n_weeks SDDP-stage-aligned weeks whose weather realisation (load, RES
# availability, ROR, inflow) is drawn from the EMPIRE ScenarioData climate
# years (hourly 2015–2019, NUTS3 columns for ES + FR/PT/EU zonal).
#
# A sampled week pairs
#   • a STUDY week: [bgn + 7(k-1), bgn + 7k) days on the SDDP calendar
#     (bgn = [bellman].bgn_date), so the existing day→stage, cut and volume
#     lookups (bellman_stage / load_cuts_at_stage / v_*_at_date) apply as-is;
#   • a DATA anchor: the ScenarioData row holding the same month/day at 00:00
#     in a random climate year.  A contiguous horizon takes 168·n_weeks
#     consecutive rows from that anchor, so weather autocorrelation across
#     week boundaries is the historical one, and a block naturally rolls over
#     New Year into the next climate year's rows.
#
# The first run draws at random and persists the sample to [weeks].key_file;
# later runs reuse the key verbatim, so all four EMPIRE scenarios are solved
# on the same weeks.  [weeks].resample = true redraws and overwrites the key.
#
# Key file columns (one row per week):
#   slot         1..n_weeks (order within the horizon)
#   week_slot    k on the SDDP calendar (stage of the week's last day == k)
#   climate_year year of the data anchor
#   study_start  first study day (Date, bgn + 7(k-1))
#   data_start   ScenarioData timestamp of the anchor row (DateTime)
#   row_start    1-based row index of the anchor in every ScenarioData file
#
# Usage (from run_market_chain.jl, cfg = TOML.parsefile("config.toml")):
#   key  = load_or_sample_weeks(cfg)          # DataFrame as above
#   days = week_study_days(key)               # all study days, chain order
#   rows = week_data_rows(key_row)            # 168-row range into ScenarioData
# ============================================================

using CSV, DataFrames, Dates, Random

const WEEK_HOURS = 168

# ScenarioData timestamp format ("01/01/2015 00:00").
const SCEN_TIME_FMT = dateformat"dd/mm/yyyy HH:MM"

_scenario_data_dir(cfg) = joinpath(@__DIR__, cfg["scenario"]["empire_dir"],
                                   "Input", "Xlsx", "ScenarioData")

# Hourly time axis shared by the ScenarioData series.  solar.csv carries an
# explicit `time` column; the other files are row-aligned to it (electricload
# has no time column at all), so this axis indexes every file.
function scenario_time_axis(cfg)::Vector{DateTime}
    f  = joinpath(_scenario_data_dir(cfg), "solar.csv")
    df = CSV.read(f, DataFrame; select = ["time"], types = String)
    return [DateTime(strip(t), SCEN_TIME_FMT) for t in df.time]
end

# Row index of `anchor` on the axis, or nothing if absent / block runs off the
# end.  The axis is hourly-continuous, so the index is pure arithmetic.
function _anchor_row(times::Vector{DateTime}, anchor::DateTime, n_hours::Int)
    idx = Dates.value(convert(Dates.Hour, anchor - times[1])) + 1
    (1 <= idx && idx + n_hours - 1 <= length(times)) || return nothing
    times[idx] == anchor || return nothing        # misalignment guard
    return idx
end

# Draw the week sample.  Contiguous (default): one random climate year and one
# random start slot, n consecutive study weeks fed by 168·n consecutive data
# rows.  Non-contiguous: n independent (year, slot) draws with distinct slots,
# each week its own 168-row block.
function sample_weeks(cfg; rng = nothing)::DataFrame
    wcfg    = cfg["weeks"]
    n       = Int(wcfg["n_weeks"])
    contig  = get(wcfg, "contiguous", true)
    seed    = Int(get(wcfg, "seed", 0))
    rng     = rng !== nothing ? rng :
              seed == 0 ? Random.Xoshiro() : Random.Xoshiro(seed)
    bgn     = Date(cfg["bellman"]["bgn_date"])
    times   = scenario_time_axis(cfg)
    years   = sort(unique(year.(times)))

    # Week slots stay within the first year of the SDDP horizon so each slot
    # has a unique season (cuts exist beyond, but slot k and k+52 would share
    # weather anchors).
    max_slot = 52
    n <= max_slot || error("[weeks].n_weeks = $n exceeds $max_slot")

    anchor_of(y, k) = begin
        d = bgn + Day(7 * (k - 1))
        DateTime(y, month(d), day(d), 0)
    end

    picks = Tuple{Int,Int,Int}[]                  # (climate_year, slot, row)
    if contig
        for _ in 1:1000
            y = rand(rng, years); k = rand(rng, 1:max_slot - n + 1)
            row = _anchor_row(times, anchor_of(y, k), n * WEEK_HOURS)
            row === nothing && continue           # e.g. late-2019 block off the end
            picks = [(y, k + i, row + i * WEEK_HOURS) for i in 0:n-1]
            break
        end
    else
        slots = Set{Int}()
        for _ in 1:1000
            length(picks) == n && break
            y = rand(rng, years); k = rand(rng, 1:max_slot)
            k in slots && continue
            row = _anchor_row(times, anchor_of(y, k), WEEK_HOURS)
            row === nothing && continue
            push!(picks, (y, k, row)); push!(slots, k)
        end
        sort!(picks; by = p -> p[2])              # chain solves in slot order
    end
    length(picks) == n || error("week sampling failed after 1000 draws")

    return DataFrame(slot         = 1:n,
                     week_slot    = [p[2] for p in picks],
                     climate_year = [p[1] for p in picks],
                     study_start  = [bgn + Day(7 * (p[2] - 1)) for p in picks],
                     data_start   = [times[p[3]] for p in picks],
                     row_start    = [p[3] for p in picks])
end

# Load the persisted key, or draw and persist a fresh one when the key is
# missing or [weeks].resample = true.  The key is validated against the current
# config/axis so a stale key fails loudly instead of feeding wrong weather.
function load_or_sample_weeks(cfg)::DataFrame
    wcfg     = cfg["weeks"]
    key_path = joinpath(@__DIR__, wcfg["key_file"])
    fresh    = get(wcfg, "resample", false) || !isfile(key_path)
    if fresh
        key = sample_weeks(cfg)
        CSV.write(key_path, key)
        return key
    end
    key = CSV.read(key_path, DataFrame,
                   types = Dict(:study_start => Date, :data_start => DateTime))
    nrow(key) == Int(wcfg["n_weeks"]) ||
        error("[weeks]: key file $(basename(key_path)) holds $(nrow(key)) weeks " *
              "but n_weeks = $(wcfg["n_weeks"]) — set [weeks].resample = true to redraw")
    times = scenario_time_axis(cfg)
    for r in eachrow(key)
        (1 <= r.row_start <= length(times) && times[r.row_start] == r.data_start) ||
            error("[weeks]: key row slot=$(r.slot) does not match the ScenarioData " *
                  "time axis — set [weeks].resample = true to redraw")
    end
    return key
end

# All study days of the sampled horizon, in chain order ("yyyy-mm-dd").
week_study_days(key::DataFrame)::Vector{String} =
    [Dates.format(r.study_start + Day(d), "yyyy-mm-dd")
     for r in eachrow(key) for d in 0:6]

# The 168-row range a key row occupies in every ScenarioData file.
week_data_rows(key_row)::UnitRange{Int} =
    key_row.row_start:(key_row.row_start + WEEK_HOURS - 1)

# The 24-row range of one study day within the sampled horizon.  `date_str`
# must be a day of some sampled week.
function day_data_rows(key::DataFrame, date_str::String)::UnitRange{Int}
    d = Date(date_str)
    for r in eachrow(key)
        off = Dates.value(d - r.study_start)
        if 0 <= off <= 6
            lo = r.row_start + 24 * off
            return lo:lo+23
        end
    end
    error("$date_str is not a day of any sampled week")
end
