# =============================================================================
# CSP.jl smoke test
# =============================================================================
# Regression checks for the standalone CSP + TES prototype. This would have
# caught all four blocking bugs (missing Statistics import, non-@kwdef input
# struct, fix() on an expression, String/Symbol column lookup) in seconds,
# plus the robustness behaviour of the typed result and input validation.
# Improvement 5: the terminal TES floor (q_tes[T] >= q_end_target) makes the
# continuation value theta_future an active part of the objective.
# Loss fix: the TES balance carries a single standing-loss channel (the
# proportional thermal_leak_rate); the redundant eta_loss retention factor is
# gone, and the dynamics checks below pin the exact balance.
#
# Run from the repository root:
#     julia --project=. test/csp_test.jl
#
# Uses plain checks (no Test.jl dependency) so it runs in any instantiation
# of this project. Exits non-zero at the first failure.
# =============================================================================

include(joinpath(@__DIR__, "..", "CSP.jl"))
using .CSP
using CSV, DataFrames

# Test fixture: an explicit plant specification (this file's own values, kept
# in sync with the demo row of Data/csp_plants.csv). NOT a data default —
# every value is written out here; real-data tests read the actual plants file.
function mkplant(; kw...)
    d = Dict{Symbol,Any}(:plant_id => "test", :bus_id => "ES0",
        :solar_capacity_mwth => 60.0, :pmax_e_mwe => 35.0,
        :tes_capacity_mwhth => 180.0, :q0_start_mwhth => 70.0,
        :q_end_target_mwhth => 70.0, :eta_solar => 0.80, :eta_power => 0.38,
        :eta_charge => 0.80, :thermal_leak_rate => 0.01,
        :pmax_charge_e_mwe => 50.0, :buy_from_grid => true,
        :allow_sell => true, :grid_price_floor_eur_mwh => 2.0,
        :vom_eur_mwh => 0.0)
    for (k, v) in pairs(kw)
        d[k] = v
    end
    return CSPPlant(; d...)
end

const N_CHECKS = Ref(0)

function check(cond::Bool, msg::String)
    N_CHECKS[] += 1
    if cond
        println("PASS: ", msg)
    else
        println("FAIL: ", msg)
        error("CSP smoke test failed: ", msg)
    end
end

# --- A.4: stage-column lookup in the solar forecast files --------------------
fc = load_solar_forecast("2024-07-08", "DA")
check(length(fc) == 24, "DA forecast for 2024-07-08 has 24 hours")
check(any(fc .!= 0.0), "DA forecast for 2024-07-08 is non-zero")
check(length(load_solar_forecast("2024-07-08", "BE")) == 24, "BE stage column is found")

# --- C.10: a missing file warns (stderr) and returns a zero profile ------------
z = load_solar_forecast("1999-01-01", "DA")
check(length(z) == 24 && all(z .== 0.0), "missing forecast file returns a zero profile")

# --- Solar geometry: the physical day shape is zero at night -------------------
shp_jul = solar_thermal_shape("2024-07-08")
check(length(shp_jul) == 24, "solar_thermal_shape returns 24 hours")
check(all(shp_jul[1:7] .== 0.0), "no thermal availability before sunrise on 8 July (hours 0-6)")
check(maximum(shp_jul) > 0.8, "clear-sky shape peaks near 1 around midday in July")
check(shp_jul[22] > 0.0, "the sun is still up at 21:00 on 8 July (CEST)")
shp_dec = solar_thermal_shape("2024-12-02")
check(all(shp_dec[1:8] .== 0.0), "no thermal availability before sunrise on 2 December (hours 0-7)")
check(maximum(shp_dec) < maximum(shp_jul), "the December peak is lower than July's")
check(all(shp_dec .>= 0.0) && all(shp_dec .<= 1.0), "shape stays within [0, 1]")

# --- the plants overlay file: single source of plant truth, no defaults -------
plants_file0 = joinpath(@__DIR__, "..", "Data", "csp_plants.csv")
plants = read_csp_plants(plants_file0)
check(length(plants) >= 3, "the plants file provides the demo, weekly and bigtes rows")
demo_row = get_csp_plant(plants_file0, "demo")
check(demo_row.plant_id == "demo" && demo_row.bus_id == "ES00007",
      "get_csp_plant picks the demo row (bus ES00007 - a real CSP bus, Valle Torresol)")
check(demo_row.solar_capacity_mwth == 60.0 && demo_row.pmax_e_mwe == 35.0 &&
      demo_row.tes_capacity_mwhth == 180.0 && demo_row.q0_start_mwhth == 70.0 &&
      demo_row.q_end_target_mwhth == 70.0,
      "the demo row carries the demo plant (60 MW_th / 35 MW_e / 180 MWh_th / floor 70)")
check(demo_row.eta_solar == 0.80 && demo_row.eta_power == 0.38 &&
      demo_row.eta_charge == 0.80 && demo_row.thermal_leak_rate == 0.01,
      "the demo row carries the efficiencies and the stress leak 0.01/h")
weekly_row = get_csp_plant(plants_file0, "weekly")
check(weekly_row.thermal_leak_rate == 0.0005,
      "the weekly row keeps the physical leak 0.0005/h for the 7-day horizon")
