# ============================================================
# EMPIRE nodal disaggregation — NUTS3 results → bus-level grid
# ============================================================
# Improves on the zonal disaggregation in empire_scenario.jl (one national
# growth ratio per tech, corridor investments dropped) by mapping the EMPIRE
# expansion results onto the bus-level grid at NUTS3 resolution:
#
#   1. Bus → NUTS3 assignment.  Every Bus_Data.csv bus is placed in a NUTS3
#      polygon (Data/nuts3_es.geojson) by point-in-polygon; coastal buses that
#      miss every polygon snap to the nearest one.  Cached in Data/bus_nuts3.csv.
#
#   2. Generation.  Per (NUTS3, tech) the existing unit fleet is scaled so the
#      regional capacity matches EMPIRE's genInstalledCap exactly (national
#      totals then match by construction).  Where EMPIRE builds a tech in a
#      region that has no such units today, new units are created on the
#      region's highest-load buses (load-proportional split).  Hydro and
#      nuclear are site-bound: no new units are created — regional targets
#      without units are redistributed over the existing fleet of that tech.
#
#   3. Transmission.  EMPIRE's corridor capacities (NUTS3 pair → MW,
#      previously discarded) become per-line expansion factors: every
#      physical line crossing a corridor is scaled by
#      installed(period)/initial, modelled as parallel circuits (rating ×f,
#      series impedance /f, shunt ×f).  Corridors EMPIRE builds where no
#      physical line exists today get a synthetic 400 kV line between the
#      strongest buses of the two regions.  ES↔FR/PT corridors go through the
#      same treatment: interconnection EMPIRE holds or builds on a NUTS3 that
#      no border line reaches today (Biscay Gulf HVDC, the new Navarra–France
#      corridor) is synthesised onto the country's nearest terminal bus, capped
#      at the country-level shortfall so a misassigned terminal bus cannot
#      double-count.
#
#   4. Storage.  The Li-Ion BESS fleet is sited per NUTS3 node (previously a
#      national top-20-load-bus split): each node's power is spread over the
#      region's buses in proportion to the thermal capacity of the AC lines
#      connected at each bus (2035 grid: corridor scaling + synthetic lines
#      included), and capped at that incident-line capacity so a battery can
#      never be scheduled beyond what its bus can physically import/export.
#      Power that no bus of the region can host spills over to other regions'
#      buses with remaining headroom.  Pumped-storage power is matched per
#      region onto the existing PHS units.
#
# Consumed by run_market_chain.jl / data_preparation.jl when
# config.toml → [scenario] disaggregation = "nodal".
#
# Standalone diagnostics (writes results/<label>/nodal/*.csv and a summary):
#   julia --project=. empire_nodal.jl
# ============================================================

using CSV, DataFrames, JSON, Printf, Statistics

# ── 1. Bus → NUTS3 assignment ───────────────────────────────

# Even-odd ray casting: point (px,py) against one closed ring [[lon,lat],…].
function _point_in_ring(px::Float64, py::Float64, ring)::Bool
    inside = false
    n = length(ring)
    j = n
    for i in 1:n
        xi, yi = Float64(ring[i][1]), Float64(ring[i][2])
        xj, yj = Float64(ring[j][1]), Float64(ring[j][2])
        if (yi > py) != (yj > py) &&
           px < (xj - xi) * (py - yi) / (yj - yi) + xi
            inside = !inside
        end
        j = i
    end
    return inside
end

# Squared degree-distance from a point to the nearest vertex of any ring
# (good enough to snap coastal buses to the right region).
function _min_vertex_dist2(px::Float64, py::Float64, rings)::Float64
    d2 = Inf
    for ring in rings, v in ring
        d2 = min(d2, (Float64(v[1]) - px)^2 + (Float64(v[2]) - py)^2)
    end
    return d2
end

"""
    nuts3_regions(; data_dir) -> Vector{(id::String, rings::Vector)}

Parse Data/nuts3_es.geojson into flat vertex-ring lists per NUTS3 region
(holes kept: even-odd counting over all rings is hole-correct).
"""
function nuts3_regions(; data_dir = joinpath(@__DIR__, "Data"))
    gj = JSON.parsefile(joinpath(data_dir, "nuts3_es.geojson"))
    out = Tuple{String,Vector{Any}}[]
    for f in gj["features"]
        id   = String(f["properties"]["NUTS_ID"])
        geom = f["geometry"]
        rings = Any[]
        if geom["type"] == "Polygon"
            append!(rings, geom["coordinates"])
        elseif geom["type"] == "MultiPolygon"
            for poly in geom["coordinates"]
                append!(rings, poly)
            end
        end
        push!(out, (id, rings))
    end
    return out
end

