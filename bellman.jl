# ============================================================
# Bellman cut utilities for hydro water-value computation
# ============================================================

using CSV, DataFrames, Dates

# One cut of the weekly cost-to-go produced by the mid-term model:
#     cost-to-go(V_FR, V_ES) = max_cuts  a_0·V_FR + a_1·V_ES + b
# The market chain models Spain alone — the French reservoir is not a decision
# variable here — so a_0·V_FR is a per-cut constant.  load_cuts_at_stage folds
# it into `b` at the French volume of the study day, which leaves the cuts
# one-dimensional in V_ES (as every consumer assumes) without distorting which
# cut binds.  Dropping the term instead would compare cuts on unequal footing:
# a_0 is nonzero in ~97% of cuts and spans −93…0 EUR/MWh across the cut sets,
# and omitting it selects a different cut on 24 of the 78 GoRES weekly stages.
struct BellmanCut
    a0::Float64   # slope for French reservoir volume [EUR/MWh] (kept for reference)
    a1::Float64   # slope for Spanish aggregate reservoir volume [EUR/MWh]
    b::Float64    # intercept, with the a_0·V_FR term already folded in
end

# Weekly stage index corresponding to the end of a study day.
# Timestep k of the cut file values the reservoir at the END of 1-indexed week
# k+1 (the SDDP node k+1's outgoing state, hour 168·(k+1) — see the exporter in
# midterm_sddp4.jl).  A study day ending at hour h therefore uses the cuts of
# its containing week, k = ceil(h/168) − 1 = div(h−1, 168).  The former
# div(h, 168) was identical for days 1–6 of a week but returned k+1 for the
# 7th day (h an exact multiple of 168), valuing the end-of-day volume with the
# *following* week's cuts.
function bellman_stage(date_str::String, bgn_date::Date, ssv_step::Int)::Int
    uc_end = Date(date_str) + Day(1)   # 00:00 of the day after = end of study day
    hours  = convert(Dates.Hour, DateTime(uc_end) - DateTime(bgn_date)).value
    return div(hours - 1, ssv_step)
end

# All Bellman cuts for a given stage index, with the French-volume term folded
# into the intercept at `v_fr` (the French reservoir volume of the study day,
# taken at the same instant as the V_ES the cuts are evaluated against).
function load_cuts_at_stage(bellman_file::String, stage::Int,
                            v_fr::Float64)::Vector{BellmanCut}
    df   = CSV.read(bellman_file, DataFrame)
    rows = filter(r -> r.Timestep == stage, df)
    isempty(rows) && error("No Bellman cuts found at stage $stage in $bellman_file")
    return [BellmanCut(Float64(r.a_0), Float64(r.a_1),
                       Float64(r.b) + Float64(r.a_0) * v_fr)
            for r in eachrow(rows)]
end

# Reservoir volume [MWh] held in `column` at 00:00 of a study date
function _volume_at_date(volume_file::String, date_str::String, bgn_date::Date,
                         column::String)::Float64
    ts  = convert(Dates.Hour, DateTime(Date(date_str)) - DateTime(bgn_date)).value
    df  = CSV.read(volume_file, DataFrame)
    row = filter(r -> r.Timestep == ts, df)
    isempty(row) && error("Timestep $ts ($(date_str) 00:00) not found in $volume_file")
    return Float64(row[1, column])
end

# Spanish / French aggregate reservoir volume [MWh] at 00:00 of a study date
v_es_at_date(volume_file::String, date_str::String, bgn_date::Date) =
    _volume_at_date(volume_file, date_str, bgn_date, "Hydro|Reservoir_ES_0")
v_fr_at_date(volume_file::String, date_str::String, bgn_date::Date) =
    _volume_at_date(volume_file, date_str, bgn_date, "Hydro|Reservoir_FR_0")

# ── Daily reservoir energy budget from the mid-term turbine schedule ─────────
# The Bellman cuts price water but do not BIND a single day: a day's draw is
# ~1 % of the Spanish reservoir, and the cuts are essentially flat across that
# range (the water value moved only 78.02 → 77.45 EUR/MWh between reservoir
# levels of 5.1 and 7.5 TWh).  Left to the cuts alone the day-ahead runs
# reservoir hydro to its nameplate in every hour whose water value undercuts
# gas — 92 % of 11 660 MW around the clock on 2 Dec 2024, against ~150 GWh/day
# actually scheduled by the mid-term model.
#
# So the mid-term model's own release decision is carried into the day-ahead as
# an energy budget for the study day: the sum of its hourly turbine schedule
# over the 24 hours of that date [MWh].  Returns `nothing` when the schedule
# file is absent, in which case the caller leaves the day unconstrained.
# `basis`:
#   :week (default) — the week's total release ÷ 7.  The mid-term model decides
#       at WEEKLY resolution and its shaping across the 84 blocks inside a week
#       carries little information for a single day: on 2024-07-08 the literal
#       24-hour slice is 0 MWh even though that week releases 268 GWh, which
#       would switch reservoir hydro off entirely.  A weekly energy target
#       shared evenly across the week is the usual mid-term → short-term
#       hand-off and leaves the intra-day shaping to the day-ahead, which has
#       the hourly demand and VRE detail to do it properly.
#   :day — the literal 24-hour slice, for when the mid-term schedule is trusted
#       at daily resolution.
function reservoir_day_budget(turbine_file::String, date_str::String,
                              bgn_date::Date; column::String = "Turbine_ES_MW",
                              basis::Symbol = :week, ssv_step::Int = 168)
    isfile(turbine_file) || return nothing
    df = CSV.read(turbine_file, DataFrame)
    hasproperty(df, Symbol(column)) || return nothing
    t0 = convert(Dates.Hour, DateTime(Date(date_str)) - DateTime(bgn_date)).value
    # Hourly MW held constant over the hour ⇒ MWh is the plain sum.
    if basis === :day
        rows = filter(r -> t0 <= r.Timestep < t0 + 24, df)
        nrow(rows) == 0 && return nothing
        return sum(Float64.(rows[!, column]))
    end
    w0   = div(t0, ssv_step) * ssv_step          # first hour of the containing week
    rows = filter(r -> w0 <= r.Timestep < w0 + ssv_step, df)
    nrow(rows) == 0 && return nothing
    return sum(Float64.(rows[!, column])) * 24 / ssv_step
end

# Water value (EUR/MWh) from the slope of the binding Bellman cut at V_ES
function binding_water_value(cuts::Vector{BellmanCut}, v_es::Float64)::Float64
    best = argmax(c -> c.b + c.a1 * v_es, cuts)   # returns the element, not the index
    return -best.a1   # a1 < 0  →  water value > 0
end
