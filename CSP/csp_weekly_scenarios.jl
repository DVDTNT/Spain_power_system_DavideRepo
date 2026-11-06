# =============================================================================
# csp_weekly_scenarios.jl — 7-day input set and runner for the CSP/TES
# prototype in CSP.jl (standalone; nothing else in the repository is touched).
#
# Run from the repository root (the script lives in CSP/ but CSP.jl stays in
# the root, where the rest of the codebase includes it from):
#     julia --project=. CSP/csp_weekly_scenarios.jl
#
# The script is self-contained: every input the model needs is defined here.
# No Data/ES/Solar forecast file is read — the hourly profiles below are
# synthetic but shaped like a Spanish July week (Mon 2024-07-01 .. Sun
# 2024-07-07, all times CEST; hour 1 = Mon 00:00-01:00, hour 168 = Sun
# 23:00-24:00).
#
# Three weather scenarios share the same plant, demand and base price shape
# and differ in the irradiance profile (and in how the day-ahead price reacts
# to the national PV supply it implies):
#   A "clear skies"    — high irradiance throughout each day, all 7 days;
#                        deep midday price dips (national PV glut).
#   B "mixed"          — 3 clear days, 2 broken-cloud days, 2 overcast days;
#                        the dip follows the weather day by day.
#   C "full overcast"  — diffuse-only irradiance all 7 days; no midday dip,
#                        prices ~8 % higher (scarce renewables).
#
# Reasonable-guess assumptions (each is one line below if you disagree):
#   * Plant data comes from Data/csp_plants.csv row "weekly" — the single
#     source of plant truth shared with Option B, the SDDP and the demos:
#     60 MW(th) field, 35 MW(e) block, 180 MWh(th) molten-salt tank,
#     field->TES 80 %, grid->TES 80 %, TES->electricity 38 %, start and
#     daily floor 70 MWh(th). Edit the FILE to change the plant.
#   * Standing loss 0.0005/h ≈ 1.2 %/day — the physical figure for a hot
#     molten-salt tank.  (The CSP.jl demo and tests deliberately stress the
#     leak with 0.01/h, which would drain ~21 % of the tank per day.)
#   * Day-ahead prices [EUR/MWh_e]: Spanish July shape — midday PV-glut dip
#     (10:00-16:00) and a 19:00-21:00 evening peak; weekends 15-20 % cheaper.
#     Buying costs the sale price + 3 EUR/MWh grid fees.  The TES round trip
#     is 0.8*0.38 = 30 %, so grid charging only pays when the spread exceeds
#     ~3.3x — i.e. on the deepest-dip sunny midday hours.  (p_buy has no
#     rating in the current model, so purchases are limited only by the tank.)
#   * Demand is a plant-scale local profile (~2.7 GWh over the week).  It is
#     a required input but standalone it is inert: CSP.jl keeps shortage /
#     curtail fixed to 0 as market-chain placeholders.
#   * Continuation value: persistence — the week after the horizon repeats
#     the same weather, and the expected future sale price is 60 / 70 / 90
#     EUR/MWh for A / B / C (cheap when sunny, dear when cloudy).
# =============================================================================

include(joinpath(@__DIR__, "..", "CSP.jl"))
using .CSP
using CSV, DataFrames, Dates

# -----------------------------------------------------------------------------
# 1. Horizon and plant constants (shared by all three scenarios)
# -----------------------------------------------------------------------------
const T_WEEK     = 168                       # 7 days x 24 hours
const STAGE      = "DA"
const DATE_LABEL = "2024-07-01..2024-07-07"  # label only — no file is read

# Plant data: the single source of truth is Data/csp_plants.csv, row
# "weekly" — the same demo-scale unit as the "demo" row, but with the
# PHYSICAL standing loss 0.0005/h; a 7-day horizon with the demo row's
# 0.01/h stress value would drain ~21 % of the tank per day.
const PLANTS_FILE = joinpath(@__DIR__, "..", "Data", "csp_plants.csv")
const PLANT_ID    = "weekly"
const plant       = CSP.get_csp_plant(PLANTS_FILE, PLANT_ID)