"""
    bus_nuts3(; data_dir, refresh = false) -> Dict{String,String}

bus_id → NUTS3 region for every Spanish bus (foreign border buses map to
their country code "FR"/"PT").  Cached in Data/bus_nuts3.csv — delete the
cache (or pass refresh = true) after a Bus_Data.csv change.
"""
function bus_nuts3(; data_dir = joinpath(@__DIR__, "Data"), refresh::Bool = false)
    cache = joinpath(data_dir, "bus_nuts3.csv")
    if isfile(cache) && !refresh
        df = CSV.read(cache, DataFrame)
        return Dict(String(r.bus_id) => String(r.nuts3) for r in eachrow(df))
    end
    regions = nuts3_regions(data_dir = data_dir)
    bus_df  = CSV.read(joinpath(data_dir, "Bus_Data.csv"), DataFrame)
    rows = NamedTuple[]
    for r in eachrow(bus_df)
        ctry = String(r.country)
        if ctry != "ES"
            push!(rows, (bus_id = String(r.bus_id), nuts3 = ctry, method = "country"))
            continue
        end
        px, py = Float64(r.x), Float64(r.y)          # x = lon, y = lat
        hit = ""
        for (id, rings) in regions
            inside = false
            for ring in rings
                _point_in_ring(px, py, ring) && (inside = !inside)
            end
            inside && (hit = id; break)
        end
        method = "polygon"
        if isempty(hit)                                # coastal miss → snap
            best = Inf
            for (id, rings) in regions
                d2 = _min_vertex_dist2(px, py, rings)
                d2 < best && (best = d2; hit = id)
            end
            method = "nearest"
        end
        push!(rows, (bus_id = String(r.bus_id), nuts3 = hit, method = method))
    end
    df = DataFrame(rows)
    CSV.write(cache, df)
    return Dict(String(r.bus_id) => String(r.nuts3) for r in eachrow(df))
end

# ── 2. Generation disaggregation ────────────────────────────

# EMPIRE tech → (primary_fuel, technology) used when CREATING new units.
# (The forward unit→tech map for the existing fleet is EMPIRE_UNIT_TECH in
# empire_scenario.jl.)
const NODAL_NEW_FT = Dict(
    "Solar"                   => ("Solar",   "PV"),
    "Wind onshore"            => ("Wind",    "Onshore"),
    "Wind offshore grounded"  => ("Wind",    "Offshore"),
    "Wind offshore floating"  => ("Wind",    "Offshore"),
    "Gas CCGT"                => ("Gas",     "Combined_cycle"),
    "Gas OCGT"                => ("Gas",     "Gas_turbine"),
    "Gas CCS"                 => ("Gas",     "Gas_CCS"),
    "Coal"                    => ("Coal",    "Coal"),
    "Coal CCS"                => ("Coal",    "Coal_CCS"),
    "Lignite"                 => ("Lignite", "Lignite"),
    "Lignite CCS"             => ("Lignite", "Lignite_CCS"),
    "Bio"                     => ("Biomass", "Biomass"),
    "Bio CCS"                 => ("Biomass", "BioCCS"),
    "Oil"                     => ("Oil",     "Combined_cycle"),
    "Waste"                   => ("Waste",   "Waste"),
    "Geo"                     => ("Geo",     "Geo"),
)

# Site-bound techs: never create greenfield units; regional targets in
# regions without such units are spread over the existing fleet instead.
const NODAL_NO_NEW = Set(["Hydro regulated", "Hydro run-of-the-river", "Nuclear"])

_slug(t) = replace(String(t), " " => "", "-" => "")

# Top-n load buses of a region with normalised weights.
function _region_site_buses(region::String, b2r::Dict{String,String},
                            load_df::DataFrame; top_n::Int = 3)
    rows = [(String(r.bus_id), Float64(r.demand)) for r in eachrow(load_df)
            if get(b2r, String(r.bus_id), "") == region]
    isempty(rows) && return Tuple{String,Float64}[]
    sort!(rows, by = r -> r[2], rev = true)
    rows = rows[1:min(top_n, length(rows))]
    wtot = sum(r[2] for r in rows)
    wtot > 0 || (rows = [(rows[1][1], 1.0)]; wtot = 1.0)
    return [(b, w / wtot) for (b, w) in rows]
end