bigtes_row = get_csp_plant(plants_file0, "bigtes")
check(bigtes_row.tes_capacity_mwhth == 800.0 && bigtes_row.q_end_target_mwhth == 300.0,
      "the bigtes row records the 800 MWh_th / floor-300 variant")
try
    get_csp_plant(plants_file0, "no-such-plant")
    check(false, "unknown plant_id raises ArgumentError listing the available rows")
catch e
    check(e isa ArgumentError && occursin("no-such-plant", e.msg) && occursin("demo", e.msg),
          "unknown plant_id raises ArgumentError listing the available rows")
end
try
    read_csp_plants(joinpath(@__DIR__, "..", "Data", "csp_plants_MISSING.csv"))
    check(false, "a missing plants file raises ArgumentError (no default plant)")
catch e
    check(e isa ArgumentError && occursin("no built-in default", e.msg),
          "a missing plants file raises ArgumentError (no default plant)")
end
mktempdir() do tmp
    badf = joinpath(tmp, "plants_missing_col.csv")
    CSV.write(badf, DataFrame(plant_id = ["x"], bus_id = ["ES0"]))
    try
        read_csp_plants(badf)
        check(false, "a plants file lacking columns raises ArgumentError")
    catch e
        check(e isa ArgumentError && occursin("solar_capacity_mwth", e.msg),
              "a plants file lacking columns raises ArgumentError (column named)")
    end
    dup = joinpath(tmp, "plants_dup.csv")
    CSV.write(dup, DataFrame(plant_id = ["x", "x"], bus_id = ["ES0", "ES0"],
        solar_capacity_mwth = [60.0, 60.0], pmax_e_mwe = [35.0, 35.0],
        tes_capacity_mwhth = [180.0, 180.0], q0_start_mwhth = [70.0, 70.0],
        q_end_target_mwhth = [70.0, 70.0], eta_solar = [0.8, 0.8],
        eta_power = [0.38, 0.38], eta_charge = [0.8, 0.8],
        thermal_leak_rate = [0.01, 0.01], pmax_charge_e_mwe = [50.0, 50.0],
        buy_from_grid = [true, true], allow_sell = [true, true],
        grid_price_floor_eur_mwh = [2.0, 2.0], vom_eur_mwh = [0.0, 0.0]))
    try
        read_csp_plants(dup)
        check(false, "duplicate plant_id raises ArgumentError")
    catch e
        check(e isa ArgumentError && occursin("duplicate", e.msg),
              "duplicate plant_id raises ArgumentError")
    end
    badv = joinpath(tmp, "plants_bad_value.csv")
    CSV.write(badv, DataFrame(plant_id = ["x"], bus_id = ["ES0"],
        solar_capacity_mwth = [60.0], pmax_e_mwe = [35.0],
        tes_capacity_mwhth = [180.0], q0_start_mwhth = [70.0],
        q_end_target_mwhth = [250.0], eta_solar = [0.8], eta_power = [0.38],
        eta_charge = [0.8], thermal_leak_rate = [0.01],
        pmax_charge_e_mwe = [50.0], buy_from_grid = [true],
        allow_sell = [true], grid_price_floor_eur_mwh = [2.0],
        vom_eur_mwh = [0.0]))
    try
        read_csp_plants(badv)
        check(false, "q_end_target above the tank raises ArgumentError")
    catch e
        check(e isa ArgumentError && occursin("q_end_target_mwhth", e.msg),
              "q_end_target above the tank raises ArgumentError (value range checked)")
    end
end
inp = inputs_from_plant(demo_row; stage = "DA", date_str = "2024-07-08",
    demand = zeros(24), solar_forecast = ones(24),
    buy_price = 50.0 .* ones(24), sell_price = 50.0 .* ones(24))
check(inp.solar_capacity == 60.0 && inp.pmax_e == 35.0 &&
      inp.tes_capacity == 180.0 && inp.q0 == 70.0 && inp.q_end_target == 70.0 &&
      inp.eta_power == 0.38 && inp.grid_price_floor == 2.0 &&
      inp.pmax_charge_e == 50.0 && inp.buy_from_grid && inp.allow_sell,
      "inputs_from_plant maps every plant field into the LP inputs")

# --- Bellman cut shape (improvement 5: positive continuation value) -------------
cut = build_solar_bellman_cut(fc; sell_price = 70.0, eta_power = 0.38)
check(cut.a1 >= 0.0 && cut.b == 0.0,
      "cut has non-negative slope and zero intercept (sunny forecast crowds storage value to zero)")
dark_cut = build_solar_bellman_cut(zeros(24); sell_price = 70.0, eta_power = 0.38)
check(isapprox(dark_cut.a1, 0.38 * 70.0; atol = 1e-9),
      "dark-tomorrow cut values terminal heat at eta_power * price")

# --- A.1 + A.2 + A.3: full DA solve through the public wrapper -----------------
result = adapt_csp_to_market_stage("DA", "2024-07-08";
    plant = mkplant(),
    demand = 20.0 .* ones(24),
    buy_price = 60.0 .* ones(24),
    sell_price = 70.0 .* ones(24))

