#!/usr/bin/env python3
"""Publish the CSP weekly scenarios (CSP/csp_weekly_scenarios.jl) as a viewer run.

The three weather scenarios (A clear / B mixed / C overcast, 168 hours each,
Mon 2024-07-01 .. Sun 2024-07-07) appear in the viewer's CSP tab as the
"gate stream" selector, so their hourly trends can be compared side by side.
The run is a synthetic CSP-only experiment: the Price tab shows scenario B's
synthetic day-ahead week, and the other market sections are placeholders.

Usage:
    julia --project=. CSP/csp_weekly_scenarios.jl   # writes results/csp_weekly/
    python viewer/publish_csp_weekly.py            # writes viewer/runs/csp-weekly-2024/
    python viewer/publish_powervision_run.py       # rebuilds runs/manifest.js (all runs)
"""
import json
import sys
from datetime import datetime
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import publish_powervision_run as pub   # ROOT, RUNS_DIR, rows(), num(), categories

WK = pub.ROOT / "results" / "csp_weekly"
RUN_ID = "csp-weekly-2024"
KEYS = ["a-clear", "b-mixed", "c-overcast"]
LABELS = {"a-clear": "A: clear skies", "b-mixed": "B: mixed sun/cloud", "c-overcast": "C: full overcast"}
FIELDS = ("price", "p_gen", "p_buy", "s_solar", "s_avail", "tes", "tes_end", "leak")


def read_dispatch(key, days):
    r = pub.rows(WK / ("csp_" + key + "_dispatch.csv"))
    d = {k: [None] * len(r) for k in FIELDS}
    di = {dd: i for i, dd in enumerate(days)}
    for row in r:
        i = di[row["date"]] * 24 + int(float(row["hour"]))
        d["price"][i] = pub.num(row["price_eur_mwh"], 2)
        d["p_gen"][i] = pub.num(row["p_gen_mw"], 2)
        d["p_buy"][i] = pub.num(row["p_buy_mw"], 2)
        d["s_solar"][i] = pub.num(row["s_solar_mwth"], 2)
        d["s_avail"][i] = pub.num(row["s_avail_mwth"], 2)
        d["tes"][i] = pub.num(row["tes_start_mwhth"], 2)
        d["tes_end"][i] = pub.num(row["tes_end_mwhth"], 2)
        d["leak"][i] = pub.num(row["leak_mwth"], 3)
    return d


def build_pkg():
    dispatch, days = {}, None
    for key in KEYS:
        r = pub.rows(WK / ("csp_" + key + "_dispatch.csv"))
        days = sorted({x["date"] for x in r})
        dispatch[LABELS[key]] = read_dispatch(key, days)
    NH = len(days) * 24

    summary = []
    for s in pub.rows(WK / "csp_weekly_summary.csv"):
        summary.append({"gate": LABELS[s["scenario"]], "date": s["date"], "solved": 1,
                        "gen_mwh": pub.num(s["gen_mwh"], 1), "buy_mwh": pub.num(s["buy_mwh"], 1),
                        "solar_th_mwh": pub.num(s["solar_th_mwh"], 1),
                        "net_eur": pub.num(s["net_eur"], 0),
                        "theta_future_eur": pub.num(s["theta_future_eur"], 1),
                        "q_end_mwhth": pub.num(s["q_end_mwhth"], 1)})
    plant = {r["param"]: pub.parse_plant_value(r["value"])
             for r in pub.rows(WK / "csp_weekly_plant.csv")}

    Z = [0.0] * NH
    N = [None] * NH
    cats = pub.CATEGORIES
    pkg = {
        "schema": 1, "id": RUN_ID, "days": days, "months": ["2024-07"],
        "price": {"DA": dispatch[LABELS["b-mixed"]]["price"],   # synthetic week, scenario B
                  "ID2": N, "ID3": N, "CID": N, "BAL": N},
        "real_price": N, "status": [1] * NH, "shed": Z, "fail_info": {},
        "categories": cats, "categories_phys": pub.CATEGORIES_PHYS,
        "mix": {st: {c: Z for c in cats} for st in ("DA", "BAL", "RD")},
        "mix_phys": {st: {c: Z for c in pub.CATEGORIES_PHYS} for st in ("DA", "BAL", "RD")},
        "real_mix": {c: N for c in cats},
        "real_phys": {c: N for c in pub.CATEGORIES_PHYS},
        "balancing": {"up": Z, "down": Z, "need": Z},
        "redispatch": {"up": Z, "down": Z, "losses": Z, "cost": Z,
                       "up_by": {c: Z for c in cats}, "down_by": {c: Z for c in cats}},
        "traded": {"ID2": Z, "ID3": Z, "CID": Z},
        "grid": {"frame": [-807.6, -4894.9, 1106.9, 913.7], "corridors": []},
        "plants": {"groups": []}, "sites": {"sites": [], "coverage": {}},
        "csp": {"plant": plant, "gates": [LABELS[k] for k in KEYS],
                "summary": summary, "dispatch": dispatch},
    }
    return pkg, days, NH


