#!/usr/bin/env python3
"""Publish the PowerVision Trinity run for the example run-viewer.

Converts results/Trinity (full market-chain run: 2024-07-08 + 2024-12-02) into
the exact format viewer/index.html + viewer.css + viewer.js expect:

  viewer/runs/powervision-trinity-2024/data.js     VIEWER.addRun({...})
  viewer/runs/powervision-trinity-2024/2024-07.js   VIEWER.addMonth(...)
  viewer/runs/powervision-trinity-2024/2024-12.js   VIEWER.addMonth(...)
  viewer/runs/powervision-trinity-2024/meta.json    run metadata
  viewer/runs/manifest.js                           window.RUN_MANIFEST
  viewer/reference/basemap.js                       window.BASEMAP (built from
                                                    Data/nuts3_es.geojson)

reference/esios_2024.js and reference/model_facts.js are deliberately NOT
generated (this repo has no REE e-sios series or paper-facts data); viewer.js
shows its built-in "missing" notes for those sections.

Usage:  python viewer/publish_powervision_run.py   then open
        viewer/index.html in a browser.
"""
import base64
import csv
import json
import math
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RES = ROOT / "results" / "Trinity"
EX = ROOT / "viewer"
RUNS_DIR = EX / "runs"
REF_DIR = EX / "reference"
RUN_ID = "powervision-trinity-2024"
DAYS = ["2024-07-08", "2024-12-02"]
MONTHS = ["2024-07", "2024-12"]
NH = 24 * len(DAYS)                      # 48 hours in the whole run

# viewer coordinate system, verified against the example run's corridors:
# x = lon * 111.32 * cos(40 deg)  (km east),  y = -lat * 111.32  (km, north up)
KX = 111.32 * math.cos(math.radians(40.0))
KY = 111.32


def proj(lat, lon):
    return [round(lon * KX, 1), round(-lat * KY, 1)]


STAGES = ["DA", "ID2", "ID3", "CID", "BAL"]
CATEGORIES = ["Nuclear", "Coal", "CCGT", "Hydro", "Wind", "Solar", "CHP group", "Imports"]
CATEGORIES_PHYS = ["Nuclear", "Coal", "Gas", "Hydro", "Wind", "Solar", "Bio & other", "Imports"]
FUEL2CAT = {"Nuclear": "Nuclear", "Coal": "Coal", "Gas": "CCGT", "Oil": "CCGT",
            "Hydro": "Hydro", "Wind": "Wind", "Solar": "Solar",
            "Biomass": "CHP group", "Waste": "CHP group", "CrossBorder": "Imports"}
CAT2PHYS = {"Nuclear": "Nuclear", "Coal": "Coal", "CCGT": "Gas", "Hydro": "Hydro",
            "Wind": "Wind", "Solar": "Solar", "CHP group": "Bio & other", "Imports": "Imports"}
CHARGE_TECHS = {"pumped_storage"}          # technologies that can charge (dispatch < 0)
SKIP_FUELS = {"Slack", "LoadShed"}         # not shown as plants or mix categories


def rows(path):
    with open(path, newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))


def num(x, nd=None):
    if x is None:
        return None
    s = str(x).strip()
    if s == "" or s.lower() == "nan":
        return None
    try:
        v = float(s)
    except ValueError:
        return None
    if math.isnan(v) or math.isinf(v):
        return None
    return round(v, nd) if nd is not None else v


def blank48():
    return [None] * NH


def zeros48():
    return [0.0] * NH


def hour_key(r):
    return (r["date"], int(float(r["hour"])))


def b64(raw):
    return base64.b64encode(raw).decode("ascii")


# ---------- static network data ----------

def load_buses():
    coords = {}
    for r in rows(ROOT / "Data" / "Bus_Data.csv"):
        coords[r["bus_id"]] = proj(num(r["y"]), num(r["x"]))
    return coords


def load_line_meta():
    kv, km = {}, {}
    for r in rows(ROOT / "Data" / "lines.csv"):
        kv[r["line_id"]] = num(r["voltage"])
        km[r["line_id"]] = num(r["length"])
    for r in rows(ROOT / "Data" / "transformers_reactance.csv"):
        kv[r["transformer_id"]] = num(r["HV_kV"])
        km[r["transformer_id"]] = 0.0
    return kv, km