"""
    nodal_unit_scale(emp; data_dir, top_n, min_new_mw)
        -> (scale, new_units, gen_diag)

Per-unit capacity factors (`scale :: unit_id ⇒ factor`) and greenfield units
(`new_units :: DataFrame(unit_id, bus_id, primary_fuel, technology, name,
capacity_mw)`) such that per (NUTS3, tech) the fleet matches EMPIRE's
installed capacity at the period.  Regions EMPIRE covers but the grid does
not (no buses, e.g. islands off the modelled network) have their targets
redistributed proportionally over the mapped regions of the same tech.
"""
function nodal_unit_scale(emp; data_dir = joinpath(@__DIR__, "Data"),
                          top_n::Int = 3, min_new_mw::Float64 = 1.0)
    b2r     = bus_nuts3(data_dir = data_dir)
    gen_df  = CSV.read(joinpath(data_dir, "generations.csv"), DataFrame)
    load_df = CSV.read(joinpath(data_dir, "load.csv"),        DataFrame)
    regions_with_buses = Set(v for v in values(b2r) if startswith(v, "ES"))

    # existing units grouped by EMPIRE tech and region
    units = Dict{String,Dict{String,Vector{Tuple{String,Float64}}}}() # tech→region→[(id,MW)]
    for r in eachrow(gen_df)
        key = (String(r.primary_fuel), String(r.technology))
        haskey(EMPIRE_UNIT_TECH, key) || continue        # pumped storage → storage path
        t   = EMPIRE_UNIT_TECH[key]
        reg = get(b2r, String(r.bus_id), "")
        startswith(reg, "ES") || continue
        push!(get!(get!(units, t, Dict{String,Vector{Tuple{String,Float64}}}()),
                   reg, Tuple{String,Float64}[]),
              (String(r.unit_id), Float64(r.capacity_mw)))
    end

    scale     = Dict{String,Float64}()
    new_rows  = NamedTuple[]
    diag_rows = NamedTuple[]
    for (tech, tgt_by_reg) in emp.caps_nuts
        u_by_reg = get(units, tech, Dict{String,Vector{Tuple{String,Float64}}}())

        # split targets into mapped regions vs off-grid regions
        placed = Dict{String,Float64}()
        orphan_offgrid = 0.0
        for (reg, mw) in tgt_by_reg
            reg in regions_with_buses ? (placed[reg] = mw) : (orphan_offgrid += mw)
        end
        if orphan_offgrid > 1e-3 && !isempty(placed)
            ptot = sum(values(placed))
            ptot > 1e-3 && (for k in keys(placed); placed[k] *= 1 + orphan_offgrid/ptot; end)
        end

        allow_new = !(tech in NODAL_NO_NEW) && haskey(NODAL_NEW_FT, tech)
        orphan_nosite = 0.0                    # target w/o units, tech site-bound
        ex_total = sum(c for regu in values(u_by_reg) for (_, c) in regu; init = 0.0)

        for reg in union(keys(placed), keys(u_by_reg))
            tgt = get(placed, reg, 0.0)
            ru  = get(u_by_reg, reg, Tuple{String,Float64}[])
            ex  = sum(c for (_, c) in ru; init = 0.0)
            f   = 0.0
            nnew, mwnew = 0, 0.0
            if ex > 1e-3
                f = tgt / ex
                for (id, _) in ru; scale[id] = f; end
            elseif tgt > min_new_mw
                if allow_new
                    fuel, tec = NODAL_NEW_FT[tech]
                    for (k, (bus, w)) in enumerate(_region_site_buses(reg, b2r, load_df; top_n))
                        mw = tgt * w
                        mw > min_new_mw || continue
                        id = "NEW_$(_slug(tech))_$(reg)_$(k)"
                        push!(new_rows, (unit_id = id, bus_id = bus,
                                         primary_fuel = fuel, technology = tec,
                                         name = id, capacity_mw = mw))
                        scale[id] = 1.0        # already at target size
                        nnew += 1; mwnew += mw
                    end
                else
                    orphan_nosite += tgt
                end
            end
            push!(diag_rows, (tech = tech, region = reg, existing_mw = ex,
                              target_mw = tgt, factor = f,
                              new_units = nnew, new_mw = mwnew))
        end

        # site-bound orphan capacity → uniform additive factor over the fleet
        if orphan_nosite > 1e-3 && ex_total > 1e-3
            bump = orphan_nosite / ex_total
            for regu in values(u_by_reg), (id, _) in regu
                scale[id] = get(scale, id, 0.0) + bump
            end
        end
    end

    # techs EMPIRE retired entirely (absent from caps_nuts): factor 0, not 1
    for (tech, u_by_reg) in units
        haskey(emp.caps_nuts, tech) && continue
        for (reg, regu) in u_by_reg
            ex = sum(c for (_, c) in regu; init = 0.0)
            for (id, _) in regu; scale[id] = 0.0; end
            push!(diag_rows, (tech = tech, region = reg, existing_mw = ex,
                              target_mw = 0.0, factor = 0.0,
                              new_units = 0, new_mw = 0.0))
        end
    end

    new_units = isempty(new_rows) ?
        DataFrame(unit_id = String[], bus_id = String[], primary_fuel = String[],
                  technology = String[], name = String[], capacity_mw = Float64[]) :
        DataFrame(new_rows)
    return (scale = scale, new_units = new_units, gen_diag = DataFrame(diag_rows))
end

# ── 3. Transmission disaggregation ──────────────────────────

_haversine_km(lat1, lon1, lat2, lon2) =
    2 * 6371.0 * asin(min(1.0, sqrt(sind((lat2 - lat1)/2)^2 +
                     cosd(lat1) * cosd(lat2) * sind((lon2 - lon1)/2)^2)))

_pair(a::String, b::String) = a < b ? (a, b) : (b, a)

# EMPIRE foreign node → the country code Bus_Data.csv uses (and that bus_nuts3
# assigns to foreign buses).  Countries absent from the bus grid (Italy, the EU
# aggregate) are deliberately unmapped: their corridors stay diagnostic-only.
const NODAL_XB_COUNTRY = Dict("France" => "FR", "Portugal" => "PT")

# Terminal bus on the foreign side of a synthetic border corridor: the nearest
# bus of that country among those at its highest modelled voltage.  A 2 GW
# corridor must land on the 400 kV terminal rather than a 225 kV one — the
# synthetic line takes its terminal's voltage, since data_preparation.jl
# derives z_base and the thermal rating from the line's own `voltage` field.
function _nearest_foreign_bus(country::String, anchor::String, bus_df)
    cand = [r for r in eachrow(bus_df) if String(r.country) == country]
    isempty(cand) && return nothing
    kvmax = maximum(Float64(r.voltage) for r in cand)
    cand  = [r for r in cand if Float64(r.voltage) >= kvmax - 1e-6]
    ai = findfirst(==(anchor), String.(bus_df.bus_id))
    ai === nothing && return nothing
    ay, ax = Float64(bus_df[ai, :y]), Float64(bus_df[ai, :x])
    best, bd = nothing, Inf
    for r in cand
        d = _haversine_km(ay, ax, Float64(r.y), Float64(r.x))
        d < bd && (best = r; bd = d)
    end
    best === nothing && return nothing
    return (bus_id = String(best.bus_id), voltage = Float64(best.voltage), km = bd)
end