check(result.solved, "DA stage solves to optimality ($(result.termination))")
check(length(result.q_tes) == 25, "TES state vector has T+1 entries")
check(result.q_tes[end] >= 70.0 - 1e-6, "terminal TES respects the q_end_target floor")
check(isapprox(result.q_tes[end], 70.0; atol = 1e-6),
      "crowded-out storage value makes the plant sell down to the floor")
check(sum(result.leak_th) > 0.0, "proportional TES leak is active")
check(all(isapprox.(result.leak_th, 0.01 .* result.q_tes[1:end-1]; atol = 1e-6)),
      "leak equals thermal_leak_rate times the stored level (single standing-loss channel)")
check(all(isapprox.(result.q_tes[2:end],
                    result.q_tes[1:end-1] .+ result.q_charge_th .- result.q_discharge .- result.leak_th;
                    atol = 1e-6)),
      "TES balance has no retention factor: q_tes[t] = q_tes[t-1] + charge - discharge - leak")
check(sum(result.p_buy) < 1e-6, "no grid purchases at 60 buy / 70 sell EUR/MWh")
check(sum(result.p_gen) > 0.0, "power block exports electricity")
check(isapprox(result.theta_future, cut.b + cut.a1 * result.q_tes[end]; atol = 1e-6),
      "theta_future equals the cut value at the optimal terminal level")

# --- Improvement 5: terminal floor + active theta_future -------------------------
# Tomorrow is dark and electricity is valuable there (70 EUR/MWh), so each stored
# MWhth is worth eta_power * 70 = 26.6 EUR - more than selling it today at 10
# EUR/MWh (0.38 * 10 = 3.8 EUR per MWhth).
stored = adapt_csp_to_market_stage("DA", "2024-07-08";
    plant = mkplant(),
    demand = 20.0 .* ones(24),
    buy_price = 100.0 .* ones(24),
    sell_price = 10.0 .* ones(24),
    future_solar_forecast = zeros(24),
    future_sell_price = 70.0)
check(stored.solved, "dark-tomorrow stage solves to optimality ($(stored.termination))")
check(stored.q_tes[end] > 70.0 + 1e-6, "plant stores above the floor when tomorrow is worth more")
check(isapprox(stored.q_tes[end], 180.0; atol = 1e-6), "abundant solar fills the TES to capacity")
check(isapprox(stored.theta_future, dark_cut.a1 * stored.q_tes[end]; atol = 1e-6),
      "theta_future prices the stored heat at the dark-tomorrow cut value")
check(sum(stored.p_gen) < sum(result.p_gen),
      "storing scenario exports less than the sell-down-to-the-floor scenario")

# Same dark and valuable tomorrow, but today's solar supply is scarce: every
# MWhth collected is worth more in store than sold, so nothing is exported.
scarce = adapt_csp_to_market_stage("DA", "2024-07-08";
    plant = mkplant(solar_capacity_mwth = 3.0),
    demand = 20.0 .* ones(24),
    buy_price = 100.0 .* ones(24),
    sell_price = 10.0 .* ones(24),
    future_solar_forecast = zeros(24),
    future_sell_price = 70.0)
check(scarce.solved, "scarce-solar stage solves to optimality ($(scarce.termination))")
check(sum(scarce.p_gen) < 1e-6, "scarce heat is kept in store, not sold cheap")
check(scarce.q_tes[end] > 71.0, "terminal TES rises above the floor when heat is scarce")

# --- C.12: failure returns a typed result, not `nothing` -----------------------
bad = adapt_csp_to_market_stage("DA", "2024-07-08";
    plant = mkplant(solar_capacity_mwth = 0.0,   # no sun at all...
                   buy_from_grid = false),       # ...and no grid charging
    demand = 20.0 .* ones(24),
    buy_price = 60.0 .* ones(24),
    sell_price = 70.0 .* ones(24),
    q0 = 0.0,                                   # terminal 50 unreachable
    q_end_target = 50.0)
check(!bad.solved, "infeasible stage reports solved = false")
check(!isempty(bad.termination), "failure carries a termination status ($(bad.termination))")
check(isnan(bad.objective), "failure carries objective = NaN")

# --- C.11: input validation -----------------------------------------------------
try
    adapt_csp_to_market_stage("DA", "2024-07-08";
        plant = mkplant(),
        demand = 20.0 .* ones(24),
        buy_price = 60.0 .* ones(23),
        sell_price = 60.0 .* ones(24))
    check(false, "buy_price/demand length mismatch raises ArgumentError")
catch e
    check(e isa ArgumentError, "buy_price/demand length mismatch raises ArgumentError")
end

try
    adapt_csp_to_market_stage("DA", "2024-07-08";
        plant = mkplant(),
        demand = 20.0 .* ones(24),
        buy_price = 60.0 .* ones(24),
        sell_price = 60.0 .* ones(24),
        q0 = 500.0)
    check(false, "q0 > tes_capacity raises ArgumentError")
catch e
    check(e isa ArgumentError, "q0 > tes_capacity raises ArgumentError")