# -----------------------------------------------------------------------------
# 2. Hourly day shapes (24 entries each)
# -----------------------------------------------------------------------------
# Per-unit clear-sky July day in Spain: sunrise ~06:00, solar noon ~13:30,
# sunset ~21:00.  Index h = hour beginning, so h1 = 00:00-01:00.
clear_day = [0.00, 0.00, 0.00, 0.00, 0.00, 0.00,      # 00-06 night
             0.05, 0.25, 0.45, 0.65, 0.82, 0.93,      # 06-12 morning
             1.00, 1.00, 0.97, 0.88, 0.72, 0.52,      # 12-18 afternoon
             0.32, 0.15, 0.05, 0.00, 0.00, 0.00]      # 18-24 evening/night

# Full-cloud day: diffuse-only irradiance, ~15 % of clear sky.
overcast_day = 0.15 .* clear_day

# Broken-cloud day: clear sky with morning and afternoon cloud events.
broken_day = copy(clear_day)
for (h, f) in ((10, 0.45), (11, 0.45), (12, 0.40),    # 09:00-12:00 clouds
               (15, 0.35), (16, 0.35), (17, 0.55))    # 14:00-17:00 clouds
    broken_day[h] *= f
end

# Day-ahead sale price [EUR/MWh_e], Spanish July weekday shape: midday
# PV-glut dip and a 19:00-21:00 evening peak.
base_sell_day = [42.0, 42.0, 41.0, 41.0, 42.0, 48.0,   # 00-06 night
                 58.0, 66.0, 55.0, 40.0, 30.0, 22.0,   # 06-12 morning
                 18.0, 15.0, 17.0, 28.0, 45.0, 62.0,   # 12-18 afternoon
                 82.0, 98.0, 102.0, 85.0, 68.0, 55.0]  # 18-24 evening/night

# Day-of-week price scale (Mon..Sun): weekends ~15-20 % cheaper.
dow_scale = [1.00, 1.03, 1.00, 1.05, 1.02, 0.85, 0.82]

# The PV-glut window whose prices the scenarios deepen or flatten.
const DIP_HOURS = 11:16    # 10:00-16:00

# Plant-scale local demand [MW].  Inert standalone (market-chain placeholder),
# passed for completeness.
demand_day = [12.0, 11.0, 10.0, 10.0, 10.0, 11.0, 13.0, 15.0, 17.0, 18.0,
              18.0, 19.0, 19.0, 19.0, 18.0, 18.0, 17.0, 18.0, 20.0, 22.0,
              24.0, 23.0, 20.0, 16.0]

# -----------------------------------------------------------------------------
# 3. Week builders
# -----------------------------------------------------------------------------
"Concatenate 7 day profiles into one 168-hour week vector."
week(days) = vcat(days...)

"""
Weekly sale price: base shape x day-of-week scale x global scenario scale,
with a scenario-specific multiplier on the PV-glut hours (10:00-16:00).
"""
function week_sell_price(dip_by_day, global_scale)
    p = Float64[]
    for d in 1:7
        day = base_sell_day .* dow_scale[d] .* global_scale
        day[DIP_HOURS] .*= dip_by_day[d]
        append!(p, day)
    end
    return p
end

"Weekly local demand (weekends 15 % lighter than weekdays)."
function week_demand()
    p = Float64[]
    for d in 1:7
        append!(p, demand_day .* (d <= 5 ? 1.0 : 0.85))
    end
    return p
end

# -----------------------------------------------------------------------------
# 4. The three weather scenarios
# -----------------------------------------------------------------------------
function make_scenario(name, headline, days, dip, pscale, future_price)
    sell = week_sell_price(dip, pscale)
    return (name = name, headline = headline, solar = week(days),
            sell = sell, buy = sell .+ 3.0, future_price = future_price)