# Strongest bus of a region: prefer 400 kV, rank by connected line rating.
function _region_anchor_bus(region::String, b2r, bus_df, line_df)
    cap = Dict{String,Float64}()             # bus_id → Σ connected MW
    for r in eachrow(line_df)
        mw = sqrt(3) * Float64(r.voltage) * Float64(r.Imax) *
             max(Float64(r.circuits), 1.0)
        for b in (String(r.bus0), String(r.bus1))
            get(b2r, b, "") == region && (cap[b] = get(cap, b, 0.0) + mw)
        end
    end
    isempty(cap) && return nothing
    kv = Dict(String(r.bus_id) => Float64(r.voltage) for r in eachrow(bus_df))
    best, score = "", -Inf
    for (b, mw) in cap
        s = (get(kv, b, 0.0) >= 400 ? 1e9 : 0.0) + mw   # 400 kV first, then strength
        s > score && (best = b; score = s)
    end
    return best
end

"""
    nodal_line_scale(cfg; data_dir, new_corridor_min_mw)
        -> (line_scale, new_lines, corr_diag)

Per-line expansion factors from EMPIRE's corridor capacities:
factor = installed(period) / initial, applied to every physical line (AC or
HVDC) whose endpoints lie in the two NUTS3 regions of the corridor.  Factors
are floored at 1.0 (EMPIRE never has to de-rate the operating grid; raw
values < 1 are reported in the diagnostics).  Corridors with capacity but no
physical line get a synthetic 400 kV line between the two regions' anchor
buses, with median 400 kV per-length parameters and Imax sized so
√3·V·Imax = corridor MW.

ES↔FR/PT corridors are treated the same way, with one extra guard.  Their
foreign end is a country, not a NUTS3, so a border terminal bus that
point-in-polygon put in the neighbouring region would otherwise let the same
MW be scaled onto an existing line *and* synthesised as a new one.  The
capacity synthesised for a country is therefore capped at that country's
shortfall — EMPIRE's total installed interconnection minus what the scaled
physical border lines already carry — and split over the corridors that no
border line reaches, each landing on the nearest foreign terminal bus.
"""
function nodal_line_scale(cfg; data_dir = joinpath(@__DIR__, "Data"),
                          new_corridor_min_mw::Float64 = 50.0)
    scfg   = cfg["scenario"]
    dir    = joinpath(@__DIR__, String(scfg["empire_dir"]))
    period = Int(scfg["period"])
    b2r    = bus_nuts3(data_dir = data_dir)
    bus_df  = CSV.read(joinpath(data_dir, "Bus_Data.csv"), DataFrame)
    line_df = CSV.read(joinpath(data_dir, "lines.csv"),    DataFrame)

    # corridor capacities: initial (input) and installed at `period` (output).
    # Rows can be duplicated in the tabs → aggregate with max, not sum.
    init = Dict{Tuple{String,String},Float64}()
    df_i = CSV.read(joinpath(dir, "Input", "Tab", "Transmission_InitialCapacity.tab"),
                    DataFrame; delim = '\t', header = false, skipto = 2,
                    types = [String, String, Int, Float64])
    # Key: intra-ES corridors as an unordered NUTS3 pair; cross-border
    # corridors (ES NUTS3 ↔ France/Portugal/Italy/…) with the ES node first and
    # the foreign node reduced to its Bus_Data country code, so the key matches
    # the way border lines group below.  Countries outside the bus grid keep
    # their EMPIRE name and stay diagnostic-only.
    _xb(n) = get(NODAL_XB_COUNTRY, n, n)
    _corr_key(f, t) = startswith(f, "ES") && startswith(t, "ES") ? _pair(f, t) :
                      startswith(f, "ES") ? (f, _xb(t)) : (t, _xb(f))
    _corr_keep(f, t) = startswith(f, "ES") || startswith(t, "ES")
    for r in eachrow(df_i)
        r[3] == period || continue
        _corr_keep(String(r[1]), String(r[2])) || continue
        k = _corr_key(String(r[1]), String(r[2]))
        init[k] = max(get(init, k, 0.0), Float64(r[4]))
    end
    inst = Dict{Tuple{String,String},Float64}()
    df_o = CSV.read(joinpath(dir, "Output", "transmissionInstalledCap.tab"),
                    DataFrame; delim = '\t')
    for r in eachrow(df_o)
        Int(r.Period) == period || continue
        f, t = String(r.FromNode), String(r.ToNode)
        _corr_keep(f, t) || continue
        k = _corr_key(f, t)
        inst[k] = max(get(inst, k, 0.0), Float64(r.transmissionInstalledCap))
    end

    # Physical lines per corridor (both AC and HVDC cross-region lines).
    # bus_nuts3 tags foreign buses with their country code, so an ES↔FR/PT line
    # keys as (ES NUTS3, "FR"/"PT") — the same key shape _corr_key produces.
    corr_lines = Dict{Tuple{String,String},Vector{String}}()
    corr_mw    = Dict{Tuple{String,String},Float64}()      # Σ nameplate MW
    for r in eachrow(line_df)
        r0, r1 = get(b2r, String(r.bus0), ""), get(b2r, String(r.bus1), "")
        (isempty(r0) || isempty(r1) || r0 == r1) && continue
        es0, es1 = startswith(r0, "ES"), startswith(r1, "ES")
        (es0 || es1) || continue                  # foreign–foreign: not ours
        k = es0 && es1 ? _pair(r0, r1) : es0 ? (r0, r1) : (r1, r0)
        push!(get!(corr_lines, k, String[]), String(r.line_id))
        corr_mw[k] = get(corr_mw, k, 0.0) + sqrt(3) * Float64(r.voltage) *
                     Float64(r.Imax) * max(Float64(r.circuits), 1.0)
    end

    # Border-mismatch re-matching.  EMPIRE's corridor endpoints and our
    # point-in-polygon bus assignment can disagree for terminal buses sitting
    # right on a NUTS3 border (e.g. the Sagunto HVDC converter: EMPIRE corridor
    # ES523–ES532 vs the bus landing in ES522).  EMPIRE corridors with initial
    # capacity but no directly-crossing lines are therefore re-matched to
    # physical cross-region line groups that no EMPIRE corridor claims and
    # that share one region — picking the candidate whose aggregate nameplate
    # rating is closest to the EMPIRE initial capacity (EMPIRE's initial
    # corridor capacities were aggregated from these same line ratings).
    empire_keys = union(keys(init), keys(inst))
    free = Set(p for p in keys(corr_lines)
               if startswith(p[2], "ES") &&           # never re-match onto a border group
                  (!(p in empire_keys) ||
                   (get(init, p, 0.0) <= 1.0 && get(inst, p, 0.0) < new_corridor_min_mw)))
    unmatched = [k for k in empire_keys
                 if startswith(k[2], "ES") &&           # intra-ES only
                    get(init, k, 0.0) > 1.0 && isempty(get(corr_lines, k, String[]))]
    sort!(unmatched, by = k -> -get(init, k, 0.0))
    remap = Dict{Tuple{String,String},Tuple{String,String}}()
    for k in unmatched
        best, bd = nothing, Inf
        for p in free
            length(intersect(Set(k), Set(p))) == 1 || continue
            d = abs(corr_mw[p] - init[k])
            d < bd && (best = p; bd = d)
        end
        best === nothing && continue
        remap[k] = best
        delete!(free, best)
    end

    # Cross-border capacity that has no physical path.  Border lines are scaled
    # like any other corridor; what EMPIRE holds or builds on a NUTS3 no border
    # line reaches has to be synthesised.  Sizing that per corridor alone would
    # double-count whenever a terminal bus landed in the neighbouring NUTS3
    # (its MW would be scaled onto the existing line AND synthesised), so the
    # synthesised total per country is capped at the country-level shortfall
    # — EMPIRE's installed interconnection minus what the scaled border lines
    # already carry — and shared over the corridors that have no line.
    _corr_factor(k) = (get(init, k, 0.0) > 1.0 && !isempty(get(corr_lines, k, String[]))) ?
                      max(get(inst, k, 0.0) / init[k], 1.0) : 1.0
    xb_new = Dict{Tuple{String,String},Float64}()      # corridor ⇒ MW to synthesise
    xb_short = Dict{String,Float64}()                  # country  ⇒ shortfall MW
    for ctry in values(NODAL_XB_COUNTRY)
        ks = [k for k in empire_keys if k[2] == ctry]
        isempty(ks) && continue
        want = sum(get(inst, k, 0.0) for k in ks)
        have = sum(get(corr_mw, k, 0.0) * _corr_factor(k) for k in ks)
        short = max(want - have, 0.0)
        xb_short[ctry] = short
        orphans = [k for k in ks if isempty(get(corr_lines, k, String[])) &&
                                    get(inst, k, 0.0) >= new_corridor_min_mw]
        otot = sum(get(inst, k, 0.0) for k in orphans; init = 0.0)
        (short > new_corridor_min_mw && otot > 1e-3) || continue
        share = min(1.0, short / otot)                 # never exceed the shortfall
        for k in orphans; xb_new[k] = get(inst, k, 0.0) * share; end
    end

    # synthetic-line electrical parameters: median of the 400 kV AC lines
    m400 = filter(r -> Float64(r.voltage) == 400 && String(r.dc) == "f", line_df)
    r_pl, x_pl, c_pl = median(Float64.(m400.r_per_length)),
                       median(Float64.(m400.x_per_length)),
                       median(Float64.(m400.c_per_length))
    bxy = Dict(String(r.bus_id) => (Float64(r.y), Float64(r.x)) for r in eachrow(bus_df))

    line_scale = Dict{String,Float64}()
    new_rows   = NamedTuple[]
    diag_rows  = NamedTuple[]
    for k in empire_keys
        c_ini, c_ins = get(init, k, 0.0), get(inst, k, 0.0)
        if !startswith(k[2], "ES")                        # ES ↔ foreign corridor
            max(c_ini, c_ins) > 1.0 || continue
            raw   = c_ini > 1.0 ? c_ins / c_ini : Inf
            lines = get(corr_lines, k, String[])
            note  = ""
            if !(k[2] in values(NODAL_XB_COUNTRY))
                note = "country outside the bus grid: zonal NTC only"
            elseif !isempty(lines)                        # existing border lines
                f = max(raw, 1.0)
                raw < 0.99 && (note = "installed < initial; floored at 1.0")
                f > 1.0 + 1e-6 && (for l in lines; line_scale[l] = f; end)
            elseif haskey(xb_new, k)                      # no line: synthesise
                mw = xb_new[k]
                b0 = _region_anchor_bus(k[1], b2r, bus_df, line_df)
                fb = b0 === nothing ? nothing : _nearest_foreign_bus(k[2], b0, bus_df)
                if b0 === nothing || fb === nothing
                    note = "no anchor bus in $(k[1]) or no $(k[2]) terminal bus"
                else
                    (la0, lo0) = bxy[b0]
                    (la1, lo1) = bxy[fb.bus_id]
                    len  = max(_haversine_km(la0, lo0, la1, lo1) * 1.3, 10.0)
                    imax = mw / (sqrt(3) * fb.voltage)     # kA so √3·V·I = MW
                    push!(new_rows, (line_id = "NEWXB_$(k[1])_$(k[2])",
                                     bus0 = b0, bus1 = fb.bus_id,
                                     voltage = fb.voltage,
                                     circuits = 1.0, length = len, dc = "f",
                                     r_per_length = r_pl, x_per_length = x_pl,
                                     c_per_length = c_pl, Imax = imax))
                    note = @sprintf("synthetic border line %s - %s (%.0f MW, %.0f km)",
                                    b0, fb.bus_id, mw, len)
                end
            else
                note = "capacity already carried by the existing border lines"
            end
            push!(diag_rows, (from = k[1], to = k[2], initial_mw = c_ini,
                              installed_mw = c_ins,
                              factor = isfinite(raw) ? raw : NaN,
                              n_lines = length(lines), kind = "xborder",
                              note = note))
            continue
        end
        lines = get(corr_lines, k, String[])
        note  = ""
        if isempty(lines) && haskey(remap, k)
            lines = corr_lines[remap[k]]
            note  = "border mismatch: applied to $(remap[k][1])-$(remap[k][2]) lines"
        end
        raw = c_ini > 1.0 ? c_ins / c_ini : Inf
        if c_ini > 1.0 && !isempty(lines)                 # existing corridor
            f = max(raw, 1.0)
            raw < 0.99 && (note = "installed < initial; floored at 1.0")
            f > 1.0 + 1e-6 && (for l in lines; line_scale[l] = f; end)
        elseif c_ini > 1.0 && isempty(lines)
            note = "no physical line found between regions"
        elseif c_ins >= new_corridor_min_mw               # brand-new corridor
            b0 = _region_anchor_bus(k[1], b2r, bus_df, line_df)
            b1 = _region_anchor_bus(k[2], b2r, bus_df, line_df)
            if b0 === nothing || b1 === nothing
                note = "new corridor but a region has no buses"
            else
                (la0, lo0), (la1, lo1) = bxy[b0], bxy[b1]
                len  = max(_haversine_km(la0, lo0, la1, lo1) * 1.3, 10.0)
                imax = c_ins / (sqrt(3) * 400.0)          # kA so √3·V·I = MW
                push!(new_rows, (line_id = "NEWES_$(k[1])_$(k[2])",
                                 bus0 = b0, bus1 = b1, voltage = 400.0,
                                 circuits = 1.0, length = len, dc = "f",
                                 r_per_length = r_pl, x_per_length = x_pl,
                                 c_per_length = c_pl, Imax = imax))
                note = "synthetic line $b0 - $b1 ($(round(len; digits = 0)) km)"
            end
        else
            continue                                       # numerically-zero corridor
        end
        push!(diag_rows, (from = k[1], to = k[2], initial_mw = c_ini,
                          installed_mw = c_ins,
                          factor = isfinite(raw) ? raw : NaN,
                          n_lines = length(lines), kind = "intra", note = note))
    end

    new_lines = isempty(new_rows) ?
        DataFrame(line_id = String[], bus0 = String[], bus1 = String[],
                  voltage = Float64[], circuits = Float64[], length = Float64[],
                  dc = String[], r_per_length = Float64[], x_per_length = Float64[],
                  c_per_length = Float64[], Imax = Float64[]) :
        DataFrame(new_rows)
    return (line_scale = line_scale, new_lines = new_lines, xb_short = xb_short,
            corr_diag = sort(DataFrame(diag_rows), :installed_mw, rev = true))