end

try
    adapt_csp_to_market_stage("DA", "2024-07-08"; buy_price = 60.0 .* ones(24))
    check(false, "missing demand raises ArgumentError")
catch e
    check(e isa ArgumentError, "missing demand raises ArgumentError")
end

try
    adapt_csp_to_market_stage("DA", "2024-07-08";
        demand = 20.0 .* ones(24), wrong_kwarg = 1.0)
    check(false, "unknown keyword is rejected")
catch
    check(true, "unknown keyword is rejected")
end

try
    adapt_csp_to_market_stage("DA", "2024-07-08";
        plant = mkplant(),
        demand = 20.0 .* ones(24),
        buy_price = 60.0 .* ones(24),
        sell_price = 60.0 .* ones(24),
        future_solar_forecast = zeros(23))
    check(false, "future_solar_forecast length mismatch raises ArgumentError")
catch e
    check(e isa ArgumentError, "future_solar_forecast length mismatch raises ArgumentError")
end

# =============================================================================
# Option B — price-taker post-processing on the chain's cleared prices
# =============================================================================
# CSP/csp_option_b.jl re-dispatches the plant against market_prices.csv after
# the chain has cleared it. Synthetic prices exercise the overlay semantics,
# the day-to-day TES hand-off and the output contract end to end.
# =============================================================================
include(joinpath(@__DIR__, "..", "CSP", "csp_option_b.jl"))

# --- price overlay: each hour takes the last gate that cleared it -------------
mp = DataFrame(date = String[], hour = Int[], stage = String[], price_eur_mwh = Float64[])
for h in 0:23
    push!(mp, ("2024-07-08", h, "DA",  40.0 + h))
    push!(mp, ("2024-07-08", h, "ID2", 50.0 + h))
    push!(mp, ("2024-07-08", h, "BAL", 70.0 + h))
    h >= 12 && push!(mp, ("2024-07-08", h, "ID3", 60.0 + h))
end
p_da  = prices_as_of_gate(mp, "2024-07-08", "DA")
p_id3 = prices_as_of_gate(mp, "2024-07-08", "ID3")
p_bal = prices_as_of_gate(mp, "2024-07-08", "BAL")
check(p_da == [40.0 + h for h in 0:23], "DA stream sees the DA clearing prices")
check(p_id3[1] == 50.0 && p_id3[13] == 72.0 && p_id3[24] == 83.0,
      "ID3 stream sees ID2 prices for hours 0-11 and ID3 prices for hours 12-23")
check(p_bal[24] == 93.0, "BAL stream sees the balancing prices")

# --- unknown gate / never-priced day fail loudly ------------------------------
try
    prices_as_of_gate(mp, "2024-07-08", "ID4")
    check(false, "unknown gate raises ArgumentError")
catch e
    check(e isa ArgumentError, "unknown gate raises ArgumentError")
end
try
    prices_as_of_gate(mp, "2024-12-25", "DA")
    check(false, "day absent from market_prices.csv raises ArgumentError")
catch e
    check(e isa ArgumentError, "day absent from market_prices.csv raises ArgumentError")
end

# --- Grid-purchase risk floor: free sun beats "free" grid power ----------------
free_sun = adapt_csp_to_market_stage("DA", "2024-07-08";
    plant = mkplant(),                    # grid_price_floor = 2 EUR/MWh
    demand = zeros(24),
    solar_forecast = ones(24),              # per-unit sun all day
    buy_price = zeros(24), sell_price = zeros(24),
    q0 = 0.0)
check(free_sun.solved, "zero-price stage with free sun solves ($(free_sun.termination))")
check(sum(free_sun.p_buy) == 0.0,
      "at zero prices the tank is filled from the SUN, not from the grid (risk floor)")
check(sum(free_sun.s_solar) > 0.0, "the field collects heat to reach the terminal floor")
paid = adapt_csp_to_market_stage("DA", "2024-07-08";
    plant = mkplant(),
    demand = zeros(24),
    solar_forecast = ones(24),
    buy_price = -5.0 .* ones(24), sell_price = zeros(24),
    q0 = 0.0)
check(paid.solved && sum(paid.p_buy) > 0.0,
      "at NEGATIVE prices the plant buys (is paid to consume), floor does not apply")
check(paid.solved && maximum(paid.p_buy) <= 50.0 + 1e-6,
      "purchases respect the electric-heater rating (pmax_charge_e)")