# ---------- corridors (the run's branches grouped into parallel circuits) ----------

def build_corridors(coords):
    """Group branch_flows rows into corridors like the example run's
    grid.corridors: {names, kv, km, a, b, ab, cls, t, lim} + hourly loading."""
    kv_meta, km_meta = load_line_meta()
    per_branch = {}                       # branch_name -> rows
    for r in rows(RES / "branch_flows.csv"):
        per_branch.setdefault(r["branch_name"], []).append(r)
    names = sorted(per_branch)
    groups = {}                           # (busA, busB, kv) -> [branch names]
    meta = {}
    for n in names:
        r0 = per_branch[n][0]
        f, t = r0["from_bus_id"], r0["to_bus_id"]
        key = (min(f, t), max(f, t))
        groups.setdefault(key, []).append(n)
        meta[n] = {"cls": r0["asset_class"], "from": f, "to": t,
                   "lim": num(r0["limit_mw"]) or 0.0,
                   "kv": kv_meta.get(n), "km": km_meta.get(n)}
    corridors, load_hour = [], {}         # load_hour[(c, h_global)] = byte
    for (fa, fb), bnames in groups.items():
        kvs = {meta[n]["kv"] for n in bnames if meta[n]["kv"]}
        kv = sorted(kvs)[0] if kvs else None
        cor = {"names": bnames, "kv": kv,
               "km": max((meta[n]["km"] or 0.0) for n in bnames),
               "a": coords.get(fa), "b": coords.get(fb), "ab": [fa, fb],
               "cls": meta[bnames[0]]["cls"],
               "t": "trafo" if bnames[0].startswith("TR_") else "line",
               "lim": round(sum(meta[n]["lim"] for n in bnames), 1)}
        corridors.append(cor)
    cidx = {id(c): i for i, c in enumerate(corridors)}
    # hourly loading: max over the corridor's branches; 255 = missing
    best = {}
    for n in names:
        i = None
        for j, c in enumerate(corridors):
            if n in c["names"]:
                i = j
                break
        for r in per_branch[n]:
            L = num(r["loading_pct"])
            v = 255 if L is None else max(0, min(254, int(round(L))))
            k = (i, hour_key(r))
            if k not in best or v > best[k]:
                best[k] = v
    return corridors, best


# ---------- plants (groups of units at one bus with one fuel+technology) ----------

def build_plants(coords):
    """gen_dispatch grouped by (bus, fuel, technology); returns groups +
    hourly output/charging bytes per group (index by global hour)."""
    bus_num_to_id = {}
    for r in rows(RES / "branch_flows.csv"):
        bus_num_to_id[r["from_bus"]] = r["from_bus_id"]
        bus_num_to_id[r["to_bus"]] = r["to_bus_id"]
    gdisp = {}                            # (bus, fuel, tech) -> {cap, gens}
    gmap = {}                             # gen_id -> group key
    for r in rows(RES / "gen_dispatch.csv"):
        fuel = r["fuel"]
        if fuel in SKIP_FUELS:
            continue
        key = (r["bus_i"], fuel, r["technology"])
        g = gdisp.setdefault(key, {"cap": 0.0, "gens": set()})
        g["cap"] += num(r["capacity_mw"]) or 0.0
        g["gens"].add(r["gen_id"])
        gmap[r["gen_id"]] = key
    keys = sorted(gdisp.keys(), key=lambda k: (k[0], k[1], k[2]))
    groups, kidx = [], {}
    for k in keys:
        bus_id = bus_num_to_id.get(k[0])
        xy = coords.get(bus_id) or [0.0, 0.0]
        kidx[k] = len(groups)
        groups.append({"bus": bus_id or k[0], "f": k[1], "x": xy[0], "y": xy[1],
                       "cap": round(gdisp[k]["cap"], 1), "n": len(gdisp[k]["gens"]),
                       "tech": k[2]})
    ng = len(groups)
    out = [[None] * ng for _ in range(NH)]     # out[h][g] = MW
    chg = [[None] * ng for _ in range(NH)]
    for r in rows(RES / "gen_dispatch.csv"):
        if r["gen_id"] not in gmap:
            continue
        g = kidx[gmap[r["gen_id"]]]
        h = (DAYS.index(r["date"])) * 24 + int(float(r["hour"]))
        mw = num(r["dispatch_mw"]) or 0.0
        out[h][g] = (out[h][g] or 0.0) + max(0.0, mw)
        if gmap[r["gen_id"]][2] in CHARGE_TECHS:
            chg[h][g] = (chg[h][g] or 0.0) + max(0.0, -mw)
    return groups, out, chg