end

scenarios = [
    make_scenario(
        "Scenario A — clear skies all week (high irradiance throughout the day)",
        "7 clear days; deep midday PV-glut dips (x0.55), prices x0.97",
        [clear_day for _ in 1:7], 0.55 .* ones(7), 0.97, 60.0),
    make_scenario(
        "Scenario B — mixed week (sunny and cloudy spells)",
        "clear / broken / overcast = 3 / 2 / 2 days; dip x0.65 / x0.85 / x1.50 per day type",
        [clear_day, broken_day, overcast_day, clear_day, broken_day, clear_day, overcast_day],
        [0.65, 0.85, 1.50, 0.65, 0.85, 0.65, 1.50], 1.00, 70.0),
    make_scenario(
        "Scenario C — full cloud coverage all week (diffuse irradiance only)",
        "7 overcast days; no midday dip (x1.60), prices x1.08 overall",
        [overcast_day for _ in 1:7], 1.60 .* ones(7), 1.08, 90.0),
]
# -----------------------------------------------------------------------------
# 5. Reporting
# -----------------------------------------------------------------------------
function print_week_result(sc, r)
    if !r.solved
        println("  NOT SOLVED — termination: ", r.termination)
        return
    end
    gen_day  = vec(sum(reshape(r.p_gen, 24, 7); dims = 1))
    heat_day = vec(sum(reshape(plant.eta_solar .* r.s_solar, 24, 7); dims = 1))
    revenue  = sum(sc.sell .* r.p_gen)
    cost     = sum(sc.buy .* r.p_buy)
    a1       = r.q_tes[end] > 0.0 ? r.theta_future / r.q_tes[end] : 0.0
    println("  termination          : ", r.termination)
    println("  stage objective      : ", round(r.objective, digits = 1), " EUR = ",
            round(cost, digits = 1), " purchases - ", round(revenue, digits = 1),
            " sales - ", round(r.theta_future, digits = 1), " continuation value")
    println("  exported energy      : ", round(sum(r.p_gen), digits = 1), " MWh_e over the week")
    println("    per day [MWh_e]    : ", round.(gen_day, digits = 1))
    println("    solar heat [MWh_th]: ", round.(heat_day, digits = 1))
    println("  grid purchases       : ", round(sum(r.p_buy), digits = 1), " MWh_e for ",
            round(cost, digits = 1), " EUR")
    println("  solar heat collected : ", round(sum(plant.eta_solar .* r.s_solar), digits = 1), " MWh_th")
    println("  TES level [MWh_th]   : start ", round(r.q_tes[1], digits = 1),
            ", end ", round(r.q_tes[end], digits = 1),
            ", min ", round(minimum(r.q_tes), digits = 1),
            ", max ", round(maximum(r.q_tes), digits = 1))
    println("  standing leak        : ", round(sum(r.leak_th), digits = 1), " MWh_th over the week")
    println("  theta_future         : ", round(r.theta_future, digits = 1),
            " EUR (implied cut slope ", round(a1, digits = 2), " EUR/MWh_th)")
    return nothing
end

# -----------------------------------------------------------------------------
# 6. Run the three scenarios
# -----------------------------------------------------------------------------
demand = week_demand()
println("CSP weekly scenarios — T = ", T_WEEK, " h (Mon 2024-07-01 .. Sun 2024-07-07), stage ", STAGE)
println("Plant: ", plant.plant_id, " (bus ", plant.bus_id, ") from ", PLANTS_FILE)
println("  ", plant.solar_capacity_mwth, " MW_th field, ", plant.pmax_e_mwe,
        " MW_e block, ", plant.tes_capacity_mwhth, " MWh_th tank; eta solar/charge/power = ",
        plant.eta_solar, "/", plant.eta_charge, "/", plant.eta_power,
        "; leak ", plant.thermal_leak_rate, "/h; q0 = q_end floor = ",
        plant.q0_start_mwhth, " MWh_th")

