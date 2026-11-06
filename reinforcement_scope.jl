"""Classify grid assets for the NUTS3 reinforcement diagnostic.

Only branches whose two terminal buses belong to the same Spanish NUTS3
region are eligible for reinforcement. Inter-NUTS3 and international capacity
is supplied by EMPIRE and must remain fixed during this step.
"""
function reinforcement_branch_scope(; data_dir = joinpath(@__DIR__, "Data"),
                                      extra_lines = nothing)
    nuts_df = CSV.read(joinpath(data_dir, "bus_nuts3.csv"), DataFrame)
    bus_region = Dict(String(r.bus_id) => String(r.nuts3) for r in eachrow(nuts_df))

    classify(bus0, bus1) = begin
        r0 = get(bus_region, String(bus0), "")
        r1 = get(bus_region, String(bus1), "")
        es0, es1 = startswith(r0, "ES"), startswith(r1, "ES")
        asset_class = if isempty(r0) || isempty(r1)
            "unmapped"
        elseif es0 && es1 && r0 == r1
            "intra_nuts3"
        elseif es0 && es1
            "inter_nuts3"
        elseif es0 || es1
            "international"
        else
            "outside_spain"
        end
        (from_bus_id = String(bus0), to_bus_id = String(bus1),
         from_nuts3 = r0, to_nuts3 = r1, asset_class = asset_class,
         reinforcement_eligible = asset_class == "intra_nuts3")
    end

    scope = Dict{String,NamedTuple}()
    line_df = CSV.read(joinpath(data_dir, "lines.csv"), DataFrame)
    if extra_lines !== nothing && nrow(DataFrame(extra_lines)) > 0
        line_df = vcat(line_df, DataFrame(extra_lines); cols = :intersect)
    end
    for r in eachrow(line_df)
        scope[String(r.line_id)] = classify(r.bus0, r.bus1)
    end

    xfmr_df = CSV.read(joinpath(data_dir, "transformers_reactance.csv"), DataFrame)
    for r in eachrow(xfmr_df)
        scope[String(r.transformer_id)] = classify(r.bus0, r.bus1)
    end
    return scope
end