def plant_bytes(groups, out, chg):
    """Hour-major byte arrays exactly as viewer.js loadRun/byItem expect."""
    ng = len(groups)
    ob = bytearray(NH * ng)
    cb = bytearray(NH * ng)
    for h in range(NH):
        for g, p in enumerate(groups):
            cap = p["cap"] or 0.0
            mw = out[h][g]
            ob[h * ng + g] = 255 if (cap <= 0 or mw is None) else max(0, min(254, int(round(250.0 * mw / cap))))
            cm = chg[h][g]
            if cm is None:
                cb[h * ng + g] = 128                     # Int8 -128 = missing
            else:
                cb[h * ng + g] = max(0, min(127, int(round(127.0 * cm / cap)))) if cap > 0 else 128
    return bytes(ob), bytes(cb)


# ---------- mix per market stage ----------

def stage_mix(fname):
    """{category: [48 MW]} from a per-generator stage dispatch file."""
    mix = {c: zeros48() for c in CATEGORIES}
    seen_fuels = set()
    for r in rows(RES / fname):
        f = r["fuel"]
        seen_fuels.add(f)
        cat = FUEL2CAT.get(f)
        if cat is None:
            continue                      # Slack/LoadShed: ~0 MW, not a category
        h = DAYS.index(r["date"]) * 24 + int(float(r["hour"]))
        mix[cat][h] += num(r["dispatch_mw"]) or 0.0
    return mix, seen_fuels


# ---------- real reference data (Data/OMIE) ----------

def real_price():
    """OMIE day-ahead price profile per month (rows jul/dec, columns 1..24)."""
    prof = {}
    for r in rows(ROOT / "Data" / "OMIE" / "omie_price.csv"):
        prof[r["month"].strip().lower()] = [num(r[str(h)]) for h in range(1, 25)]
    out = []
    for d in DAYS:
        m = "jul" if d[5:7] == "07" else "dec"
        out.extend(prof.get(m) or [None] * 24)
    return out


OMIE_MIX_COLS = {"Coal": "Coal", "Fuel-Gas": "CCGT", "Combined Cycle": "CCGT",
                 "Nuclear": "Nuclear", "Hydropower": "Hydro", "Wind": "Wind",
                 "Solar Thermal": "Solar", "Solar Photovoltaic": "Solar",
                 "Cogeneration/Waste/Small Hydro": "CHP group", "Self-producer": "CHP group",
                 "International Import": "Imports", "International Import (without MIBEL)": "Imports",
                 "Storage": "Hydro"}


def real_mix():
    """OMIE per-technology generation (day-ahead programme) per category."""
    mix = {c: blank48() for c in CATEGORIES}
    files = {"2024-07-08": "actual_generation_July_8.csv",
             "2024-12-02": "actual_generation_Dec_2.csv"}
    for d, f in files.items():
        base = DAYS.index(d) * 24
        for r in rows(ROOT / "Data" / "OMIE" / f):
            h = base + int(float(r["Hour"])) - 1
            for col, cat in OMIE_MIX_COLS.items():
                v = num(r.get(col))
                if v is not None:
                    mix[cat][h] = (mix[cat][h] or 0.0) + max(0.0, v)
    return mix