end

# ── 4. Storage disaggregation ───────────────────────────────

# Thermal capacity [MW] of the AC lines connected at each bus (√3·V·Imax per
# circuit, all circuits).  `line_scale` (corridor expansion, parallel circuits)
# and `new_lines` (synthetic corridors) make the total reflect the scenario
# grid rather than today's.  Transformers and HVDC converters are deliberately
# excluded: a bus reachable only through a transformer has no line capacity of
# its own and should not host bulk storage.
function _bus_line_capacity_mw(; data_dir = joinpath(@__DIR__, "Data"),
                               line_scale = nothing, new_lines = nothing)
    line_df = CSV.read(joinpath(data_dir, "lines.csv"), DataFrame)
    if new_lines !== nothing && nrow(new_lines) > 0
        line_df = vcat(line_df, new_lines; cols = :intersect)
    end
    lsc(id) = line_scale === nothing ? 1.0 : get(line_scale, String(id), 1.0)
    cap = Dict{String,Float64}()
    for r in eachrow(line_df)
        String(r.dc) == "t" && continue
        nc = max(Float64(r.circuits), 1.0) * lsc(r.line_id)
        mw = sqrt(3) * Float64(r.voltage) * Float64(r.Imax) * nc
        for b in (String(r.bus0), String(r.bus1))
            cap[b] = get(cap, b, 0.0) + mw
        end
    end
    return cap
