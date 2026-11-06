# ============================================================
# Spain Power System — Cross-border exchange reader (redispatch input)
# ============================================================
# Reads the market-cleared cross-border schedule (Data/crossborder.csv)
# and turns it into fixed nodal injections at the FR/PT terminal buses,
# so the redispatch AC OPF sees the imports/exports that were settled in
# the market clearing that preceded redispatch.
#
# crossborder.csv columns:
#   Day      : "8_Jul" / "2_Dec"        -> study date
#   Time     : "HH:00 - HH:00"          -> delivery hour (start hour, 0..23)
#   to_PT,   from_PT                    : Spain->PT export, PT->Spain import [MW]
#   from_FR, to_FR                      : FR->Spain import, Spain->FR export [MW]
#
# Net injection into Spain per country = from_X - to_X  (import positive).
# The per-country total is disaggregated across that country's border
# lines proportionally to each line's thermal rating (∝ V·Imax) and then
# aggregated to the foreign terminal bus, where it is injected.
#
# Usage (from run_market_chain.jl, after data_preparation.jl is included):
#   xb     = load_crossborder()                       # date => hour => (FR,PT) net MW
#   fracs  = crossborder_bus_fractions()              # country => bus_id => share
#   inj    = crossborder_injections(xb, fracs, "2024-12-02", 13)  # bus_id => MW
# ============================================================

using CSV, DataFrames, Dates

# "Day" label in crossborder.csv -> study date used everywhere else.
const XB_DAY_MAP = Dict("8_Jul" => "2024-07-08", "2_Dec" => "2024-12-02")

# Read the cross-border schedule into date => hour => (FR=net, PT=net) in MW,
# where net = import into Spain − export from Spain.
function load_crossborder()::Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}
    df = CSV.read(joinpath(DATA, "crossborder.csv"), DataFrame)
    data = Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}()
    for row in eachrow(df)
        haskey(XB_DAY_MAP, string(row.Day)) || continue
        date_str = XB_DAY_MAP[string(row.Day)]
        hour     = parse(Int, split(strip(string(row.Time)), ":")[1])   # start hour
        net_fr   = Float64(row.from_FR) - Float64(row.to_FR)
        net_pt   = Float64(row.from_PT) - Float64(row.to_PT)
        get!(data, date_str, Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}())[hour] =
            (FR = net_fr, PT = net_pt)
    end
    return data
end

# ── Mid-term (SDDP) cleared exchange as the DA schedule ─────────────────────
# Alternative to the observed crossborder.csv, selected by [crossborder].source
# = "sddp".  Reads the hourly ES-FR / ES-PT net positions midterm_sddp4.jl
# writes alongside the turbine schedule (Import_FR_MW / Import_PT_MW, import
# into Spain positive, on the same Timestep = hours-since-bgn_date axis as the
# volume and turbine files) and returns them in the same shape load_crossborder
# produces, so every downstream consumer is unchanged.
#
# NOTE (see docs/method_midterm_exchange_handoff.md): the mid-term model clears
# exchange zonally against EMPIRE/EDF climate-year weather, NOT against the
# actual weather of a 2024 calendar day, and its ES-FR flow sits on the NTC
# bound in ~90 % of blocks.  Its schedule for a literal study day is therefore a
# scenario-average, not a forecast of that day.
function load_midterm_exchange(exchange_file::String, dates, bgn_date::Date
                               )::Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}
    isfile(exchange_file) || error(
        "[crossborder].source = \"sddp\" needs $exchange_file — regenerate it with " *
        "`julia --project=. midterm_sddp4.jl export` (reloads the trained cuts, no retraining)")
    df   = CSV.read(exchange_file, DataFrame)
    data = Dict{String,Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}}()
    for date_str in dates
        t0 = convert(Dates.Hour, DateTime(Date(date_str)) - DateTime(bgn_date)).value
        day = Dict{Int,@NamedTuple{FR::Float64, PT::Float64}}()
        for h in 0:23
            row = filter(r -> r.Timestep == t0 + h, df)
            isempty(row) && error("Timestep $(t0 + h) ($date_str h$h) not in $exchange_file")
            day[h] = (FR = Float64(row[1, "Import_FR_MW"]),
                      PT = Float64(row[1, "Import_PT_MW"]))
        end
        data[date_str] = day
    end
    return data