def real_phys():
    """ENTSO-E actual generation per physical category (both study days)."""
    mix = {c: blank48() for c in CATEGORIES_PHYS}
    files = {"2024-07-08": "ENTSOE_actual_genertion_8_july_2024_categorized.csv",
             "2024-12-02": "ENTSOE_actual_genertion_2_dec_2024_categorized.csv"}
    for d, f in files.items():
        base = DAYS.index(d) * 24
        for r in rows(ROOT / "Data" / "OMIE" / f):
            hh = r["time_start"].split(" ")[1].split(":")[0]
            h = base + int(hh)
            for col, cat in (("Nuclear", "Nuclear"), ("Coal", "Coal"), ("Combined_cycle", "Gas"),
                             ("Wind", "Wind"), ("Solar", "Solar")):
                v = num(r.get(col))
                if v is not None:
                    mix[cat][h] = (mix[cat][h] or 0.0) + v
            hyd = (num(r.get("Hydro")) or 0.0) + (num(r.get("pumped_storage_discharge")) or 0.0) \
                - (num(r.get("pumped_storage_charge")) or 0.0)
            mix["Hydro"][h] = (mix["Hydro"][h] or 0.0) + hyd
            bio = (num(r.get("Biomas")) or 0.0) + (num(r.get("Biomass")) or 0.0) + (num(r.get("ICCC")) or 0.0)
            mix["Bio & other"][h] = (mix["Bio & other"][h] or 0.0) + bio
    return mix


# ---------- stage deltas: traded, balancing, redispatch ----------

def stage_gen(fname):
    """gen_id -> [48 MW]."""
    g = {}
    for r in rows(RES / fname):
        g.setdefault(r["gen_id"], [0.0] * NH)[DAYS.index(r["date"]) * 24 + int(float(r["hour"]))] = \
            num(r["dispatch_mw"]) or 0.0
    return g


def gen_fuel_map():
    m = {}
    for r in rows(RES / "gen_dispatch.csv"):
        m[r["gen_id"]] = FUEL2CAT.get(r["fuel"], "CHP group")
    return m


def deltas(prev, cur, by_cat=None):
    """Total up/down [48] (+ per-category up/down if by_cat given)."""
    up, down = zeros48(), zeros48()
    ub, db = ({c: zeros48() for c in CATEGORIES} for _ in range(2))
    for gid, vals in cur.items():
        pv = prev.get(gid)
        if pv is None:
            continue
        cat = by_cat.get(gid) if by_cat else None
        for h in range(NH):
            dlt = (vals[h] or 0.0) - (pv[h] or 0.0)
            if dlt > 0:
                up[h] += dlt
                if cat:
                    ub[cat][h] += dlt
            elif dlt < 0:
                down[h] += -dlt
                if cat:
                    db[cat][h] += -dlt
    return up, down, ub, db


# ---------- prices, summary ----------

def prices():
    out = {s: blank48() for s in STAGES}
    for r in rows(RES / "market_prices.csv"):
        st = r["stage"].strip().upper()
        if st in out:
            out[st][DAYS.index(r["date"]) * 24 + int(float(r["hour"]))] = num(r["price_eur_mwh"], 2)
    return out


def summary():
    status, shed, obj, mism = blank48(), blank48(), blank48(), blank48()
    for r in rows(RES / "summary.csv"):
        h = DAYS.index(r["date"]) * 24 + int(float(r["hour"]))
        status[h] = 1 if "SOLVED" in (r.get("status") or "").upper() else 0
        shed[h] = num(r["load_shed_mw"], 2) or 0.0
        obj[h] = num(r["objective_eur_h"], 0) or 0.0
        mism[h] = num(r["mismatch_mw"], 2) or 0.0
    return status, shed, obj, mism


# ---------- CSP/TES price-taker results (Option B), if the run has them ----------

# viewer fact key <- column of Data/csp_plants.csv (the plant overlay file)
PLANT_CSV2KEY = {
    "plant_id": "plant_id", "bus_id": "bus_id",
    "solar_capacity_mwth": "solar_capacity", "pmax_e_mwe": "pmax_e",
    "tes_capacity_mwhth": "tes_capacity", "q0_start_mwhth": "q0_start",
    "q_end_target_mwhth": "q_end_target", "eta_solar": "eta_solar",
    "eta_power": "eta_power", "eta_charge": "eta_charge",
    "thermal_leak_rate": "thermal_leak_rate", "pmax_charge_e_mwe": "pmax_charge_e",
    "buy_from_grid": "buy_from_grid", "allow_sell": "allow_sell",
    "grid_price_floor_eur_mwh": "grid_price_floor", "vom_eur_mwh": "vom_eur_mwh",
}


def parse_plant_value(s):
    t = str(s).strip().lower()
    if t == "true":
        return True
    if t == "false":
        return False
    try:
        return float(t)
    except ValueError:
        return s