end

# Spread `budget` MW over `buses` proportionally to their incident-line
# capacity, never exceeding `headroom[b]` at any bus (iterative waterfill:
# distribute ∝ capacity, clip at the cap, re-spread the overflow over the
# buses still open).  Mutates `headroom`; returns (alloc::Dict, leftover).
function _waterfill!(headroom::Dict{String,Float64}, cap::Dict{String,Float64},
                     buses::Vector{String}, budget::Float64)
    alloc = Dict{String,Float64}(b => 0.0 for b in buses)
    while budget > 1e-6
        act = [b for b in buses if headroom[b] > 1e-9]
        isempty(act) && break
        wsum = sum(cap[b] for b in act)
        wsum > 0 || break
        rem = budget
        for b in act
            add = min(rem * cap[b] / wsum, headroom[b])
            alloc[b]    += add
            headroom[b] -= add
            budget      -= add
        end
    end
    return alloc, budget
end

"""
    nodal_bess_units(cfg; data_dir, line_scale, new_lines) -> Vector{NamedTuple}

EMPIRE's Spanish Li-Ion BESS fleet sited per NUTS3 node: each node's power/
energy is split over the region's buses in proportion to the thermal capacity
of the AC lines connected at each bus, and capped at that capacity (so no bus
hosts a battery its lines cannot evacuate).  Power a region cannot host spills
over to buses of other regions with remaining headroom (a warning is printed
if even that fails).  Off-grid nodes are redistributed over the mapped ones.
Same output shape as empire_bess_units: [(bus_id, power_mw, energy_mwh), …].
"""
function nodal_bess_units(cfg; data_dir = joinpath(@__DIR__, "Data"),
                          line_scale = nothing, new_lines = nothing)
    scfg   = cfg["scenario"]
    dir    = joinpath(@__DIR__, String(scfg["empire_dir"]))
    period = Int(scfg["period"])
    b2r     = bus_nuts3(data_dir = data_dir)
    regions_with_buses = Set(v for v in values(b2r) if startswith(v, "ES"))

    node = Dict{String,Dict{Symbol,Float64}}()            # region → pw/en
    for (f, col, key) in (("storPWInstalledCap.tab", :storPWInstalledCap, :pw),
                          ("storENInstalledCap.tab", :storENInstalledCap, :en))
        df = CSV.read(joinpath(dir, "Output", f), DataFrame; delim = '\t')
        for r in eachrow(df)
            (Int(r.Period) == period && startswith(String(r.Node), "ES") &&
             String(r.Storage) == "Li-Ion_BESS") || continue
            d = get!(node, String(r.Node), Dict{Symbol,Float64}())
            d[key] = get(d, key, 0.0) + Float64(r[col])
        end
    end

    placed = Dict(k => v for (k, v) in node if k in regions_with_buses)
    orphan_pw = sum(get(v, :pw, 0.0) for (k, v) in node if !(k in regions_with_buses); init = 0.0)
    orphan_en = sum(get(v, :en, 0.0) for (k, v) in node if !(k in regions_with_buses); init = 0.0)
    ptot = sum(get(v, :pw, 0.0) for v in values(placed); init = 0.0)

    # Incident-line capacity per bus = both the siting weight and the hard cap.
    buscap = _bus_line_capacity_mw(; data_dir, line_scale, new_lines)
    region_buses = Dict{String,Vector{String}}()
    for (b, reg) in b2r
        (startswith(reg, "ES") && get(buscap, b, 0.0) > 0) || continue
        push!(get!(region_buses, reg, String[]), b)
    end
    headroom = Dict(b => c for (b, c) in buscap)

    alloc_pw = Dict{String,Float64}()               # bus ⇒ MW placed
    alloc_en = Dict{String,Float64}()               # bus ⇒ MWh placed
    spill_pw = 0.0; spill_en = 0.0                  # power no region bus can host
    for (reg, d) in placed
        pw = get(d, :pw, 0.0); en = get(d, :en, 0.0)
        if ptot > 1e-3 && orphan_pw > 1e-3
            pw += orphan_pw * get(d, :pw, 0.0) / ptot
            en += orphan_en * get(d, :pw, 0.0) / ptot
        end
        pw > 1e-3 || continue
        buses = get(region_buses, reg, String[])
        a, left = isempty(buses) ? (Dict{String,Float64}(), pw) :
                                   _waterfill!(headroom, buscap, buses, pw)
        for (b, v) in a
            v > 0 || continue
            alloc_pw[b] = get(alloc_pw, b, 0.0) + v
            alloc_en[b] = get(alloc_en, b, 0.0) + en * v / pw
        end
        spill_pw += left
        spill_en += en * left / pw
    end

    # Spill-over pass: whatever a region's own buses could not host goes to any
    # Spanish bus with headroom left (still capacity-proportional and capped).
    if spill_pw > 1e-3
        all_buses = collect(Iterators.flatten(values(region_buses)))
        a, left = _waterfill!(headroom, buscap, all_buses, spill_pw)
        for (b, v) in a
            v > 0 || continue
            alloc_pw[b] = get(alloc_pw, b, 0.0) + v
            alloc_en[b] = get(alloc_en, b, 0.0) + spill_en * v / spill_pw
        end
        left > 1e-3 && @printf "WARNING: %.1f MW of BESS exceeds the line capacity of every bus and was dropped\n" left
    end

    return [(bus_id = b, power_mw = alloc_pw[b], energy_mwh = get(alloc_en, b, 0.0))
            for b in sort(collect(keys(alloc_pw))) if alloc_pw[b] > 1e-3]