# --- end-to-end on synthetic cleared prices (real 2024-07-08 solar file) ------
mktempdir() do tmp
    CSV.write(joinpath(tmp, "market_prices.csv"), mp)
    plants_csv = joinpath(tmp, "plants.csv")
    CSV.write(plants_csv, DataFrame(
        plant_id = ["t"], bus_id = ["ES0"], solar_capacity_mwth = [60.0],
        pmax_e_mwe = [35.0], tes_capacity_mwhth = [180.0],
        q0_start_mwhth = [70.0], q_end_target_mwhth = [70.0],
        eta_solar = [0.80], eta_power = [0.38], eta_charge = [0.80],
        thermal_leak_rate = [0.01], pmax_charge_e_mwe = [50.0],
        buy_from_grid = [true], allow_sell = [true],
        grid_price_floor_eur_mwh = [2.0], vom_eur_mwh = [0.0]))
    out = run_csp_option_b(results_dir = tmp;
        csp_cfg = Dict("gates" => ["DA", "BAL"], "plants_file" => plants_csv,
                       "plant_id" => "t"))
    check(isfile(joinpath(tmp, "csp", "csp_summary.csv")), "Option B writes csp_summary.csv")
    check(isfile(joinpath(tmp, "csp", "csp_da_dispatch.csv")), "Option B writes the DA stream dispatch")
    sm = out[:summary]
    check(nrow(sm) == 2, "summary has one row per (gate, day)")
    da = sm[sm.gate .== "DA", :][1, :]
    check(da.solved, "DA stream solves on synthetic cleared prices ($(da.termination))")
    dispatch = CSV.read(joinpath(tmp, "csp", "csp_da_dispatch.csv"), DataFrame)
    dstr = string.(dispatch.date)                  # date column parses as Date
    night = (dstr .== "2024-07-08") .& (dispatch.hour .<= 5)
    check(all(dispatch.s_solar_mwth[night] .== 0.0),
          "the field collects no heat at night (solar-geometry shape applied)")
    day = (dstr .== "2024-07-08") .& (dispatch.hour .>= 8) .& (dispatch.hour .<= 18)
    check(any(dispatch.s_solar_mwth[day] .> 0.0),
          "the field collects heat during the day")
    check(count(dispatch.s_solar_mwth[dstr .== "2024-07-08"] .> 0.0) >= 10,
          "collection spans roughly the whole daylight window")
    check(isapprox(da.net_eur,
                   sum(dispatch.price_eur_mwh .* (dispatch.p_gen_mw .- dispatch.p_buy_mw));
                   atol = 1e-4),
          "stream cash flow equals the hourly dispatch valued at cleared prices")
    check(isapprox(da.objective_eur, -da.net_eur - da.theta_future_eur; atol = 1e-4),
          "stage objective equals -(net cash flow + continuation value)")
    try
        run_csp_option_b(results_dir = tmp; csp_cfg = Dict("gates" => ["ID4"]))
        check(false, "[csp].gates with an unknown gate raises ArgumentError")
    catch e
        check(e isa ArgumentError, "[csp].gates with an unknown gate raises ArgumentError")
    end
    try
        run_csp_option_b(results_dir = tmp; csp_cfg = Dict("gates" => ["DA"]))
        check(false, "csp_cfg without plants_file raises ArgumentError")
    catch e
        check(e isa ArgumentError && occursin("plants_file", e.msg),
              "csp_cfg without plants_file raises ArgumentError (no default plant)")
    end
    try
        run_csp_option_b(results_dir = tmp;
            csp_cfg = Dict("gates" => ["DA"], "plants_file" => plants_csv,
                           "plant_id" => "missing"))
        check(false, "plant_id absent from the plants file raises ArgumentError")
    catch e
        check(e isa ArgumentError && occursin("missing", e.msg),
              "plant_id absent from the plants file raises ArgumentError (no fallback)")
    end
    try
        run_csp_option_b(results_dir = joinpath(tmp, "missing"))
        check(false, "results_dir without market_prices.csv raises ArgumentError")
    catch e
        check(e isa ArgumentError, "results_dir without market_prices.csv raises ArgumentError")
    end

    # --- TES hands over across consecutive days, resets across gaps ----------
    for h in 0:23
        push!(mp, ("2024-07-09", h, "DA", 45.0 + h))     # consecutive day
        push!(mp, ("2024-12-02", h, "DA", 55.0 + h))     # far-away day
    end
    CSV.write(joinpath(tmp, "market_prices.csv"), mp)
    out3 = run_csp_option_b(results_dir = tmp;
        csp_cfg = Dict("gates" => ["DA"], "plants_file" => plants_csv,
                       "plant_id" => "t"))
    s3 = out3[:summary]
    check(nrow(s3) == 3, "target_days = nothing dispatches every day in the price file")
    check(isapprox(s3[1, :q_end_mwhth], s3[2, :q0_mwhth]; atol = 1e-6),
          "TES hands over q_end -> next day's q0 across consecutive days")
    check(isapprox(s3[3, :q0_mwhth], 70.0; atol = 1e-9),
          "TES resets to q0_start across the July -> December gap")
end


# =============================================================================
# Thermal value SDDP — the ReSDDP/water-value analog (CSP/thermal_value_sddp.jl)
# =============================================================================
include(joinpath(@__DIR__, "..", "CSP", "thermal_value_sddp.jl"))

tv_plant = get_csp_plant(joinpath(@__DIR__, "..", "Data", "csp_plants.csv"), "demo")
tv_scen  = default_scenario_set(tv_plant)
check(sum(s.prob for s in tv_scen) ≈ 1.0,
      "thermal-value branch probabilities sum to 1")
check(all(length(s.sell_price) == 24 && length(s.solar_avail) == 24 for s in tv_scen),
      "every branch has 24-hour price and solar-availability profiles")
