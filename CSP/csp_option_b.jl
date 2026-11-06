# ==============================================================
# Option B — CSP/TES plant as an external price taker
# ==============================================================
# Companion to CSP.jl for config.toml -> [csp] mode = "postprocess".
#
# What this does
# -------------
# After the market chain (DA -> ID2 -> ID3 -> CID -> BAL -> redispatch) has
# finished and written results/<label>/market_prices.csv, this runner
# re-dispatches the standalone CSP/TES plant of CSP.jl against those CLEARED
# prices — one LP per (gate, day):
#
#   gate "DA"  sees the DA clearing prices;
#   gate "ID2" sees the ID2 clearing prices;
#   gate "ID3" sees ID2 prices for hours 0-11 and ID3 prices for hours 12-23
#              (ID3 only trades the last 12 hours);
#   gate "CID" sees the CID rolling-gate prices;
#   gate "BAL" sees the balancing prices.
#
# Every hour is valued at the price of the LAST gate at or before the stream's
# gate that actually cleared that hour — exactly how a participant experiences
# the sequence of settlements. Each gate is an independent counterfactual
# stream ("had the plant optimised against the prices settled at this gate,
# how would it have run?"), started from the same initial TES level. Within a
# stream the TES state hands over from day to day (q_end -> next q0) across
# CONSECUTIVE study days; a calendar gap (e.g. 2024-07-08 -> 2024-12-02)
# resets the tank to q0_start. The BAL stream is the closest to physical
# reality; the earlier gates show the schedule the plant would have made.
#
# The plant is a PURE PRICE TAKER: it appears in no market model, so it can
# never influence any clearing — it only reacts to prices the chain cleared
# without it. That is the defining property of Option B (the coupled
# alternative, Option A, is specified in
# CSP/option_A_chain_native_csp_design.md).
#
# Outputs (results/<label>/csp/ by default)
#   csp_summary.csv           one row per (gate, day): energy, cash flow, TES
#   csp_<gate>_dispatch.csv   hourly dispatch of the stream, one file per gate
#
# Usage
# -----
# Automatic: [csp] enabled = true, mode = "postprocess" in config.toml —
# run_market_chain.jl includes this file after "8. Save results" and runs it
# on the study days of the run (TARGET_DAYS).
#
# Manual re-run against an existing results directory (no chain re-run):
#   julia --project=. -e 'using TOML; cfg = TOML.parsefile("config.toml");
#       include("CSP/csp_option_b.jl");
#       run_csp_option_b(results_dir = "results/Trinity", csp_cfg = cfg["csp"])'
# With target_days = nothing the study days are read from market_prices.csv.
#
# The PLANT comes from the plants file named by [csp].plants_file, row
# [csp].plant_id (default Data/csp_plants.csv — the single source of plant
# truth shared with the thermal-value SDDP, the standalone demos and the
# weekly scenarios). There is NO built-in default plant: a missing file,
# key or row is a hard error, never a silent fallback.
# ==============================================================

# The chain (or a previous include) already defines Main.CSP; a manual run
# includes the prototype itself.
isdefined(Main, :CSP) || include(joinpath(@__DIR__, "..", "CSP.jl"))

using CSV, DataFrames, Dates, Printf

# Gate order = the chain's gate order.
const OPTION_B_GATES = ["DA", "ID2", "ID3", "CID", "BAL"]

# market_prices.csv labels the balancing gate "BAL"; the solar forecast files
# (Data/ES/Solar/<d_m_yyyy>.csv) label the same vintage "BE". One mapping,
# used everywhere, so the two naming conventions never leak into callers.
const OPTION_B_SOLAR_STAGE = Dict("DA" => "DA", "ID2" => "ID2", "ID3" => "ID3",
                                  "CID" => "CID", "BAL" => "BE")

_as_date(x) = x isa Date ? x : Date(String(x))