def load_plant_row(plant_id):
    """Plant facts from Data/csp_plants.csv - the single source of plant truth.
    A missing file or row is a hard error: there is no built-in default plant."""
    path = ROOT / "Data" / "csp_plants.csv"
    if not path.exists():
        raise SystemExit("Data/csp_plants.csv not found - the CSP plant facts shown in "
                         "the viewer come from there; there is no built-in default plant.")
    for r in rows(path):
        if str(r["plant_id"]).strip() == str(plant_id).strip():
            return {k: parse_plant_value(r[c]) for c, k in PLANT_CSV2KEY.items()}
    raise SystemExit("plant_id '%s' not found in Data/csp_plants.csv" % plant_id)


def load_csp(csp_subdir="csp", overrides=None, plant_id=None):
    """Read results/Trinity/<csp_subdir>/* into the run package's csp object
    (None if absent). Plant facts come from the `plant_id` row of
    Data/csp_plants.csv (the plant overlay file - the single source of plant
    truth); `overrides` (--set key=value) take precedence for ad-hoc tweaks,
    and a variant run simply publishes the plant row it ran with (--plant-id)."""
    cd = RES / csp_subdir
    if not (cd / "csp_summary.csv").exists():
        return None
    summary = []
    for r in rows(cd / "csp_summary.csv"):
        summary.append({"gate": r["gate"], "date": r["date"],
                        "solved": 1 if (r.get("solved") or "").lower() == "true" else 0,
                        "gen_mwh": num(r["gen_mwh"], 1), "buy_mwh": num(r["buy_mwh"], 1),
                        "solar_th_mwh": num(r["solar_th_mwh"], 1),
                        "net_eur": num(r["net_eur"], 0),
                        "theta_future_eur": num(r["theta_future_eur"], 1),
                        "q_end_mwhth": num(r["q_end_mwhth"], 1)})
    dispatch = {}
    for g in STAGES:
        p = cd / ("csp_" + g.lower() + "_dispatch.csv")
        if not p.exists():
            continue
        d = {k: [None] * NH for k in ("price", "p_gen", "p_buy", "s_solar", "s_avail", "tes", "tes_end", "leak")}
        for r in rows(p):
            h = DAYS.index(r["date"]) * 24 + int(float(r["hour"]))
            d["price"][h] = num(r["price_eur_mwh"], 2)
            d["p_gen"][h] = num(r["p_gen_mw"], 2)
            d["p_buy"][h] = num(r["p_buy_mw"], 2)
            d["s_solar"][h] = num(r["s_solar_mwth"], 2)
            d["s_avail"][h] = num(r.get("s_avail_mwth"), 2)
            d["tes"][h] = num(r["tes_start_mwhth"], 2)
            d["tes_end"][h] = num(r["tes_end_mwhth"], 2)
            d["leak"][h] = num(r["leak_mwth"], 3)
        dispatch[g] = d
    if not plant_id:
        try:
            import tomllib
            with open(ROOT / "config.toml", "rb") as fh:
                plant_id = (tomllib.load(fh).get("csp") or {}).get("plant_id")
        except Exception:
            plant_id = None
        if not plant_id:
            raise SystemExit("[csp].plant_id is not set in config.toml - cannot pick the "
                             "plant row of Data/csp_plants.csv (there is no default plant).")
    plant = load_plant_row(plant_id)
    if overrides:
        plant.update({k: parse_plant_value(v) for k, v in overrides.items()})
    return {"plant": plant, "gates": list(dispatch.keys()), "summary": summary,
            "dispatch": dispatch}


# ---------- basemap stub from Data/nuts3_es.geojson ----------