check(all(all(s.solar_avail[1:7] .== 0.0) for s in tv_scen),
      "branch solar availability is zero through the night (hours 0-6)")
check(tv_scen[1].sell_price[11] < tv_scen[3].sell_price[11],
      "clear weather has the deeper midday price dip (PV glut)")

# --- cut arithmetic: value = max over cuts, thermal value = -binding slope ----
hc = [ThermalValueCut(1, -20.0, 100.0), ThermalValueCut(1, -5.0, 0.0)]
check(value_at(hc, 0.0) == 100.0 && binding_thermal_value(hc, 0.0) == 20.0,
      "first cut binds at an empty tank: value 100 EUR, thermal value 20 EUR/MWh_th")
check(value_at(hc, 10.0) == -50.0 && binding_thermal_value(hc, 10.0) == 5.0,
      "second cut binds at 10 MWh_th: value -50 EUR, thermal value 5 EUR/MWh_th")

# --- deterministic training (one branch, two stages): SDDP = exact DP --------
# (a single branch gives all forward trajectories the same trial states, so the
# cut set converges to the kinks of V only from the states it visits — a small
# residual gap around a kink is expected SDDP behaviour, ReSDDP's included)
det_scen = [ThermalDayScenario("only", 1.0, tv_scen[2].sell_price,
                               tv_scen[2].solar_avail)]
cuts_det, conv_det = train_thermal_value(tv_plant, det_scen,
    ThermalValueSettings(n_stages = 2, n_scen = 4, max_iter = 15,
                         conv_eps = 1e-4, seed = 7, verbose = false))
det_gap = conv_det.upper_bound[end] - conv_det.lower_bound[end]
check(abs(conv_det.rel_gap[end]) < 5e-3,
      "deterministic training converges (rel gap $(round(abs(conv_det.rel_gap[end]), sigdigits = 2)))")
check(abs(det_gap) < 50.0,
      "deterministic SDDP nearly closes the gap: upper - lower = $(round(abs(det_gap), digits = 2)) EUR")
check(all(c.slope <= 1e-9 for stage_cuts in cuts_det for c in stage_cuts),
      "deterministic cut slopes are <= 0 (thermal value non-negative)")

# --- stochastic training on the three-branch archetype set -------------------
cuts_st, _ = train_thermal_value(tv_plant, tv_scen,
    ThermalValueSettings(n_stages = 4, n_scen = 6, max_iter = 6,
                         conv_eps = 1e-3, seed = 11, verbose = false))
check(all(c.slope <= 1e-9 for stage_cuts in cuts_st for c in stage_cuts),
      "stochastic cut slopes are <= 0 across all stages")
curve = thermal_value_curve(cuts_st[1], tv_plant)
check(all(diff(curve.value_eur) .<= 1e-9),
      "the cost-to-go V(q) is non-increasing in the tank level")
check(all(diff(curve.thermal_value_eur_per_mwhth) .<= 1e-9),
      "the thermal value is non-increasing in the tank level (fuller tank -> cheaper heat)")

# --- applying the trained policy: floor, balance, round-trip ------------------
r_tv = solve_day_with_thermal_value(tv_plant, cuts_st[1],
    tv_scen[1].sell_price, tv_scen[1].solar_avail; q0 = tv_plant.q_end_target_mwhth)
check(r_tv.q_end >= tv_plant.q_end_target_mwhth - 1e-6,
      "the trained policy respects the daily TES floor")
check(r_tv.thermal_value_end >= 0.0,
      "the thermal value at the end state is non-negative")
leak_sum = sum(tv_plant.thermal_leak_rate * r_tv.q_tes[i] for i in 1:24)
dis_sum  = sum(r_tv.p_gen) / tv_plant.eta_power
balance  = r_tv.q_tes[1] + tv_plant.eta_solar * sum(r_tv.s_solar) +
           tv_plant.eta_charge * sum(r_tv.p_buy) - dis_sum - leak_sum
check(isapprox(r_tv.q_tes[25], balance; atol = 1e-4),
      "the trained dispatch closes the TES energy balance")

mktempdir() do tmp
    p = save_cuts(cuts_st, joinpath(tmp, "cuts.csv"))
    dfc = CSV.read(p, DataFrame)
    check(nrow(dfc) == sum(length(c) for c in cuts_st),
          "save_cuts writes one row per cut")
    check(isapprox(dfc.slope_eur_per_mwhth[1], cuts_st[1][1].slope; atol = 0) &&
          isapprox(dfc.intercept_eur[1], cuts_st[1][1].intercept; atol = 0),
          "cuts.csv round-trips slope and intercept exactly")
    check(dfc.thermal_value_eur_per_mwhth[1] == -cuts_st[1][1].slope,
          "cuts.csv thermal-value column equals -slope (the BellmanValuesOUT convention)")
end

# --- no silent defaults: the scenario source must be explicit -----------------
try
    train_thermal_value(tv_plant)
    check(false, "train_thermal_value without scenarios raises an explicit error")
catch e
    check(e isa ErrorException && occursin("scenario", e.msg),
          "train_thermal_value without scenarios raises an explicit error (no silent default)")