"""
    _solar_thermal_shape(results_dir, gate, day) -> Vector{Float64}

Diurnal shape (24 hourly values in [0, 1]) of the field's thermal collection:
the chain's own solar generation profile for the day (`<gate>_profiles.csv` in
`results_dir`, normalised to its peak) wherever the sun is up, and exactly 0 at
night (sun below the horizon, per `CSP.solar_thermal_shape`). Falls back to
the clear-sky geometric shape alone when the run has no profiles file.

The per-gate forecast factors from Data/ES/Solar are ACCURACY multipliers
around 1.0 (the chain applies them to a real solar_mw profile), so on their
own they would let the field collect at midnight; this shape restores the
physics. Availability passed to the plant = factor .× shape.
"""
function _solar_thermal_shape(results_dir::AbstractString, gate::AbstractString, day::Date)
    geom = CSP.solar_thermal_shape(string(day))
    prof = joinpath(results_dir, lowercase(String(gate)) * "_profiles.csv")
    isfile(prof) || return geom
    try
        df = CSV.read(prof, DataFrame)
        (hasproperty(df, :solar_mw) && hasproperty(df, :date)) || return geom
        dstr = string(day)
        sel  = [occursin(dstr, string(x)) for x in df[!, :date]]
        mw   = Float64.(df[sel, :solar_mw])
        (length(mw) == 24 && !any(isnan, mw)) || return geom
        mx = maximum(mw)
        mx > 0 || return geom
        up = geom .> 0                       # astronomical day window
        return [up[h] ? mw[h] / mx : 0.0 for h in 1:24]
    catch
        return geom
    end
end

"""
    prices_as_of_gate(price_df, date_str, gate; T = 24) -> Vector{Float64}

Price vector the plant faces at `gate` on `date_str`, built from the chain's
market_prices.csv (columns date, hour, stage, price_eur_mwh). Gates only
price the hours they actually trade, so each hour takes the price of the LAST
gate at or before `gate` that cleared it: DA/ID2/CID/BAL price all 24 hours,
ID3 only hours 12-23, so the ID3 stream sees ID2 prices in the morning and
ID3 prices in the afternoon. Throws ArgumentError for an unknown gate or for
an hour that no gate up to `gate` ever priced.
"""
function prices_as_of_gate(price_df::DataFrame, date_str::AbstractString,
                           gate::AbstractString; T::Int = 24)
    _prices_from_index(_index_prices(price_df), _as_date(date_str), String(gate); T = T)
end

"""One pass over market_prices.csv: (date, hour) -> gate index -> price."""
function _index_prices(price_df::DataFrame)
    for col in ("date", "hour", "stage", "price_eur_mwh")
        hasproperty(price_df, Symbol(col)) ||
            throw(ArgumentError("market_prices.csv lacks column '$col' " *
                                "(got $(names(price_df)))"))
    end
    idx = Dict{Tuple{Date,Int},Dict{Int,Float64}}()
    for r in eachrow(price_df)
        g = findfirst(==(String(r.stage)), OPTION_B_GATES)
        g === nothing && continue          # unknown stage label: ignore it
        h = Int(r.hour)
        entries = get!(idx, (_as_date(r.date), h), Dict{Int,Float64}())
        entries[g] = Float64(r.price_eur_mwh)   # same gate twice: keep the last
    end
    return idx
end

"""Price vector as of `gate` from the pre-built index (hours 0..T-1)."""
function _prices_from_index(idx, d::Date, gate::String; T::Int = 24)
    gate ∈ OPTION_B_GATES ||
        throw(ArgumentError("gate must be one of $(join(OPTION_B_GATES, ", ")) (got \"$gate\")"))
    upto = findfirst(==(gate), OPTION_B_GATES)
    p = fill(NaN, T)
    for h in 0:T-1
        best = -1
        for (g, price) in get(idx, (d, h), Dict{Int,Float64}())
            if g <= upto && g > best
                best = g
                p[h+1] = price
            end
        end
    end
    any(isnan, p) &&
        throw(ArgumentError("no cleared prices for $d at or before gate $gate " *
                            "(some hours were never priced)"))
    return p
end