end

# ── 5. Bundle for run_market_chain.jl ────────────────────────────────

"""
    build_nodal_disaggregation(cfg, emp; data_dir) -> NamedTuple

Everything the market chain needs, in one call:
  unit_scale : unit_id ⇒ capacity factor (per-unit; overrides the zonal
               (fuel, tech) growth table where present)
  new_units  : DataFrame appended to generations.csv (greenfield capacity)
  line_scale : line_id ⇒ expansion factor ≥ 1 (parallel-circuit scaling)
  new_lines  : DataFrame appended to lines.csv (brand-new corridors)
  bess       : nodal Li-Ion BESS fleet (replaces empire_bess_units)
  gen_diag / corr_diag : per-(region, tech) and per-corridor diagnostics
"""
function build_nodal_disaggregation(cfg, emp; data_dir = joinpath(@__DIR__, "Data"))
    g = nodal_unit_scale(emp; data_dir)
    l = nodal_line_scale(cfg; data_dir)
    b = nodal_bess_units(cfg; data_dir, line_scale = l.line_scale, new_lines = l.new_lines)
    return (unit_scale = g.scale, new_units = g.new_units,
            line_scale = l.line_scale, new_lines = l.new_lines,
            xb_short = l.xb_short,
            bess = b, gen_diag = g.gen_diag, corr_diag = l.corr_diag)