results = Dict{String, Any}()
for (key, sc) in zip(["a-clear", "b-mixed", "c-overcast"], scenarios)
    println()
    println("=== ", sc.name, " ===")
    println("    ", sc.headline)
    r = adapt_csp_to_market_stage(STAGE, DATE_LABEL;
        plant                 = plant,        # row "weekly" of Data/csp_plants.csv
        demand                = demand,
        solar_forecast        = sc.solar,
        future_solar_forecast = sc.solar,     # persistence: next week = this week
        buy_price             = sc.buy,
        sell_price            = sc.sell,
        future_sell_price     = sc.future_price)
    results[key] = (sc = sc, r = r)
    print_week_result(sc, r)
end

# -----------------------------------------------------------------------------
# 7. Export for the run viewer (viewer/publish_csp_weekly.py reads these)
# -----------------------------------------------------------------------------
out_dir = joinpath(@__DIR__, "..", "results", "csp_weekly")
mkpath(out_dir)
days = [Date("2024-07-01") + Day(k) for k in 0:6]

for (key, sc) in zip(["a-clear", "b-mixed", "c-overcast"], scenarios)
    rr = results[key].r
    rr.solved || continue
    rows = NamedTuple[]
    for h in 1:T_WEEK
        push!(rows, (date = string(days[div(h - 1, 24) + 1]), hour = (h - 1) % 24,
            price_eur_mwh   = sc.sell[h],
            p_gen_mw        = rr.p_gen[h],
            p_buy_mw        = rr.p_buy[h],
            s_solar_mwth    = rr.s_solar[h],
            s_avail_mwth    = plant.solar_capacity_mwth * sc.solar[h],
            tes_start_mwhth = rr.q_tes[h],
            tes_end_mwhth   = rr.q_tes[h + 1],
            leak_mwth       = rr.leak_th[h]))
    end
    CSV.write(joinpath(out_dir, "csp_$(key)_dispatch.csv"), DataFrame(rows))
end

srows = NamedTuple[]
for (key, sc) in zip(["a-clear", "b-mixed", "c-overcast"], scenarios)
    rr = results[key].r
    rr.solved || continue
    for d in 1:7
        idx = (d - 1) * 24 .+ (1:24)
        push!(srows, (scenario = key, date = string(days[d]),
            gen_mwh         = sum(rr.p_gen[idx]),
            buy_mwh         = sum(rr.p_buy[idx]),
            solar_th_mwh    = sum(plant.eta_solar .* rr.s_solar[idx]),
            net_eur         = sum(sc.sell[idx] .* rr.p_gen[idx]) - sum(sc.buy[idx] .* rr.p_buy[idx]),
            theta_future_eur = rr.theta_future,          # week-terminal continuation value
            q_end_mwhth     = rr.q_tes[d * 24 + 1]))
    end
end
CSV.write(joinpath(out_dir, "csp_weekly_summary.csv"), DataFrame(srows))

plant_facts = DataFrame(
    param = ["plant_id", "bus_id", "solar_capacity", "pmax_e", "tes_capacity", "q0_start",
             "q_end_target", "eta_solar", "eta_power", "eta_charge", "thermal_leak_rate",
             "buy_from_grid", "allow_sell", "grid_price_floor", "pmax_charge_e"],
    value  = [plant.plant_id, plant.bus_id, plant.solar_capacity_mwth, plant.pmax_e_mwe,
              plant.tes_capacity_mwhth, plant.q0_start_mwhth, plant.q_end_target_mwhth,
              plant.eta_solar, plant.eta_power, plant.eta_charge, plant.thermal_leak_rate,
              plant.buy_from_grid, plant.allow_sell, plant.grid_price_floor_eur_mwh,
              plant.pmax_charge_e_mwe])
CSV.write(joinpath(out_dir, "csp_weekly_plant.csv"), plant_facts)
println("\nExported hourly dispatch, summary and plant facts to ", out_dir)