"""
    run_csp_option_b(; results_dir, target_days = nothing,
                     csp_cfg = Dict{String,Any}(), out_subdir = nothing,
                     base_dir = joinpath(@__DIR__, "..", "Data")) -> Dict

Re-dispatch the CSP/TES plant against the chain's cleared prices (Option B).

* `results_dir`  — the chain's output directory; must contain market_prices.csv.
* `target_days`  — study days to dispatch; `nothing` = every date found in the
                   price file. The TES state hands over only across
                   consecutive days; calendar gaps reset the tank to q0_start.
* `csp_cfg`      — the [csp] table of config.toml: `plants_file` and `plant_id` (REQUIRED - no default plant), `gates`
                   (default all five, chain order) and `out_subdir` ("csp").
* `out_subdir`   — explicit override of the output subdirectory.

Returns `Dict(:out_dir, :summary, :prices, :net_eur, :gates)`. Throws
ArgumentError when market_prices.csv is missing or malformed — i.e. when the
market chain has not cleared anything yet.
"""
function run_csp_option_b(; results_dir::AbstractString,
                          target_days = nothing,
                          csp_cfg::AbstractDict = Dict{String,Any}(),
                          out_subdir = nothing,
                          base_dir::AbstractString = joinpath(@__DIR__, "..", "Data"))
    price_file = joinpath(results_dir, "market_prices.csv")
    isfile(price_file) ||
        throw(ArgumentError("Option B needs $price_file — run the market chain " *
                            "first (run_market_chain.jl, RUN_MARKET active)."))
    price_df = CSV.read(price_file, DataFrame)
    idx = _index_prices(price_df)

    # ── streams (chain order) and study days ──────────────────────
    gates = String.(get(csp_cfg, "gates", OPTION_B_GATES))
    bad = setdiff(Set(gates), Set(OPTION_B_GATES))
    isempty(bad) || throw(ArgumentError("[csp].gates may only contain " *
        "$(join(OPTION_B_GATES, ", ")) — got $(join(sort(collect(bad)), ", "))"))
    gates = [g for g in OPTION_B_GATES if g in gates]   # keep the chain order
    isempty(gates) && throw(ArgumentError("[csp].gates is empty"))

    days = target_days === nothing ?
        sort(unique([k[1] for k in keys(idx)])) :
        sort(unique([_as_date(x) for x in target_days]))

    # -- plant: a row of the plants file named by [csp].plants_file ----------
    # There is no built-in default plant: [csp] must name the file and the row.
    plants_key = get(csp_cfg, "plants_file", nothing)
    plants_key === nothing && throw(ArgumentError(
        "[csp] must set plants_file (e.g. \"Data/csp_plants.csv\") - the plant " *
        "comes from there; there is no built-in default plant."))
    plant_id_cfg = get(csp_cfg, "plant_id", nothing)
    plant_id_cfg === nothing && throw(ArgumentError(
        "[csp] must set plant_id (the row of plants_file to dispatch) - " *
        "there is no built-in default plant."))
    plants_path = String(plants_key)
    if !isfile(plants_path)                       # allow repo-root-relative paths
        alt = normpath(joinpath(@__DIR__, "..", plants_path))
        isfile(alt) && (plants_path = alt)
    end
    plant = CSP.get_csp_plant(plants_path, String(plant_id_cfg))

    # Local aliases for the fields the TES hand-over and dispatch rows use.
    q0_start       = plant.q0_start_mwhth       # MWh_th stream start
    tes_capacity   = plant.tes_capacity_mwhth   # MWh_th tank
    solar_capacity = plant.solar_capacity_mwth  # MW_th field

    out_dir = joinpath(results_dir,
        String(out_subdir === nothing ? get(csp_cfg, "out_subdir", "csp") : out_subdir))
    mkpath(out_dir)

    println("\nCSP Option B — price taker on the chain's cleared prices")
    @printf "  plant  : %s (bus %s) from %s\n" plant.plant_id plant.bus_id plants_path
    @printf "  prices : %s (%d rows, %d day(s))\n" price_file nrow(price_df) length(days)
    @printf "  gates  : %s\n" join(gates, " -> ")
    @printf "  output : %s\n" out_dir

    summary_rows = []
    net_by_gate  = Dict{String,Float64}()

    for gate in gates
        solar_stage = OPTION_B_SOLAR_STAGE[gate]
        q_state = q0_start            # TES handed across days within the stream
        prev_day = nothing
        gate_rows = []

        for day in days
            date_str = string(day)
            # The TES state hands over only across CONSECUTIVE study days; a
            # calendar gap (e.g. July -> December) resets the tank.
            if prev_day !== nothing && day != prev_day + Day(1)
                @warn "CSP Option B: study days are not consecutive — resetting the tank" gate date_str
                q_state = q0_start
            end

            prices = _prices_from_index(idx, day, gate)
            # Thermal availability = per-gate forecast-accuracy factor .× physical
            # day shape (real solar profile where the sun is up, zero at night).
            shape  = _solar_thermal_shape(results_dir, gate, day)
            solar  = CSP.load_solar_forecast(date_str, solar_stage;
                                             base_dir = String(base_dir)) .* shape

            res = CSP.adapt_csp_to_market_stage(gate, date_str;
                plant          = plant,      # every plant parameter from the plants file
                demand         = zeros(24),  # inert placeholder, required by CSP.jl
                solar_forecast = solar,
                buy_price      = prices,     # price taker: buys at the cleared price
                sell_price     = prices,     # ...and sells at the cleared price
                q0             = q_state)   # TES handed across days within the stream

            if res.solved
                # Cash flow is reported at the CLEARED prices (the floor only
                # shapes the LP's decision; it is a planning assumption, not a
                # cost actually paid).
                rev_gen  = sum(prices .* res.p_gen)     # sell at the cleared price
                cost_buy = sum(prices .* res.p_buy)     # buy at the cleared price
                net      = rev_gen - cost_buy
                net_by_gate[gate] = get(net_by_gate, gate, 0.0) + net
                q_next = clamp(res.q_tes[end], 0.0, tes_capacity)
                for t in 1:24
                    push!(gate_rows, (gate = gate, date = date_str, hour = t - 1,
                        price_eur_mwh   = prices[t],
                        p_gen_mw        = res.p_gen[t],
                        p_buy_mw        = res.p_buy[t],
                        s_solar_mwth    = res.s_solar[t],
                        s_avail_mwth    = solar_capacity * solar[t],  # field potential (factor .× shape)
                        tes_start_mwhth = res.q_tes[t],
                        tes_end_mwhth   = res.q_tes[t + 1],
                        leak_mwth       = res.leak_th[t]))
                end
                push!(summary_rows, (gate = gate, date = date_str, solved = true,
                    termination = res.termination,
                    gen_mwh = sum(res.p_gen), buy_mwh = sum(res.p_buy),
                    solar_th_mwh = sum(res.s_solar),
                    rev_gen_eur = rev_gen, cost_buy_eur = cost_buy, net_eur = net,
                    objective_eur = res.objective, theta_future_eur = res.theta_future,
                    q0_mwhth = q_state, q_end_mwhth = q_next))
                q_state = q_next
            else
                @warn "CSP Option B: stage did not solve — keeping the tank level" gate date_str termination = res.termination
                push!(summary_rows, (gate = gate, date = date_str, solved = false,
                    termination = res.termination,
                    gen_mwh = 0.0, buy_mwh = 0.0, solar_th_mwh = 0.0,
                    rev_gen_eur = 0.0, cost_buy_eur = 0.0, net_eur = 0.0,
                    objective_eur = NaN, theta_future_eur = NaN,
                    q0_mwhth = q_state, q_end_mwhth = q_state))
            end
            prev_day = day
        end

        gate_file = joinpath(out_dir, "csp_$(lowercase(gate))_dispatch.csv")
        CSV.write(gate_file, DataFrame(gate_rows))
        @printf "  csp_%s_dispatch.csv : %d rows\n" lowercase(gate) length(gate_rows)
    end

    summary = DataFrame(summary_rows)
    isempty(summary) || sort!(summary, [:gate, :date])
    CSV.write(joinpath(out_dir, "csp_summary.csv"), summary)

    println("\n  CSP Option B — net market cash flow per gate (sell − buy):")
    for gate in gates
        g = summary[summary.gate .== gate, :]
        @printf "    %-3s net %12.2f EUR | gen %10.1f MWh | %d/%d day(s) solved\n" gate get(net_by_gate, gate, 0.0) sum(g.gen_mwh) count(g.solved) nrow(g)
    end

    return Dict(:out_dir => out_dir, :summary => summary, :prices => price_df,
                :net_eur => net_by_gate, :gates => gates)
end