end

# ── 6. Standalone diagnostics ───────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    using TOML
    @isdefined(load_empire_scenario) || include("empire_scenario.jl")
    cfg = TOML.parsefile(joinpath(@__DIR__, "config.toml"))
    empire_active(cfg) || error("[scenario] label = \"2024\" — nothing to disaggregate")
    label = empire_label(cfg)
    emp   = load_empire_scenario(cfg)
    nd    = build_nodal_disaggregation(cfg, emp)

    outdir = joinpath(@__DIR__, "results", label, "nodal")
    mkpath(outdir)
    gen_df = CSV.read(joinpath(@__DIR__, "Data", "generations.csv"), DataFrame)
    b2r    = bus_nuts3()
    us = DataFrame(unit_id = String[], bus_id = String[], region = String[],
                   primary_fuel = String[], technology = String[],
                   cap_2024_mw = Float64[], factor = Float64[], cap_scen_mw = Float64[])
    for r in eachrow(gen_df)
        f = get(nd.unit_scale, String(r.unit_id), NaN)
        isnan(f) && continue
        push!(us, (String(r.unit_id), String(r.bus_id),
                   get(b2r, String(r.bus_id), "?"), String(r.primary_fuel),
                   String(r.technology), Float64(r.capacity_mw), f,
                   Float64(r.capacity_mw) * f))
    end
    CSV.write(joinpath(outdir, "unit_scale.csv"),  us)
    CSV.write(joinpath(outdir, "new_units.csv"),   nd.new_units)
    CSV.write(joinpath(outdir, "gen_regions.csv"), sort(nd.gen_diag, [:tech, :region]))
    CSV.write(joinpath(outdir, "line_scale.csv"),
              DataFrame(line_id = collect(keys(nd.line_scale)),
                        factor  = collect(values(nd.line_scale))))
    CSV.write(joinpath(outdir, "new_lines.csv"),   nd.new_lines)
    CSV.write(joinpath(outdir, "corridors.csv"),   nd.corr_diag)
    CSV.write(joinpath(outdir, "bess_units.csv"),  DataFrame(nd.bess))

    # consistency: scaled fleet + new units vs EMPIRE national totals
    println("\n=== Nodal disaggregation — $label (period $(emp.period)) ===")
    println("\nGeneration (national totals, MW):")
    tot = Dict{String,Float64}()
    for r in eachrow(us)
        key = (String(r.primary_fuel), String(r.technology))
        haskey(EMPIRE_UNIT_TECH, key) || continue
        tot[EMPIRE_UNIT_TECH[key]] = get(tot, EMPIRE_UNIT_TECH[key], 0.0) + r.cap_scen_mw
    end
    for r in eachrow(nd.new_units)
        key = (String(r.primary_fuel), String(r.technology))
        t = findfirst(p -> NODAL_NEW_FT[p] == key, collect(keys(NODAL_NEW_FT)))
        t === nothing && continue
        tn = collect(keys(NODAL_NEW_FT))[t]
        tot[tn] = get(tot, tn, 0.0) + Float64(r.capacity_mw)
    end
    for t in sort(collect(keys(emp.caps_nuts)))
        want = sum(values(emp.caps_nuts[t]))
        got  = get(tot, t, 0.0)
        flag = isapprox(want, got; rtol = 1e-3) ? "OK  " : "DIFF"
        @printf "  %s %-24s  EMPIRE %9.1f | fleet %9.1f\n" flag t want got
    end
    @printf "\nNew units: %d (%.1f MW) | reinforced lines: %d | new corridors: %d\n" nrow(nd.new_units) sum(nd.new_units.capacity_mw; init = 0.0) length(nd.line_scale) nrow(nd.new_lines)
    println("\nCross-border (EMPIRE installed vs the scaled physical border):")
    for (c, short) in sort(collect(nd.xb_short); by = first)
        built = sum(sqrt(3) * r.voltage * r.Imax for r in eachrow(nd.new_lines)
                    if startswith(String(r.line_id), "NEWXB_") &&
                       endswith(String(r.line_id), "_$c"); init = 0.0)
        @printf "  %s: shortfall %7.1f MW | synthesised %7.1f MW\n" c short built
    end
    nbess = length(nd.bess)
    @printf "BESS sites: %d (%.1f MW / %.1f MWh)\n" nbess sum(b.power_mw for b in nd.bess; init = 0.0) sum(b.energy_mwh for b in nd.bess; init = 0.0)
    println("\nDiagnostics written to $outdir")
end