end

try
    _demo_scenarios(String[], tv_plant)
    check(false, "the demo refuses to run without an explicit scenario source")
catch e
    check(e isa ErrorException && occursin("--scenarios", e.msg),
          "the demo refuses to run without an explicit scenario source (usage message)")
end

sc, src = _demo_scenarios(["--archetypes"], tv_plant)
check(length(sc) == 3 && src == "SYNTHETIC archetypes",
      "--archetypes explicitly opts in to the synthetic branch set")

# --- no default PLANT either: the demos demand --plants-file/--plant-id ---------
plants_file = joinpath(@__DIR__, "..", "Data", "csp_plants.csv")
try
    _demo_plant(String[])
    check(false, "the SDDP demo refuses to run without --plants-file/--plant-id")
catch e
    check(e isa ErrorException && occursin("no default plant", e.msg),
          "the SDDP demo refuses to run without --plants-file/--plant-id (no default plant)")
end
p_demo, rest_demo = _demo_plant(["--plants-file", plants_file, "--plant-id", "demo", "--archetypes"])
check(p_demo.plant_id == "demo" && rest_demo == ["--archetypes"],
      "the SDDP demo loads its plant from the plants file and forwards the scenario flags")
try
    CSP._demo_plant_args(String[])
    check(false, "the standalone demo refuses to run without --plants-file/--plant-id")
catch e
    check(e isa ErrorException && occursin("no default plant", e.msg),
          "the standalone demo refuses to run without --plants-file/--plant-id (no default plant)")
end
p2 = CSP._demo_plant_args(["--plants-file", plants_file, "--plant-id", "demo"])
check(p2.plant_id == "demo",
      "the standalone demo loads its plant from the plants-file row named on the command line")

mktempdir() do tmp
    rows = (name = String[], prob = Float64[], hour = Int[],
            price_eur_mwh = Float64[], solar_avail_mwth = Float64[])
    sub = tv_scen[1:2]
    tot = sum(s.prob for s in sub)
    for s in sub, h in 0:23
        push!(rows.name, s.name); push!(rows.prob, s.prob / tot)
        push!(rows.hour, h)
        push!(rows.price_eur_mwh, s.sell_price[h + 1])
        push!(rows.solar_avail_mwth, s.solar_avail[h + 1])
    end
    br = joinpath(tmp, "branches.csv")
    CSV.write(br, rows)
    rs = read_thermal_scenarios(br)
    check(length(rs) == 2 && sum(s.prob for s in rs) ≈ 1.0,
          "read_thermal_scenarios loads branches from CSV")
    check(rs[1].sell_price == tv_scen[1].sell_price &&
          rs[1].solar_avail == tv_scen[1].solar_avail,
          "the CSV round-trip preserves the hourly profiles")
    sc2, src2 = _demo_scenarios(["--scenarios", br], tv_plant)
    check(length(sc2) == 2 && src2 == br,
          "--scenarios loads the custom branch set from the command line")
    try
        read_thermal_scenarios(joinpath(tmp, "missing.csv"))
        check(false, "a missing scenario file raises an error")
    catch e
        check(e isa ErrorException, "a missing scenario file raises an error")
    end
    rows2 = (name = rows.name, prob = rows.prob ./ 2.0, hour = rows.hour,
             price_eur_mwh = rows.price_eur_mwh, solar_avail_mwth = rows.solar_avail_mwth)
    CSV.write(br, rows2)
    try
        read_thermal_scenarios(br)
        check(false, "branch probabilities that do not sum to 1 raise an error")
    catch e
        check(e isa ErrorException && occursin("sum to", e.msg),
              "branch probabilities that do not sum to 1 raise an error")
    end
end

# =============================================================================
# Option A — the da.jl TES block vs the standalone LP (design doc A.8 #1)
# =============================================================================
const BASEMVA = 100.0
include(joinpath(@__DIR__, "..", "da.jl"))