end

# Identify the FR/PT border buses and the share of their country's exchange that
# each one carries, proportional to the thermal rating (∝ V·Imax) of the border
# line(s) terminating at that bus.  Returns country => (bus_id => fraction),
# fractions summing to 1 within each country.
#
# In a nodal scenario run the border is not the 2024 one: pass the nodal
# disaggregation's `line_scale` (corridor expansion as parallel circuits) and
# `extra_lines` (corridors EMPIRE built where no border line exists today) so
# the exchange is split over the scenario border rather than today's.  A new
# corridor therefore takes its rating share of the schedule, and the AC OPF has
# a physical path for it.
# Per-country, per-bus nameplate rating [MW] of the border lines terminating
# at each foreign terminal bus (√3·V·Imax·circuits, at the scenario's corridor
# expansion incl. synthetic lines).  The shared primitive behind the fraction
# split, the border totals and the per-bus caps of the redispatch XB re-split.
function crossborder_bus_ratings(; line_scale = nothing,
                                   extra_lines = nothing)::Dict{String,Dict{String,Float64}}
    bus_df  = CSV.read(joinpath(DATA, "Bus_Data.csv"), DataFrame)
    line_df = CSV.read(joinpath(DATA, "lines.csv"),    DataFrame)
    if extra_lines !== nothing && nrow(DataFrame(extra_lines)) > 0
        line_df = vcat(line_df, DataFrame(extra_lines); cols = :intersect)
    end
    lscale(id) = line_scale === nothing ? 1.0 : get(line_scale, string(id), 1.0)
    country = Dict(string(r.bus_id) => string(r.country) for r in eachrow(bus_df))
    rating = Dict("FR" => Dict{String,Float64}(), "PT" => Dict{String,Float64}())
    for r in eachrow(line_df)
        b0, b1 = string(r.bus0), string(r.bus1)
        # A border line has exactly one foreign (FR/PT) end and one ES end.
        for (foreign, home) in ((b0, b1), (b1, b0))
            c = get(country, foreign, "ES")
            (c == "FR" || c == "PT") && get(country, home, "ES") == "ES" || continue
            w = sqrt(3) * Float64(r.voltage) * Float64(r.Imax) *
                max(Float64(r.circuits), 1.0) * lscale(r.line_id)
            rating[c][foreign] = get(rating[c], foreign, 0.0) + w
        end
    end
    return rating
end

function crossborder_bus_fractions(; line_scale = nothing,
                                     extra_lines = nothing)::Dict{String,Dict{String,Float64}}
    rating = crossborder_bus_ratings(; line_scale, extra_lines)
    fracs = Dict{String,Dict{String,Float64}}()
    for (c, busw) in rating
        tot = sum(values(busw))
        fracs[c] = Dict(bus => w / tot for (bus, w) in busw)
    end
    return fracs
end

# Total nameplate MW of the physical border per country (√3·V·Imax·circuits,
# at the scenario's corridor expansion incl. synthetic lines).  The 4-zone DA
# caps its NTC at this rating × [network].line_rating_factor so it never
# schedules exchange the bus-level border cannot physically carry.
function crossborder_border_ratings(; line_scale = nothing,
                                      extra_lines = nothing)::Dict{String,Float64}
    rating = crossborder_bus_ratings(; line_scale, extra_lines)
    return Dict(c => sum(values(busw); init = 0.0) for (c, busw) in rating)
end

# Net cross-border injection (MW, import into Spain positive) per foreign bus for
# one study date and hour (0..23).  Returns Dict{bus_id => MW}.
function crossborder_injections(xb_data, fracs, date_str::String, hour::Int)::Dict{String,Float64}
    net = xb_data[date_str][hour]
    inj = Dict{String,Float64}()
    for (country, total) in (("FR", net.FR), ("PT", net.PT))
        for (bus, f) in fracs[country]
            inj[bus] = get(inj, bus, 0.0) + total * f
        end
    end
    return inj
end