def build_basemap():
    gj = json.loads((ROOT / "Data" / "nuts3_es.geojson").read_text(encoding="utf-8"))

    def rings(geom):
        if geom["type"] == "Polygon":
            return geom["coordinates"]
        if geom["type"] == "MultiPolygon":
            return [r for poly in geom["coordinates"] for r in poly]
        return []

    def peninsular(nid):
        # mainland NUTS3 = ES1..ES6 (incl. Andalusia/Murcia ES6x); drop only the
        # island groups: ES7 Canary, ES53 Balearic. Ceuta/Melilla (ES63/64) are
        # kept - they fall outside the grid frame anyway.
        return not (nid.startswith("ES7") or nid.startswith("ES53"))

    def path_of(ring):
        pts = []
        for lon, lat in ring:
            x, y = proj(lat, lon)
            pts.append("%.1f %.1f" % (x, y))
        return "M" + " L".join(pts) + " Z"

    spain, provinces = [], []
    for f in gj["features"]:
        if not peninsular(f["properties"]["NUTS_ID"]):
            continue
        for ring in rings(f["geometry"]):
            if len(ring) < 4:
                continue
            d = path_of(ring)
            spain.append(d)
            provinces.append(d)
    outline = {"Spain": " ".join(spain)}

    # neighbouring countries, like the example's original basemap. One-time
    # download of Natural Earth (50m admin-0) to Data/countries_50m.geojson.
    ne_path = ROOT / "Data" / "countries_50m.geojson"
    neighbours = {"France", "Portugal", "Andorra", "Morocco", "Algeria", "Gibraltar"}
    if ne_path.exists():
        ne = json.loads(ne_path.read_text(encoding="utf-8"))
        found = set()
        for f in ne["features"]:
            p = f.get("properties") or {}
            name = p.get("ADMIN") or p.get("NAME")
            if name in neighbours and name not in found:
                d = " ".join(path_of(r) for r in rings(f["geometry"]) if len(r) >= 4)
                if d:
                    outline[name] = d
                    found.add(name)
        missing = neighbours - found
        if missing:
            print("NOTE: countries not found in the Natural Earth file:", sorted(missing))
    else:
        print("NOTE: Data/countries_50m.geojson not present - the basemap shows Spain only")
    cities = [("Madrid", 40.4168, -3.7038, 1), ("Barcelona", 41.3874, 2.1686, 1),
              ("Valencia", 39.4699, -0.3763, 2), ("Sevilla", 37.3891, -5.9845, 2),
              ("Zaragoza", 41.6488, -0.8891, 2), ("Bilbao", 43.2630, -2.9350, 2),
              ("Porto", 41.1579, -8.6291, 2), ("Lisboa", 38.7223, -9.1393, 2),
              ("A Coruna", 43.3623, -8.4115, 3), ("Valladolid", 41.6523, -4.7245, 3),
              ("Murcia", 37.9922, -1.1307, 3), ("Vigo", 42.2406, -8.7207, 3),
              ("Oviedo", 43.3619, -5.8494, 3), ("San Sebastian", 43.3183, -1.9812, 3)]
    sx, sy = proj(43.2717, -5.8814)     # Soto de Ribera (Ribera de Arriba, Asturias)
    gif = "data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=="
    return {"outline": outline, "provinces": " ".join(provinces),
            "regions": "", "region_labels": [],
            "cities": [{"name": n, "x": proj(la, lo)[0], "y": proj(la, lo)[1], "rank": r}
                       for n, la, lo, r in cities],
            "soto": {"x": sx, "y": sy}, "relief": {"href": gif, "x": 0, "y": 0, "w": 1, "h": 1}}


# ---------- main ----------