def main():
    pkg, days, NH = build_pkg()
    out_run = pub.RUNS_DIR / RUN_ID
    out_run.mkdir(parents=True, exist_ok=True)
    (out_run / "data.js").write_text(
        "VIEWER.addRun(" + json.dumps(pkg, separators=(",", ":"), allow_nan=False) + ");\n",
        encoding="utf-8")
    part = {"h0": 0, "hours": NH, "grid_load": "", "plant_out": "", "plant_chg": "",
            "site_model": "", "site_real": ""}
    (out_run / "2024-07.js").write_text(
        'VIEWER.addMonth("' + RUN_ID + '", "2024-07", ' +
        json.dumps(part, separators=(",", ":")) + ");\n", encoding="utf-8")
    meta = {
        "schema": 1, "id": RUN_ID,
        "name": "CSP weekly scenarios (synthetic July week)",
        "note": "Standalone 7-day CSP/TES experiment (CSP/csp_weekly_scenarios.jl): Mon 2024-07-01 .. "
                "Sun 2024-07-07, one 168-hour LP per weather scenario. In the CSP tab the gate selector "
                "switches between A: clear skies / B: mixed sun and cloud / C: full overcast to compare "
                "the hourly trends. Fully synthetic inputs (Spanish July price shape, demo-scale plant, "
                "physical leak 0.0005/h, persistence continuation value): the Price tab shows scenario "
                "B's synthetic day-ahead week; every other market section is a placeholder because this "
                "run never touched the market chain.",
        "published": datetime.now().isoformat(timespec="seconds"),
        "published_by": "publish_csp_weekly.py",
        "first_day": days[0], "last_day": days[-1], "n_days": len(days),
        "ac_solved": NH, "ac_total": NH, "months": ["2024-07"], "size_mb": 0.05,
        "info": {"ran_by": "CSP/csp_weekly_scenarios.jl", "branch": "public_version",
                 "commit": "-", "commit_message": "", "uncommitted_files": [],
                 "started": "-", "finished": "-", "runtime_min": None,
                 "power_flow": "n/a (LP price taker)", "linear_solver": "HiGHS",
                 "label": "synthetic week", "reconstructed": False},
        "features": {"res": "accepted", "xb": False, "gas": False, "markup": False,
                     "hydro": False, "chain": "day"},
    }
    (out_run / "meta.json").write_text(json.dumps(meta, indent=1), encoding="utf-8")
    print("published %s: %d days, %d scenarios, %d summary rows"
          % (RUN_ID, len(days), len(KEYS), len(pkg["csp"]["summary"])))
    print("now run: python viewer\\publish_powervision_run.py   (rebuilds runs/manifest.js)")


if __name__ == "__main__":
    main()