begin
    # with_grid_charging copies every field and flips only the flag
    wg = CSP.with_grid_charging(demo_row, false)
    check(wg.buy_from_grid == false && wg.plant_id == demo_row.plant_id &&
          wg.bus_id == demo_row.bus_id &&
          wg.tes_capacity_mwhth == demo_row.tes_capacity_mwhth &&
          wg.eta_power == demo_row.eta_power &&
          wg.pmax_charge_e_mwe == demo_row.pmax_charge_e_mwe,
          "with_grid_charging copies the row and flips only buy_from_grid")

    plant_e = mkplant(buy_from_grid = false)
    factor  = CSP.load_solar_forecast("2024-07-08", "DA")
    shape   = CSP.solar_thermal_shape("2024-07-08")
    avail   = plant_e.solar_capacity_mwth .* factor .* shape
    prices  = [40.0, 38.0, 36.0, 35.0, 35.0, 38.0, 45.0, 55.0, 30.0, 12.0, 0.0, 0.0,
               0.0, 0.0, 5.0, 25.0, 48.0, 70.0, 88.0, 102.0, 95.0, 60.0, 45.0, 42.0]
    # persistence cut in COST form — exactly what solve_csp_market_stage builds
    # from the same future expectations (slope = -a1 of the reward cut)
    fp    = 60.0
    fprof = avail ./ plant_e.solar_capacity_mwth
    a1    = plant_e.eta_power * fp * max(0.0, 1.0 - mean(fprof))
    cuts  = [(-a1, 0.0)]

    # (a) the embedded block: a price-taker mini-model with the da.jl physics
    model = Model(HiGHS.Optimizer)
    set_silent(model)
    pg_by_name = Dict{Tuple{Int,String},JuMP.VariableRef}()
    for t in 1:24
        pg_by_name[(t, "CSP_test")] = @variable(model,
            lower_bound = 0.0, upper_bound = plant_e.pmax_e_mwe / BASEMVA)
    end
    csp_arg = (units = [plant_e], q0 = Dict("test" => 70.0),
               avail = Dict("test" => avail), cuts = Dict("test" => cuts),
               s_th_pin = Dict{String,Vector{Union{Nothing,Float64}}}())
    blk = _add_csp_tes_block!(model, pg_by_name, csp_arg, 24)
    @objective(model, Min,
        sum(-prices[t] * pg_by_name[(t, "CSP_test")] * BASEMVA for t in 1:24) +
        blk["CSP_test"].theta)
    optimize!(model)
    @assert termination_status(model) == MOI.OPTIMAL
    pg_emb  = [value(pg_by_name[(t, "CSP_test")]) * BASEMVA for t in 1:24]
    q_emb   = value.(blk["CSP_test"].q)
    s_emb   = value.(blk["CSP_test"].s_th)
    th_emb  = value(blk["CSP_test"].theta)
    obj_emb = objective_value(model)

    # (b) the standalone LP on identical inputs
    res_ref = solve_csp_market_stage(CSPMarketInputs(
        stage = "DA", date_str = "2024-07-08",
        demand = zeros(24), solar_forecast = fprof,
        buy_price = prices, sell_price = prices,
        solar_capacity = plant_e.solar_capacity_mwth, pmax_e = plant_e.pmax_e_mwe,
        tes_capacity = plant_e.tes_capacity_mwhth, q0 = 70.0,
        q_end_target = plant_e.q_end_target_mwhth,
        eta_solar = plant_e.eta_solar, eta_power = plant_e.eta_power,
        eta_charge = plant_e.eta_charge, thermal_leak_rate = plant_e.thermal_leak_rate,
        buy_from_grid = false, allow_sell = true,
        grid_price_floor = plant_e.grid_price_floor_eur_mwh,
        pmax_charge_e = plant_e.pmax_charge_e_mwe,
        future_solar_forecast = fprof, future_sell_price = fp))
    @assert res_ref.solved

    # The embedded theta is recentred at q0 (da.jl reports the storage delta),
    # so the objectives differ by the constant a1*q0 and theta_emb by the same.
    check(isapprox(obj_emb - 70.0 * a1, res_ref.objective; atol = 1e-3),
          "the da.jl TES block reproduces the standalone objective up to the recentring constant (A.8 #1)")
    check(maximum(abs.(pg_emb .- res_ref.p_gen)) < 1e-6,
          "the da.jl TES block reproduces the standalone hourly generation")
    check(isapprox(q_emb[end], res_ref.q_tes[end]; atol = 1e-6),
          "the da.jl TES block hands over the same terminal TES level")
    check(isapprox(sum(s_emb), sum(res_ref.s_solar); atol = 1e-6),
          "the da.jl TES block collects the same total solar heat")
    check(isapprox(th_emb, 70.0 * a1 - res_ref.theta_future; atol = 1e-6),
          "the embedded theta is the standalone continuation value recentred at q0")

    # (c) the pin: a settled hour's collection is frozen even when the later
    # gate's forecast (availability bound) disagrees
    model2 = Model(HiGHS.Optimizer)
    set_silent(model2)
    pg2 = Dict{Tuple{Int,String},JuMP.VariableRef}()
    for t in 1:24
        pg2[(t, "CSP_test")] = @variable(model2,
            lower_bound = 0.0, upper_bound = plant_e.pmax_e_mwe / BASEMVA)
    end
    pin = Dict("test" => Vector{Union{Nothing,Float64}}(nothing, 24))
    pin["test"][3] = 10.0                      # settled: 10 MW_th collected at h2
    @assert avail[3] == 0.0                     # night hour: the later gate sees no sun
    csp_pin = (units = [plant_e], q0 = Dict("test" => 70.0),
               avail = Dict("test" => avail), cuts = Dict("test" => []),
               s_th_pin = pin)
    blk2 = _add_csp_tes_block!(model2, pg2, csp_pin, 24)
    @objective(model2, Min,
        sum(-prices[t] * pg2[(t, "CSP_test")] * BASEMVA for t in 1:24) + blk2["CSP_test"].theta)
    optimize!(model2)
    @assert termination_status(model2) == MOI.OPTIMAL
    check(value(blk2["CSP_test"].s_th[3]) == 10.0,
          "a pinned (settled) hour keeps its collection even past the availability bound")
end

println("\nAll ", N_CHECKS[], " CSP smoke-test checks passed.")