def main():
    import argparse
    ap = argparse.ArgumentParser(description="Publish a PowerVision run for viewer/index.html. "
                                              "Variant example: --run-id powervision-trinity-2024-bigtes "
                                              "--csp-subdir csp_bigtes --plant-id bigtes")
    ap.add_argument("--run-id", default=RUN_ID, help="run id / folder under viewer/runs/")
    ap.add_argument("--name", default="PowerVision Trinity, 2024 study days")
    ap.add_argument("--csp-subdir", default="csp",
                    help="results/Trinity/<subdir> holding the Option B output (default: csp)")
    ap.add_argument("--plant-id", default=None,
                    help="plant row of Data/csp_plants.csv to publish as the CSP plant facts "
                         "(default: [csp].plant_id from config.toml)")
    ap.add_argument("--set", action="append", default=[], metavar="KEY=VALUE",
                    help="ad-hoc override of a plant fact on top of the file row (repeatable)")
    args = ap.parse_args()
    rid = args.run_id
    overrides = {}
    for kv in args.set:
        k, _, v = kv.partition("=")
        k = k.strip()
        try:
            overrides[k] = float(v)
        except ValueError:
            overrides[k] = v.strip()

    coords = load_buses()
    corridors, load_best = build_corridors(coords)
    nc = len(corridors)
    gb = bytearray(NH * nc)
    # hour-major layout: byte at [global_hour * nc + corridor]
    for (ci, key), v in load_best.items():
        d, hr = key
        gi = DAYS.index(d) * 24 + hr
        gb[gi * nc + ci] = v
    groups, out_mw, chg_mw = build_plants(coords)
    ob, cb = plant_bytes(groups, out_mw, chg_mw)
    ng = len(groups)

    mix_da, f1 = stage_mix("da_dispatch.csv")
    mix_bal, f2 = stage_mix("bal_dispatch.csv")
    mix_rd, f3 = stage_mix("gen_dispatch.csv")
    unmapped = (f1 | f2 | f3) - set(FUEL2CAT)
    if unmapped:
        print("NOTE unmapped fuels (excluded from mix categories):", sorted(unmapped))
    mix = {"DA": mix_da, "BAL": mix_bal, "RD": mix_rd}
    for st in mix:
        mix[st] = {c: [round(v, 1) for v in mix[st][c]] for c in CATEGORIES}
    mix_phys = {st: {p: zeros48() for p in CATEGORIES_PHYS} for st in mix}
    for st in mix:
        for c in CATEGORIES:
            p = CAT2PHYS[c]
            mix_phys[st][p] = [round(a + b, 1) for a, b in zip(mix_phys[st][p], mix[st][c])]

    gda = stage_gen("da_dispatch.csv")
    gid2 = stage_gen("id2_dispatch.csv")
    gid3 = stage_gen("id3_dispatch.csv")
    gcid = stage_gen("cid_dispatch.csv")
    gbal = stage_gen("bal_dispatch.csv")
    grd = stage_gen("gen_dispatch.csv")
    fmap = gen_fuel_map()
    t2, _, _, _ = deltas(gda, gid2)
    t3, _, _, _ = deltas(gid2, gid3)
    tc, _, _, _ = deltas(gid3, gcid)
    bup, bdown, _, _ = deltas(gcid, gbal)
    rup, rdown, rub, rdb = deltas(gbal, grd, fmap)
    status, shed, obj, mism = summary()

    xs = [p[0] for c in corridors for p in (c["a"], c["b"]) if p]
    ys = [p[1] for c in corridors for p in (c["a"], c["b"]) if p]
    frame = [round(min(xs) - 30, 1), round(min(ys) - 30, 1),
             round(max(xs) - min(xs) + 60, 1), round(max(ys) - min(ys) + 60, 1)]

    pkg = {
        "schema": 1, "id": rid, "days": DAYS, "months": MONTHS,
        "price": prices(), "scenario": {"label": "Trinity", "period": 2, "weather_years": [2024]},
        "real_price": real_price(), "status": status, "shed": shed, "fail_info": {},
        "categories": CATEGORIES, "categories_phys": CATEGORIES_PHYS,
        "mix": mix, "mix_phys": mix_phys, "real_mix": real_mix(), "real_phys": real_phys(),
        "balancing": {"up": [round(v, 1) for v in bup], "down": [round(v, 1) for v in bdown],
                      "need": [round(v, 1) for v in bup]},
        "redispatch": {"up": [round(v, 1) for v in rup], "down": [round(v, 1) for v in rdown],
                       "losses": [round(max(0.0, v), 1) for v in mism],
                       "cost": [round(v, 0) for v in obj],
                       "up_by": {c: [round(v, 1) for v in rub[c]] for c in CATEGORIES},
                       "down_by": {c: [round(v, 1) for v in rdb[c]] for c in CATEGORIES}},
        "traded": {"ID2": [round(v, 1) for v in t2], "ID3": [round(v, 1) for v in t3],
                   "CID": [round(v, 1) for v in tc]},
        "grid": {"frame": frame, "corridors": corridors},
        "plants": {"groups": groups}, "sites": {"sites": [], "coverage": {}},
        "csp": load_csp(args.csp_subdir, overrides, plant_id=args.plant_id),
    }

    out_run = RUNS_DIR / rid
    out_run.mkdir(parents=True, exist_ok=True)
    (out_run / "data.js").write_text(
        "VIEWER.addRun(" + json.dumps(pkg, separators=(",", ":"), allow_nan=False) + ");\n",
        encoding="utf-8")
    for mi, m in enumerate(MONTHS):
        s, e = mi * 24, (mi + 1) * 24
        part = {"h0": mi * 24, "hours": 24,
                "grid_load": b64(bytes(gb[s * nc:e * nc])),
                "plant_out": b64(ob[s * ng:e * ng]),
                "plant_chg": b64(cb[s * ng:e * ng]),
                "site_model": "", "site_real": ""}
        (out_run / (m + ".js")).write_text(
            'VIEWER.addMonth("' + rid + '", "' + m + '", ' +
            json.dumps(part, separators=(",", ":")) + ");\n", encoding="utf-8")

    meta = {
        "schema": 1, "id": rid,
        "name": args.name,
        "note": "The PowerVision market-chain run of this repo (DA, ID2, ID3, CID, BAL gates "
                "+ AC/DC redispatch) on its two study days, published into the run viewer. "
                "Real price = OMIE's monthly-average day-ahead profile for July/December "
                "(Data/OMIE/omie_price.csv); real mix = OMIE per-technology generation; real "
                "physical = ENTSO-E actual generation. REE e-sios series and the PowerVision "
                "paper facts are not bundled, so those sections show their missing-data notes."
                + ("" if (not overrides and not args.plant_id) else
                   " CSP variant: plant row '%s' of Data/csp_plants.csv" % (args.plant_id or "[csp].plant_id")
                   + ("" if not overrides else " (overrides: "
                      + ", ".join("%s=%s" % (k, overrides[k]) for k in sorted(overrides)) + ")")
                   + "."),
        "published": datetime.now().isoformat(timespec="seconds"),
        "published_by": "publish_powervision_run.py",
        "first_day": DAYS[0], "last_day": DAYS[-1], "n_days": len(DAYS),
        "ac_solved": int(sum(status)), "ac_total": NH, "months": MONTHS,
        "size_mb": 0.1,
        "info": {"ran_by": "PowerVision (Spain_power_system repo)", "branch": "public_version",
                 "commit": "-", "commit_message": "", "uncommitted_files": [],
                 "started": "-", "finished": "-", "runtime_min": None,
                 "power_flow": "AC", "linear_solver": "default",
                 "label": "Trinity", "reconstructed": False},
        "scenario": {"label": "Trinity", "period": 2, "weather_years": [2024]},
        "features": {"res": "accepted", "xb": True, "gas": True, "markup": False,
                     "hydro": False, "chain": "day"},
    }
    (out_run / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")

    # manifest: the base run first (it is the default in the viewer), then every
    # other published run under runs/
    manifest = [meta]
    for p in sorted(RUNS_DIR.glob("*/meta.json")):
        m = json.loads(p.read_text(encoding="utf-8"))
        if m.get("id") != rid:
            manifest.append(m)
    manifest.sort(key=lambda m: (m["id"] != RUN_ID, m["id"]))
    (RUNS_DIR / "manifest.js").write_text(
        "window.RUN_MANIFEST = " + json.dumps(manifest, separators=(",", ":")) + ";\n",
        encoding="utf-8")

    REF_DIR.mkdir(parents=True, exist_ok=True)
    if (REF_DIR / "basemap.js").exists():
        print("  basemap.js   kept (already present - user-provided basemap is not overwritten)")
    else:
        (REF_DIR / "basemap.js").write_text(
            "// generated by viewer/publish_powervision_run.py from Data/nuts3_es.geojson\n"
            "window.BASEMAP = " + json.dumps(build_basemap()) + ";\n", encoding="utf-8")
        print("  basemap.js   %.0f KB (generated stub; the original from the model repo can replace it)"
              % ((REF_DIR / "basemap.js").stat().st_size / 1024))

    print("published %s: %d corridors, %d plant groups, %d days" % (rid, nc, ng, len(DAYS)))
    print("  data.js      %.0f KB" % ((out_run / "data.js").stat().st_size / 1024))
    print("  manifest.js  %s" % ", ".join(m["id"] for m in manifest))
    print("open viewer/index.html in a browser")


if __name__ == "__main__":
    main()