// Results viewer for the Spain power-market model (github.com/Leide0022/spain-model-runs).
// Reads reference/basemap.js and runs/manifest.js (loaded by index.html), then each picked run's
// package from runs/<id>/. Packages are written by scripts/publish_run.py in the model repo.
(() => {
  // Runs are listed in runs/manifest.js; a run's files (runs/<id>/data.js and one file per month)
  // are loaded when it is picked. Both are written by scripts/publish_run.py in the model repo.
  const MANIFEST = window.RUN_MANIFEST || [];
  const D = { categories: [], categories_phys: [], runs: [] };   // the runs loaded so far
  window.MAP_LAYERS = window.BASEMAP;
  const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
  const PRICE_STAGES = ["DA", "ID2", "ID3", "CID", "BAL"];
  const MIX_STAGES = [["DA", "Day-ahead", "DA"], ["BAL", "Balancing", "BAL"], ["RD", "Redispatch", "RD"]];
  const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const NS = "http://www.w3.org/2000/svg";

  const state = { run: MANIFEST.length ? MANIFEST[0].id : null, priceStage: "DA", priceRes: "hour", mixStage: "DA", mixRes: "hour", mixRef: "omie", cspGate: "BAL", zoom: null, tab: "overview", gridMode: "max", gridHour: null, gridSel: null, mapStyle: "terrain", plantSize: "cap", plantTime: "period", plantHour: null, plantSel: null, plantHidden: [], playSpeed: 2,
    gridLayers: ["hv", "lv", "trafo", "border"], gridSort: ["max", -1], gridQuery: "", gridAll: false };
  const TABS = [["overview", "Overview"], ["price", "Price"], ["mix", "Generation mix"], ["flex", "Trading margin"], ["invest", "Investment case"], ["status", "AC redispatch"], ["csp", "CSP"], ["grid", "Grid"], ["plants", "Power plants"], ["stages", "Market stages"], ["esios", "REE (e·sios)"], ["compare", "Compare runs"]];
  try { const saved = localStorage.getItem("runviewer.tab"); if (TABS.some(x => x[0] === saved)) state.tab = saved; } catch (e) {}
  try { const ms = localStorage.getItem("runviewer.mapStyle"); if (["plain", "political", "terrain", "dark"].includes(ms)) state.mapStyle = ms; } catch (e) {}
  const CAT_COLOR = { Hydro: "var(--cat-1)", CCGT: "var(--cat-2)", Wind: "var(--cat-3)", Solar: "var(--cat-4)",
    "CHP group": "var(--cat-5)", Imports: "var(--cat-6)", Nuclear: "var(--cat-7)", Coal: "var(--cat-8)",
    Gas: "var(--cat-2)", "Bio & other": "var(--cat-5)" };
  const STACK = ["Coal", "Nuclear", "Imports", "CHP group", "Solar", "Wind", "CCGT", "Hydro"]; // bottom to top
  const STACK_PHYS = ["Coal", "Nuclear", "Imports", "Bio & other", "Solar", "Wind", "Gas", "Hydro"];
  const REF_NAME = { omie: "OMIE day-ahead programme", entsoe: "ENTSO-E actual generation" };
  // the real data and model grouping the mix section compares
  function mixData(r) {
    const phys = state.mixRef === "entsoe";
    return {
      ref: state.mixRef, cats: phys ? D.categories_phys : D.categories, stack: phys ? STACK_PHYS : STACK,
      real: phys ? r.real_phys : r.real_mix, model: (phys ? r.mix_phys : r.mix)[state.mixStage],
    };
  }
  try {
    const h = location.hash.slice(1);
    if (MANIFEST.some(m => m.id === h)) state.run = h;
  } catch (e) {}


  // ---------- hover explanations ----------
  const GLOSS = {
    solved: ["AC hours solved", "Share of hours where the AC redispatch (Ipopt) found a solution. In a failed hour the market stages still have results, but the redispatch has none."],
    failed: ["Failed hour", "The AC redispatch stopped without a solution, usually Ipopt getting stuck (local infeasibility). It does not mean the system was short of power."],
    okhour: ["Solved hour", "The AC redispatch found a schedule that respects line limits and voltages for this hour."],
    meanprice: ["Mean day-ahead price", "Average of the model's day-ahead price over the hours shown, next to OMIE's real Spanish day-ahead price for the same hours."],
    bias: ["Price bias", "Model mean minus real mean. Negative means the model price is too low on average. Errors up and down can cancel out here, so read it together with MAE."],
    mae: ["MAE (mean absolute error)", "The average size of the hourly price error, ignoring the sign. 0 is perfect. 20 €/MWh means the model is off by 20 €/MWh in a typical hour."],
    corr: ["Correlation", "How well the model follows the ups and downs of the real price, from −1 to 1. 1 means the same shape (even if the level is off), 0 means no relation."],
    real_price: ["Real price", "OMIE's day-ahead marginal price for the Spanish zone (the marginalpdbc files)."],
    real_ida2: ["Real IDA2 price", "The second European intraday auction (closes 22:00 the day before, all 24 hours), Spanish zone, from e·sios (indicator 613). It replaced the MIBEL intraday sessions on 14 June 2024; earlier days are left out because they were a different market."],
    real_ida3: ["Real IDA3 price", "The third European intraday auction (closes 10:00 on the day, hours 12–23 only), Spanish zone, from e·sios (indicator 614). It replaced the MIBEL intraday sessions on 14 June 2024; earlier days are left out because they were a different market."],
    real_cid: ["Real continuous intraday price", "REE's reference price for the continuous intraday market: the weighted average of all trades for each hour with a buyer or seller in Spain, from e·sios (indicator 1727)."],
    real_bal: ["Real balancing price", "REE's price for replacement reserve (RR), the hourly balancing energy market, from e·sios. The closest real counterpart of the model's balancing (BAL) price; Spain has no single balancing price."],
    ree_rd: ["REE redispatch", "What REE changed after the market for grid security, from e·sios: technical constraints after the day-ahead (phase I adds energy where the grid needs it, phase II takes about the same amount out elsewhere) and real-time constraints."],
    model_bal: ["Model balancing", "What the model's balancing stage moved compared with the continuous intraday schedule, summed up and down over the plants that respond (wind, solar and the fixed cross-border flows left out: their forecast change is what has to be balanced)."],
    ree_imb: ["REE net imbalance", "e·sios indicator 1338: the net imbalance of generation and demand in each hour, which REE covers with balancing energy."],
    model_imb: ["Model forecast change", "Load minus wind minus solar at the balancing stage, minus the same at the continuous intraday stage: the forecast change the model's balancing stage has to cover. It is the model's counterpart of the imbalance."],
    rd_cost: ["Extra cost of redispatch", "What the redispatch costs on top of the market: paid for energy turned up minus what is saved or refunded for energy turned down. REE: its settled cost of technical constraints (P.O. 14.4), pay-as-bid with start-up costs. Model: marginal cost × change, with no start-ups or bids."],
    model_rd: ["Model redispatch", "The model's AC redispatch minus its balancing schedule, summed over all units except the fixed border flows. It includes the grid losses the copper-plate markets do not see. Failed AC hours have no value."],
    real_mix: ["Real generation", "OMIE's day-ahead programme per technology (the 'Energía horaria por tecnologías' report)."],
    DA: ["Day-ahead (DA)", "Clears all 24 hours the day before delivery, using the day-ahead forecast of load, wind and solar."],
    ID2: ["Intraday 2 (ID2)", "Re-clears all 24 hours with an updated forecast, starting from the DA schedule."],
    ID3: ["Intraday 3 (ID3)", "Re-clears hours 12–23 with a newer forecast, starting from ID2."],
    CID: ["Continuous intraday (CID)", "Rolling trading up to one hour before delivery. Each hour is settled with the latest forecast for that hour."],
    BAL: ["Balancing (BAL)", "The last adjustment before delivery, using the realised load, wind and solar."],
    RD: ["Redispatch", "An AC power-flow solve for each hour that changes the balancing schedule so it works on the real grid (line limits, voltages)."],
    Nuclear: ["Nuclear", "Nuclear plants. Their available capacity is set per day from OMIE data."],
    Coal: ["Coal", "Coal plants. The model has no minimum output for coal, so it often runs them at zero."],
    CCGT: ["CCGT", "Combined-cycle gas plants and gas turbines. Industrial CHP gas is counted in the CHP group, not here."],
    Hydro: ["Hydro", "Reservoir, run-of-river and pumped-storage generation. Mini-hydro is in the CHP group."],
    Wind: ["Wind", "Onshore and offshore wind."],
    Solar: ["Solar", "Solar PV and solar thermal."],
    "CHP group": ["CHP group", "OMIE's group 'cogeneration / waste / mini-hydro'. In the model: industrial CHP gas, waste and mini-hydro blocks, plus biomass."],
    Imports: ["Imports", "Imports from France and Portugal. Real: OMIE's import columns. Model: the interconnector units."],
    input: ["Model input", "At day-ahead this comes from OMIE's own numbers, so it matches by construction and says nothing about model accuracy."],
    diff: ["Difference", "Model energy minus real energy over the hours shown. The bar shows its size next to the other technologies."],
    hourly_error: ["Hourly error", "Average absolute difference in MW between model and real, hour by hour. Unlike the total, errors up and down do not cancel."],
    commit: ["Code version", "The git commit the run used. Anyone can get exactly that code with git checkout and the commit id."],
    dirty: ["Uncommitted changes", "Files that were edited but not committed when the run started. The commit alone does not reproduce the run exactly."],
    rd_setup: ["Redispatch setup", "AC means a full AC power flow solved with Ipopt. HSL MA57 is the fast linear solver Ipopt uses; MUMPS is the slower default."],
    Gas: ["Gas", "All gas-fired generation: combined cycles, gas turbines and industrial CHP gas. ENTSO-E reports them together as 'Fossil Gas'."],
    "Bio & other": ["Biomass & other", "Biomass, waste, oil and ENTSO-E's 'other' types. In the model: biomass, the waste block and the oil units."],
    ref_omie: ["OMIE day-ahead programme", "The result of the day-ahead market: what was planned the day before. Right reference for the market stages (DA to BAL)."],
    ref_entsoe: ["ENTSO-E actual generation", "Measured output per fuel type: what plants really produced after all markets and REE's grid fixes. Right reference for the redispatch."],
    g_max: ["Highest loading", "For each line, the highest loading in any solved hour of the shown period."],
    g_h90: ["Hours at 90 % or more", "For each line, how many solved hours in the shown period it was loaded to 90 % of its limit or more."],
    g_hour: ["One hour", "Loading of every line in a single hour. Pick the hour with the slider; failed AC hours have no flows."],
    st_plain: ["Plain map", "Land, sea and country borders only, so the lines stand out most."],
    st_political: ["Political map", "Spain's autonomous communities and provinces, the largest cities, and Soto de Ribera."],
    st_terrain: ["Terrain map", "Shaded mountains and valleys (Natural Earth shaded relief), with the communities and cities."],
    st_dark: ["Dark map", "A dark background where the loaded lines light up. Stays dark in a light page."],
    p_cap: ["Installed capacity", "The MW the plants can produce at most. Shows where the generation fleet is."],
    p_out: ["Output", "What the plants produced in the AC redispatch (the final stage), as an average over the shown period or in one hour."],
    p_chg: ["Redispatch change", "Redispatch output minus balancing output: how much the grid stage turned each plant up or down to keep line flows and voltages within limits."],
    p_period: ["Average over period", "The average over all solved hours in the shown period."],
    p_hour: ["One hour", "A single hour; pick it with the slider. Failed AC hours have no redispatch output."],
    p_realout: ["Real output", "What the plant really produced (ENTSO-E's measured output per unit), as an average over the shown period or in one hour. Only plants ENTSO-E reports one by one are shown."],
    p_real: ["Real vs model", "Compares the model's redispatch output with what the plant really produced (ENTSO-E). Only plants ENTSO-E reports one by one are shown."],
    p_above: ["Model above real", "A filled circle: the model ran the plant more than it really ran."],
    p_below: ["Model below real", "A ring: the model ran the plant less than it really ran."],
    p_entsoe: ["ENTSO-E unit data", "ENTSO-E's 'actual generation per generation unit': measured hourly output of each large unit (about 100 MW and up), matched to the model's plants by a hand-made table."],
    p_up: ["Turned up", "A filled circle: the grid stage made the plant produce more than in the balancing market."],
    p_down: ["Turned down", "A ring: the grid stage made the plant produce less than in the balancing market."],
    soto: ["Soto de Ribera", "The coal plant studied in the thesis (Ribera de Arriba, Asturias). Location approximate."],
    g_hv: ["400 kV lines", "The main transmission grid (400 kV, plus the 320 kV DC link to France counted as a line). Drawn thick."],
    g_lv: ["220 kV and lower", "The regional grid: 220 kV and the few 132 kV lines. Drawn thin."],
    g_trafo: ["Transformers", "Connect two voltage levels at one substation (e.g. 400/220 kV). Both ends are at the same place, so they are drawn as squares, coloured by loading like the lines."],
    g_border: ["Border lines", "The lines to France and Portugal. The model enters the exchange with each country as fixed power at the far end of these lines, split by line rating."],
    g_nlim: ["Hours at limit", "Solved AC hours in the period where this line or transformer carried its full limit (100 % loading). Failed hours are not counted."],
    g_limit: ["At limit", "The line carries its full limit. The AC redispatch does not let a line go over its limit, so 100 % means the limit is binding."],
    gas_dot: ["CCGT running", "A combined-cycle gas plant produced more than 1 MW at the balancing stage in that hour."],
    f_chain: ["Market stage order", "Stage by stage: each market stage is solved for all days before the next stage (DA for every day, then ID2 for every day, …). Day by day: each day runs DA → ID2 → ID3 → CID → BAL before the next day starts, as in reality, so a day can hand on which plants are running at midnight (model change §16). See the Market stages tab."],
    f_res: ["Solar/wind input", "Accepted: OMIE's accepted day-ahead solar and wind. Offered: also what was offered in the auction but not accepted, so the model can curtail it (model change §12)."],
    f_xb: ["Cross-border split", "The redispatch chooses how the exchange with France and Portugal is split over the border lines, instead of a fixed split by line rating (§11). Removed most failed AC hours."],
    f_gas: ["Gas and coal", "Each gas plant has its own cost (daily gas and CO₂ price, efficiency by build year) and on/off rules; coal cost from import prices; closed coal plants removed; island plants out of the market; day-by-day market chain (§13, §14, §16)."],
    f_markup: ["Tax and mark-ups", "Spain's generation tax (IVPEE, by quarter) and mark-ups on gas and coal bids; the gas mark-up is higher in tight hours (§17)."],
    f_hydro: ["Improved hydro planning", "Improved hydro planning: real starting reservoir level (REE), seasonal limits (rule curves) and monthly inflow (§15)."],
    f_margin: ["Trading margin", "Money from selling electricity minus money paid for the electricity it bought. Not profit: the investment (heater, tank or battery), staff, maintenance, insurance, wear, grid charges and taxes still have to be paid out of it. Here it is also a best case: perfect knowledge of the day's prices, day-ahead market only."],
    f_len: ["Period", "Length of the run: a full year, about a month, or a week or less."],
  };
  const term = (label, key) => `<span class="term" tabindex="0" data-tip="${key}">${label}</span>`;
  const gloss = document.createElement("div");
  gloss.className = "gloss"; gloss.hidden = true; gloss.setAttribute("role", "tooltip");
  document.body.appendChild(gloss);
  let glossAnchor = null;
  function showGloss(el) {
    const g = GLOSS[el.dataset.tip]; if (!g) return;
    glossAnchor = el;
    gloss.innerHTML = `<b>${g[0]}</b>${g[1]}`; gloss.hidden = false;
    const r = el.getBoundingClientRect(), gw = gloss.offsetWidth, vw = document.documentElement.clientWidth;
    const left = Math.max(8, Math.min(r.left, vw - gw - 8));
    let top = r.bottom + 6;
    if (top + gloss.offsetHeight > window.innerHeight - 8) top = r.top - gloss.offsetHeight - 6;
    gloss.style.left = left + window.scrollX + "px"; gloss.style.top = top + window.scrollY + "px";
  }
  function hideGloss() { gloss.hidden = true; glossAnchor = null; }
  document.addEventListener("pointerover", e => { const el = e.target.closest && e.target.closest("[data-tip]"); if (el) showGloss(el); });
  document.addEventListener("pointerout", e => { const el = e.target.closest && e.target.closest("[data-tip]"); if (el && !el.contains(e.relatedTarget)) hideGloss(); });
  document.addEventListener("focusin", e => { const el = e.target.closest && e.target.closest("[data-tip]"); if (el) showGloss(el); });
  document.addEventListener("focusout", hideGloss);
  document.addEventListener("pointermove", () => { if (glossAnchor && !glossAnchor.isConnected) hideGloss(); });
  window.addEventListener("scroll", hideGloss, { passive: true });

  // ---------- the visible period (zoom) ----------
  function view() {
    const r = run(), z = state.zoom;
    if (!z) return { ...r, offset: 0 };
    const h0 = z[0] * 24, h1 = (z[1] + 1) * 24;
    const sl = a => a.slice(h0, h1);
    const each = (o, f) => Object.fromEntries(Object.entries(o).map(([k, v]) => [k, f(v)]));
    return {
      ...r, offset: z[0], days: r.days.slice(z[0], z[1] + 1),
      price: each(r.price, sl), real_price: sl(r.real_price), status: sl(r.status),
      real_mix: each(r.real_mix, sl), mix: each(r.mix, m => each(m, sl)),
      real_phys: each(r.real_phys, sl), mix_phys: each(r.mix_phys, m => each(m, sl)),
      balancing: r.balancing ? each(r.balancing, sl) : null,
      traded: r.traded ? each(r.traded, sl) : null,
      redispatch: r.redispatch ? Object.fromEntries(Object.entries(r.redispatch).map(([k, v]) => [k, Array.isArray(v) ? sl(v) : each(v, sl)])) : null,
    };
  }
  function setZoom(a, b) {
    const nd = run().days.length;
    a = Math.max(0, Math.min(nd - 1, a)); b = Math.max(a, Math.min(nd - 1, b));
    state.zoom = a === 0 && b === nd - 1 ? null : [a, b];
    hideGloss(); renderAll();
  }
  // a drag on a chart gives chart-local indices; hourly charts snap to whole days
  function zoomFromChart(a, b, hourly) {
    const off = view().offset;
    setZoom(off + (hourly ? Math.floor(a / 24) : a), off + (hourly ? Math.floor(b / 24) : b));
  }

  // ---------- helpers ----------
  const $ = id => document.getElementById(id);
  const nf = (x, d = 1) => x == null || Number.isNaN(x) ? "–" :
    x.toLocaleString("en-GB", { minimumFractionDigits: d, maximumFractionDigits: d }).replace("-", "−");
  const signed = (x, d = 1) => x == null ? "–" : (x > 0 ? "+" : "") + nf(x, d);
  const dt = iso => new Date(iso + "T00:00:00Z");
  const dayLabel = (iso, dow = true) => { const d = dt(iso); return (dow ? DOW[d.getUTCDay()] + " " : "") + d.getUTCDate() + " " + MON[d.getUTCMonth()]; };
  const hh = h => String(h).padStart(2, "0") + ":00";
  function period(days) {
    const a = dt(days[0]), b = dt(days[days.length - 1]);
    return a.getUTCMonth() === b.getUTCMonth()
      ? `${a.getUTCDate()}–${b.getUTCDate()} ${MON[b.getUTCMonth()]} ${b.getUTCFullYear()}`
      : `${dayLabel(days[0], false)} – ${dayLabel(days[days.length - 1], false)} ${b.getUTCFullYear()}`;
  }
  function svg(tag, attrs, parent) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    if (parent) parent.appendChild(e);
    return e;
  }
  // REE e·sios series (reference/esios_2024.js) for the days a view shows, 24 values per day
  const esiosDay = window.ESIOS ? Object.fromEntries(window.ESIOS.days.map((d, i) => [d, i])) : {};
  function esiosFor(r, key) {
    const E = window.ESIOS, s = E && E.series[key];
    if (!s) return null;
    // scenario runs (e.g. 2035) carry 2024 calendar dates: REE's 2024 data must not sit next to them
    if (r.scenario) return r.days.flatMap(() => Array(24).fill(null));
    return r.days.flatMap(d => { const i = esiosDay[d]; return i == null ? Array(24).fill(null) : s.slice(i * 24, i * 24 + 24); });
  }
  const mean = a => { let s = 0, n = 0; for (const x of a) if (x != null) { s += x; n++; } return n ? s / n : null; };
  function pairs(a, b) { const out = []; for (let i = 0; i < a.length; i++) if (a[i] != null && b[i] != null) out.push([a[i], b[i]]); return out; }
  function corr(p) {
    const n = p.length; if (n < 3) return null;
    const mx = p.reduce((s, q) => s + q[0], 0) / n, my = p.reduce((s, q) => s + q[1], 0) / n;
    let sxy = 0, sxx = 0, syy = 0;
    for (const [x, y] of p) { sxy += (x - mx) * (y - my); sxx += (x - mx) ** 2; syy += (y - my) ** 2; }
    return sxx && syy ? sxy / Math.sqrt(sxx * syy) : null;
  }
  function dailyMean(arr, nDays) {
    const out = [];
    for (let d = 0; d < nDays; d++) out.push(mean(arr.slice(d * 24, d * 24 + 24)));
    return out;
  }
  function dailySum(arr, nDays) {
    const out = [];
    for (let d = 0; d < nDays; d++) {
      const sl = arr.slice(d * 24, d * 24 + 24).filter(x => x != null);
      out.push(sl.length ? sl.reduce((s, x) => s + x, 0) / 1000 : null);
    }
    return out;
  }
  function niceTicks(lo, hi, count) {
    const span = hi - lo || 1, raw = span / count, mag = 10 ** Math.floor(Math.log10(raw));
    const step = [1, 2, 2.5, 5, 10].map(m => m * mag).find(s => span / s <= count) || 10 * mag;
    const t0 = Math.floor(lo / step) * step, t1 = Math.ceil(hi / step) * step, out = [];
    for (let t = t0; t <= t1 + step / 2; t += step) out.push(+t.toFixed(6));
    return out;
  }
  const run = () => D.runs.find(r => r.id === state.run);
  const icon = kind => kind === "bad"
    ? '<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="5.5" fill="var(--critical)"/><path d="M6 3v3.6M6 8.4v.2" stroke="#fff" stroke-width="1.6" stroke-linecap="round"/></svg>'
    : kind === "warn"
    ? '<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><path d="M6 .8 11.4 10.6H.6Z" fill="#fab219"/><path d="M6 4.3v3M6 8.9v.1" stroke="#141413" stroke-width="1.4" stroke-linecap="round"/></svg>'
    : '<svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true"><circle cx="6" cy="6" r="5.5" fill="var(--good)"/><path d="m3.4 6.2 1.8 1.8 3.4-3.6" stroke="#fff" stroke-width="1.5" fill="none" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  function solveStatus(pct) {
    if (pct >= 97) return ["good", "Good"];
    if (pct >= 90) return ["warn", "Some failures"];
    return ["bad", "Many failures"];
  }

  // ---------- generic line chart ----------
  function lineChart(host, o) {
    host.innerHTML = "";
    const W = Math.max(260, host.clientWidth);
    const H = o.height;
    const all = o.series.flatMap(s => s.values.filter(v => v != null));
    let lo = Math.min(0, ...all), hi = Math.max(...all, 1);
    const ticks = niceTicks(lo, hi, o.yTicks || 4);
    lo = ticks[0]; hi = ticks[ticks.length - 1];
    // left margin wide enough for the longest axis number (e.g. 1,200,000 €)
    const tickW = Math.max(...ticks.map(t => t.toLocaleString("en-GB").length)) * 6.6 + 12;
    const endW = o.endLabels ? Math.max(...o.series.map(q => String(q.name).length)) * 7.6 + 16 : 8;
    const m = { l: Math.max(40, tickW), r: o.endLabels ? Math.max(66, endW) : 8, t: o.yUnit ? 26 : 8, b: (o.band ? 34 : 0) + 22 };
    const pw = W - m.l - m.r, ph = H - m.t - m.b;
    const n = o.n;
    const x = i => m.l + (n === 1 ? pw / 2 : (i / (n - 1)) * pw);
    const y = v => m.t + ph - ((v - lo) / (hi - lo)) * ph;
    const s = svg("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": o.label }, host);

    for (const t of ticks) {
      svg("line", { x1: m.l, x2: m.l + pw, y1: y(t), y2: y(t), stroke: t === 0 ? "var(--axis)" : "var(--grid)", "stroke-width": 1 }, s);
      const tx = svg("text", { x: m.l - 6, y: y(t) + 4, "text-anchor": "end" }, s);
      tx.textContent = t.toLocaleString("en-GB");
    }
    if (o.yUnit) { const u = svg("text", { x: 0, y: 15, "text-anchor": "start", class: "y-unit" }, s); u.textContent = o.yUnit; }
    const xb = m.t + ph;
    for (const t of o.xTicks) {
      svg("line", { x1: x(t.i), x2: x(t.i), y1: xb, y2: xb + 4, stroke: "var(--axis)" }, s);
      const tx = svg("text", { x: x(t.i), y: xb + (o.band ? 34 : 0) + 16, "text-anchor": "middle" }, s);
      tx.textContent = t.label;
    }

    if (o.band) {
      const by = xb + 10, bh = 14;
      svg("rect", { x: m.l, y: by, width: pw, height: bh, fill: "var(--surface-2)", rx: 2 }, s);
      const bw = Math.max(1.5, pw / Math.max(n, 1));
      o.band.forEach((v, i) => {
        if (!v) return;
        const hgt = Math.max(3, bh * v);
        svg("rect", { x: x(i) - bw / 2, y: by + bh - hgt, width: bw, height: hgt, fill: "var(--critical)" }, s);
      });
      const bl = svg("text", { x: m.l - 6, y: by + 11, "text-anchor": "end" }, s);
      bl.textContent = "AC";
    }

    for (const ser of o.series) {
      let d = "", pen = false;
      ser.values.forEach((v, i) => {
        if (v == null) { pen = false; return; }
        d += (pen ? "L" : "M") + x(i).toFixed(1) + "," + y(v).toFixed(1);
        pen = true;
      });
      const pa = svg("path", { d, fill: "none", stroke: ser.color, "stroke-width": Math.max(2, ser.width || 2), "stroke-linejoin": "round", "stroke-linecap": "round" }, s);
      if (ser.dash) pa.setAttribute("stroke-dasharray", ser.dash);
    }
    // optional dots on the first series, e.g. the hours a storage unit charges or discharges
    for (const pt of o.points || []) for (const i of pt.idx) {
      const v = o.series[0].values[i];
      if (v != null) svg("circle", { cx: x(i), cy: y(v), r: pt.r || 3, fill: pt.color, stroke: "var(--surface)", "stroke-width": 1, "pointer-events": "none" }, s);
    }

    if (o.endLabels) {
      const ends = o.series.map(ser => {
        let i = ser.values.length - 1; while (i >= 0 && ser.values[i] == null) i--;
        return { ser, yy: i >= 0 ? y(ser.values[i]) : null };
      }).filter(e => e.yy != null).sort((a, b) => a.yy - b.yy);
      for (let k = 1; k < ends.length; k++) if (ends[k].yy - ends[k - 1].yy < 14) ends[k].yy = ends[k - 1].yy + 14;
      for (const e of ends) {
        const t = svg("text", { x: m.l + pw + 8, y: e.yy + 4, class: "end-label" }, s);
        t.style.fill = e.ser.color;
        t.textContent = e.ser.name;
      }
    }

    // hover layer
    const tip = document.createElement("div"); tip.className = "tip"; tip.hidden = true; host.appendChild(tip);
    const guide = svg("line", { y1: m.t, y2: xb, stroke: "var(--axis)", "stroke-width": 1, visibility: "hidden" }, s);
    const dots = o.series.map(ser => svg("circle", { r: 4, fill: ser.color, stroke: "var(--surface)", "stroke-width": 2, visibility: "hidden" }, s));
    const sel = svg("rect", { y: m.t, height: ph, fill: "var(--model)", opacity: 0.12, visibility: "hidden", "pointer-events": "none" }, s);
    const hit = svg("rect", { x: m.l, y: m.t, width: pw, height: ph + (o.band ? 34 : 0), fill: "transparent", tabindex: 0, "aria-label": o.label + ". Use the arrow keys to read values." }, s);
    if (o.onZoom) { hit.style.cursor = "crosshair"; hit.style.touchAction = "pan-y"; }
    let cur = -1, drag = null;
    const idxAt = ev => { const r = s.getBoundingClientRect(); const px = (ev.clientX - r.left) * (W / r.width); return Math.max(0, Math.min(n - 1, Math.round(((px - m.l) / pw) * (n - 1)))); };
    hit.addEventListener("pointerdown", ev => { if (!o.onZoom || n < 2) return; drag = idxAt(ev); hit.setPointerCapture(ev.pointerId); });
    hit.addEventListener("pointerup", ev => {
      if (drag == null) return;
      const j = idxAt(ev), a = Math.min(drag, j), b = Math.max(drag, j);
      drag = null; sel.setAttribute("visibility", "hidden");
      if (x(b) - x(a) > 6) o.onZoom(a, b);
    });
    hit.addEventListener("pointercancel", () => { drag = null; sel.setAttribute("visibility", "hidden"); });
    function show(i) {
      if (i < 0 || i >= n) return hide();
      cur = i;
      guide.setAttribute("x1", x(i)); guide.setAttribute("x2", x(i)); guide.setAttribute("visibility", "visible");
      o.series.forEach((ser, k) => {
        const v = ser.values[i];
        if (v == null) { dots[k].setAttribute("visibility", "hidden"); return; }
        dots[k].setAttribute("cx", x(i)); dots[k].setAttribute("cy", y(v)); dots[k].setAttribute("visibility", "visible");
      });
      tip.innerHTML = o.tooltip(i);
      tip.hidden = false;
      const k = s.getBoundingClientRect().width / W, tw = tip.offsetWidth, hw = host.clientWidth;
      let left = x(i) * k + 12; if (left + tw > hw) left = x(i) * k - tw - 12;
      tip.style.left = Math.max(0, left) + "px"; tip.style.top = m.t * k + "px";
    }
    function hide() {
      cur = -1; tip.hidden = true; guide.setAttribute("visibility", "hidden");
      dots.forEach(d => d.setAttribute("visibility", "hidden"));
    }
    hit.addEventListener("pointermove", ev => {
      const r = s.getBoundingClientRect();
      const px = (ev.clientX - r.left) * (W / r.width);
      show(Math.round(((px - m.l) / pw) * (n - 1)));
      if (drag != null) {
        const j = idxAt(ev);
        sel.setAttribute("x", Math.min(x(drag), x(j))); sel.setAttribute("width", Math.abs(x(j) - x(drag))); sel.setAttribute("visibility", "visible");
      }
    });
    hit.addEventListener("pointerleave", hide);
    hit.addEventListener("focus", () => show(cur < 0 ? n - 1 : cur));
    hit.addEventListener("blur", hide);
    hit.addEventListener("keydown", ev => {
      const step = ev.shiftKey ? 24 : 1;
      if (ev.key === "ArrowRight") { show(Math.min(n - 1, cur + step)); ev.preventDefault(); }
      if (ev.key === "ArrowLeft") { show(Math.max(0, cur - step)); ev.preventDefault(); }
    });
  }

  function stackChart(host, o) {
    host.innerHTML = "";
    const W = Math.max(260, host.clientWidth), H = o.height;
    const ticks = niceTicks(0, o.yMax, 4), hi = ticks[ticks.length - 1];
    const m = { l: Math.max(48, Math.max(...ticks.map(t => t.toLocaleString("en-GB").length)) * 6.6 + 12), r: 8, t: 26, b: 22 };
    const pw = W - m.l - m.r, ph = H - m.t - m.b, n = o.n;
    const x = i => m.l + (n === 1 ? pw / 2 : (i / (n - 1)) * pw);
    const y = v => m.t + ph - (v / hi) * ph;
    const s = svg("svg", { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": o.label }, host);
    for (const tk of ticks) {
      svg("line", { x1: m.l, x2: m.l + pw, y1: y(tk), y2: y(tk), stroke: tk === 0 ? "var(--axis)" : "var(--grid)" }, s);
      const tx = svg("text", { x: m.l - 6, y: y(tk) + 4, "text-anchor": "end" }, s); tx.textContent = tk.toLocaleString("en-GB");
    }
    const u = svg("text", { x: 0, y: 15, class: "y-unit" }, s); u.textContent = o.yUnit;
    const valid = Array.from({ length: n }, (_, i) => o.layers.every(L => L.values[i] != null));
    let base = new Array(n).fill(0);
    for (const L of o.layers) {
      const top = base.map((b, i) => valid[i] ? b + Math.max(0, L.values[i]) : null);
      for (let i = 0; i < n;) {
        while (i < n && !valid[i]) i++;
        if (i >= n) break;
        let j = i; while (j + 1 < n && valid[j + 1]) j++;
        let d = `M${x(i).toFixed(1)},${y(top[i]).toFixed(1)}`;
        for (let k = i + 1; k <= j; k++) d += `L${x(k).toFixed(1)},${y(top[k]).toFixed(1)}`;
        for (let k = j; k >= i; k--) d += `L${x(k).toFixed(1)},${y(base[k]).toFixed(1)}`;
        svg("path", { d: d + "Z", fill: L.color, stroke: "var(--surface)", "stroke-width": 0.75, "stroke-linejoin": "round" }, s);
        i = j + 1;
      }
      base = top.map((tp, i) => tp == null ? base[i] : tp);
    }
    for (const tk of o.xTicks) {
      svg("line", { x1: x(tk.i), x2: x(tk.i), y1: m.t + ph, y2: m.t + ph + 4, stroke: "var(--axis)" }, s);
      const tx = svg("text", { x: x(tk.i), y: m.t + ph + 16, "text-anchor": "middle" }, s); tx.textContent = tk.label;
    }
    const guide = svg("line", { y1: m.t, y2: m.t + ph, stroke: "var(--ink)", "stroke-width": 1, visibility: "hidden" }, s);
    const tip = document.createElement("div"); tip.className = "tip"; tip.hidden = true; host.appendChild(tip);
    const sel = svg("rect", { y: m.t, height: ph, fill: "var(--ink)", opacity: 0.15, visibility: "hidden", "pointer-events": "none" }, s);
    const hit = svg("rect", { x: m.l, y: m.t, width: pw, height: ph, fill: "transparent", tabindex: 0, "aria-label": o.label + ". Use the arrow keys to read values." }, s);
    hit.style.cursor = "crosshair"; hit.style.touchAction = "pan-y";
    let cur = -1, drag = null;
    const idxAt = ev => { const r = s.getBoundingClientRect(); return Math.max(0, Math.min(n - 1, Math.round((((ev.clientX - r.left) * (W / r.width)) - m.l) / pw * (n - 1)))); };
    hit.addEventListener("pointerdown", ev => { if (n < 2) return; drag = idxAt(ev); hit.setPointerCapture(ev.pointerId); });
    hit.addEventListener("pointerup", ev => {
      if (drag == null) return;
      const j = idxAt(ev), a = Math.min(drag, j), b = Math.max(drag, j);
      drag = null; sel.setAttribute("visibility", "hidden");
      if (x(b) - x(a) > 6) o.onZoom(a, b);
    });
    hit.addEventListener("pointercancel", () => { drag = null; sel.setAttribute("visibility", "hidden"); });
    hit.addEventListener("pointermove", ev => {
      if (drag == null) return;
      const j = idxAt(ev);
      sel.setAttribute("x", Math.min(x(drag), x(j))); sel.setAttribute("width", Math.abs(x(j) - x(drag))); sel.setAttribute("visibility", "visible");
    });
    const api = {
      guide(i) { guide.setAttribute("x1", x(i)); guide.setAttribute("x2", x(i)); guide.setAttribute("visibility", "visible"); },
      hide() { guide.setAttribute("visibility", "hidden"); tip.hidden = true; },
      hideTip() { tip.hidden = true; },
      tip(i, html) {
        tip.innerHTML = html; tip.hidden = false;
        const k = s.getBoundingClientRect().width / W, tw = tip.offsetWidth, hw = host.clientWidth;
        let left = x(i) * k + 14; if (left + tw > hw) left = x(i) * k - tw - 14;
        tip.style.left = Math.max(0, left) + "px"; tip.style.top = "4px";
      },
    };
    const go = i => { if (i < 0 || i >= n) return; cur = i; o.onMove(i, api); };
    hit.addEventListener("pointermove", ev => { const r = s.getBoundingClientRect(); go(Math.round((((ev.clientX - r.left) * (W / r.width)) - m.l) / pw * (n - 1))); });
    hit.addEventListener("pointerleave", () => { cur = -1; o.onLeave(); });
    hit.addEventListener("focus", () => go(cur < 0 ? n - 1 : cur));
    hit.addEventListener("blur", () => o.onLeave());
    hit.addEventListener("keydown", ev => {
      const st = ev.shiftKey ? 24 : 1;
      if (ev.key === "ArrowRight") { go(Math.min(n - 1, cur + st)); ev.preventDefault(); }
      if (ev.key === "ArrowLeft") { go(Math.max(0, cur - st)); ev.preventDefault(); }
    });
    return api;
  }

  function renderStacks(r) {
    const hourly = state.mixRes === "hour", nd = r.days.length;
    const md = mixData(r), CATS = md.cats, STACK = md.stack;
    const series = src => Object.fromEntries(CATS.map(c => [c, hourly ? src[c] : dailyMean(src[c], nd)]));
    const real = series(md.real), model = series(md.model);
    const n = real[CATS[0]].length;
    let yMax = 1;
    for (const src of [real, model]) for (let i = 0; i < n; i++) {
      let tot = 0; for (const c of CATS) tot += Math.max(0, src[c][i] || 0); yMax = Math.max(yMax, tot);
    }
    const stageName = MIX_STAGES.find(s => s[0] === state.mixStage)[1];
    $("stack-real-title").innerHTML = `<span class="st-main"><i style="background:var(--real)"></i>Real</span><span class="st-sub">${REF_NAME[md.ref]}</span>`;
    $("stack-model-title").innerHTML = `<span class="st-main"><i style="background:var(--model)"></i>Model</span><span class="st-sub">${stageName}${state.mixStage === "RD" ? ", gaps are failed hours" : ""} · grouped like ${md.ref === "entsoe" ? "ENTSO-E" : "OMIE"}</span>`;
    $("stack-legend").innerHTML = [...STACK].reverse().map(c => `<span><i class="sw-box" style="background:${CAT_COLOR[c]}"></i>${term(c, c)}</span>`).join("")
      + `<span style="color:var(--muted)">${hourly ? "MW each hour" : "Average MW per day"}</span>`;
    const charts = [];
    const tipHtml = i => {
      const day = hourly ? Math.floor(i / 24) : i;
      const when = dayLabel(r.days[day]) + (hourly ? ", " + hh(i % 24) : " (daily average)");
      let tr = 0, tm = 0, mOk = true;
      const rows = [...STACK].reverse().map(c => {
        const a = real[c][i], b = model[c][i];
        tr += a || 0; if (b == null) mOk = false; else tm += b;
        return `<tr><td><i class="sw-box" style="background:${CAT_COLOR[c]};margin-right:6px"></i>${c}</td><td>${nf(a, 0)}</td><td>${nf(b, 0)}</td></tr>`;
      }).join("");
      return `<b>${when}</b><table><tr><th></th><th>Real MW</th><th>Model MW</th></tr>${rows}
        <tr class="total"><td>Total</td><td>${nf(tr, 0)}</td><td>${mOk ? nf(tm, 0) : "–"}</td></tr></table>`;
    };
    const opts = (host, src, label) => ({
      n, height: state.tab === "mix" ? 300 : 230, yMax, yUnit: "MW", label,
      xTicks: dayTicks(r.days, hourly, host.clientWidth - 60),
      layers: STACK.map(c => ({ name: c, color: CAT_COLOR[c], values: src[c] })),
      onMove: (i, me) => { charts.forEach(c => { c.guide(i); if (c !== me) c.hideTip(); }); me.tip(i, tipHtml(i)); },
      onLeave: () => charts.forEach(c => c.hide()),
      onZoom: (a, b) => zoomFromChart(a, b, hourly),
    });
    charts.push(stackChart($("stack-real"), opts($("stack-real"), real, "Real generation mix, stacked")));
    charts.push(stackChart($("stack-model"), opts($("stack-model"), model, "Model generation mix, stacked")));
  }

  function dayTicks(days, perHour, width) {
    const n = days.length;
    const every = Math.max(1, Math.ceil(n / Math.max(2, Math.floor(width / 64))));
    const out = [];
    for (let d = 0; d < n; d += every) out.push({ i: perHour ? d * 24 : d, label: dayLabel(days[d], false) });
    if (perHour && n <= 2) for (let d = 0; d < n; d++) for (const h of [6, 12, 18]) out.push({ i: d * 24 + h, label: hh(h) });
    else if (perHour && n <= 4) for (let d = 0; d < n; d++) out.push({ i: d * 24 + 12, label: "12:00" });
    return out;
  }

  function seg(host, options, current, onPick) {
    host.innerHTML = "";
    for (const [val, label, tip] of options) {
      const b = document.createElement("button");
      b.type = "button"; b.textContent = label;
      if (tip) b.dataset.tip = tip;
      b.setAttribute("aria-pressed", String(val === current));
      b.addEventListener("click", () => onPick(val));
      host.appendChild(b);
    }
  }

  // ---------- run filters: which model changes a run used ----------
  // meta.features in runs/manifest.js: res ("accepted"/"offered") and true/false for the rest;
  // a run without features only shows when that filter is on "Any".
  const ON_OFF = [["any", "Any"], ["on", "On"], ["off", "Off"]];
  const FEATS = [
    ["chain", "Market stage order", "f_chain", [["any", "Any"], ["stage", "Stage"], ["day", "Day by day"]], "day by day"],
    ["res", "Solar/wind", "f_res", [["any", "Any"], ["accepted", "Accepted"], ["offered", "Offered"]], "offered"],
    ["xb", "Cross-border split", "f_xb", ON_OFF, "cross-border"],
    ["gas", "Gas and coal", "f_gas", ON_OFF, "gas & coal"],
    ["markup", "Tax and mark-ups", "f_markup", ON_OFF, "mark-ups"],
    ["hydro", "Improved hydro planning", "f_hydro", ON_OFF, "hydro"],
    ["len", "Period", "f_len", [["any", "Any"], ["year", "Year"], ["month", "Month"], ["week", "≤ Week"]], null],
  ];
  const filters = Object.fromEntries(FEATS.map(f => [f[0], "any"]));
  try { const sf = JSON.parse(localStorage.getItem("runviewer.filters") || "{}"); for (const [k, opts] of FEATS.map(f => [f[0], f[3]])) if (opts.some(o => o[0] === sf[k])) filters[k] = sf[k]; } catch (e) {}
  function featValue(m, key) {
    if (key === "len") return m.n_days >= 300 ? "year" : m.n_days >= 20 ? "month" : "week";
    const v = (m.features || {})[key];
    return v == null ? null : typeof v === "boolean" ? (v ? "on" : "off") : v;
  }
  const runMatches = (m, skip) => FEATS.every(([k]) => k === skip || filters[k] === "any" || featValue(m, k) === filters[k]);
  function renderRunFilters() {
    const host = $("rf-body"); host.innerHTML = "";
    for (const [key, label, tip, opts] of FEATS) {
      const row = document.createElement("div"); row.className = "rf-row";
      row.innerHTML = `<span class="rf-label">${term(label, tip)}</span>`;
      const g = document.createElement("div"); g.className = "seg rf-seg"; g.setAttribute("role", "group"); g.setAttribute("aria-label", label);
      for (const [val, txt] of opts) {
        // how many runs this choice would leave, given the other filters
        const n = MANIFEST.filter(m => runMatches(m, key) && (val === "any" || featValue(m, key) === val)).length;
        const b = document.createElement("button");
        b.type = "button"; b.setAttribute("aria-pressed", String(filters[key] === val));
        b.innerHTML = `${esc(txt)}<span class="rf-n">${n}</span>`;
        b.disabled = n === 0 && filters[key] !== val;
        b.addEventListener("click", () => { filters[key] = val; saveFilters(); renderRunList(); });
        g.appendChild(b);
      }
      row.appendChild(g); host.appendChild(row);
    }
    const nActive = FEATS.filter(f => filters[f[0]] !== "any").length;
    $("rf-active").innerHTML = nActive ? `${nActive} on · <button type="button" class="rf-clear" id="rf-clear">Clear</button>` : "";
    if (nActive) $("rf-clear").addEventListener("click", ev => { ev.preventDefault(); FEATS.forEach(f => { filters[f[0]] = "any"; }); saveFilters(); renderRunList(); });
  }
  function saveFilters() { try { localStorage.setItem("runviewer.filters", JSON.stringify(filters)); } catch (e) {} }

  // ---------- sections ----------
  let runsOpen = false;
  try { runsOpen = localStorage.getItem("runviewer.runsOpen") === "1"; } catch (e) {}
  function setRunsOpen(open) {
    runsOpen = open;
    try { localStorage.setItem("runviewer.runsOpen", open ? "1" : "0"); } catch (e) {}
    document.querySelector(".layout").classList.toggle("runs-closed", !open);
    const t = $("runs-toggle"); if (t) t.setAttribute("aria-expanded", String(open));
    if (open) window.scrollTo({ top: 0 });
  }
  function renderRunList() {
    renderRunFilters();
    const host = $("run-list"); host.innerHTML = "";
    const shown = MANIFEST.filter(m => runMatches(m));
    for (const m of shown) {
      const pct = m.ac_total ? 100 * m.ac_solved / m.ac_total : 0, i = m.info || {};
      const tagOn = { res: "offered", chain: "day" };
      const tags = m.features ? FEATS.filter(f => f[4] && featValue(m, f[0]) === (tagOn[f[0]] || "on")).map(f => f[4]) : [];
      if (m.features && m.features.res === "accepted") tags.unshift("accepted");
      if (m.scenario) tags.unshift(m.scenario.label);
      const b = document.createElement("button");
      b.type = "button"; b.className = "run-item";
      b.setAttribute("aria-current", String(m.id === state.run));
      b.innerHTML = `<span class="ri-name">${esc(m.name)}</span>
        <span class="ri-meta"><span>${period([m.first_day, m.last_day])}</span><span class="mono">${esc(i.commit || "–")}</span><span>${esc(i.ran_by || "–")}</span></span>
        ${tags.length ? `<span class="ri-tags">${tags.map(t => `<span class="ri-tag">${esc(t)}</span>`).join("")}</span>` : ""}
        <span class="ri-meta"><span>${nf(pct, 0)} % of hours solved</span></span>
        <span class="meter" aria-hidden="true"><span style="width:${pct}%"></span></span>`;
      b.addEventListener("click", () => { if (m.id !== state.run || !run()) selectRun(m.id); setRunsOpen(false); });
      host.appendChild(b);
    }
    if (!shown.length) host.innerHTML = `<p class="rf-empty">No run has this combination of model changes.</p>`;
    else if (!shown.some(m => m.id === state.run)) host.insertAdjacentHTML("afterbegin", `<p class="rf-empty">The run you are viewing is hidden by the filters.</p>`);
    $("run-count").textContent = shown.length === MANIFEST.length ? String(MANIFEST.length) : `${shown.length} of ${MANIFEST.length}`;
  }

  function renderHead(r) {
    const i = r.info;
    $("run-head").innerHTML = `
      <h2>${esc(r.name)}</h2>
      <p class="note">${esc(r.note)}</p>
      ${r.scenario ? `<p class="note"><span class="flag">${icon("warn")} Scenario run: ${esc(r.scenario.label)}${r.scenario.period ? `, EMPIRE period ${esc(String(r.scenario.period))}` : ""}${(r.scenario.weather_years || []).length ? `, weather year ${esc(r.scenario.weather_years.join(", "))}` : ""}. The dates follow the 2024 calendar the model uses; there is no real data to compare, so the real (OMIE, ENTSO-E, REE) series are empty.</span></p>` : ""}
      <dl class="facts">
        <div><dt>Period</dt><dd>${period(r.days)} · ${r.days.length} days</dd></div>
        <div><dt>${term("Code version", "commit")}</dt><dd><span class="mono">${i.commit}</span> on <span class="mono">${i.branch}</span></dd></div>
        <div><dt>${term("Uncommitted changes", "dirty")}</dt><dd>${i.dirty.length ? `<span class="flag">${icon("warn")} ${i.dirty.map(f => `<span class="mono">${f}</span>`).join(", ")}</span>` : "None"}</dd></div>
        <div><dt>${term("Redispatch", "rd_setup")}</dt><dd>${i.power_flow}, ${i.solver}</dd></div>
        <div><dt>Ran by</dt><dd>${i.ran_by}</dd></div>
        <div><dt>Finished</dt><dd>${i.finished} · ${i.runtime}</dd></div>
      </dl>
      <p class="fineprint" style="margin:0">${i.commit_msg ? `Commit message: “${esc(i.commit_msg)}”. ` : ""}${i.reconstructed ? "This run was made before runs recorded their own info, so it was filled in by hand when it was published. " : ""}Published ${esc((r.meta.published || "").slice(0, 10))} by ${esc(r.meta.published_by || "–")}.</p>`;
  }

  function renderTabs(v) {
    const p = pairs(v.price.DA, v.real_price);
    const mae = mean(p.map(q => Math.abs(q[0] - q[1])));
    const solvedPct = 100 * v.status.reduce((a, b) => a + b, 0) / v.status.length;
    const hint = { price: `MAE ${nf(mae)} €/MWh`, status: `${nf(solvedPct, 0)} % solved` };
    const host = $("tabs"); host.innerHTML = "";
    TABS.forEach(([key, label]) => {
      if (key === "csp" && !run().csp) return;   // CSP tab only for runs that have it
      const b = document.createElement("button");
      b.type = "button"; b.setAttribute("role", "tab"); b.id = "tab-" + key;
      b.setAttribute("aria-selected", String(key === state.tab));
      b.tabIndex = key === state.tab ? 0 : -1;
      b.innerHTML = label + (hint[key] ? `<small>${hint[key]}</small>` : "");
      b.addEventListener("click", () => pickTab(key));
      b.addEventListener("keydown", ev => {
        const i = TABS.findIndex(x => x[0] === state.tab);
        if (ev.key === "ArrowRight" || ev.key === "ArrowLeft") {
          const j = (i + (ev.key === "ArrowRight" ? 1 : TABS.length - 1)) % TABS.length;
          pickTab(TABS[j][0]); $("tab-" + TABS[j][0]).focus(); ev.preventDefault();
        }
      });
      host.appendChild(b);
    });
    document.querySelectorAll("[data-tabs]").forEach(el => { el.hidden = !el.dataset.tabs.split(" ").includes(state.tab); });
  }
  function pickTab(key) {
    if (key === state.tab) return;
    state.tab = key;
    try { localStorage.setItem("runviewer.tab", key); } catch (e) {}
    hideGloss();
    const v = view();
    renderTabs(v);
    // sections that were hidden have no width yet, so draw them now that they are visible
    renderPrice(v); renderMix(v); renderStatus(v); renderCsp(v); renderRedispatch(v); renderBalancing(v); renderGrid(v); renderPlants(v); renderFlex(v); renderInvest(v); renderCompare(v);
    // if the page was scrolled down, jump back to the top of the new tab's content
    const headBottom = $("run-head").getBoundingClientRect().bottom;
    if (headBottom < 0) window.scrollTo({ top: window.scrollY + headBottom + 16 });
  }



  // ---------- play through the hours ----------
  // key: "gh" (line map) or "ph" (plant map). The timer lives outside the render functions,
  // which rebuild the hour bar on every step.
  const players = {};
  const PLAYERS = {
    gh: { active: () => state.gridMode === "hour" && !$("sec-grid").hidden, get: () => state.gridHour,
          set: h => { state.gridHour = h; }, draw: () => renderGrid(view()) },
    ph: { active: () => state.plantSize !== "cap" && state.plantTime === "hour" && !$("sec-plants").hidden, get: () => state.plantHour,
          set: h => { state.plantHour = h; }, draw: () => renderPlants(view()) },
  };
  function stopPlay(key) { if (players[key]) { clearInterval(players[key].id); players[key] = null; } }
  function playControls(key) {
    const on = !!players[key];
    return `<button type="button" class="play" id="${key}-play" aria-pressed="${on}">${on ? "❚❚ Pause" : "▶ Play"}</button>
      <select id="${key}-speed" aria-label="Seconds per hour">${[0.5, 1, 2, 3].map(v => `<option value="${v}"${v === state.playSpeed ? " selected" : ""}>${v} s per hour</option>`).join("")}</select>`;
  }
  function wirePlay(key) {
    const P = PLAYERS[key];
    const bounds = () => { const r = view(); return [r.offset * 24, (r.offset + r.days.length) * 24]; };
    const start = () => {
      const runId = state.run;
      players[key] = { id: setInterval(() => {
        const [h0, h1] = bounds(), next = P.get() + 1;
        if (state.run !== runId || !P.active() || next >= h1) { stopPlay(key); P.draw(); return; }
        P.set(Math.max(h0, next)); P.draw();
      }, state.playSpeed * 1000) };
    };
    $(`${key}-play`).onclick = () => {
      if (players[key]) { stopPlay(key); P.draw(); return; }
      const [h0, h1] = bounds();
      if (P.get() >= h1 - 1) P.set(h0);  // at the end: start again from the first hour
      start(); P.draw();
    };
    $(`${key}-speed`).onchange = e => { state.playSpeed = +e.target.value; if (players[key]) { stopPlay(key); start(); } };
  }

  // ---------- grid map ----------
  const G = { outline: window.BASEMAP.outline, frame: null, corridors: [], runs: {} };  // corridors: the picked run's grid
  const G_BINS = [[25, "var(--ld-0)", "under 25 %"], [50, "var(--ld-1)", "25–50 %"], [75, "var(--ld-2)", "50–75 %"],
                  [90, "var(--ld-3)", "75–90 %"], [99.5, "var(--ld-4)", "90–99 %"], [Infinity, "var(--critical)", "at limit"]];
  const H_BINS = [[1, "var(--ld-0)", "0 h"], [3, "var(--ld-1)", "1–2 h"], [11, "var(--ld-2)", "3–10 h"],
                  [51, "var(--ld-3)", "11–50 h"], [Infinity, "var(--ld-4)", "over 50 h"]];
  const gridCache = {};
  function gridRun(id) {
    if (!gridCache[id]) {
      const g = G.runs[id], dec = s => Uint8Array.from(atob(s), ch => ch.charCodeAt(0));
      gridCache[id] = { H: g.hours, load: dec(g.load), flow: new Int16Array(dec(g.flow).buffer) };
    }
    return gridCache[id];
  }
  const binOf = (bins, v) => bins.find(b => v < b[0]);
  const gName = c => c.t === "trafo" ? c.names.join(" + ") : c.names.map(n => n.replace(/^LTGES/, "")).join(" + ");
  // map layers the Show buttons switch on and off
  const G_LAYERS = [["hv", "400 kV lines", "g_hv"], ["lv", "220 kV and lower", "g_lv"], ["trafo", "Transformers", "g_trafo"], ["border", "Border lines", "g_border"]];
  const gLayer = k => k.cls === "international" ? "border" : k.t === "trafo" ? "trafo" : (parseFloat(k.kv) >= 300 ? "hv" : "lv");
  const gShown = k => state.gridLayers.includes(gLayer(k));
  // the foreign end of a border line, from its position (the Portuguese border lies west of 5° W)
  const gCountry = k => k.a[0] / (111.32 * Math.cos(40 * Math.PI / 180)) < -5 ? "Portugal" : "France";
  const gType = k => k.t === "trafo" ? `Transformer ${k.kv} kV` : gLayer(k) === "border" ? `Border line to ${gCountry(k)}, ${k.kv} kV` : `${k.kv ?? "?"} kV line`;
  const gText = k => [gName(k), ...k.names, gType(k), ...k.ab].join(" ").toLowerCase();  // what the search matches
  const gOption = k => `${gName(k)} (${k.ab.join("–")})`;

  // per corridor over the shown period: highest loading (and when), hours ≥ 90 %, hours at the limit
  const statCache = {};
  function gridStats(r) {
    const key = `${r.id}|${r.offset}|${r.days.length}`;
    if (statCache[key]) return statCache[key];
    const gr = gridRun(r.id), H = gr.H, h0 = r.offset * 24, h1 = h0 + r.days.length * 24, C = G.corridors.length;
    const max = new Float32Array(C).fill(NaN), when = new Int32Array(C).fill(-1), n90 = new Int32Array(C), nlim = new Int32Array(C);
    for (let c = 0; c < C; c++) for (let h = h0; h < h1; h++) {
      const v = gr.load[c * H + h]; if (v === 255) continue;
      if (!(v <= max[c])) { max[c] = v; when[c] = h; }
      if (v >= 90) n90[c]++;
      if (v >= 99.5) nlim[c]++;
    }
    return (statCache[key] = { max, when, n90, nlim });
  }

  // select a line or transformer, switch its layer on and zoom the map to it
  function gridFocus(c, scroll) {
    const k = G.corridors[c], F = G.frame, l = gLayer(k);
    if (!state.gridLayers.includes(l)) state.gridLayers = [...state.gridLayers, l];
    state.gridSel = c;
    const w = k.t === "trafo" ? F[2] / 14 : Math.max(F[2] / 8, Math.abs(k.a[0] - k.b[0]) * 3);
    const cx = (k.a[0] + k.b[0]) / 2, cy = (k.a[1] + k.b[1]) / 2;
    mapVBs.grid = [cx - w / 2, cy - w * F[3] / F[2] / 2, w, w * F[3] / F[2]];
    renderGrid(view());
    if (scroll) $("grid-map").scrollIntoView({ behavior: "smooth", block: "nearest" });
  }
  function wireGridSearch() {
    const inp = $("grid-search");
    if (inp.dataset.wired) return;
    inp.dataset.wired = "1";
    let t = null;
    const pick = c => { inp.value = gName(G.corridors[c]); state.gridQuery = inp.value; state.gridAll = false; gridFocus(c, true); };
    inp.addEventListener("input", () => {
      const c = G.searchIdx && G.searchIdx.get(inp.value);
      if (c != null) return pick(c);  // picked from the suggestions
      clearTimeout(t);
      t = setTimeout(() => { state.gridQuery = inp.value; state.gridAll = false; renderGrid(view()); }, 200);
    });
    inp.addEventListener("keydown", ev => {
      if (ev.key !== "Enter") return;
      const q = inp.value.trim().toLowerCase();
      const c = q ? G.corridors.findIndex(k => gText(k).includes(q)) : -1;
      if (c >= 0) { state.gridQuery = inp.value; gridFocus(c, true); }
    });
  }

  function gridValues(r) {
    const gr = gridRun(r.id), H = gr.H, h0 = r.offset * 24, h1 = h0 + r.days.length * 24, C = G.corridors.length;
    const vals = new Float32Array(C).fill(NaN), when = new Int32Array(C).fill(-1);
    if (state.gridMode === "hour") {
      const h = state.gridHour;
      for (let c = 0; c < C; c++) { const v = gr.load[c * H + h]; if (v !== 255) vals[c] = v; }
    } else {
      for (let c = 0; c < C; c++) {
        let best = -1, bi = -1, n90 = 0, any = false;
        for (let h = h0; h < h1; h++) {
          const v = gr.load[c * H + h]; if (v === 255) continue;
          any = true; if (v > best) { best = v; bi = h; } if (v >= 90) n90++;
        }
        if (any) { vals[c] = state.gridMode === "max" ? best : n90; when[c] = bi; }
      }
    }
    return { vals, when, gr, h0, h1 };
  }

  function peakHour(r) {
    const gr = gridRun(r.id), H = gr.H, h0 = r.offset * 24, h1 = h0 + r.days.length * 24;
    let best = -1, bh = h0, C = G.corridors.length;
    for (let h = h0; h < h1; h++) { let s = 0, n = 0; for (let c = 0; c < C; c++) { const v = gr.load[c * H + h]; if (v !== 255 && v >= 90) s++; if (v !== 255) n++; } if (n && s > best) { best = s; bh = h; } }
    return bh;
  }

  function renderGrid(r) {
    if ($("sec-grid").hidden) return;
    seg($("grid-mode"), [["max", "Highest loading", "g_max"], ["h90", "Hours ≥ 90 %", "g_h90"], ["hour", "One hour", "g_hour"]], state.gridMode,
      v => { state.gridMode = v; renderGrid(view()); });
    seg($("grid-style"), [["plain", "Plain", "st_plain"], ["political", "Political", "st_political"], ["terrain", "Terrain", "st_terrain"], ["dark", "Dark", "st_dark"]],
      state.mapStyle, v => { state.mapStyle = v; try { localStorage.setItem("runviewer.mapStyle", v); } catch (e) {} renderGrid(view()); });
    const h0 = r.offset * 24, h1 = h0 + r.days.length * 24;
    if (state.gridMode === "hour" && (state.gridHour == null || state.gridHour < h0 || state.gridHour >= h1)) state.gridHour = peakHour(r);

    // hour bar
    const hb = $("grid-hour");
    hb.hidden = state.gridMode !== "hour";
    if (state.gridMode === "hour") {
      const rel = state.gridHour - h0, d = Math.floor(rel / 24), hr = rel % 24;
      const ok = r.status[rel] === 1;
      hb.innerHTML = `${playControls("gh")}
        <button type="button" id="gh-prev" aria-label="Previous hour">‹</button>
        <input type="range" id="gh-range" min="0" max="${h1 - h0 - 1}" value="${rel}" aria-label="Hour shown on the map">
        <button type="button" id="gh-next" aria-label="Next hour">›</button>
        <span class="gh-label">${dayLabel(r.days[d])}, ${hh(hr)}</span>
        <span class="status">${ok ? icon("good") + " AC solved" : icon("bad") + " AC failed"}</span>
        <button type="button" id="gh-peak">Busiest hour</button>
        <button type="button" id="gh-fail">Next failed hour</button>`;
      const go = rr => { stopPlay("gh"); state.gridHour = h0 + Math.max(0, Math.min(h1 - h0 - 1, rr)); renderGrid(view()); };
      wirePlay("gh");
      $("gh-range").addEventListener("input", e => go(+e.target.value));
      $("gh-prev").onclick = () => go(rel - 1);
      $("gh-next").onclick = () => go(rel + 1);
      $("gh-peak").onclick = () => { stopPlay("gh"); state.gridHour = peakHour(r); renderGrid(view()); };
      $("gh-fail").onclick = () => {
        const n = h1 - h0;
        for (let k = 1; k <= n; k++) { const j = (rel + k) % n; if (r.status[j] === 0) return go(j); }
      };
    }

    const bins = state.gridMode === "h90" ? H_BINS : G_BINS;
    $("grid-legend").className = "legend" + (state.mapStyle === "dark" ? " st-dark" : "");
    const SYM = {
      hv: `<svg width="18" height="10" aria-hidden="true"><line x1="2" y1="5" x2="16" y2="5" stroke="currentColor" stroke-width="3.5" stroke-linecap="round"/></svg>`,
      lv: `<svg width="18" height="10" aria-hidden="true"><line x1="2" y1="5" x2="16" y2="5" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>`,
      trafo: `<svg width="12" height="12" aria-hidden="true"><rect x="1.5" y="1.5" width="9" height="9" fill="currentColor"/></svg>`,
      border: `<svg width="18" height="10" aria-hidden="true"><line x1="2" y1="5" x2="16" y2="5" stroke="currentColor" stroke-width="2.4" stroke-dasharray="4 2"/></svg>`,
    };
    const nOf = l => G.corridors.reduce((n, k) => n + (gLayer(k) === l), 0);
    $("grid-legend").innerHTML = `<div class="legend-row">` + bins.map(b => `<span><i class="lsw" style="background:${b[1]}"></i>${b[2] === "at limit" ? term("at limit", "g_limit") : b[2]}</span>`).join("")
      + `<span><svg width="12" height="12" aria-hidden="true"><path d="M6 1L11 6L6 11L1 6Z" fill="var(--soto)"/></svg>${term("Soto de Ribera", "soto")}</span></div>`
      + `<div class="legend-row"><span class="ctl-label">Show</span>` + G_LAYERS.map(([l, label, tk]) =>
          `<button type="button" class="chip layer" data-l="${l}" data-tip="${tk}" aria-pressed="${state.gridLayers.includes(l)}">${SYM[l]}${label}<span class="n">${nOf(l)}</span></button>`).join("") + `</div>`;
    $("grid-legend").querySelectorAll(".chip").forEach(b => b.addEventListener("click", () => {
      const l = b.dataset.l;
      state.gridLayers = state.gridLayers.includes(l) ? state.gridLayers.filter(x => x !== l) : [...state.gridLayers, l];
      renderGrid(view());
    }));
    // search suggestions: rebuilt when the run (and so the grid) changes
    if (G.listFor !== r.id) {
      G.listFor = r.id;
      G.searchIdx = new Map(G.corridors.map((k, c) => [gOption(k), c]));
      $("grid-search-list").innerHTML = G.corridors.map(k => `<option value="${esc(gOption(k))}">${esc(gType(k))}</option>`).join("");
    }
    wireGridSearch();

    const { vals, when, gr } = gridValues(r);
    const C = G.corridors.length;
    const host = $("grid-map");
    const M = baseMap(host, "grid", "Map of the Spanish grid coloured by line loading");
    const F = M.F, tip = M.tip;

    // lines first, transformers on top; within each, the most loaded last so they stay visible
    const isTr = c => G.corridors[c].t === "trafo" ? 1 : 0;
    const order = [...Array(C).keys()].filter(c => gShown(G.corridors[c]))
      .sort((a, b) => isTr(a) - isTr(b) || (isNaN(vals[a]) ? -1 : vals[a]) - (isNaN(vals[b]) ? -1 : vals[b]));
    const gLines = svg("g", { "stroke-linecap": "round" }, M.data), gHit = svg("g", {}, M.data);
    const els = {};
    for (const c of order) {
      const k = G.corridors[c], v = vals[c], tr = k.t === "trafo";
      const col = isNaN(v) ? "var(--ld-0)" : binOf(bins, v)[1];
      const at = { x1: k.a[0], y1: k.a[1], x2: k.b[0], y2: k.b[1], "vector-effect": "non-scaling-stroke" };
      if (tr) {
        // both ends sit at one substation: a square of fixed screen size with a dark edge
        const g = svg("g", isNaN(v) ? { opacity: 0.55 } : {}, gLines);
        svg("line", { ...at, stroke: "var(--mp-sel)", "stroke-width": 11, "stroke-linecap": "square" }, g);
        svg("line", { ...at, stroke: col, "stroke-width": 8, "stroke-linecap": "square" }, g);
        els[c] = g;
      } else {
        const attrs = { ...at, stroke: col, "stroke-width": parseFloat(k.kv) >= 300 ? 2.4 : 1.2 };
        if (gLayer(k) === "border") attrs["stroke-dasharray"] = "5 2.5";
        if (isNaN(v)) attrs.opacity = 0.5;
        els[c] = svg("line", attrs, gLines);
      }
      svg("line", { ...at, class: "hit", "stroke-width": tr ? 14 : 10, "stroke-linecap": tr ? "square" : "butt", "data-c": c }, gHit);
    }
    if (state.gridSel != null && els[state.gridSel]) {
      const k = G.corridors[state.gridSel], tr = k.t === "trafo";
      svg("line", { x1: k.a[0], y1: k.a[1], x2: k.b[0], y2: k.b[1], stroke: "var(--mp-sel)", "stroke-width": tr ? 22 : 7, opacity: tr ? 0.35 : 0.3, "stroke-linecap": tr ? "square" : "round", "vector-effect": "non-scaling-stroke", "pointer-events": "none" }, gLines);
      gLines.appendChild(els[state.gridSel]);
    }
    M.rescale();

    const empty = !Array.prototype.some.call(vals, v => !isNaN(v));
    if (empty) {
      const n = document.createElement("div"); n.className = "map-note";
      n.innerHTML = state.gridMode === "hour" ? "The AC redispatch failed in this hour, so there are no line flows." : "No solved AC hours in the shown period.";
      host.appendChild(n);
    }

    // hover details
    gHit.addEventListener("pointermove", ev => {
      if (M.panning()) return;
      const c = +ev.target.getAttribute("data-c"); if (isNaN(c)) return;
      const k = G.corridors[c], v = vals[c];
      let rows = `<div class="row">${gType(k)}${k.names.length > 1 ? `<span class="v">${k.names.length} circuits</span>` : ""}</div>`;
      if (k.km) rows += `<div class="row">Length<span class="v">${nf(k.km, 0)} km</span></div>`;
      rows += `<div class="row">Between<span class="v">${k.ab[0]} – ${k.ab[1]}</span></div>`;
      rows += `<div class="row">Limit<span class="v">${nf(k.lim, 0)} MW</span></div>`;
      if (state.gridMode === "hour") {
        const f = gr.flow ? gr.flow[c * gr.H + state.gridHour] : v / 100 * k.lim;  // packages store loading, not flow
        rows += isNaN(v) ? `<div class="row">No flow in this hour</div>`
          : `<div class="row">Flow<span class="v">${nf(Math.abs(f), 0)} MW</span></div><div class="row">Loading<span class="v">${nf(v, 0)} %</span></div>`;
      } else if (!isNaN(v)) {
        const wh = when[c] - r.offset * 24;
        rows += state.gridMode === "max"
          ? `<div class="row">Highest loading<span class="v">${nf(v, 0)} %</span></div><div class="row">When<span class="v">${dayLabel(r.days[Math.floor(wh / 24)])}, ${hh(wh % 24)}</span></div>`
          : `<div class="row">Hours at ≥ 90 %<span class="v">${v} of ${r.status.reduce((a, b) => a + b, 0)}</span></div>`;
        rows += `<div class="row">Hours at limit<span class="v">${gridStats(r).nlim[c]}</span></div>`;
      }
      M.showTip(ev, `<b>${gName(k)}</b>${rows}`);
    });
    gHit.addEventListener("pointerleave", () => { tip.hidden = true; });
    gHit.addEventListener("click", ev => {
      if (M.panning()) return;
      const c = +ev.target.getAttribute("data-c"); if (isNaN(c)) return;
      state.gridSel = state.gridSel === c ? null : c; renderGrid(view());
    });

    // most-loaded list
    const unit = state.gridMode === "h90" ? "h" : "%";
    $("grid-top-title").textContent = state.gridMode === "h90" ? "Most hours at ≥ 90 %" : state.gridMode === "hour" ? "Most loaded in this hour" : "Highest loading in the period";
    const top = [...Array(C).keys()].filter(c => gShown(G.corridors[c]) && !isNaN(vals[c]) && vals[c] > 0).sort((a, b) => vals[b] - vals[a] || G.corridors[b].lim - G.corridors[a].lim).slice(0, 12);
    $("grid-top").innerHTML = `<thead><tr><th>Line</th><th>kV</th><th>${state.gridMode === "h90" ? "Hours" : "Loading"}</th></tr></thead><tbody>` +
      (top.length ? top.map(c => { const k = G.corridors[c]; return `<tr data-c="${c}" class="${state.gridSel === c ? "sel" : ""}"><td>${gName(k)}</td><td>${k.kv ?? "?"}</td><td><i class="lsw" style="background:${binOf(bins, vals[c])[1]};margin-right:6px"></i>${nf(vals[c], 0)} ${unit}</td></tr>`; }).join("")
        : `<tr><td colspan="3" style="color:var(--muted)">No data</td></tr>`) + "</tbody>";
    $("grid-top").querySelectorAll("tbody tr[data-c]").forEach(tr => tr.addEventListener("click", () => gridFocus(+tr.dataset.c)));

    // every line and transformer: sortable, follows the Show buttons and the search box
    const st = gridStats(r), q = state.gridQuery.trim().toLowerCase(), one = state.gridMode === "hour";
    const cols = [["name", "Name"], ["type", "Type"], ["lim", "Limit MW"], ...(one ? [["now", "This hour"]] : []),
                  ["max", "Highest loading"], ["n90", "Hours ≥ 90 %"], ["nlim", term("Hours at limit", "g_nlim")]];
    const val = { name: c => gName(G.corridors[c]), type: c => gType(G.corridors[c]), lim: c => G.corridors[c].lim,
                  now: c => vals[c], max: c => st.max[c], n90: c => st.n90[c], nlim: c => st.nlim[c] };
    let [sk, sd] = state.gridSort;
    if (!val[sk] || (sk === "now" && !one)) { sk = "max"; sd = -1; }
    const all = [...Array(C).keys()].filter(c => gShown(G.corridors[c]) && (!q || gText(G.corridors[c]).includes(q)));
    all.sort((a, b) => {
      const x = val[sk](a), y = val[sk](b);
      if (typeof x === "string") return sd * x.localeCompare(y);
      if (isNaN(x) || isNaN(y)) return isNaN(x) - isNaN(y);  // no data last
      return sd * (x - y) || G.corridors[b].lim - G.corridors[a].lim;
    });
    const LIMIT = 60, rows = state.gridAll ? all : all.slice(0, LIMIT);
    const pct = v => isNaN(v) ? "–" : `<i class="lsw" style="background:${binOf(G_BINS, v)[1]}"></i>${nf(v, 0)} %`;
    $("grid-table").innerHTML = `<thead><tr>${cols.map(([k2, l]) => `<th aria-sort="${sk === k2 ? (sd < 0 ? "descending" : "ascending") : "none"}"><button type="button" class="sort" data-k="${k2}">${l}${sk === k2 ? (sd < 0 ? " ↓" : " ↑") : ""}</button></th>`).join("")}</tr></thead><tbody>`
      + (rows.length ? rows.map(c => {
        const k = G.corridors[c], wh = st.when[c] - h0;
        return `<tr data-c="${c}" class="${state.gridSel === c ? "sel" : ""}"><td>${esc(gName(k))}<div class="sub">${k.ab.join(" – ")}</div></td><td>${gType(k)}</td><td>${nf(k.lim, 0)}</td>`
          + (one ? `<td>${pct(vals[c])}</td>` : "")
          + `<td>${pct(st.max[c])}${wh >= 0 ? `<div class="sub">${dayLabel(r.days[Math.floor(wh / 24)])}, ${hh(wh % 24)}</div>` : ""}</td><td>${st.n90[c]}</td><td>${st.nlim[c] ? `<b>${st.nlim[c]}</b>` : "0"}</td></tr>`;
      }).join("")
        : `<tr><td colspan="${cols.length}" style="color:var(--muted)">Nothing matches${q ? ` “${esc(q)}”` : ""}. Check the search box and the Show buttons above the map.</td></tr>`) + "</tbody>";
    $("grid-table-count").innerHTML = `${all.length.toLocaleString("en-GB")} of ${C.toLocaleString("en-GB")} · hours counted over the ${r.status.reduce((a, b) => a + b, 0)} solved AC hours in the period`
      + (all.length > LIMIT ? ` · <button type="button" class="linkbtn" id="grid-table-all">${state.gridAll ? `Show the first ${LIMIT}` : `Show all ${all.length.toLocaleString("en-GB")}`}</button>` : "");
    $("grid-table").querySelectorAll("button.sort").forEach(b => b.addEventListener("click", () => {
      const k2 = b.dataset.k;
      state.gridSort = [k2, state.gridSort[0] === k2 ? -state.gridSort[1] : (k2 === "name" || k2 === "type" ? 1 : -1)];
      renderGrid(view());
    }));
    $("grid-table").querySelectorAll("tbody tr[data-c]").forEach(tr => tr.addEventListener("click", () => gridFocus(+tr.dataset.c, true)));
    if ($("grid-table-all")) $("grid-table-all").onclick = () => { state.gridAll = !state.gridAll; renderGrid(view()); };
  }

  // ---------- shared map: basemap, cities, Soto de Ribera, zoom and drag ----------
  const mapVBs = {};  // each map keeps its own zoom
  function baseMap(host, key, label) {
    const F = G.frame;
    if (!mapVBs[key]) mapVBs[key] = F.slice();
    host.innerHTML = "";
    (host.closest(".grid-wrap") || host).style.setProperty("--map-ar", F[2] / F[3]);
    const s = svg("svg", { viewBox: mapVBs[key].join(" "), role: "img", "aria-label": label, preserveAspectRatio: "xMidYMid meet" }, host);
    s.style.aspectRatio = `${F[2]} / ${F[3]}`;
    const ML = window.MAP_LAYERS, st = state.mapStyle, plain = st === "plain", terrain = st === "terrain";
    host.className = "map st-" + st;
    const seaCol = plain ? "var(--sea)" : terrain ? "var(--mp-tsea)" : "var(--mp-sea)";
    svg("rect", { x: F[0] - 3 * F[2], y: F[1] - 3 * F[3], width: 7 * F[2], height: 7 * F[3], fill: seaCol }, s);
    const land = svg("g", {}, s);
    for (const [name, d] of Object.entries(G.outline)) {
      const fill = plain ? (name === "Spain" ? "var(--land)" : "var(--surface-2)")
        : name === "Spain" || name === "Portugal" ? (terrain ? "var(--mp-tland)" : "var(--mp-land)") : "var(--mp-land2)";
      svg("path", { d, fill, stroke: plain ? "var(--coast)" : "var(--mp-coast)", "stroke-width": 1, "vector-effect": "non-scaling-stroke" }, land);
    }
    if (terrain) {
      const defs = svg("defs", {}, s), cp = svg("clipPath", { id: "landclip-" + key }, defs);
      for (const d of Object.values(G.outline)) svg("path", { d }, cp);
      svg("image", { href: ML.relief.href, x: ML.relief.x, y: ML.relief.y, width: ML.relief.w, height: ML.relief.h,
        preserveAspectRatio: "none", "clip-path": `url(#landclip-${key})`, class: "rel" }, s);
    }
    if (!plain) {
      svg("path", { d: ML.provinces, fill: "none", stroke: "var(--mp-prov)", "stroke-width": 0.6, "vector-effect": "non-scaling-stroke" }, s);
      svg("path", { d: ML.regions, fill: "none", stroke: "var(--mp-reg)", "stroke-width": 1, opacity: 0.8, "vector-effect": "non-scaling-stroke" }, s);
    }
    const scaled = [];  // labels and markers keep their screen size when the map is zoomed
    if (!plain) {
      const gReg = svg("g", {}, s);
      for (const rl of ML.region_labels) {
        const tx = svg("text", { x: rl.x, y: rl.y, "text-anchor": "middle", class: "reg" }, gReg); tx.textContent = rl.name;
        scaled.push({ el: tx, fs: 9.5, sw: 3 });
      }
    }
    const data = svg("g", {}, s);  // the caller draws its layer here
    const gTop = svg("g", {}, s);  // cities and Soto de Ribera stay on top
    const OFFSET = { Oviedo: [5, -5, "start"], "San Sebastián": [5, -4, "start"], Porto: [-6, 3, "end"], Lisboa: [-6, 3, "end"], Vigo: [-6, 3, "end"] };
    if (!plain) for (const c of ML.cities) {
      const dot = svg("circle", { cx: c.x, cy: c.y, fill: "var(--mp-label)", stroke: "var(--mp-halo)", "pointer-events": "none" }, gTop);
      const [dx, dy, anchor] = OFFSET[c.name] || [5, 3, "start"];
      const tx = svg("text", { x: c.x, y: c.y, "text-anchor": anchor }, gTop); tx.textContent = c.name;
      scaled.push({ el: dot, r: c.rank === 1 ? 3 : 2.2, sw: 1, minZoom: c.rank === 3 ? 1.8 : 0 });
      scaled.push({ el: tx, fs: c.rank === 1 ? 11.5 : 10, sw: 3, dx, dy, x: c.x, y: c.y, weight: c.rank === 1 ? 600 : 400, minZoom: c.rank === 3 ? 1.8 : 0 });
    }
    {
      const so = ML.soto;
      const mk = svg("path", { fill: "var(--soto)", stroke: "var(--mp-halo)", "data-tip": "soto", tabindex: 0 }, gTop);
      mk.style.pointerEvents = "auto"; mk.style.cursor = "help";
      const tx = svg("text", { x: so.x, y: so.y, "text-anchor": "end", class: "soto" }, gTop); tx.textContent = "Soto de Ribera";
      scaled.push({ el: mk, diamond: 5.5, x: so.x, y: so.y, sw: 1.2 });
      scaled.push({ el: tx, fs: 10.5, sw: 3, dx: -8, dy: 12, x: so.x, y: so.y });
    }
    const rescale = () => {
      const vb = mapVBs[key], pxw = s.getBoundingClientRect().width || 600, k = vb[2] / pxw, zoom = F[2] / vb[2];
      for (const o of scaled) {
        if (o.minZoom) o.el.style.display = zoom >= o.minZoom ? "" : "none";
        if (o.fs) { o.el.setAttribute("font-size", o.fs * k); if (o.weight) o.el.setAttribute("font-weight", o.weight); }
        if (o.dx != null) { o.el.setAttribute("x", o.x + o.dx * k); o.el.setAttribute("y", o.y + o.dy * k); }
        if (o.r) o.el.setAttribute("r", o.r * k);
        if (o.diamond) { const a = o.diamond * k; o.el.setAttribute("d", `M${o.x},${o.y - a}L${o.x + a},${o.y}L${o.x},${o.y + a}L${o.x - a},${o.y}Z`); }
        o.el.setAttribute("stroke-width", o.sw * k);
      }
    };

    const tip = document.createElement("div"); tip.className = "tip"; tip.hidden = true;
    const tools = document.createElement("div"); tools.className = "map-tools";
    tools.innerHTML = `<button type="button" aria-label="Zoom in">+</button><button type="button" aria-label="Zoom out">−</button><button type="button" aria-label="Show all of Spain" style="font-size:12px">⤢</button>`;
    host.appendChild(tools); host.appendChild(tip);
    const setVB = vb => { mapVBs[key] = vb; s.setAttribute("viewBox", vb.join(" ")); rescale(); };
    const zoomAt = (f, cx, cy) => {
      const [x, y, w, h] = mapVBs[key], nw = Math.min(F[2] * 1.2, Math.max(F[2] / 25, w * f)), nh = nw * h / w;
      setVB([cx - (cx - x) * nw / w, cy - (cy - y) * nh / h, nw, nh]);
    };
    const ctr = () => { const v = mapVBs[key]; return [v[0] + v[2] / 2, v[1] + v[3] / 2]; };
    const [bIn, bOut, bAll] = tools.querySelectorAll("button");
    bIn.onclick = () => zoomAt(0.6, ...ctr()); bOut.onclick = () => zoomAt(1 / 0.6, ...ctr()); bAll.onclick = () => setVB(F.slice());
    const toSvg = ev => { const r0 = s.getBoundingClientRect(), v = mapVBs[key], k = v[2] / r0.width; return [v[0] + (ev.clientX - r0.left) * k, v[1] + (ev.clientY - r0.top) * k]; };
    s.addEventListener("wheel", ev => { if (!(ev.ctrlKey || ev.metaKey)) return; ev.preventDefault(); zoomAt(ev.deltaY < 0 ? 0.8 : 1.25, ...toSvg(ev)); }, { passive: false });
    s.addEventListener("dblclick", ev => zoomAt(0.5, ...toSvg(ev)));
    let pan = null;
    s.addEventListener("pointerdown", ev => { if (ev.button !== 0) return; pan = { x: ev.clientX, y: ev.clientY, vb: mapVBs[key].slice(), moved: false }; s.setPointerCapture(ev.pointerId); });
    s.addEventListener("pointermove", ev => {
      if (!pan) return;
      const dx = ev.clientX - pan.x, dy = ev.clientY - pan.y;
      if (Math.abs(dx) + Math.abs(dy) > 3) { pan.moved = true; s.classList.add("panning"); tip.hidden = true; }
      if (!pan.moved) return;
      const k = mapVBs[key][2] / s.getBoundingClientRect().width;
      setVB([pan.vb[0] - dx * k, pan.vb[1] - dy * k, pan.vb[2], pan.vb[3]]);
    });
    const endPan = () => { setTimeout(() => { pan = null; }, 0); s.classList.remove("panning"); };
    s.addEventListener("pointerup", endPan); s.addEventListener("pointercancel", endPan);
    const showTip = (ev, html) => {
      tip.innerHTML = html; tip.hidden = false;
      const hr = host.getBoundingClientRect(), tw = tip.offsetWidth;
      let left = ev.clientX - hr.left + 14; if (left + tw > hr.width) left = ev.clientX - hr.left - tw - 14;
      tip.style.left = Math.max(4, left) + "px"; tip.style.top = Math.max(4, ev.clientY - hr.top - 10) + "px";
    };
    return {
      s, F, data, tip, scaled, rescale, showTip,
      panning: () => !!(pan && pan.moved),
      zoomTo: (cx, cy, w) => { mapVBs[key] = [cx - w / 2, cy - w * F[3] / F[2] / 2, w, w * F[3] / F[2]]; },
    };
  }

  // ---------- power plants map ----------
  const PD = { groups: [], runs: {} };  // groups: the picked run's plants
  const PLANT_FUELS = ["Nuclear", "Coal", "Gas", "Hydro", "Wind", "Solar", "Biomass", "Imports"];
  const PLANT_COLOR = { Hydro: "var(--cat-1)", Gas: "var(--cat-2)", Wind: "var(--cat-3)", Solar: "var(--cat-4)",
    Biomass: "var(--cat-5)", Imports: "var(--cat-6)", Nuclear: "var(--cat-7)", Coal: "var(--cat-8)" };
  const plantCache = {};
  function plantRun(id) {
    if (!plantCache[id]) {
      const g = PD.runs[id], dec = s => Uint8Array.from(atob(s), ch => ch.charCodeAt(0));
      const out = dec(g.out), chg = new Int8Array(dec(g.chg).buffer);
      let maxChg = 1;
      PD.groups.forEach((p, i) => { for (let h = 0; h < g.hours; h++) { const v = chg[i * g.hours + h]; if (v !== -128) maxChg = Math.max(maxChg, Math.abs(v) / 127 * p.cap); } });
      plantCache[id] = { H: g.hours, out, chg, maxChg };
    }
    return plantCache[id];
  }
  let maxCap = 1;  // largest plant group of the picked run
  // real names: a plant group at the same substation and fuel as an ENTSO-E site takes the site's name
  const plantName = p => { const s = PD.siteOf && PD.siteOf.get(`${p.x},${p.y},${p.f}`); return s == null ? null : RP.sites[s].name; };
  const plantOption = (p, i) => `${plantName(p) ? plantName(p) + " — " : ""}${p.f}${p.tech && p.tech.toLowerCase() !== p.f.toLowerCase() ? " " + p.tech : ""} at ${p.bus}, ${nf(p.cap, 0)} MW`;
  function plantFocus(i) {
    const p = PD.groups[i], F = G.frame, realMode = state.plantSize === "real" || state.plantSize === "realout";
    const s = PD.siteOf.get(`${p.x},${p.y},${p.f}`);
    if (realMode && s == null) state.plantSize = "cap";  // no ENTSO-E data for this plant: show it on the capacity map
    state.plantHidden = state.plantHidden.filter(f => f !== p.f);
    state.plantSel = state.plantSize === "real" || state.plantSize === "realout" ? "s" + s : i;
    const w = F[2] / 10;
    mapVBs.plants = [p.x - w / 2, p.y - w * F[3] / F[2] / 2, w, w * F[3] / F[2]];
    renderPlants(view());
    $("plant-map").scrollIntoView({ behavior: "smooth", block: "nearest" });
  }
  function wirePlantSearch() {
    const inp = $("plant-search");
    if (inp.dataset.wired) return;
    inp.dataset.wired = "1";
    inp.addEventListener("input", () => {
      const i = PD.searchIdx && PD.searchIdx.get(inp.value);
      if (i != null) { inp.value = plantName(PD.groups[i]) || `${PD.groups[i].f} at ${PD.groups[i].bus}`; plantFocus(i); }
    });
    inp.addEventListener("keydown", ev => {
      if (ev.key !== "Enter") return;
      const q = inp.value.trim().toLowerCase();
      if (!q) return;
      // biggest matching plant first
      let best = -1;
      PD.groups.forEach((p, i) => { if (plantOption(p, i).toLowerCase().includes(q) && (best < 0 || p.cap > PD.groups[best].cap)) best = i; });
      if (best >= 0) plantFocus(best);
    });
  }
  function plantValues(r) {
    const pr = plantRun(r.id), H = pr.H, h0 = r.offset * 24, h1 = h0 + r.days.length * 24, N = PD.groups.length;
    const vals = new Float32Array(N).fill(NaN), size = state.plantSize, one = state.plantTime === "hour";
    for (let i = 0; i < N; i++) {
      const cap = PD.groups[i].cap;
      if (size === "cap") { vals[i] = cap; continue; }
      const read = h => { const v = size === "out" ? pr.out[i * H + h] : pr.chg[i * H + h];
        return size === "out" ? (v === 255 ? NaN : v / 250 * cap) : (v === -128 ? NaN : v / 127 * cap); };
      if (one) { vals[i] = read(state.plantHour); continue; }
      let s = 0, n = 0;
      for (let h = h0; h < h1; h++) { const v = read(h); if (!isNaN(v)) { s += v; n++; } }
      if (n) vals[i] = s / n;
    }
    return { vals, pr, h0, h1 };
  }
  function plantBusiestHour(r) {
    const pr = plantRun(r.id), H = pr.H, h0 = r.offset * 24, h1 = h0 + r.days.length * 24;
    let best = -1, bh = h0;
    for (let h = h0; h < h1; h++) {
      let s = 0, any = false;
      PD.groups.forEach((p, i) => { const v = pr.chg[i * H + h]; if (v !== -128) { any = true; s += Math.abs(v) / 127 * p.cap; } });
      if (any && s > best) { best = s; bh = h; }
    }
    return bh;
  }


  // ---------- real vs model per plant (ENTSO-E actual generation per unit) ----------
  const RP = { sites: [], coverage: {}, runs: {} };  // ENTSO-E sites, from the picked run's package
  const realCache = {};
  function realRun(id) {
    if (!realCache[id]) {
      const g = RP.runs[id], dec = s => new Uint16Array(Uint8Array.from(atob(s), ch => ch.charCodeAt(0)).buffer);
      realCache[id] = { H: g.hours, model: dec(g.model), real: dec(g.real) };
    }
    return realCache[id];
  }
  // two views of the ENTSO-E plants: "realout" = real output only, "real" = model minus real
  function renderRealVsModel(r, one, h0, h1) {
    const rr = realRun(r.id), H = rr.H, S = RP.sites.length, NA = 65535;
    const only = state.plantSize === "realout";
    // model and real over the hours that have both (for the comparison and the hover)
    const md = new Float32Array(S).fill(NaN), rl = new Float32Array(S).fill(NaN);
    // real alone over every hour ENTSO-E has, failed AC hours included (for "Real output")
    const ro = new Float32Array(S).fill(NaN);
    for (let s = 0; s < S; s++) {
      if (one) {
        const a = rr.model[s * H + state.plantHour], b = rr.real[s * H + state.plantHour];
        if (b !== NA) ro[s] = b;
        if (a !== NA && b !== NA) { md[s] = a; rl[s] = b; }
        continue;
      }
      let sa = 0, sb = 0, n = 0, so = 0, no = 0;
      for (let h = h0; h < h1; h++) {
        const a = rr.model[s * H + h], b = rr.real[s * H + h];
        if (b !== NA) { so += b; no++; }
        if (a !== NA && b !== NA) { sa += a; sb += b; n++; }
      }
      if (n) { md[s] = sa / n; rl[s] = sb / n; }
      if (no) ro[s] = so / no;
    }
    const value = s => only ? ro[s] : md[s] - rl[s];
    const fuels = PLANT_FUELS.filter(f => RP.sites.some(x => x.f === f));
    const shown = [...RP.sites.keys()].filter(s => !isNaN(value(s)) && !state.plantHidden.includes(RP.sites[s].f));
    let ref = only ? maxCap : 1;
    if (!only) shown.forEach(s => { ref = Math.max(ref, Math.abs(value(s))); });
    const RMAX = only ? 22 : 24, radius = v => Math.max(only ? 1.8 : 2, RMAX * Math.sqrt(Math.abs(v) / ref));
    const niceFloor = x => { const m = 10 ** Math.floor(Math.log10(x)); return [5, 2, 1].map(k => k * m).find(v => v <= x) || m; };
    const sizes = only ? [100, 500, 2000] : [...new Set([ref / 25, ref / 5, ref].map(niceFloor))];

    const cov = RP.coverage;
    const covText = fuels.map(f => `${f.toLowerCase()} ${Math.round(100 * cov[f].matched / cov[f].total)} %`).join(", ");
    const sizeSvg = sizes.map(mw => { const q = radius(mw); return `<span><svg width="${2 * q + 2}" height="${2 * q + 2}" aria-hidden="true"><circle cx="${q + 1}" cy="${q + 1}" r="${q}" fill="none" stroke="var(--ink-2)"/></svg>${mw.toLocaleString("en-GB")} MW</span>`; }).join("");
    $("plant-legend").innerHTML = `<div class="legend-row">` + fuels.map(f => `<button type="button" class="chip" data-f="${f}" aria-pressed="${!state.plantHidden.includes(f)}"><i style="background:${PLANT_COLOR[f]}"></i>${f}</button>`).join("") + `</div>`
      + `<div class="legend-row sizes">${sizeSvg}`
      + (only ? "" : `<span class="legend-gap"></span><span><svg width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="5" fill="var(--ink-2)"/></svg>${term("model above real", "p_above")}</span>`
        + `<span><svg width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="4.5" fill="none" stroke="var(--ink-2)" stroke-width="1.8"/></svg>${term("model below real", "p_below")}</span>`) + `</div>`
      + `<div class="legend-note">${RP.sites.length} sites with ${term("ENTSO-E unit data", "p_entsoe")}, covering ${covText} of the model's capacity. Wind, smaller plants and imports have no per-unit data.</div>`;
    $("plant-legend").className = "legend" + (state.mapStyle === "dark" ? " st-dark" : "");
    $("plant-legend").querySelectorAll(".chip").forEach(b => b.addEventListener("click", () => {
      const f = b.dataset.f;
      state.plantHidden = state.plantHidden.includes(f) ? state.plantHidden.filter(x => x !== f) : [...state.plantHidden, f];
      renderPlants(view());
    }));

    const host = $("plant-map");
    const M = baseMap(host, "plants", only ? "Map of the real output of plants ENTSO-E reports one by one" : "Map of plants with real output, sized by the model's error");
    const order = [...shown].sort((a, b) => Math.abs(value(b)) - Math.abs(value(a)));
    const gP = svg("g", {}, M.data);
    for (const s of order) {
      const site = RP.sites[s], v = value(s), ring = !only && v < 0, zero = only && v < 0.5;
      const c = svg("circle", { cx: site.x, cy: site.y, "data-s": s, fill: ring ? "transparent" : PLANT_COLOR[site.f],
        stroke: ring ? PLANT_COLOR[site.f] : "var(--mp-halo)", opacity: zero ? 0.35 : 0.9 }, gP);
      c.style.cursor = "pointer";
      M.scaled.push({ el: c, r: zero ? 1.4 : radius(v), sw: ring ? 2 : 0.8 });
      if (state.plantSel === "s" + s) M.scaled.push({ el: svg("circle", { cx: site.x, cy: site.y, fill: "none", stroke: "var(--mp-sel)", "pointer-events": "none" }, gP), r: radius(v) + 4, sw: 2 });
    }
    M.rescale();
    if (!shown.length) {
      const n = document.createElement("div"); n.className = "map-note";
      n.innerHTML = only ? "ENTSO-E has no data for this choice."
        : one && r.status[state.plantHour - h0] === 0 ? "The AC redispatch failed in this hour, so there is no model output to compare." : "No hours with both model and real data in this period.";
      host.appendChild(n);
    }

    const mw = v => isNaN(v) ? "–" : nf(v, 0) + " MW";
    const avg = one ? "" : " (average)";
    gP.addEventListener("pointermove", ev => {
      if (M.panning()) return;
      const s = +ev.target.getAttribute("data-s"); if (isNaN(s)) return;
      const site = RP.sites[s];
      const rows = (only
        ? `<div class="row">Real (ENTSO-E)${avg}<span class="v">${mw(ro[s])}</span></div>
           <div class="row">Model${avg}<span class="v">${isNaN(md[s]) ? "AC failed" : mw(md[s])}</span></div>`
        : `<div class="row">Model${avg}<span class="v">${mw(md[s])}</span></div>
           <div class="row">Real (ENTSO-E)${avg}<span class="v">${mw(rl[s])}</span></div>
           <div class="row">Difference<span class="v">${signed(value(s), 0)} MW</span></div>`)
        + `<div class="row">Model capacity<span class="v">${mw(site.cap)} · ${site.model_units} unit${site.model_units > 1 ? "s" : ""}</span></div>
        <div class="row">ENTSO-E units<span class="v">${site.entsoe.length > 4 ? site.entsoe.slice(0, 4).join(", ") + ", …" : site.entsoe.join(", ")}</span></div>
        <div class="row">Match<span class="v">${site.conf === "sure" ? "sure" : "probable (from the unit code)"}</span></div>`;
      M.showTip(ev, `<b><i class="sw-box" style="background:${PLANT_COLOR[site.f]};margin-right:6px"></i>${site.name}</b>${rows}`);
    });
    gP.addEventListener("pointerleave", () => { M.tip.hidden = true; });
    gP.addEventListener("click", ev => {
      if (M.panning()) return;
      const s = +ev.target.getAttribute("data-s"); if (isNaN(s)) return;
      state.plantSel = state.plantSel === "s" + s ? null : "s" + s; renderPlants(view());
    });

    $("plant-top-title").textContent = only ? "Largest real output" : "Biggest differences, model − real";
    $("plant-top").innerHTML = `<thead><tr><th>Plant</th><th>${only ? "Real" : "Model − real"}</th></tr></thead><tbody>` +
      (order.length ? order.slice(0, 12).map(s => {
        const site = RP.sites[s];
        const sub = only ? `model ${isNaN(md[s]) ? "–" : nf(md[s], 0)} MW` : `model ${nf(md[s], 0)} · real ${nf(rl[s], 0)} MW`;
        return `<tr data-s="${s}" class="${state.plantSel === "s" + s ? "sel" : ""}"><td class="wrap"><i class="sw-box" style="background:${PLANT_COLOR[site.f]};margin-right:6px"></i>${site.name}<div class="sub">${sub}</div></td><td>${only ? mw(ro[s]) : signed(value(s), 0) + " MW"}</td></tr>`;
      }).join("") : `<tr><td colspan="2" style="color:var(--muted)">No data</td></tr>`) + "</tbody>";
    $("plant-top").querySelectorAll("tbody tr[data-s]").forEach(tr => tr.addEventListener("click", () => {
      const s = +tr.dataset.s, site = RP.sites[s];
      state.plantSel = "s" + s;
      M.zoomTo(site.x, site.y, M.F[2] / 5);
      renderPlants(view());
    }));
  }

  function renderPlants(r) {
    if ($("sec-plants").hidden) return;
    wirePlantSearch();
    seg($("plant-size"), [["cap", "Installed capacity", "p_cap"], ["out", "Output", "p_out"], ["chg", "Redispatch change", "p_chg"], ["realout", "Real output", "p_realout"], ["real", "Real vs model", "p_real"]], state.plantSize,
      v => { state.plantSize = v; renderPlants(view()); });
    const timeHost = $("plant-time");
    timeHost.hidden = state.plantSize === "cap";
    seg(timeHost, [["period", "Average over period", "p_period"], ["hour", "One hour", "p_hour"]], state.plantTime,
      v => { state.plantTime = v; renderPlants(view()); });
    seg($("plant-style"), [["plain", "Plain", "st_plain"], ["political", "Political", "st_political"], ["terrain", "Terrain", "st_terrain"], ["dark", "Dark", "st_dark"]],
      state.mapStyle, v => { state.mapStyle = v; try { localStorage.setItem("runviewer.mapStyle", v); } catch (e) {} renderPlants(view()); });

    const h0 = r.offset * 24, h1 = h0 + r.days.length * 24;
    const one = state.plantSize !== "cap" && state.plantTime === "hour";
    if (one && (state.plantHour == null || state.plantHour < h0 || state.plantHour >= h1)) state.plantHour = plantBusiestHour(r);
    const hb = $("plant-hour");
    hb.hidden = !one;
    if (one) {
      const rel = state.plantHour - h0, d = Math.floor(rel / 24), hr = rel % 24, ok = r.status[rel] === 1;
      hb.innerHTML = `${playControls("ph")}
        <button type="button" id="ph-prev" aria-label="Previous hour">‹</button>
        <input type="range" id="ph-range" min="0" max="${h1 - h0 - 1}" value="${rel}" aria-label="Hour shown on the plant map">
        <button type="button" id="ph-next" aria-label="Next hour">›</button>
        <span class="gh-label">${dayLabel(r.days[d])}, ${hh(hr)}</span>
        <span class="status">${ok ? icon("good") + " AC solved" : icon("bad") + " AC failed"}</span>
        ${state.plantSize === "real" || state.plantSize === "realout" ? "" : `<button type="button" id="ph-busy">Biggest redispatch hour</button>`}
        <button type="button" id="ph-fail">Next failed hour</button>`;
      const go = rr => { stopPlay("ph"); state.plantHour = h0 + Math.max(0, Math.min(h1 - h0 - 1, rr)); renderPlants(view()); };
      wirePlay("ph");
      $("ph-range").addEventListener("input", e => go(+e.target.value));
      $("ph-prev").onclick = () => go(rel - 1);
      $("ph-next").onclick = () => go(rel + 1);
      if ($("ph-busy")) $("ph-busy").onclick = () => { stopPlay("ph"); state.plantHour = plantBusiestHour(r); renderPlants(view()); };
      $("ph-fail").onclick = () => { const n = h1 - h0; for (let k = 1; k <= n; k++) { const j = (rel + k) % n; if (r.status[j] === 0) return go(j); } };
    }

    if (state.plantSize === "real" || state.plantSize === "realout") return renderRealVsModel(r, one, h0, h1);
    const { vals, pr } = plantValues(r);
    const chg = state.plantSize === "chg";
    // circle area ∝ MW; changes are scaled to the largest change shown, so period averages stay visible
    let ref = maxCap;
    if (chg) { ref = 1; vals.forEach((v, i) => { if (!isNaN(v) && !state.plantHidden.includes(PD.groups[i].f)) ref = Math.max(ref, Math.abs(v)); }); }
    const RMAX = 22;
    const radius = v => Math.max(1.8, RMAX * Math.sqrt(Math.abs(v) / ref));
    const niceFloor = x => { const m = 10 ** Math.floor(Math.log10(x)); return [5, 2, 1].map(k => k * m).find(v => v <= x) || m; };

    // legend: clickable fuels + circle sizes
    const sizes = chg ? [...new Set([ref / 25, ref / 5, ref].map(niceFloor))] : [100, 500, 2000];
    const sizeSvg = sizes.map(mw => { const rr = radius(mw); return `<span><svg width="${2 * rr + 2}" height="${2 * rr + 2}" aria-hidden="true"><circle cx="${rr + 1}" cy="${rr + 1}" r="${rr}" fill="none" stroke="var(--ink-2)"/></svg>${mw.toLocaleString("en-GB")} MW</span>`; }).join("");
    // two rows: the fuel buttons, then the circle sizes (and up/down) on one line underneath
    $("plant-legend").innerHTML = `<div class="legend-row">` + PLANT_FUELS.map(f => `<button type="button" class="chip" data-f="${f}" aria-pressed="${!state.plantHidden.includes(f)}"><i style="background:${PLANT_COLOR[f]}"></i>${f}</button>`).join("") + `</div>`
      + `<div class="legend-row sizes">` + sizeSvg
      + (chg ? `<span class="legend-gap"></span><span><svg width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="5" fill="var(--ink-2)"/></svg>${term("turned up", "p_up")}</span><span><svg width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="4.5" fill="none" stroke="var(--ink-2)" stroke-width="1.8"/></svg>${term("turned down", "p_down")}</span>` : "") + `</div>`;
    $("plant-legend").querySelectorAll(".chip").forEach(b => b.addEventListener("click", () => {
      const f = b.dataset.f;
      state.plantHidden = state.plantHidden.includes(f) ? state.plantHidden.filter(x => x !== f) : [...state.plantHidden, f];
      renderPlants(view());
    }));
    $("plant-legend").className = "legend" + (state.mapStyle === "dark" ? " st-dark" : "");

    const host = $("plant-map");
    const M = baseMap(host, "plants", "Map of the power plants in the model");
    const shown = [...PD.groups.keys()].filter(i => !state.plantHidden.includes(PD.groups[i].f) && !isNaN(vals[i]) && (!chg || Math.abs(vals[i]) >= 1));
    shown.sort((a, b) => Math.abs(vals[b]) - Math.abs(vals[a]));  // big ones first, small ones on top
    const gP = svg("g", {}, M.data);
    for (const i of shown) {
      const p = PD.groups[i], v = vals[i], down = chg && v < 0, zero = !chg && v < 0.5;
      const c = svg("circle", { cx: p.x, cy: p.y, "data-i": i, fill: down ? "transparent" : PLANT_COLOR[p.f],
        stroke: down ? PLANT_COLOR[p.f] : "var(--mp-halo)", opacity: zero ? 0.35 : 0.9 }, gP);
      c.style.cursor = "pointer";
      M.scaled.push({ el: c, r: zero ? 1.4 : radius(v), sw: down ? 1.8 : 0.8 });
      if (state.plantSel === i) M.scaled.push({ el: svg("circle", { cx: p.x, cy: p.y, fill: "none", stroke: "var(--mp-sel)", "pointer-events": "none" }, gP), r: radius(v) + 4, sw: 2 });
    }
    M.rescale();
    if (!shown.length) {
      const n = document.createElement("div"); n.className = "map-note";
      n.innerHTML = one && r.status[state.plantHour - h0] === 0 ? "The AC redispatch failed in this hour, so there is no redispatch output." : "Nothing to show for this choice.";
      host.appendChild(n);
    }

    const what = state.plantSize === "cap" ? "Capacity" : state.plantSize === "out" ? (one ? "Output this hour" : "Average output") : (one ? "Change this hour" : "Average change");
    const mw = v => (chg ? signed(v, 0) : nf(v, 0)) + " MW";
    gP.addEventListener("pointermove", ev => {
      if (M.panning()) return;
      const i = +ev.target.getAttribute("data-i"); if (isNaN(i)) return;
      const p = PD.groups[i];
      let rows = `<div class="row">Type<span class="v">${p.tech || p.f.toLowerCase()}</span></div>
        <div class="row">Substation<span class="v">${p.bus}</span></div>
        <div class="row">Capacity<span class="v">${nf(p.cap, 0)} MW${p.n > 1 ? ` · ${p.n} units` : ""}</span></div>`;
      if (state.plantSize !== "cap") rows += `<div class="row">${what}<span class="v">${mw(vals[i])}</span></div>`;
      if (chg) rows += `<div class="row">${vals[i] > 0 ? "Turned up by the grid stage" : "Turned down by the grid stage"}</div>`;
      M.showTip(ev, `<b><i class="sw-box" style="background:${PLANT_COLOR[p.f]};margin-right:6px"></i>${plantName(p) ? esc(plantName(p)) + " · " : ""}${p.f}</b>${rows}`);
    });
    gP.addEventListener("pointerleave", () => { M.tip.hidden = true; });
    gP.addEventListener("click", ev => {
      if (M.panning()) return;
      const i = +ev.target.getAttribute("data-i"); if (isNaN(i)) return;
      state.plantSel = state.plantSel === i ? null : i; renderPlants(view());
    });

    // list beside the map
    $("plant-top-title").textContent = state.plantSize === "cap" ? "Largest plants" : chg ? "Largest redispatch changes" : "Largest output";
    const top = shown.slice(0, 12);
    $("plant-top").innerHTML = `<thead><tr><th>Plant</th><th>${chg ? "Change" : "MW"}</th></tr></thead><tbody>` +
      (top.length ? top.map(i => { const p = PD.groups[i]; return `<tr data-i="${i}" class="${state.plantSel === i ? "sel" : ""}"><td class="wrap"><i class="sw-box" style="background:${PLANT_COLOR[p.f]};margin-right:6px"></i>${plantName(p) ? esc(plantName(p)) : p.f + " · " + p.bus}</td><td>${mw(vals[i])}</td></tr>`; }).join("")
        : `<tr><td colspan="2" style="color:var(--muted)">No data</td></tr>`) + "</tbody>";
    $("plant-top").querySelectorAll("tbody tr[data-i]").forEach(tr => tr.addEventListener("click", () => {
      const i = +tr.dataset.i, p = PD.groups[i];
      state.plantSel = i;
      M.zoomTo(p.x, p.y, M.F[2] / 5);
      renderPlants(view());
    }));
  }

  function renderPeriod() {
    const r = run(), nd = r.days.length, z = state.zoom || [0, nd - 1], len = z[1] - z[0] + 1;
    const el = $("period");
    el.classList.toggle("zoomed", !!state.zoom);
    el.innerHTML = `<span class="p-run"><button type="button" class="runs-toggle" id="runs-toggle" aria-expanded="${runsOpen}" aria-controls="runs-nav">☰ Runs</button><b title="${esc(r.name)}">${esc(r.name)}</b></span>
      <span class="p-label">Showing</span>
      <label class="p-date">From <input type="date" id="p-from" min="${r.days[0]}" max="${r.days[nd - 1]}" value="${r.days[z[0]]}" aria-label="First day shown"></label>
      <label class="p-date">to <input type="date" id="p-to" min="${r.days[0]}" max="${r.days[nd - 1]}" value="${r.days[z[1]]}" aria-label="Last day shown"></label>
      <span class="p-count">${len} of ${nd} days</span>
      <button type="button" id="p-prev" aria-label="Show the previous ${len} days" ${z[0] === 0 || !state.zoom ? "disabled" : ""}>← Earlier</button>
      <button type="button" id="p-next" aria-label="Show the next ${len} days" ${z[1] === nd - 1 || !state.zoom ? "disabled" : ""}>Later →</button>
      <button type="button" id="p-reset" ${state.zoom ? "" : "disabled"}>Show all days</button>
      <span class="p-key" aria-label="Colours"><span><i class="sw-line" style="background:var(--model)"></i>Model</span><span><i class="sw-line" style="background:var(--real)"></i>Real</span></span>`;
    $("runs-toggle").onclick = () => setRunsOpen(!runsOpen);
    // a picked date maps to the nearest run day inside the range (runs can skip days)
    const firstFrom = iso => { const i = r.days.findIndex(d => d >= iso); return i < 0 ? nd - 1 : i; };
    const lastTo = iso => { let i = nd - 1; while (i > 0 && r.days[i] > iso) i--; return i; };
    $("p-from").onchange = e => { if (!e.target.value) return; const a = firstFrom(e.target.value); setZoom(a, Math.max(a, z[1])); };
    $("p-to").onchange = e => { if (!e.target.value) return; const b = lastTo(e.target.value); setZoom(Math.min(z[0], b), b); };
    $("p-prev").onclick = () => { const a = Math.max(0, z[0] - len); setZoom(a, a + len - 1); };
    $("p-next").onclick = () => { const b = Math.min(nd - 1, z[1] + len); setZoom(b - len + 1, b); };
    $("p-reset").onclick = () => setZoom(0, nd - 1);
  }

  function renderKpis(r) {
    const solved = r.status.reduce((a, b) => a + b, 0), N = r.status.length, pct = 100 * solved / N;
    const p = pairs(r.price.DA, r.real_price);
    const mm = mean(p.map(q => q[0])), mr = mean(p.map(q => q[1]));
    const mae = mean(p.map(q => Math.abs(q[0] - q[1])));
    const c = corr(p);
    const [k, word] = solveStatus(pct);
    const tiles = [
      [term("AC hours solved", "solved"), `${nf(pct, 0)}<small>%</small>`, `<span class="status">${icon(k)} ${word}</span> · ${solved} of ${N} hours`],
      [term("Mean day-ahead price", "meanprice"), `${nf(mm)}<small>€/MWh</small>`, `Real: ${nf(mr)} €/MWh`],
      [term("Price bias", "bias"), `${signed(mm - mr)}<small>€/MWh</small>`, mm < mr ? "Model below real" : "Model above real"],
      [term("Price error (MAE)", "mae"), `${nf(mae)}<small>€/MWh</small>`, "Typical size of the hourly error"],
      [term("Price correlation", "corr"), `${nf(c, 2)}`, "Hourly, model vs real (1 = same shape)"],
    ];
    $("kpis").innerHTML = tiles.map(([l, v, s]) => `<div class="kpi"><span class="k-label">${l}</span><span class="k-value">${v}</span><span class="k-sub">${s}</span></div>`).join("");
  }

  // the real price shown next to each model stage: the intraday stages have their own market price
  // (the auctions only from 14 June 2024, see build_esios.py); DA and BAL are compared with OMIE's DA
  const REAL_FOR_STAGE = {
    ID2: ["ida2", "Real (IDA2)", "real_ida2"], ID3: ["ida3", "Real (IDA3)", "real_ida3"],
    CID: ["cid", "Real (continuous intraday)", "real_cid"],
  };

  function renderPrice(r) {
    seg($("price-stage"), PRICE_STAGES.map(s => [s, s, s]), state.priceStage, v => { state.priceStage = v; renderPrice(view()); });
    seg($("price-res"), [["hour", "Hourly"], ["day", "Daily mean"]], state.priceRes, v => { state.priceRes = v; renderPrice(view()); });
    const [rKey, rName, rTerm] = REAL_FOR_STAGE[state.priceStage] || [null, "Real (OMIE day-ahead)", "real_price"];
    $("price-legend").innerHTML = "";
    const host = $("price-chart");
    const nd = r.days.length, hourly = state.priceRes === "hour";
    const model = r.price[state.priceStage];
    const real = rKey ? (esiosFor(r, rKey) || model.map(() => null)) : r.real_price;
    const nReal = real.filter(x => x != null).length;
    $("price-note").textContent = !rKey ? ""
      : !window.ESIOS ? "reference/esios_2024.js is missing, so there is no real intraday price. Run tools/build_esios.py."
      : rKey === "cid" ? "Real: REE's continuous intraday reference price, the weighted average of the trades for each hour (e·sios 1727)."
      : (nReal ? `Real: the European intraday auction ${rKey === "ida2" ? "IDA2 (all 24 hours)" : "IDA3 (hours 12–23 only, like the model's ID3)"} from e·sios. Only from 14 June 2024, when the auctions replaced the MIBEL intraday sessions.`
        : "No real price for these days: the European intraday auctions started on 14 June 2024. Before that Spain had six MIBEL intraday sessions, a different market, which are left out for now.");
    const mv = hourly ? model : dailyMean(model, nd);
    const rv = hourly ? real : dailyMean(real, nd);
    const n = mv.length;
    lineChart(host, {
      n, height: state.tab === "price" ? 440 : 310, label: "Price, model vs real", endLabels: true, yUnit: "€/MWh",
      onZoom: (a, b) => zoomFromChart(a, b, hourly),
      xTicks: dayTicks(r.days, hourly, host.clientWidth - 110),
      series: [
        { name: rName, values: rv, color: "var(--real)", width: 2 },
        { name: `Model (${state.priceStage})`, values: mv, color: "var(--model)", width: 2.25 },
      ],
      tooltip: i => {
        const day = hourly ? Math.floor(i / 24) : i;
        const when = dayLabel(r.days[day]) + (hourly ? ", " + hh(i % 24) : " (daily mean)");
        const a = rv[i], b = mv[i];
        return `<b>${when}</b>
          <div class="row"><i class="sw-line" style="background:var(--real)"></i>${rName}<span class="v">${nf(a)} €/MWh</span></div>
          <div class="row"><i class="sw-line" style="background:var(--model)"></i>Model ${state.priceStage}<span class="v">${nf(b)} €/MWh</span></div>
          <div class="row">Difference<span class="v">${a != null && b != null ? signed(b - a) + " €/MWh" : "–"}</span></div>`;
      },
    });
  }

  function renderMix(r) {
    seg($("mix-stage"), MIX_STAGES, state.mixStage, v => {
      state.mixStage = v; state.mixRef = v === "RD" ? "entsoe" : "omie"; renderMix(view());
    });
    seg($("mix-ref"), [["omie", "OMIE day-ahead", "ref_omie"], ["entsoe", "ENTSO-E actual", "ref_entsoe"]], state.mixRef,
      v => { state.mixRef = v; renderMix(view()); });
    seg($("mix-res"), [["hour", "Hourly"], ["day", "Daily mean"]], state.mixRes, v => { state.mixRes = v; renderMix(view()); });
    renderStacks(r);
    const md = mixData(r), mix = md.model, realSrc = md.real;
    const N = r.status.length, solved = r.status.reduce((a, b) => a + b, 0), nd = r.days.length;
    const rows = md.cats.map(c => {
      const p = pairs(mix[c], realSrc[c]);
      const gm = p.reduce((s, q) => s + q[0], 0) / 1000, gr = p.reduce((s, q) => s + q[1], 0) / 1000;
      const mae = mean(p.map(q => Math.abs(q[0] - q[1])));
      return { c, gm, gr, diff: gm - gr, pct: gr > 0.5 ? 100 * (gm - gr) / gr : null, mae };
    });
    // Switching the real data only regroups the model into that source's categories; say so,
    // with the model total (all hours with a model value), which is the same in both groupings.
    const modelTotal = md.cats.reduce((s, c) => s + mix[c].reduce((a, v) => a + (v || 0), 0), 0) / 1000;
    $("mix-ref-note").innerHTML = (md.ref === "entsoe"
      ? `<b>Same model run, regrouped</b> into ENTSO-E's fuel types so it can be compared: CCGT and CHP gas → <b>Gas</b>; mini-hydro → <b>Hydro</b>; biomass, waste and oil → <b>Bio & other</b>.`
      : `<b>Model grouped like OMIE's technology report:</b> CHP gas, biomass, waste and mini-hydro → <b>CHP group</b>. "ENTSO-E actual" regroups the same model numbers into fuel types.`)
      + ` Only the grouping changes, not the model: total ${nf(modelTotal, 0)} GWh in both views.`;
    const tot = rows.reduce((s, x) => ({ gm: s.gm + x.gm, gr: s.gr + x.gr }), { gm: 0, gr: 0 });
    const maxAbs = Math.max(...rows.map(x => Math.abs(x.diff)), 1);
    const input = state.mixStage === "DA" && md.ref === "omie" ? { Wind: 1, Solar: 1 } : {};
    $("mix-table").innerHTML = `<thead><tr><th>Technology</th><th>${term("Real GWh", md.ref === "entsoe" ? "ref_entsoe" : "real_mix")}</th><th>Model GWh</th><th>${term("Difference", "diff")}</th><th></th><th>${term("Hourly error", "hourly_error")}</th></tr></thead><tbody>` +
      rows.map(x => {
        const w = 35 * Math.abs(x.diff) / maxAbs;
        const bar = `<span class="diffbar" aria-hidden="true"><i style="left:${x.diff < 0 ? 35 - w : 35}px;width:${Math.max(w, 0.5)}px"></i></span>`;
        return `<tr><td>${term(x.c, x.c)}${input[x.c] ? `<span class="tag">${term("input", "input")}</span>` : ""}</td>
          <td>${nf(x.gr, 0)}</td><td>${nf(x.gm, 0)}</td>
          <td>${signed(x.diff, 0)} GWh${x.pct != null ? ` <span style="color:var(--muted)">(${signed(x.pct, 0)} %)</span>` : ""}</td><td>${bar}</td>
          <td>${nf(x.mae, 0)} MW</td></tr>`;
      }).join("") + `<tr class="total-row"><td>Total</td><td>${nf(tot.gr, 0)}</td><td>${nf(tot.gm, 0)}</td>
          <td>${signed(tot.gm - tot.gr, 0)} GWh</td><td></td><td></td></tr></tbody>`;
    const notes = [];
    const omie = md.ref === "omie";
    if (state.mixStage === "DA" && omie) notes.push("Wind and solar match exactly because the day-ahead uses OMIE's own numbers as input. The other rows are the model's own decisions.");
    if (state.mixStage === "BAL" && omie) notes.push("Balancing uses the updated wind, solar and load forecasts, while the reference is OMIE's day-ahead programme, so wind and solar differ here by design.");
    if (state.mixStage === "RD") notes.push(`Redispatch counts only the ${solved} of ${N} hours where the AC solve finished.`);
    if (state.mixStage === "RD" && omie) notes.push("OMIE's day-ahead programme is a plan, so this comparison also includes everything that changed in reality after the day-ahead. ENTSO-E actual is the fairer reference for this stage.");
    if (!omie) notes.push("Imports are measured physical flows from France and Portugal.");
    if (!omie && state.mixStage !== "RD") notes.push("This compares a market stage with the final real outcome, so the difference also includes the real changes made after that market.");
    notes.push("Hourly error is the mean absolute difference per hour.");
    $("mix-note").textContent = notes.join(" ");

    $("mix-legend").innerHTML = `<span><i class="sw-line" style="background:var(--real)"></i>Real (${md.ref === "entsoe" ? "ENTSO-E" : "OMIE"})</span><span><i class="sw-line" style="background:var(--model)"></i>Model (${MIX_STAGES.find(s => s[0] === state.mixStage)[1].toLowerCase()})</span><span style="color:var(--muted)">${nd <= 3 ? "MW each hour" : "Energy per day"} for each technology</span>`;
    const sm = $("mix-sm"); sm.innerHTML = "";
    const smHourly = nd <= 3;
    for (const x of rows) {
      const box = document.createElement("div"); box.className = "sm";
      box.innerHTML = `<h4>${x.c}<span>${x.pct != null ? signed(x.pct, 0) + " %" : signed(x.diff, 1) + " GWh"}</span></h4>`;
      const ch = document.createElement("div"); ch.className = "chart"; box.appendChild(ch); sm.appendChild(box);
      const masked = realSrc[x.c].map((v, i) => mix[x.c][i] == null ? null : v);
      const rv = smHourly ? masked : dailySum(masked, nd);
      const mv = smHourly ? mix[x.c] : dailySum(mix[x.c], nd);
      const unit = smHourly ? "MW" : "GWh";
      requestAnimationFrame(() => lineChart(ch, {
        n: rv.length, height: 122, yTicks: 2, yUnit: smHourly ? "MW" : "GWh/day", label: x.c + ", model vs real",
        xTicks: dayTicks(r.days, smHourly, ch.clientWidth - 60).filter((t, k, a) => smHourly ? t.label.includes(" ") : (k === 0 || k === a.length - 1)),
        series: [{ name: "Real", values: rv, color: "var(--real)", width: 1.5 }, { name: "Model", values: mv, color: "var(--model)", width: 1.75 }],
        onZoom: (a, b) => zoomFromChart(a, b, smHourly),
        tooltip: i => `<b>${smHourly ? dayLabel(r.days[Math.floor(i / 24)]) + ", " + hh(i % 24) : dayLabel(r.days[i])}</b>
          <div class="row"><i class="sw-line" style="background:var(--real)"></i>Real<span class="v">${nf(rv[i])} ${unit}</span></div>
          <div class="row"><i class="sw-line" style="background:var(--model)"></i>Model<span class="v">${nf(mv[i])} ${unit}</span></div>`,
      }));
    }
  }

  // ---------- balancing: the model's BAL stage next to REE's balancing markets (e·sios) ----------
  function renderBalancing(r) {
    if ($("sec-bal").hidden || !window.ESIOS) return;
    const nd = r.days.length, hourly = nd <= 3, E = k => esiosFor(r, k);
    const agg = a => hourly ? a : dailyMean(a, nd);
    const PR = [["Model, balancing (BAL)", r.price.BAL, "var(--model)", 2], ["REE, RR price", E("rr_price"), "var(--real)", 1.5],
                ["REE, aFRR up", E("afrr_up_price"), "var(--cat-2)", 1.2], ["REE, aFRR down", E("afrr_down_price"), "var(--cat-3)", 1.2]];
    $("bal-legend").innerHTML = `<span style="color:var(--muted)">${hourly ? "each hour" : "daily mean"}</span>`;
    const host = $("bal-chart");
    const ser = PR.map(([name, v, color, width]) => ({ name, values: agg(v), color, width }));
    lineChart(host, {
      n: ser[0].values.length, height: 300, yUnit: "€/MWh", label: "Balancing price, model vs REE", endLabels: true,
      xTicks: dayTicks(r.days, hourly, host.clientWidth - 60), onZoom: (a, b) => zoomFromChart(a, b, hourly),
      series: ser,
      tooltip: i => `<b>${hourly ? dayLabel(r.days[Math.floor(i / 24)]) + ", " + hh(i % 24) : dayLabel(r.days[i]) + " (daily mean)"}</b>`
        + ser.map(s => `<div class="row"><i class="sw-line" style="background:${s.color}"></i>${s.name}<span class="v">${nf(s.values[i])} €/MWh</span></div>`).join(""),
    });
    const sum = a => a ? a.reduce((s, x) => s + (x || 0), 0) / 1000 : 0;
    const sumAbs = a => a ? a.reduce((s, x) => s + Math.abs(x || 0), 0) / 1000 : 0;
    const V = [["aFRR (secondary)", "afrr"], ["mFRR (tertiary)", "mfrr"], ["RR (replacement)", "rr"]];
    const rows = V.map(([l, k]) => [l, sum(E(k + "_up")), sum(E(k + "_down")), mean(E(k === "rr" ? "rr_price" : k + "_up_price"))]);
    const ru = rows.reduce((s, x) => s + x[1], 0), rd = rows.reduce((s, x) => s + x[2], 0);
    const B = r.balancing;
    const pct = (a, b) => b ? ` <span class="pv-muted-txt">(${nf(100 * a / b, 0)} % of REE)</span>` : "";
    $("bal-table").innerHTML = `<thead><tr><th>Balancing energy, ${nd} day${nd > 1 ? "s" : ""}</th><th>Up, GWh</th><th>Down, GWh</th><th>Mean price up, €/MWh (RR: its one price)</th></tr></thead><tbody>`
      + rows.map(([l, u, d, pz]) => `<tr><td>REE, ${l}</td><td>${nf(u, 0)}</td><td>${nf(d, 0)}</td><td>${nf(pz, 1)}</td></tr>`).join("")
      + `<tr class="total-row"><td>REE, total</td><td>${nf(ru, 0)}</td><td>${nf(rd, 0)}</td><td></td></tr>`
      + (B ? `<tr class="total-row"><td>${term("Model, balancing stage", "model_bal")}</td><td>${nf(sum(B.up), 0)}${pct(sum(B.up), ru)}</td><td>${nf(sum(B.down), 0)}${pct(sum(B.down), rd)}</td><td>${nf(mean(r.price.BAL), 1)} <span class="pv-muted-txt">(BAL price)</span></td></tr>`
           : `<tr><td colspan="4" class="pv-tbc">The model's balancing volume is not in this run's package yet; publish it again with the current publish_run.py.</td></tr>`)
      + "</tbody>";
    $("imb-table").innerHTML = `<thead><tr><th>What had to be balanced, ${nd} day${nd > 1 ? "s" : ""}</th><th>Sum of hourly absolute values, GWh</th></tr></thead><tbody>`
      + `<tr><td>${term("REE, net imbalance of generation and demand", "ree_imb")}</td><td>${nf(sumAbs(E("imbalance")), 0)}</td></tr>`
      + (B ? `<tr><td>${term("Model, forecast change from CID to balancing", "model_imb")}</td><td>${nf(sumAbs(B.need), 0)}${pct(sumAbs(B.need), sumAbs(E("imbalance")))}</td></tr>` : "")
      + "</tbody>";
    // volume charts: REE's balancing energy (aFRR + mFRR + RR) vs the model's balancing stage
    const vhost = $("bal-vol");
    if (!B) { vhost.innerHTML = ""; return; }
    const add = (...a) => a[0].map((_, i) => a.reduce((s, x) => s + (x[i] || 0), 0));
    const rUp = add(E("afrr_up"), E("mfrr_up"), E("rr_up")), rDn = add(E("afrr_down"), E("mfrr_down"), E("rr_down"));
    const unit = hourly ? "MW" : "GWh/day", ag = a => hourly ? a : dailySum(a, nd);
    vhost.innerHTML = `<div class="rd-pair"><div><h4>Balancing up</h4><div class="chart" id="bal-up"></div></div><div><h4>Balancing down</h4><div class="chart" id="bal-down"></div></div></div>`;
    const draw = (id, label, real, model) => {
      const rv = ag(real), mv = ag(model);
      lineChart($(id), {
        n: rv.length, height: 220, yTicks: 4, yUnit: unit, label, endLabels: true,
        xTicks: dayTicks(r.days, hourly, $(id).clientWidth - 110), onZoom: (a, b) => zoomFromChart(a, b, hourly),
        series: [{ name: "REE", values: rv, color: "var(--real)", width: 1.5 }, { name: "Model", values: mv, color: "var(--model)", width: 2 }],
        tooltip: i => `<b>${hourly ? dayLabel(r.days[Math.floor(i / 24)]) + ", " + hh(i % 24) : dayLabel(r.days[i])}</b>
          <div class="row"><i class="sw-line" style="background:var(--real)"></i>REE<span class="v">${nf(rv[i], hourly ? 0 : 1)} ${unit}</span></div>
          <div class="row"><i class="sw-line" style="background:var(--model)"></i>Model<span class="v">${nf(mv[i], hourly ? 0 : 1)} ${unit}</span></div>`,
      });
    };
    requestAnimationFrame(() => { draw("bal-up", "Balancing up, REE vs model", rUp, B.up); draw("bal-down", "Balancing down, REE vs model", rDn, B.down); });
  }

  // ---------- redispatch: model vs what REE really did (e·sios) ----------
  function renderRedispatch(r) {
    if ($("sec-rd").hidden) return;
    const host = $("rd-charts");
    if (!window.ESIOS) { host.innerHTML = `<p class="fineprint">reference/esios_2024.js is missing. Run tools/build_esios.py.</p>`; return; }
    const nd = r.days.length, N = nd * 24, h0 = r.offset * 24, hourly = nd <= 3;
    const pr = plantRun(r.id), H = pr.H;
    // model: redispatch minus balancing, summed up and down (no value in failed hours). Packages
    // published with the current publish_run.py carry it over all units, with the cost; older
    // ones fall back to the plant groups on the map, without cost.
    const RD = r.redispatch;
    const mUp = RD ? RD.up.slice() : new Array(N).fill(null), mDown = RD ? RD.down.slice() : new Array(N).fill(null);
    for (let i = 0; i < N && !RD; i++) {
      if (r.status[i] !== 1) continue;
      let up = 0, dn = 0;
      PD.groups.forEach((p, g) => {
        if (p.f === "Imports") return;
        const v = pr.chg[g * H + h0 + i]; if (v === -128) return;
        const mw = v / 127 * p.cap; if (mw > 0) up += mw; else dn -= mw;
      });
      mUp[i] = up; mDown[i] = dn;
    }
    const E = k => esiosFor(r, k);
    const add = (...a) => a[0].map((_, i) => a.reduce((s, x) => s + (x[i] || 0), 0));
    const rUp = add(E("rt1_up"), E("rt2_up"), E("rtr_up")), rDown = add(E("rt1_down"), E("rt2_down"), E("rtr_down"));
    const unit = hourly ? "MW" : "GWh/day";
    const agg = a => hourly ? a : dailySum(a, nd);
    const draw = (id, label, real, model) => {
      const rv = agg(real), mv = agg(model);
      lineChart($(id), {
        n: rv.length, height: 230, yTicks: 4, yUnit: unit, label, endLabels: true,
        xTicks: dayTicks(r.days, hourly, $(id).clientWidth - 110),
        onZoom: (a, b) => zoomFromChart(a, b, hourly),
        series: [{ name: "REE", values: rv, color: "var(--real)", width: 1.5 }, { name: "Model", values: mv, color: "var(--model)", width: 2 }],
        tooltip: i => `<b>${hourly ? dayLabel(r.days[Math.floor(i / 24)]) + ", " + hh(i % 24) : dayLabel(r.days[i])}</b>
          <div class="row"><i class="sw-line" style="background:var(--real)"></i>REE<span class="v">${nf(rv[i], hourly ? 0 : 1)} ${unit}</span></div>
          <div class="row"><i class="sw-line" style="background:var(--model)"></i>Model<span class="v">${nf(mv[i], hourly ? 0 : 1)} ${unit}</span></div>`,
      });
    };
    host.innerHTML = `<div class="rd-pair"><div><h4>Turned up</h4><div class="chart" id="rd-up"></div></div><div><h4>Turned down</h4><div class="chart" id="rd-down"></div></div></div>`;
    $("rd-legend").innerHTML = `<span><i class="sw-line" style="background:var(--real)"></i>${term("REE redispatch", "ree_rd")}</span><span><i class="sw-line" style="background:var(--model)"></i>${term("Model redispatch", "model_rd")}</span><span style="color:var(--muted)">${hourly ? "MW each hour" : "Energy per day"}</span>`;
    requestAnimationFrame(() => { draw("rd-up", "Redispatch up, REE vs model", rUp, mUp); draw("rd-down", "Redispatch down, REE vs model", rDown, mDown); });
    // totals over the solved hours, so both sides cover the same hours
    const ok = i => r.status[i] === 1;
    const tot = a => a ? a.reduce((s, x, i) => s + (ok(i) ? (x || 0) : 0), 0) : 0;
    const G = a => tot(a) / 1000, M = a => tot(a) / 1e6;
    // REE cost = extra cost over the market (P.O. 14.4): what is paid for going up minus the refunds
    // for going down. Phase I/II from 1373–1376 (their net is indicator 709); real time from 1723/1724
    const rows = [
      ["REE, after the day-ahead, phase I", G(E("rt1_up")), G(E("rt1_down")), M(E("rt1_up_cost")) - M(E("rt1_down_cost"))],
      ["REE, after the day-ahead, phase II (rebalancing)", G(E("rt2_up")), G(E("rt2_down")), M(E("rt2_up_cost")) - M(E("rt2_down_cost"))],
      ["REE, real time", G(E("rtr_up")), G(E("rtr_down")), M(E("rtr_up_cost")) + M(E("rtr_down_cost"))],
    ];
    const ru = rows.reduce((s, x) => s + x[1], 0), rd = rows.reduce((s, x) => s + x[2], 0), rc = rows.reduce((s, x) => s + x[3], 0);
    const mu = G(mUp), md = G(mDown), mc = RD ? M(RD.cost) : null, ml = RD ? G(RD.losses) : null;
    const perMWh = (c, v) => c == null || !v ? "–" : nf(1e6 * c / (1000 * v), 1);
    const solved = r.status.reduce((a, b) => a + b, 0);
    const pctOf = (a, b) => b ? ` <span class="pv-muted-txt">(${nf(100 * a / b, 0)} %)</span>` : "";
    $("rd-table").innerHTML = `<thead><tr><th>Over the ${solved} solved hours</th><th>Up, GWh</th><th>Down, GWh</th><th>${term("Extra cost", "rd_cost")}, €</th><th>€ per MWh up</th></tr></thead><tbody>`
      + rows.map(([l, u, d, c]) => `<tr><td>${l}</td><td>${nf(u, 0)}</td><td>${nf(d, 0)}</td><td>${nf(c * 1e6, 0)}</td><td>${perMWh(c, u)}</td></tr>`).join("")
      + `<tr class="total-row"><td>REE, total</td><td>${nf(ru, 0)}</td><td>${nf(rd, 0)}</td><td>${nf(rc * 1e6, 0)}</td><td>${perMWh(rc, ru)}</td></tr>`
      + `<tr class="total-row"><td>Model, AC redispatch</td><td>${nf(mu, 0)}${pctOf(mu, ru)}</td><td>${nf(md, 0)}${pctOf(md, rd)}</td><td>${mc == null ? "–" : nf(mc * 1e6, 0) + pctOf(mc, rc)}</td><td>${perMWh(mc, mu)}</td></tr>`
      + (RD ? `<tr><td class="pv-muted-txt">of which grid losses in the model (the markets have none)</td><td class="pv-muted-txt">${nf(ml, 0)}</td><td></td><td></td><td></td></tr>` : "")
      + "</tbody>";
    $("rd-cost-note").innerHTML = RD ? `REE's whole real-time cost was ${nf(M(E("rtr_cost")) * 1e6, 0)} € (indicator 724); the table uses its up and down parts (1723, 1724), which go with the volumes.`
      : `This run's package has no model cost yet; publish it again with the current publish_run.py.`;
    // cost per day (or hour), REE vs model
    const cHost = $("rd-cost-chart");
    if (!RD) { cHost.innerHTML = ""; return; }
    const reeCost = add(E("rt1_up_cost"), E("rt2_up_cost"), E("rtr_up_cost"), E("rtr_down_cost")).map((x, i) => x - (E("rt1_down_cost")[i] || 0) - (E("rt2_down_cost")[i] || 0));
    const cu = hourly ? "€ per hour" : "€ per day";
    const cv = a => hourly ? a.map((x, i) => ok(i) && x != null ? x : null) : dailySum(a.map((x, i) => ok(i) ? x : null), nd).map(x => x == null ? null : x * 1000);   // dailySum divides by 1000
    requestAnimationFrame(() => {
      const rv = cv(reeCost), mv = cv(RD.cost);
      lineChart(cHost, {
        n: rv.length, height: 230, yTicks: 4, yUnit: cu, label: "Redispatch cost, REE vs model", endLabels: true,
        xTicks: dayTicks(r.days, hourly, cHost.clientWidth - 110), onZoom: (a, b) => zoomFromChart(a, b, hourly),
        series: [{ name: "REE", values: rv, color: "var(--real)", width: 1.5 }, { name: "Model", values: mv, color: "var(--model)", width: 2 }],
        tooltip: i => `<b>${hourly ? dayLabel(r.days[Math.floor(i / 24)]) + ", " + hh(i % 24) : dayLabel(r.days[i])}</b>
          <div class="row"><i class="sw-line" style="background:var(--real)"></i>REE<span class="v">${nf(rv[i], 0)} €</span></div>
          <div class="row"><i class="sw-line" style="background:var(--model)"></i>Model<span class="v">${nf(mv[i], 0)} €</span></div>`,
      });
      renderWhy(r, { G, M, E, ok, ru, rd, rc, mu, mc, RD });
    });
  }

  // ---------- why REE's redispatch is so much larger: by cause vs by type, and a cost bridge ----------
  const CAUSES = [
    ["scb", "Overloads, base case", "var(--model)", true],
    ["sca", "Overloads after a contingency (N-1)", "var(--cat-8)", false],
    ["ct", "Voltage control", "var(--cat-2)", false],
    ["rtd", "Distribution grid", "var(--cat-5)", false],
    ["rsi", "Too little upward reserve", "var(--cat-4)", false],
    ["rbi", "Too little downward reserve", "var(--cat-6)", false],
    ["ase", "Frequency (European area)", "var(--cat-7)", false],
    ["otros", "Other causes", "var(--axis)", false],
  ];
  const REBAL = ["Rebalancing after phase I", "var(--cat-3)"];
  const RD_TYPES = [["Pumped storage", "var(--cat-7)"], ["Hydro", "var(--cat-1)"], ["Gas", "var(--cat-2)"], ["Wind and solar", "var(--cat-3)"], ["Other", "var(--axis)"]];
  function renderWhy(r, k) {
    const host = $("rd-why");
    if (!k.RD || !k.RD.up_by) { host.innerHTML = `<p class="fineprint">Publish this run again with the current publish_run.py to see the model's split.</p>`; $("rd-why-note").textContent = ""; return; }
    const { G, E, ru, rd, rc, mu, mc, RD } = k;
    // REE: the causes overlap a little, so each stage's cause split is scaled to that stage's total
    const byCause = dir => {
      const seg = Object.fromEntries(CAUSES.map(c => [c[0], 0]));
      for (const [stage, tot] of [["rt1", G(E(`rt1_${dir}`))], ["rtr", G(E(`rtr_${dir}`))]]) {
        const raw = CAUSES.map(c => G(E(`${stage}_${dir}_${c[0]}`) || []));
        const s = raw.reduce((a, b) => a + b, 0);
        CAUSES.forEach((c, i) => { seg[c[0]] += s ? tot * raw[i] / s : 0; });
      }
      return CAUSES.map(c => ({ name: c[1], color: c[2], v: seg[c[0]], inModel: c[3] }))
        .concat([{ name: REBAL[0], color: REBAL[1], v: G(E(`rt2_${dir}`)), inModel: null }]).filter(s => s.v > 0.5);
    };
    const byType = dir => RD_TYPES.map(([n, c]) => ({ name: n, color: c, v: G(RD[dir === "up" ? "up_by" : "down_by"][n]) })).filter(s => s.v > 0.5);
    const rows = [["REE, turned up", byCause("up")], ["Model, turned up", byType("up")], null,
                  ["REE, turned down", byCause("down")], ["Model, turned down", byType("down")]];
    const W = Math.max(320, host.clientWidth), lab = 128, bw = W - lab - 70, bh = 24, gap = 12;
    const max = Math.max(ru, rd, mu, 1);
    let y = 6, svgParts = [];
    for (const row of rows) {
      if (!row) { y += 14; continue; }
      const [name, segs] = row, total = segs.reduce((a, s) => a + s.v, 0);
      svgParts.push(`<text x="${lab - 8}" y="${y + bh / 2 + 4}" text-anchor="end" class="why-lab">${name}</text>`);
      let x = lab;
      for (const s of segs) {
        const w = bw * s.v / max;
        const tick = s.inModel === true ? " (the model sees this)" : s.inModel === false ? " (not in the model)" : "";
        svgParts.push(`<rect x="${x}" y="${y}" width="${Math.max(w, 0.5)}" height="${bh}" fill="${s.color}" stroke="var(--surface)" stroke-width="1"><title>${s.name}${tick}: ${nf(s.v, 0)} GWh (${nf(100 * s.v / total, 0)} %)</title></rect>`);
        { const short = s.name.split(" (")[0].split(",")[0]; if (w > short.length * 6.3 + 10) svgParts.push(`<text x="${x + 5}" y="${y + bh / 2 + 4}" class="why-in">${short}</text>`); }
        x += w;
      }
      svgParts.push(`<text x="${x + 6}" y="${y + bh / 2 + 4}" class="why-val">${nf(total, 0)} GWh</text>`);
      y += bh + gap;
    }
    // cost bridge: REE's extra cost -> at the model's volume -> the model's extra cost
    const pR = ru ? rc / ru : 0;              // M€ per GWh = k€/MWh
    const atModelVolume = mu * pR;
    const steps = [["REE extra cost", rc, "abs"], ["REE moves more energy", atModelVolume - rc, "step"],
                   ["Marginal cost instead of bids and start-ups; pumped storage almost free", mc - atModelVolume, "step"], ["Model extra cost", mc, "abs"]];
    const by = y + 26, bH = 150, vals = [0, rc, atModelVolume, mc];
    const lo = Math.min(0, ...vals), hi = Math.max(...vals, 1);
    const Y = v => by + bH - (v - lo) / (hi - lo) * bH;
    const cw = Math.min(150, (W - lab) / 4.4);
    let level = 0;
    svgParts.push(`<text x="0" y="${by - 10}" class="why-h">The cost, step by step (€)</text>`);
    svgParts.push(`<line x1="${lab}" x2="${W - 8}" y1="${Y(0)}" y2="${Y(0)}" stroke="var(--axis)"/>`);
    steps.forEach(([name, v, kind], i) => {
      const x = lab + i * (cw * 1.1);
      const a = kind === "abs" ? 0 : level, b = kind === "abs" ? v : level + v;
      const col = kind === "abs" ? (i === 0 ? "var(--real)" : "var(--model)") : (v < 0 ? "var(--cat-3)" : "var(--critical)");
      svgParts.push(`<rect x="${x}" y="${Math.min(Y(a), Y(b))}" width="${cw}" height="${Math.max(1, Math.abs(Y(a) - Y(b)))}" fill="${col}" rx="2"><title>${name}: ${nf(v * 1e6, 0)} €</title></rect>`);
      svgParts.push(`<text x="${x + cw / 2}" y="${Math.min(Y(a), Y(b)) - 5}" text-anchor="middle" class="why-val">${kind === "step" && v > 0 ? "+" : ""}${nf(v * 1e6, 0)}</text>`);
      const words = name.split(" "), lines = [];
      for (const wd of words) { const l = lines.length ? lines[lines.length - 1] : null; if (l != null && (l + " " + wd).length <= Math.floor(cw / 6.2)) lines[lines.length - 1] = l + " " + wd; else lines.push(wd); }
      lines.slice(0, 4).forEach((l, j) => svgParts.push(`<text x="${x + cw / 2}" y="${by + bH + 16 + j * 13}" text-anchor="middle" class="why-cap">${l}</text>`));
      level = kind === "abs" ? v : level + v;
    });
    const H = by + bH + 16 + 4 * 13 + 6;
    host.innerHTML = `<svg width="${W}" height="${H}" role="img" aria-label="Redispatch volume by cause (REE) and by type (model), and the cost from REE to the model, step by step">${svgParts.join("")}</svg>`
      + `<div class="legend why-legend"><span class="why-key">REE causes:</span>${CAUSES.map(c => `<span><i class="sw-box" style="background:${c[2]}"></i>${c[1]}${c[3] ? " ✔" : ""}</span>`).join("")}<span><i class="sw-box" style="background:${REBAL[1]}"></i>${REBAL[0]}</span></div>`
      + `<div class="legend why-legend"><span class="why-key">Model types:</span>${RD_TYPES.map(([n, c]) => `<span><i class="sw-box" style="background:${c}"></i>${n}</span>`).join("")}</div>`;
    // the main reasons in words, with this period's numbers
    const up = byCause("up"), share = n => { const s = up.find(x => x.name === n); return s ? 100 * s.v / ru : 0; };
    const ps = G(RD.up_by["Pumped storage"]), gasDown = G(RD.down_by["Gas"]);
    $("rd-why-note").innerHTML = `<b>Why:</b> ${nf(share("Voltage control"), 0)} % of what REE turned up was for <b>voltage control</b> and ${nf(share("Overloads after a contingency (N-1)"), 0)} % for <b>overloads after a contingency</b>; the model has neither. Only ${nf(share("Overloads, base case"), 1)} % was for overloads in the base case, the one cause the model's AC grid sees (✔). REE paid ${nf(1000 * pR, 0)} €/MWh above the market for what it turned up (bids with start-up costs); the model values its changes at marginal cost, and in its hour-by-hour redispatch pumped storage has no energy limit and costs almost nothing: it turned pumped storage up by ${nf(ps, 0)} GWh and gas down by ${nf(gasDown, 0)} GWh. REE's causes overlap a little; each stage's split is scaled to its total.`;
  }

  // Ipopt's verdict for a failed hour (summary.csv `status`), in plain words
  const FAIL_WORDS = {
    LOCALLY_INFEASIBLE: "No feasible point: Ipopt converged to a point that breaks some limits",
    INFEASIBLE: "Infeasible",
    ITERATION_LIMIT: "Stopped at Ipopt's iteration limit",
    TIME_LIMIT: "Stopped at the time limit",
    NUMERICAL_ERROR: "Numerical trouble (Ipopt's restoration phase failed)",
    OTHER_ERROR: "Ipopt stopped with an error",
    SLOW_PROGRESS: "Stopped: no more progress",
    ALMOST_LOCALLY_SOLVED: "Almost solved (tolerance not met)",
  };
  function renderStatus(r) {
    const host = $("fail-list");
    const ccgt = r.mix.BAL.CCGT, mixBal = r.mix.BAL;
    const h0 = r.offset * 24, info = r.fail_info || null;
    const failed = []; r.status.forEach((s, i) => { if (s !== 1) failed.push(i); });
    if (!failed.length) {
      host.innerHTML = `<p class="fail-none">${icon("good")} All ${r.status.length.toLocaleString("en-GB")} hours in this period solved.</p>`;
    } else {
      const reasons = {};
      for (const i of failed) { const k = info && info[h0 + i] ? info[h0 + i].status : "not recorded"; reasons[k] = (reasons[k] || 0) + 1; }
      const mw = (k, i) => mixBal[k] ? nf(mixBal[k][i] || 0, 0) : "–";
      const rows = failed.map(i => {
        const d = r.days[Math.floor(i / 24)], f = info && info[h0 + i];
        const why = f ? `<span class="mono">${esc(f.status)}</span>${FAIL_WORDS[f.status] ? `<span class="fail-why">${esc(FAIL_WORDS[f.status])}</span>` : ""}${f.where ? `<span class="fail-where">${esc(f.where)}</span>` : ""}${f.ipopt ? `<span class="fail-why">Ipopt: ${esc(f.ipopt)}</span>` : ""}` : `<span class="fail-why">not recorded</span>`;
        return `<tr data-h="${h0 + i}" tabindex="0"><td>${dayLabel(d)}</td><td>${hh(i % 24)}</td><td class="fail-reason">${why}</td>
          <td>${mw("Imports", i)}</td><td>${mw("Wind", i)}</td><td>${mw("Solar", i)}</td><td>${nf(ccgt[i] || 0, 0)}</td><td>${nf(r.price.DA[i])}</td></tr>`;
      }).join("");
      host.innerHTML = `<div class="fail-sum">${Object.entries(reasons).sort((a, b) => b[1] - a[1]).map(([k, n]) => `<span class="ri-tag">${esc(k)} · ${n}</span>`).join("")}</div>
        <div class="gt-scroll fail-scroll"><table id="fail-table"><thead><tr><th>Day</th><th>Hour</th><th>Why it stopped</th>
        <th>Imports<br>MW</th><th>Wind<br>MW</th><th>Solar<br>MW</th><th>CCGT<br>MW</th><th>DA price<br>€/MWh</th></tr></thead><tbody>${rows}</tbody></table></div>
        ${info ? "" : `<p class="fineprint">This run was published before the reason was recorded. Republish it with the newest <span class="mono">scripts/publish_run.py</span> to fill in "Why it stopped".</p>`}
        <p class="fineprint">Imports, wind, solar and CCGT are the balancing-stage values the redispatch started from.</p>`;
      const open = h => { stopPlay("gh"); state.gridMode = "hour"; state.gridHour = h; if (state.tab === "grid") renderGrid(view()); else pickTab("grid"); };
      host.querySelectorAll("tr[data-h]").forEach(tr => {
        tr.addEventListener("click", () => open(+tr.dataset.h));
        tr.addEventListener("keydown", ev => { if (ev.key === "Enter") open(+tr.dataset.h); });
      });
    }

    const grp = on => { let n = 0, f = 0; r.status.forEach((sv, i) => { if (((ccgt[i] || 0) > 1) === on) { n++; if (!sv) f++; } }); return { n, f }; };
    const g1 = grp(true), g0 = grp(false), all = { n: r.status.length, f: r.status.filter(x => !x).length };
    const rate = (lbl, g, sub) => `<div class="rate"><div class="r-top"><span>${lbl}</span><b>${g.n ? nf(100 * g.f / g.n, 0) : "–"} %</b></div>
      <div class="r-bar"><span style="width:${g.n ? 100 * g.f / g.n : 0}%"></span></div><div class="r-sub">${g.f} of ${g.n} hours failed${sub ? " · " + sub : ""}</div></div>`;
    $("rates").innerHTML = rate("All hours", all) + rate("With CCGT running", g1) + rate("Without CCGT", g0, "gas off at balancing");
  }

  // ---------- market stages: the model laid out like the PowerVision paper ----------
  // Static facts about the model (reference/model_facts.js); the same for every run.
  let stagesDone = false;
  // ---------- CSP/TES plant: price taker (Option B) on the cleared prices ----------
  function renderCsp(r) {
    const sec = $("sec-csp");
    if (!sec) return;
    const c = r.csp;
    if (!c || !c.dispatch || !Object.keys(c.dispatch).length) { sec.hidden = true; return; }
    const nd = r.days.length;
    if (!c.gates.includes(state.cspGate)) state.cspGate = c.gates.includes("BAL") ? "BAL" : c.gates[0];
    seg($("csp-gate"), c.gates.map(g => [g, g, g]), state.cspGate, v => { state.cspGate = v; renderCsp(view()); });
    const p = c.plant || {};
    $("csp-plant").innerHTML = [
      ["Plant / bus", (p.plant_id != null ? String(p.plant_id) : "-") + " @ " + (p.bus_id != null ? String(p.bus_id) : "-")],
      ["Solar field", p.solar_capacity != null ? nf(p.solar_capacity, 0) + " MW_th" : "–"],
      ["Power block", p.pmax_e != null ? nf(p.pmax_e, 0) + " MW_e" : "–"],
      ["TES tank", p.tes_capacity != null ? nf(p.tes_capacity, 0) + " MWh_th" : "–"],
      ["Terminal floor", p.q_end_target != null ? nf(p.q_end_target, 0) + " MWh_th" : "–"],
      ["Tank at stream start", p.q0_start != null ? nf(p.q0_start, 0) + " MWh_th" : "–"],
      ["η field→TES / TES→el / grid→TES", (p.eta_solar ?? "–") + " / " + (p.eta_power ?? "–") + " / " + (p.eta_charge ?? "–")],
      ["Thermal leak", p.thermal_leak_rate != null ? p.thermal_leak_rate + " per hour" : "–"],
      ["Grid charging", p.buy_from_grid == null ? "–" : p.buy_from_grid ? "enabled" : "off"],
    ].map(([l, v]) => `<div><dt>${l}</dt><dd>${v}</dd></div>`).join("");

    const d = c.dispatch[state.cspGate];
    const sl = a => a.slice(r.offset * 24, (r.offset + nd) * 24);
    const gen = sl(d.p_gen), buy = sl(d.p_buy), tes = sl(d.tes), price = sl(d.price), sol = sl(d.s_solar);
    const tot = a => a.reduce((s, v) => s + (v || 0), 0);
    const rows = c.summary.filter(s => s.gate === state.cspGate && r.days.includes(s.date));
    const net = rows.reduce((s, x) => s + (x.net_eur || 0), 0);
    $("csp-kpis").innerHTML = [
      ["Net market cash flow", nf(net, 0) + " €", "sell − buy, " + state.cspGate + " stream"],
      ["Generated", nf(tot(gen), 0) + " MWh_e", "over the days shown"],
      ["Solar heat collected", nf(tot(sol), 0) + " MWh_th", "thermal inflow: field \u2192 tank"],
      ["Bought from grid", nf(tot(buy), 0) + " MWh_e", p.buy_from_grid ? "price-taker arbitrage" : "grid charging off"],
      ["Tank at the end", rows.length ? nf(rows[rows.length - 1].q_end_mwhth, 1) + " MWh_th" : "–", "floor " + (p.q_end_target ?? "–")],
    ].map(([l, v, s]) => `<div class="kpi"><span class="k-label">${l}</span><span class="k-value">${v}</span><span class="k-sub">${s}</span></div>`).join("");
    // Clickable legend: each dataset toggles on/off the chart. The tooltip only
    // ever reports what the chart actually draws (hidden series drop out too).
    const on = state.cspOn || (state.cspOn = { sol: true, avail: true, gen: true, buy: true });
    const avail = d.s_avail ? sl(d.s_avail) : null;
    const leg = $("csp-legend");
    leg.innerHTML = "";
    const mkToggle = (key, label, color) => {
      const b = document.createElement("button");
      b.type = "button";
      b.className = "leg-toggle" + (on[key] ? "" : " off");
      b.setAttribute("aria-pressed", String(on[key]));
      b.title = "Show or hide this dataset";
      b.innerHTML = `<i class="leg-box"${on[key] ? ` style="background:${color};border-color:${color}"` : ""}></i><i class="sw-line" style="background:${color}"></i>${label}`;
      b.onclick = () => { on[key] = !on[key]; renderCsp(view()); };
      leg.appendChild(b);
    };
    mkToggle("sol", "Solar heat collected (MW_th)", "var(--cat-4)");
    if (avail) mkToggle("avail", "Available field heat (MW_th, dashed)", "var(--muted)");
    mkToggle("gen", "Generation (MW)", "var(--cat-3)");
    mkToggle("buy", "Grid charging (MW)", "var(--cat-2)");
    lineChart($("csp-chart"), {
      n: gen.length, height: 240, label: "CSP dispatch, " + state.cspGate, yUnit: "MW_e / MW_th",
      xTicks: dayTicks(r.days, true, Math.max(260, $("csp-chart").clientWidth) - 110),
      onZoom: (a, b) => zoomFromChart(a, b, true),
      series: [
        ...(on.sol ? [{ name: "Solar heat", values: sol, color: "var(--cat-4)" }] : []),
        ...(on.gen ? [{ name: "Generation", values: gen, color: "var(--cat-3)" }] : []),
        ...(on.buy ? [{ name: "Grid charging", values: buy, color: "var(--cat-2)" }] : []),
        ...(on.avail && avail ? [{ name: "available", values: avail, color: "var(--muted)", width: 1.5, dash: "4 4" }] : []),
      ],
      tooltip: i => `<b>${dayLabel(r.days[Math.floor(i / 24)])}, ${hh(i % 24)}</b>` +
        (on.sol ? `<div class="row"><i class="sw-line" style="background:var(--cat-4)"></i>Solar heat collected<span class="v">${nf(sol[i])} MW_th</span></div>` : "") +
        (on.avail && avail ? `<div class="row">Available field heat<span class="v">${nf(avail[i])} MW_th</span></div>` : "") +
        (on.gen ? `<div class="row"><i class="sw-line" style="background:var(--cat-3)"></i>Generation<span class="v">${nf(gen[i])} MW</span></div>` : "") +
        (on.buy ? `<div class="row"><i class="sw-line" style="background:var(--cat-2)"></i>Grid charging<span class="v">${nf(buy[i])} MW</span></div>` : ""),
    });

    $("csp-tes-legend").innerHTML = `<span><i class="sw-line" style="background:var(--cat-7)"></i>Tank level, start of hour (MWh_th)</span>` +
      (p.q_end_target != null ? `<span><i class="sw-line" style="background:var(--muted)"></i>Terminal floor</span>` : "") +
      (p.tes_capacity != null ? `<span><i class="sw-line" style="background:var(--muted)"></i>Full tank</span>` : "");
    lineChart($("csp-tes-chart"), {
      n: tes.length, height: 190, label: "TES tank level, " + state.cspGate, yUnit: "MWh_th",
      xTicks: dayTicks(r.days, true, Math.max(260, $("csp-tes-chart").clientWidth) - 110),
      onZoom: (a, b) => zoomFromChart(a, b, true),
      series: [
        { name: "TES level", values: tes, color: "var(--cat-7)" },
        ...(p.q_end_target != null ? [{ name: "floor", values: tes.map(() => p.q_end_target), color: "var(--muted)", width: 1.5, dash: "4 4" }] : []),
        ...(p.tes_capacity != null ? [{ name: "full", values: tes.map(() => p.tes_capacity), color: "var(--muted)", width: 1.5, dash: "2 6" }] : []),
      ],
      tooltip: i => `<b>${dayLabel(r.days[Math.floor(i / 24)])}, ${hh(i % 24)}</b>` +
        `<div class="row"><i class="sw-line" style="background:var(--cat-7)"></i>Tank at start<span class="v">${nf(tes[i])} MWh_th</span></div>` +
        `<div class="row">Tank at end<span class="v">${nf(sl(d.tes_end)[i])} MWh_th</span></div>`,
    });

    const trows = c.summary.filter(s => r.days.includes(s.date)).map(s =>
      `<tr${s.gate === state.cspGate ? ` class="csp-sel"` : ""}><td>${s.gate}</td><td>${dayLabel(s.date, false)}</td>` +
      `<td>${nf(s.gen_mwh, 0)}</td><td>${nf(s.buy_mwh, 0)}</td><td>${nf(s.solar_th_mwh, 0)}</td>` +
      `<td>${nf(s.net_eur, 0)}</td><td>${nf(s.theta_future_eur, 1)}</td><td>${nf(s.q_end_mwhth, 1)}</td></tr>`).join("");
    $("csp-table").innerHTML = `<thead><tr><th>Gate</th><th>Day</th><th>Gen<br>MWh_e</th><th>Grid buy<br>MWh_e</th>` +
      `<th>Solar heat<br>MWh_th</th><th>Net<br>€</th><th>θ_future<br>€</th><th>Tank end<br>MWh_th</th></tr></thead><tbody>${trows}</tbody>`;
    $("csp-note").textContent = `Option B price taker: the plant is re-dispatched per gate stream against the cleared prices and influences no market. ` +
      `BAL is the stream closest to physical reality. θ_future is the Bellman-cut continuation value of the stored heat.` +
      (p.buy_from_grid ? ` Grid purchases heat the tank (η ${p.eta_charge ?? "–"}) when the price is low.` : "");
  }

  function renderStages() {
    if (stagesDone) return;
    const F = window.MODEL_FACTS;
    if (!F) { $("pv-structure").innerHTML = `<p class="fineprint">reference/model_facts.js is missing. Run tools/build_model_facts.py.</p>`; return; }
    stagesDone = true;
    const n0 = x => Number(x).toLocaleString("en-GB");
    const cap = (label, text, paper) => `<b>${label}</b> ${text} <span class="pv-ref">${paper}</span>`;
    const tbc = `<span class="pv-tbc">to be checked</span>`;

    // Fig. 2: model structure, drawn like the paper's flow diagram
    const X = i => 20 + i * 156, W = i => (i === 5 ? 140 : 118), CX = i => X(i) + W(i) / 2;
    const ST = [["DA", "day-ahead"], ["ID2", "IDA2 · 22:00 D−1"], ["ID3", "IDA3 · 10:00 D"], ["CID", "h − 1"], ["BAL", "h · paper: BE"], ["Redispatch", "AC · h"]];
    const arrow = (x1, y1, x2, y2) => `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" class="ar" marker-end="url(#pv-head)"/>`;
    const lines = (x, y0, list, cls = "") => list.map((s, k) => `<text x="${x}" y="${y0 + k * 18}" class="${cls}">${s}</text>`).join("");
    $("pv-structure").innerHTML = `<svg class="pv-svg" viewBox="0 0 960 400" role="img" aria-label="Structure of the model: inputs and a forecasting model feed a chain of market stages, DA, ID2, ID3, CID and BAL on one zone, then an AC redispatch on the transmission grid">
      <defs><marker id="pv-head" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="hd"/></marker></defs>
      <rect x="20" y="20" width="380" height="165" rx="8" class="bx"/>
      <text x="36" y="46" class="ti">Inputs</text><text x="100" y="46" class="df">paper: all from FanSi</text>
      <text x="36" y="72" class="hd2">Static</text>${lines(36, 92, ["Production capacity", "Plant costs", "Grid model"])}
      <text x="200" y="72" class="hd2">Time-dependent</text>${lines(200, 92, ["Water values, SDDP (weekly)", "Fuel and CO₂ prices (daily)", "Nuclear, coal, CHP (daily)", "Demand, wind, solar (hourly)", "Cross-border flow (hourly)"])}
      <rect x="430" y="20" width="340" height="165" rx="8" class="bx"/>
      <text x="446" y="46" class="ti">Forecasting model</text>
      ${lines(446, 72, ["ENTSO-E data:", "day-ahead forecast and", "lagged actuals of wind,", "solar and load", "→ linear regression"])}
      <text x="446" y="172" class="df">paper: wind and load only</text>
      <line x1="642" y1="62" x2="642" y2="150" class="ax"/><line x1="642" y1="150" x2="756" y2="150" class="ax"/>
      <path d="M648,140 C672,104 700,88 752,76" class="cv"/>
      <text x="646" y="58" class="sm">RMSE</text><text x="700" y="168" class="sm" text-anchor="middle">lead time [h]</text>
      <rect x="800" y="20" width="140" height="165" rx="8" class="bx"/>
      <text x="812" y="46" class="ti">Transmission</text><text x="812" y="64" class="ti">grid data</text>
      ${lines(812, 88, [`${n0(F.n_buses)} buses`, `${n0(F.lines.reduce((s, l) => s + l.lines, 0))} lines`, `${n0(F.n_trafos)} transformers`, "shunt reactors"])}
      <text x="812" y="172" class="df">paper: DC flow</text>
      ${arrow(CX(0), 185, CX(0), 246)}
      <line x1="600" y1="185" x2="600" y2="214" class="ar"/><line x1="${CX(1)}" y1="214" x2="${CX(4)}" y2="214" class="ar"/>
      ${[1, 2, 3, 4].map(i => arrow(CX(i), 214, CX(i), 246)).join("")}
      <text x="608" y="207" class="sm">forecast updates</text>
      ${arrow(CX(5), 185, CX(5), 246)}
      ${ST.map(([s, d], i) => `<rect x="${X(i)}" y="250" width="${W(i)}" height="58" rx="6" class="${i === 5 ? "st rd" : "st"}"/>
        <text x="${CX(i)}" y="274" class="ti" text-anchor="middle">${s}</text><text x="${CX(i)}" y="294" class="sm" text-anchor="middle">${d}</text>`).join("")}
      ${[0, 1, 2, 3, 4].map(i => arrow(X(i) + W(i) + 3, 279, X(i + 1) - 3, 279)).join("")}
      <text x="${(CX(1) + CX(4)) / 2}" y="330" class="sm" text-anchor="middle">trading adjustments at every gate (the active case)</text>
      <text x="20" y="352" class="hd2">Resolution</text>
      <rect x="20" y="358" width="${X(4) + W(4) - 20}" height="30" rx="4" class="zn"/>
      <text x="${(20 + X(4) + W(4)) / 2}" y="378" class="lb" text-anchor="middle">Zonal: Spain as one zone, no grid</text>
      <rect x="${X(5)}" y="358" width="${W(5)}" height="30" rx="4" class="gr"/>
      <text x="${CX(5)}" y="378" class="lb" text-anchor="middle">Transmission grid</text>
    </svg>`;
    $("pv-structure-cap").innerHTML = cap("Fig. 2, Spanish version.", "The model is a chain of deterministic optimisation problems. DA to BAL clear Spain as one zone with no grid; each re-clears with that gate's forecast and moves the previous schedule as little as possible. Only the redispatch sees the transmission grid. Yellow labels show where the paper's Norway model differs.", "PowerVision paper, Fig. 2");

    // Table 1: gates
    const G = [
      ["DA", "12:00 D−1 (−12 h)", "0–23", "Zonal", "12:00 D−1", "12:00 D−1"],
      ["IDA1", "not modelled", "–", "–", "15:00 D−1", "–"],
      ["ID2", "22:00 D−1 (−2 h)", "0–23", "Zonal", "IDA2, 22:00 D−1", tbc],
      ["ID3", "10:00 D (+10 h)", "12–23", "Zonal", "IDA3, 10:00 D (hours 12–23)", tbc],
      ["CID", "h − 1", "h", "Zonal", `continuous; closing ${tbc}`, tbc],
      ["BAL", "h", "h", "Zonal", `REE balancing; ${tbc}`, tbc],
      ["Redispatch", "h", "h", `Grid (${n0(F.n_buses)} buses)`, `REE redispatch; ${tbc}`, tbc],
    ];
    $("pv-gates").innerHTML = `<thead><tr><th rowspan="2">Stage</th><th colspan="3" class="grp">Model</th><th colspan="2" class="grp">Real Spain, gate closure</th></tr>
      <tr><th>GCT</th><th>Delivery hours</th><th>Resolution</th><th>from 14 June 2024</th><th>before 14 June 2024</th></tr></thead><tbody>`
      + G.map(r => `<tr${r[1] === "not modelled" ? ` class="pv-muted"` : ""}>${r.map(c => `<td>${c}</td>`).join("")}</tr>`).join("") + "</tbody>";
    $("pv-gates-cap").innerHTML = cap("Table 1, Spanish version.", "Gate closure time (GCT), delivery hours and resolution of each stage. Hours are Spanish local time relative to 0:00 on the delivery day; −12 h is 12:00 the day before. The model's times are those used to build each gate's forecast (forecast_updates/main.py). Since 14 June 2024 Spain trades in the three European intraday auctions at the times in the paper's Fig. 1; the model's ID2 matches IDA2 and ID3 matches IDA3. Before that Spain had its own MIBEL sessions, so January and May have no one-to-one match.", "PowerVision paper, Table 1");

    // Table 2: capacity and load
    const C = F.capacity;
    $("pv-capacity").innerHTML = `<thead><tr><th>Spain (one zone)</th><th>Model</th><th>Real 2024 (ENTSO-E)</th><th>Model − real</th></tr></thead><tbody>`
      + C.rows.map(r => `<tr><td>${r.item}</td><td>${n0(r.model)} ${r.unit}${r.model_note ? `<div class="sub">${r.model_note}</div>` : ""}</td><td>${n0(r.real)} ${r.unit}</td><td>${signed(r.model - r.real, 0)} ${r.unit} <span class="pv-muted-txt">(${signed(100 * (r.model - r.real) / r.real, 0)} %)</span></td></tr>`).join("") + "</tbody>";
    $("pv-capacity-cap").innerHTML = cap("Table 2, Spanish version.", `Installed wind and solar capacity and mean load. Model: ${C.model_src}. Real: ${C.real_src}. ENTSO-E gives one capacity per year, so solar built during 2024 may be missing from it (to be checked). The model's load includes exports to France and Portugal; ENTSO-E's does not.`, "PowerVision paper, Table 2");

    // Fig. 7: data sources, grouped like the paper
    const nd = `<span class="pv-tbc">source not documented</span>`;
    const P = [
      ["Demand, wind and solar", "zn", "Zonal stages", [
        ["Day-ahead baseline per hour", "OMIE technology report, 2024", "omie_conversion/"],
        ["Forecast at each gate", "ENTSO-E actuals and day-ahead forecasts, 2022–2024", "forecast_updates/"],
        ["Spread over the buses", `share per bus (Data/load.csv) ${nd}`, "data_preparation.jl"]]],
      ["Generators", "zn", "Zonal stages and grid", [
        ["Plant list and capacity", `Data/generations.csv ${nd}`, ""],
        ["Nuclear, coal and CHP per day", "OMIE technology report", "omie_conversion/"],
        ["Fuel and CO₂ prices", "MIBGAS, EU ETS", "fuel_prices.jl"],
        ["Hydro water values", "37 climate years of inflow (Data/ts)", "midterm_sddp4.jl"]]],
      ["Cross-border", "zn", "Zonal stages and grid", [
        ["Exchange with France and Portugal", "ENTSO-E flows, OMIE exchange, 2024", "entsoe_download/"]]],
      ["Transmission grid", "gr", "Grid", [
        ["Buses, lines, transformers", `${nd}; the per-km values match the open European grid model`, "data_preparation.jl"],
        ["Shunt reactors", "REE, installed fleet December 2024", "data_preparation.jl"],
        [`Line rating × ${F.line_rating_factor}`, "N-1 margin, config.toml", ""]]],
    ];
    $("pv-sources").innerHTML = `<div class="pv-panels">` + P.map(([h, cls, use, items]) => `<div class="pv-panel">
        <div class="pv-panel-h">${h}</div>
        <ul>${items.map(([what, src, code]) => `<li><b>${what}</b><span>${src}</span>${code ? `<code>${code}</code>` : ""}</li>`).join("")}</ul>
        <div class="pv-panel-f ${cls}">Used in: ${use}</div></div>`).join("") + `</div>`;
    $("pv-sources-cap").innerHTML = cap("Fig. 7, Spanish version.", "The main data sources and the code that processes them (in the model repo). The paper builds its Norway grid from an open European grid model and line data from NVE; here the grid's source is not documented, but its standard line values match that same open model.", "PowerVision paper, Fig. 7");

    // Table 3: lines and transformers
    const lrf = F.line_rating_factor;
    $("pv-lines").innerHTML = `<thead><tr><th>Lines</th><th>Count</th><th>Circuits</th><th>Current limit</th><th>Thermal capacity per circuit</th><th>Limit in the model (× ${lrf})</th><th>r / x per km</th></tr></thead><tbody>`
      + F.lines.map(l => `<tr><td>${l.kv} kV${l.dc ? " DC" : ""}</td><td>${n0(l.lines)}</td><td>${n0(l.circuits)}</td><td>${l.imax_ka} kA</td><td>${n0(l.mva)} MVA</td><td>${n0(l.limit)} MW</td><td>${l.dc ? "–" : `${l.r} / ${l.x} Ω`}</td></tr>`).join("") + "</tbody>";
    $("pv-trafos").innerHTML = `<thead><tr><th>Transformers (high side)</th><th>Count</th><th>Standard unit</th><th>Units</th><th>Installed</th><th>Limit in the model (× ${lrf})</th></tr></thead><tbody>`
      + F.trafos.map(t => `<tr><td>${t.hv} kV</td><td>${t.count}</td><td>${n0(t.unit_mva)} MVA</td><td>${t.units}</td><td>${n0(t.installed)} MVA</td><td>${n0(t.limit)} MW</td></tr>`).join("") + "</tbody>";
    $("pv-lines-cap").innerHTML = cap("Table 3, Spanish version.", `Line and transformer assumptions. Every line of one voltage level has the same current limit and values per km: standard line types, not the real rating of each line, which is not public. The 400 kV and 320 kV reactances (0.246 and 0.265 Ω/km) are the values the paper uses. Transformers are sized by a rule (a number of standard units), with ${F.trafo_x.map(x => Math.round(x * 100)).join("–")} % reactance. Example: the Arkale transformer at the French border is 3 × 100 MVA here but a 550 MVA phase-shifter in reality (REE, 2017). The 320 kV link to France is modelled as four AC lines; the one DC line is the 250 kV link to the Balearic Islands. The paper compares three line-type cases; this model has one.`, "PowerVision paper, Table 3");
  }

  // Table 4: traded volume per stage, model vs real Spain, GWh/day (one side: what is sold)
  function renderTraded(r) {
    const host = $("pv-traded");
    if (!host) return;
    const n0 = x => Number(x).toLocaleString("en-GB");
    const E = k => esiosFor(r, k), nd = r.days.length;
    const add = (...as) => as[0].map((_, i) => as.reduce((s, a) => (a[i] == null ? s : s + a[i]), 0));
    const B = r.balancing;
    const cols = [
      ["IDA2", "ID2", r.traded && r.traded.ID2, E("ida2_mwh")],
      ["IDA3", "ID3", r.traded && r.traded.ID3, E("ida3_mwh")],
      ["CID", "CID", r.traded && r.traded.CID, E("cid_mwh")],
      ["BE", "BAL", B && add(B.up, B.down), window.ESIOS && add(...["afrr_up", "afrr_down", "mfrr_up", "mfrr_down", "rr_up", "rr_down"].map(E))],
    ];
    // average over the days both sides have data for that stage
    const hasDay = (a, d) => a && a.slice(d * 24, d * 24 + 24).some(x => x != null);
    const daySum = (a, d) => a.slice(d * 24, d * 24 + 24).reduce((s, x) => s + (x || 0), 0);
    const res = cols.map(([real, model, m, e]) => {
      // (only the real side's days when this package has no model volume yet)
      const days = [...Array(nd).keys()].filter(d => (!m || hasDay(m, d)) && hasDay(e, d));
      const avg = a => days.length ? days.reduce((s, d) => s + daySum(a, d), 0) / days.length / 1000 : null;
      return { real, model, n: days.length, m: m ? avg(m) : null, e: avg(e) };
    });
    const v = x => x == null ? "–" : nf(x, 1);
    host.innerHTML = `<thead><tr><th>GWh/day, one side</th>${res.map(c => `<th>${c.real}<div class="sub">model: ${c.model}</div></th>`).join("")}</tr></thead><tbody>`
      + `<tr><td>Model (this run)</td>${res.map(c => `<td>${v(c.m)}</td>`).join("")}</tr>`
      + `<tr><td>Real Spain (OMIE, REE via e·sios)</td>${res.map(c => `<td>${v(c.e)}</td>`).join("")}</tr>`
      + `<tr><td class="pv-muted-txt">Model as % of real</td>${res.map(c => `<td class="pv-muted-txt">${c.m == null || !c.e ? "–" : nf(100 * c.m / c.e, 0) + " %"}</td>`).join("")}</tr>`
      + `<tr><td class="pv-muted-txt">Days compared</td>${res.map(c => `<td class="pv-muted-txt">${n0(c.n)}</td>`).join("")}</tr></tbody>`;
    const none = !r.traded ? " This run's package has no intraday volumes yet; publish it again with the current publish_run.py." : "";
    const early = res[0].n === 0 && r.traded ? " These days are before 14 June 2024, when the European intraday auctions started, so there is no real IDA2/IDA3 volume to compare with." : "";
    $("pv-traded-cap").innerHTML = `<b>Table 4, Spanish version.</b> Average volume traded per stage over the days shown, in GWh per day, counting one side of each trade (what is sold, which equals what is bought). Model: in ID2, ID3 and CID, the sum of all position increases from the previous stage, over every plant and the consumers (a higher load forecast is a purchase); ID3 trades hours 12–23 only. In BE, what the balancing plants moved up plus down. Real: energy assigned in IDA2 (e·sios 606) and IDA3 (607) from 14 June 2024, and in the continuous market (1442), all from OMIE; BE is REE's activated aFRR, mFRR and RR, up plus down. Each column averages only over days with data on both sides.${early}${none} <span class="pv-ref">PowerVision paper, Table 4 (which counts buy + sell, twice our numbers)</span>`;
  }

  // ---------- flexibility value: daily storage arbitrage on model vs real day-ahead prices ----------
  // One unit with 1 MW charging power and room for `h` hours of charging; each MWh stored gives back
  // `eff` MWh when discharged (discharge power = eff MW). Every day starts and ends empty, and the
  // best plan is found exactly by dynamic programming over the hours and the (whole-MWh) state of
  // charge: with integer power and size the LP optimum is integral, so nothing is lost by that.
  const FLEX_ASSETS = {
    // TES: 42 % round trip and 8 h as PNNL 2022's molten salt + single steam cycle (Lundy 2020); 824 MW of
    // heaters give 0.42 × 824 = 346 MW out, the size of Soto de Ribera 3
    tes: { name: "Soto de Ribera TES", h: 8, eff: 42, mw: 824, note: "electric heater into a molten-salt tank, back out through the existing steam cycle; 42 % round trip and 8 h as in PNNL's 2022 cost report for molten salt with a steam cycle; 824 MW of heaters give 346 MW out, the size of Soto de Ribera 3" },
    battery: { name: "Battery", h: 4, eff: 88, mw: 100, note: "a 4-hour lithium-ion battery, for comparison" },
  };
  // "flex2": defaults changed on 2026-10-19 (sourced TES), so settings saved under the old key are not reused
  try { const sv = JSON.parse(localStorage.getItem("runviewer.flex2") || "null"); if (sv && FLEX_ASSETS[sv.asset]) { state.flexAsset = sv.asset; for (const k in FLEX_ASSETS) if (sv[k]) Object.assign(FLEX_ASSETS[k], { h: +sv[k].h || FLEX_ASSETS[k].h, eff: +sv[k].eff || FLEX_ASSETS[k].eff, mw: +sv[k].mw || FLEX_ASSETS[k].mw }); } } catch (e) {}
  state.flexAsset = state.flexAsset || "tes";
  state.flexMW = FLEX_ASSETS[state.flexAsset].mw;   // charging power of the unit picked (MW); per-MW figures do not depend on it
  function saveFlex() { try { localStorage.setItem("runviewer.flex2", JSON.stringify({ asset: state.flexAsset, tes: FLEX_ASSETS.tes, battery: FLEX_ASSETS.battery })); } catch (e) {} }
  function pickFlexAsset(v) { state.flexAsset = v; state.flexMW = FLEX_ASSETS[v].mw; saveFlex(); }
  // money always in whole euros: 19,150,000 €
  const eurS = x => x == null || !isFinite(x) ? "–" : `${nf(x, 0)} €`;
  // the unit's size in words: TES heat in vs electricity out, battery the same MW both ways
  const sizeText = (a, MW) => state.flexAsset === "tes"
    ? `${nf(MW, 0)} MW in (heater) → ${nf(MW * a.eff / 100, 0)} MW out (turbine), tank holds ${nf(MW * a.h, 0)} MWh of heat`
    : `${nf(MW, 0)} MW in and out, holds ${nf(MW * a.h, 0)} MWh`;
  function arbitrageDay(p, h, eff) {
    // V[t][s]: best earnings from hour t on with s MWh stored; must end at 0
    const T = p.length, NEG = -1e18;
    const V = Array.from({ length: T + 1 }, () => new Float64Array(h + 1).fill(NEG));
    const A = Array.from({ length: T }, () => new Int8Array(h + 1));
    V[T][0] = 0;
    for (let t = T - 1; t >= 0; t--) for (let s = 0; s <= h; s++) {
      let best = V[t + 1][s], act = 0;                               // idle
      if (p[t] != null) {
        if (s < h && V[t + 1][s + 1] - p[t] > best + 1e-9) { best = V[t + 1][s + 1] - p[t]; act = 1; }         // charge 1 MWh
        if (s > 0 && V[t + 1][s - 1] + eff * p[t] > best + 1e-9) { best = V[t + 1][s - 1] + eff * p[t]; act = -1; } // discharge
      }
      V[t][s] = best; A[t][s] = act;
    }
    const act = []; let s = 0;
    for (let t = 0; t < T; t++) { act.push(A[t][s]); s += A[t][s]; }
    return { value: V[0][0], act };
  }
  function flexStats(prices, nd, h, eff) {
    const days = [], acts = [], chg = new Array(24).fill(0), dis = new Array(24).fill(0);
    for (let d = 0; d < nd; d++) {
      const p = prices.slice(d * 24, d * 24 + 24).map(x => x == null || Number.isNaN(x) ? null : x);
      const ok = p.filter(x => x != null);
      const { value, act } = arbitrageDay(p, h, eff);
      acts.push(...act);
      let buyMWh = 0, buyEur = 0, sellMWh = 0, sellEur = 0;
      act.forEach((a, k) => {
        if (a === 1) { chg[k]++; buyMWh += 1; buyEur += p[k]; }
        else if (a === -1) { dis[k]++; sellMWh += eff; sellEur += eff * p[k]; }
      });
      days.push({ value, spread: ok.length ? Math.max(...ok) - Math.min(...ok) : null, runs: value > 0.005, buyMWh, buyEur, sellMWh, sellEur });
    }
    return { days, acts, chg: chg.map(c => c / nd), dis: dis.map(c => c / nd) };
  }
  // How the unit decides, on one made-up day with a typical solar-shaped price: the same
  // calculation as for the run (arbitrageDay), with the unit's size and efficiency.
  const FLEX_EXAMPLE_DAY = [62, 58, 55, 53, 54, 60, 72, 85, 80, 62, 40, 22, 12, 8, 6, 9, 18, 40, 75, 98, 112, 108, 90, 72];
  function renderFlexExplain(a) {
    const p = FLEX_EXAMPLE_DAY, eff = a.eff / 100, { value, act } = arbitrageDay(p, a.h, eff);
    const W = 520, l = 44, pw = W - l - 10, bw = pw / 24, top = 26, ph = 130, lvlTop = top + ph + 50, lh = 54, H = lvlTop + lh + 10;
    const yP = v => top + ph - v / 120 * ph;
    let g = `<svg viewBox="0 0 ${W} ${H}" class="flex-ex" role="img" aria-label="Example day: the unit charges in the cheapest hours and discharges in the most expensive ones">
      <text x="${l}" y="14" class="fx-h">Made-up example day: price per hour (€/MWh)</text>`;
    for (const v of [0, 40, 80, 120]) g += `<line x1="${l}" x2="${l + pw}" y1="${yP(v)}" y2="${yP(v)}" class="fp-grid"/><text x="${l - 5}" y="${yP(v) + 3}" text-anchor="end" class="fp-ax">${v}</text>`;
    let s = 0; const lvl = [];
    act.forEach((x, k) => {
      const cls = x === 1 ? "fp-chg" : x === -1 ? "fp-dis" : "fx-idle";
      g += `<rect x="${l + k * bw + 1.5}" y="${yP(p[k])}" width="${bw - 3}" height="${yP(0) - yP(p[k])}" rx="2" class="${cls}"><title>${hh(k)}: ${p[k]} €/MWh, ${x === 1 ? "charges" : x === -1 ? "discharges" : "waits"}</title></rect>`;
      s += x; lvl.push(s);
      if (k % 3 === 0) g += `<text x="${l + k * bw + bw / 2}" y="${top + ph + 14}" text-anchor="middle" class="fp-ax">${hh(k)}</text>`;
    });
    // stored energy through the day
    const yL = v => lvlTop + lh - v / a.h * lh;
    let d = `M${l},${yL(0)}`;
    lvl.forEach((v, k) => { d += `L${l + k * bw},${yL(v)}L${l + (k + 1) * bw},${yL(v)}`; });
    d += `L${l + pw},${yL(0)}Z`;
    g += `<text x="${l}" y="${lvlTop - 8}" class="fx-h">Stored energy</text>
      <line x1="${l}" x2="${l + pw}" y1="${yL(0)}" y2="${yL(0)}" class="fp-axis"/><line x1="${l}" x2="${l + pw}" y1="${yL(a.h)}" y2="${yL(a.h)}" class="fp-grid"/>
      <text x="${l - 5}" y="${yL(a.h) + 3}" text-anchor="end" class="fp-ax">full</text><text x="${l - 5}" y="${yL(0) + 3}" text-anchor="end" class="fp-ax">empty</text>
      <path d="${d}" class="fx-lvl"/></svg>`;
    const buys = act.map((x, k) => x === 1 ? p[k] : null).filter(x => x != null), sells = act.map((x, k) => x === -1 ? p[k] : null).filter(x => x != null);
    const mean = v => v.reduce((x, y) => x + y, 0) / v.length;
    const res = buys.length
      ? `Example day: buys at about <b>${nf(mean(buys), 0)}</b>, sells at about <b>${nf(mean(sells), 0)} €/MWh</b> → trading margin <b>${nf(value, 0)} € per MW</b>.`
      : `Example day: nothing pays, so it waits.`;
    $("flex-explain").innerHTML = `${g}
      <div class="fx-text">
        <ol>
          <li><b>Buys</b> <i class="sw-box" style="background:var(--buy)"></i> in the day's cheapest hours and <b>sells</b> <i class="sw-box" style="background:var(--sell)"></i> in the most expensive.</li>
          <li><b>Only if it pays:</b> 1 MWh in gives ${nf(eff, 2)} MWh back, so it sells only at <b>${nf(100 / a.eff, 2)} ×</b> the buying price or more.</li>
          <li><b>Empty</b> at the start and end of every day; holds up to ${a.h} hours of charging.</li>
        </ol>
        <p>${res}</p>
      </div>`;
  }
  // Storage size and round-trip efficiency, drawn for the unit picked
  function renderFlexTerms(a) {
    const eff = a.eff / 100, MW = state.flexMW, tes = state.flexAsset === "tes";
    // storage size: one block per hour of charging at 1 MW
    const W1 = 480, bw = Math.min(40, 400 / a.h), x0 = 20, y0 = 34, bh = 46;
    let s1 = `<svg viewBox="0 0 ${W1} 150" class="flex-ex" role="img" aria-label="Storage size: ${a.h} hours of charging at 1 MW is ${a.h} MWh">
      <text x="${x0}" y="16" class="fx-h">Storage size: ${a.h} hours of charging</text>
      <rect x="${x0 - 3}" y="${y0 - 3}" width="${a.h * bw + 6}" height="${bh + 6}" rx="6" class="fx-tank"/>`;
    for (let k = 0; k < a.h; k++) s1 += `<rect x="${x0 + k * bw + 1.5}" y="${y0}" width="${bw - 3}" height="${bh}" rx="3" class="fp-chg"/>`
      + (bw >= 28 ? `<text x="${x0 + k * bw + bw / 2}" y="${y0 + bh / 2 + 4}" text-anchor="middle" class="fx-in">${k + 1} h</text>` : "");
    s1 += `<text x="${x0}" y="${y0 + bh + 26}" class="fx-t">Charging 1 MW for ${a.h} hours fills it: <tspan class="fx-b">${a.h} MWh per MW</tspan>.</text>
      <text x="${x0}" y="${y0 + bh + 46}" class="fx-t">${tes ? `${nf(MW, 0)} MW of heaters store ${nf(a.h * MW, 0)} MWh of heat = ${a.h} h at ${nf(MW * eff, 0)} MW out.` : `A ${nf(MW, 0)} MW battery stores ${nf(a.h * MW, 0)} MWh.`}</text></svg>`;
    // round-trip efficiency: 1 MWh in, eff back out, the rest lost
    const W2 = 480, L = 20, BW = 400, y1 = 40, y2 = 104, hb = 26;
    const s2 = `<svg viewBox="0 0 ${W2} 150" class="flex-ex" role="img" aria-label="Round-trip efficiency: 1 MWh bought gives ${nf(eff, 2)} MWh back">
      <text x="${L}" y="16" class="fx-h">Round-trip efficiency: ${a.eff} %</text>
      <rect x="${L}" y="${y1}" width="${BW}" height="${hb}" rx="4" class="fp-chg"/>
      <text x="${L + 8}" y="${y1 + 17}" class="fx-in">Bought: 1 MWh</text>
      <text x="${L + BW / 2}" y="${y1 + hb + 22}" text-anchor="middle" class="fx-t">↓ ${tes ? "heater → salt tank → steam turbine" : "into the battery and back out"} ↓</text>
      <rect x="${L}" y="${y2}" width="${BW * eff}" height="${hb}" rx="4" class="fp-dis"/>
      <rect x="${L + BW * eff + 2}" y="${y2}" width="${Math.max(0, BW * (1 - eff) - 2)}" height="${hb}" rx="4" class="fx-loss"/>
      <text x="${L + 8}" y="${y2 + 17}" class="fx-in">${BW * eff > 110 ? `Sold: ${nf(eff, 2)} MWh` : nf(eff, 2)}</text>
      ${eff < 0.97 ? `<text x="${L + BW * eff + 10}" y="${y2 + 17}" class="fx-t">${BW * (1 - eff) > 120 ? `Lost: ${nf(1 - eff, 2)} MWh${tes ? " (heat)" : ""}` : "lost"}</text>` : ""}
    </svg>`;
    // trading margin vs profit, on the made-up example day
    const ex = arbitrageDay(FLEX_EXAMPLE_DAY, a.h, eff);
    const sales = ex.act.reduce((t, x, k) => t + (x === -1 ? eff * FLEX_EXAMPLE_DAY[k] : 0), 0);
    const bought = ex.act.reduce((t, x, k) => t + (x === 1 ? FLEX_EXAMPLE_DAY[k] : 0), 0);
    const W3 = 980, X0 = 200, SW = 560, sx = v => v / Math.max(sales, 1) * SW, rh3 = 30;
    const row = (k, label, x, w, cls, val) => `<text x="${X0 - 10}" y="${34 + k * (rh3 + 8) + 20}" text-anchor="end" class="fx-t">${label}</text>`
      + `<rect x="${X0 + x}" y="${34 + k * (rh3 + 8)}" width="${Math.max(w, 2)}" height="${rh3}" rx="4" class="${cls}"/>`
      + `<text x="${X0 + x + Math.max(w, 2) + 8}" y="${34 + k * (rh3 + 8) + 20}" class="fx-t">${val}</text>`;
    const s3 = `<svg viewBox="0 0 ${W3} 210" class="flex-ex" role="img" aria-label="From sales to profit on the example day">
      <text x="20" y="16" class="fx-h">Trading margin is not profit (example day, per MW)</text>
      ${row(0, "Money from selling", 0, sx(sales), "fp-dis", `${nf(sales, 0)} €`)}
      ${row(1, "− electricity bought", sx(sales - bought), sx(bought), "fp-chg", `−${nf(bought, 0)} €`)}
      ${row(2, "= trading margin", 0, sx(sales - bought), "fx-margin", `<tspan class="fx-b">${nf(sales - bought, 0)} €</tspan>  ← what this tab shows`)}
      ${row(3, "− other costs", 0, sx(sales - bought), "fx-unknown", "investment, staff, maintenance, wear, grid charges: not included")}
      <text x="${X0 - 10}" y="${34 + 4 * (rh3 + 8) + 14}" text-anchor="end" class="fx-t">= profit</text>
      <text x="${X0}" y="${34 + 4 * (rh3 + 8) + 14}" class="fx-t">unknown here: the margin minus the other costs</text>
    </svg>`;
    $("flex-terms").innerHTML = `<div>${s1}</div><div>${s2}<p class="fx-note">So selling must pay at least <b>${nf(100 / a.eff, 2)} ×</b> the buying price just to break even.</p></div><div class="fx-wide">${s3}</div>`;
  }
  // ---------- investment check (NPV) on top of the trading margin ----------
  // TES costs from PNNL's 2022 storage cost report (PNNL-33283, 2021 dollars, × 0.924 €/$ = ECB 2024 average),
  // molten salt with a single steam cycle (Lundy 2020), the turbine not bought since it exists:
  //   heater   $114/kW direct (Capp 2021) × 1.3 (EPC 10 % + project development 20 %)          → 137 €/kW
  //   tank     storage block + balance of system 58–104 $/kWh_e, mid 81, × 1.3, × 0.42 to heat → 41 €/kWh
  //   fixed O&M 2 % of direct capital per year, counted on heater + tank + a new steam block of the
  //            same size (mid 1,338 $/kW_e), since the old turbine must also be kept running     → 18 €/kW·yr
  //   all O&M is fixed in PNNL → variable 0; real WACC 6.52 % → 6.5; calendar life 35 years
  // Not included: refurbishing the 1980s turbine (fixed sum 0, open). Check: Project Alba (AES Andes, Chile,
  // 560 MW coal → molten salt, US$450 M, 2022) is about 2/3 of this per kW out. Battery: still placeholders.
  const INV_DEFAULT = {
    tes: { capKW: 137, capKWh: 41, capFix: 0, opexKW: 18, opexMWh: 0, rate: 6.5, life: 35, growth: 0 },
    battery: { capKW: 150, capKWh: 200, capFix: 0, opexKW: 8, opexMWh: 0, rate: 7, life: 15, growth: 0 },
  };
  const INV = JSON.parse(JSON.stringify(INV_DEFAULT));
  // "inv3": defaults changed on 2026-10-19 (sourced TES; fixed sum in € instead of M€), so costs saved under older keys are not reused
  try { const sv = JSON.parse(localStorage.getItem("runviewer.inv3") || "null"); if (sv) for (const k in INV) Object.assign(INV[k], sv[k] || {}); } catch (e) {}
  const saveInv = () => { try { localStorage.setItem("runviewer.inv3", JSON.stringify(INV)); } catch (e) {} };
  function renderFlexNPV(a, M, nd, MW) {
    const key = state.flexAsset, c = INV[key];
    const kW = MW * 1000, kWh = MW * a.h * 1000;
    const capex = kW * c.capKW + kWh * c.capKWh + c.capFix;
    const margin = M.days.reduce((t, d) => t + d.value, 0) * MW * 365 / nd;        // €/yr, year 1
    const sold = M.days.reduce((t, d) => t + d.sellMWh, 0) * MW * 365 / nd;        // MWh/yr
    const r = c.rate / 100, L = Math.max(1, Math.round(c.life)), g = c.growth / 100;
    const cash = Array.from({ length: L }, (_, t) => margin * (1 + g) ** t - c.opexKW * kW - c.opexMWh * sold);
    const pv = rr => cash.reduce((s, x, t) => s + x / (1 + rr) ** (t + 1), 0);
    const npv = pv(r) - capex;
    const payback = disc => {   // years until the cumulative cash covers the CAPEX (fraction of a year by interpolation)
      let cum = -capex;
      for (let t = 0; t < L; t++) { const x = disc ? cash[t] / (1 + r) ** (t + 1) : cash[t]; if (cum + x >= 0 && x > 0) return t + (-cum) / x; cum += x; }
      return null;
    };
    let irr = null;
    if (pv(-0.99) - capex > 0 && pv(1) - capex < 0) { let lo = -0.99, hi = 1; for (let k = 0; k < 80; k++) { const mid = (lo + hi) / 2; if (pv(mid) - capex > 0) lo = mid; else hi = mid; } irr = (lo + hi) / 2; }
    const breakEven = pv(r);
    const Meur = x => x == null ? "–" : nf(x, 0);   // whole euros
    const yrs = x => x == null ? `never within ${L} years` : `${nf(x, 1)} years`;

    // inputs in three columns: what it costs to build, what it costs to run, money over time
    const tesU = key === "tes";
    const inp = (k, st) => `<input type="number" data-k="${k}" step="${st}" value="${c[k]}">`;
    const item = (k, st, unit, name, what, total) => `<div class="npv-item"><div class="npv-row"><b>${name}</b><span>${inp(k, st)} ${unit}</span></div>
      <div class="npv-what">${what}</div>${total ? `<div class="npv-tot">${total}</div>` : ""}</div>`;
    $("npv-inputs").innerHTML = `
      <div class="npv-col"><h5><span class="npv-dot capex"></span>CAPEX: paid once, to build it</h5>
        ${item("capKW", 10, tesU ? "€ per kW of heater" : "€ per kW", tesU ? "Heater" : "Power electronics", tesU ? `The electric heater that turns electricity into heat. ${nf(c.capKW, 0)} € per kW = ${nf(c.capKW * 1e3, 0)} € per MW.` : `The inverter and grid connection. ${nf(c.capKW, 0)} € per kW = ${nf(c.capKW * 1e3, 0)} € per MW.`, `${nf(MW, 0)} MW × ${nf(c.capKW * 1e3, 0)} € = ${eurS(kW * c.capKW)}`)}
        ${item("capKWh", 1, tesU ? "€ per kWh of heat" : "€ per kWh", tesU ? "Salt tank" : "Battery cells", tesU ? `The tanks of molten salt that hold the heat. ${nf(c.capKWh, 0)} € per kWh = ${nf(c.capKWh * 1e3, 0)} € per MWh.` : `The cells that hold the energy. ${nf(c.capKWh, 0)} € per kWh = ${nf(c.capKWh * 1e3, 0)} € per MWh.`, `${nf(MW * a.h, 0)} MWh × ${nf(c.capKWh * 1e3, 0)} € = ${eurS(kWh * c.capKWh)}`)}
        ${item("capFix", 100000, "€", "Fixed sum", tesU ? "One-off costs that do not depend on size: adapting the existing steam turbine, connecting the tank, planning." : "One-off costs that do not depend on size: planning, permits, site work.", "")}
        <div class="npv-sum">Total CAPEX <b>${eurS(capex)}</b>${tesU ? ` = ${nf(capex / (kW * a.eff / 100), 0)} € per kW out` : ""}</div></div>
      <div class="npv-col"><h5><span class="npv-dot opex"></span>OPEX: paid every year, to run it</h5>
        ${item("opexKW", 1, tesU ? "€ per kW of heater, per year" : "€ per kW, per year", "Fixed", "Staff, maintenance, insurance. Paid every year, even if the plant never runs.", `${nf(MW, 0)} MW × ${nf(c.opexKW * 1e3, 0)} € = ${eurS(c.opexKW * kW)} per year`)}
        ${item("opexMWh", 0.5, "€ per MWh sold", "Variable", tesU ? "Wear and starting the steam turbine. Paid for each MWh it sells, so only when it runs." : "Wear on the cells. Paid for each MWh it sells, so only when it runs.", `${nf(sold, 0)} MWh sold per year → ${eurS(c.opexMWh * sold)} per year`)}
        <div class="npv-sum">Total OPEX <b>${eurS(c.opexKW * kW + c.opexMWh * sold)}</b> per year</div></div>
      <div class="npv-col"><h5><span class="npv-dot time"></span>Money over time</h5>
        ${item("rate", 0.5, "% per year", "Discount rate", `Money later is worth less than money now. At ${c.rate} %, 100 € in a year is worth ${nf(100 / (1 + c.rate / 100), 0)} € today.`, "")}
        ${item("life", 1, "years", "Lifetime", "How many years the plant runs and earns.", "")}
        ${item("growth", 0.5, "% per year", "Margin change", "Lets the trading margin grow (or shrink) each year. 0 = every year like this run's year.", "")}
        <button type="button" class="npv-reset" id="npv-reset">Reset to defaults</button></div>`;
    $("npv-inputs").querySelectorAll("input").forEach(el => el.addEventListener("change", () => {
      const v = +el.value; if (Number.isFinite(v)) { c[el.dataset.k] = v; saveInv(); renderFlexNPV(a, M, nd, MW); }
    }));
    $("npv-reset").onclick = () => { INV[key] = { ...INV_DEFAULT[key] }; saveInv(); renderFlexNPV(a, M, nd, MW); };

    // the plant, with what each part costs: CAPEX on the parts, OPEX on the running plant
    const parts = tesU
      ? [["Grid", "buys electricity", null], ["Heater", `${nf(MW, 0)} MW in`, eurS(kW * c.capKW)], ["Salt tank", `${nf(MW * a.h, 0)} MWh of heat`, eurS(kWh * c.capKWh)], ["Steam turbine", `existing, ${nf(MW * a.eff / 100, 0)} MW out`, eurS(c.capFix)], ["Grid", "sells electricity", null]]
      : [["Grid", "buys electricity", null], ["Inverter", `${nf(MW, 0)} MW`, eurS(kW * c.capKW)], ["Battery cells", `${nf(MW * a.h, 0)} MWh`, eurS(kWh * c.capKWh)], ["Inverter", "same one, back out", c.capFix ? `${eurS(c.capFix)} other` : null], ["Grid", "sells electricity", null]];
    const PW = 980, pbw = 150, pgap = (PW - 40 - 5 * pbw) / 4, pbx = k => 20 + k * (pbw + pgap);
    let pl = `<svg viewBox="0 0 ${PW} 200" class="npv-plant" role="img" aria-label="The plant and what each part costs">
      <defs><marker id="npv-head" viewBox="0 0 10 10" refX="9" refY="5" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="9" orient="auto"><path d="M0,0 L10,5 L0,10 z" class="np-hd"/></marker></defs>`;
    parts.forEach(([n, sub, cost], k) => {
      const grid = n === "Grid";
      pl += `<rect x="${pbx(k)}" y="20" width="${pbw}" height="58" rx="8" class="${grid ? "np-grid" : "np-part"}"/>
        <text x="${pbx(k) + pbw / 2}" y="44" text-anchor="middle" class="np-n">${n}</text><text x="${pbx(k) + pbw / 2}" y="63" text-anchor="middle" class="np-s">${sub}</text>`;
      if (cost) pl += `<text x="${pbx(k) + pbw / 2}" y="100" text-anchor="middle" class="np-cap">CAPEX ${cost}</text>`;
      if (k < 4) pl += `<line x1="${pbx(k) + pbw + 4}" y1="49" x2="${pbx(k + 1) - 4}" y2="49" class="np-ar" marker-end="url(#npv-head)"/>`;
    });
    const ox = pbx(1), ow = pbx(3) + pbw - pbx(1);
    pl += `<rect x="${ox}" y="122" width="${ow}" height="54" rx="8" class="np-opex"/>
      <text x="${ox + ow / 2}" y="144" text-anchor="middle" class="np-n">OPEX every year: ${eurS(c.opexKW * kW + c.opexMWh * sold)}</text>
      <text x="${ox + ow / 2}" y="164" text-anchor="middle" class="np-s">fixed ${eurS(c.opexKW * kW)} (staff, maintenance) + variable ${eurS(c.opexMWh * sold)} (wear, per MWh sold)</text>
      <text x="${pbx(0) + pbw / 2}" y="100" text-anchor="middle" class="np-s">pays the buying price</text>
      <text x="${pbx(4) + pbw / 2}" y="100" text-anchor="middle" class="np-s">gets the selling price</text></svg>`;
    $("npv-plant").innerHTML = pl;

    const tiles = [
      ["NPV", `${Meur(npv)}<small>€</small>`, npv >= 0 ? `${icon("good")} pays off at ${c.rate} %` : `does not pay off at ${c.rate} %`],
      ["Payback", payback(false) == null ? `<span class="npv-never">never</span>` : `${nf(payback(false), 1)}<small>years</small>`, `with discounting: ${yrs(payback(true))}`],
      ["IRR", irr == null ? "–" : `${nf(100 * irr, 1)}<small>%</small>`, irr == null ? "no rate makes it pay" : `return per year; compare with ${c.rate} %`],
      ["Break-even CAPEX", breakEven > 0 ? `${Meur(breakEven)}<small>€</small>` : "0", breakEven > 0 ? `the most it may cost (now ${Meur(capex)} €)` : "running costs eat the whole margin"],
    ];
    $("npv-kpis").innerHTML = tiles.map(([l, v, s]) => `<div class="kpi"><span class="k-label">${l}</span><span class="k-value">${v}</span><span class="k-sub">${s}</span></div>`).join("");
    // when every year loses money, no CAPEX can pay off: say so plainly
    const runCost = c.opexKW * kW + c.opexMWh * sold;
    const warn = cash[0] <= 0
      ? `<span class="npv-warn"><b>It loses money every year</b>: the running costs (${Meur(runCost)} € per year) are bigger than the trading margin (${Meur(margin)} € per year), so it can never pay off, whatever it costs to build. It needs a bigger trading margin (prices that swing more, or another unit) or lower OPEX: fixed OPEX would have to be below ${nf(Math.max(0, margin - c.opexMWh * sold) / kW, 2)} € per kW per year just to break even each year.</span><br>`
      : "";
    $("npv-cash").innerHTML = warn + `CAPEX <b>${Meur(capex)} €</b> (${nf(MW, 0)} MW × ${c.capKW} €/kW + ${nf(MW * a.h, 0)} MWh × ${c.capKWh} €/kWh + ${nf(c.capFix, 0)} €) ·
      year 1: trading margin <b>${Meur(margin)} €</b> − fixed OPEX ${Meur(c.opexKW * kW)} € − variable OPEX ${Meur(c.opexMWh * sold)} € = <b>${Meur(cash[0])} €</b> cash`;

    // cumulative discounted cash, year 0 (the investment) to the end of the lifetime
    const cum = [-capex]; cash.forEach((x, t) => cum.push(cum[t] + x / (1 + r) ** (t + 1)));
    const W = 900, H = 270, l = 104, b = 26, t0 = 26, pw = W - l - 10, ph = H - t0 - b;
    const lo = Math.min(0, ...cum), hi = Math.max(0, ...cum), span = hi - lo || 1;
    const y = v => t0 + (hi - v) / span * ph, bw = pw / cum.length;
    let s = `<svg viewBox="0 0 ${W} ${H}" class="npv-chart" role="img" aria-label="Cumulative discounted cash flow over the lifetime">`;
    for (const v of niceTicks(lo, hi, 4)) if (v >= lo - 1e-6 && v <= hi + 1e-6) s += `<line x1="${l}" x2="${l + pw}" y1="${y(v)}" y2="${y(v)}" class="fp-grid"/><text x="${l - 6}" y="${y(v) + 4}" text-anchor="end" class="fp-ax">${nf(v, 0)}</text>`;
    s += `<text x="0" y="14" class="y-unit">€ (discounted)</text>`;
    cum.forEach((v, k) => {
      const x = l + k * bw + 2, w = Math.max(2, bw - 4);
      s += `<rect x="${x}" y="${Math.min(y(v), y(0))}" width="${w}" height="${Math.max(1, Math.abs(y(v) - y(0)))}" rx="2" class="${v >= 0 ? "npv-pos" : "npv-neg"}"><title>Year ${k}: ${nf(v, 0)} € so far (discounted)</title></rect>`;
      if (k % Math.ceil(cum.length / 13) === 0 || k === cum.length - 1) s += `<text x="${x + w / 2}" y="${H - 8}" text-anchor="middle" class="fp-ax">${k}</text>`;
    });
    s += `<line x1="${l}" x2="${l + pw}" y1="${y(0)}" y2="${y(0)}" class="fp-axis"/>`;
    const pb = payback(true);
    if (pb != null) { const xp = l + (pb + 0.5) * bw; s += `<line x1="${xp}" x2="${xp}" y1="${t0}" y2="${t0 + ph}" class="npv-pb"/><text x="${xp + 4}" y="${t0 + 10}" class="fp-ax">paid back after ${nf(pb, 1)} years</text>`; }
    $("npv-chart").innerHTML = s + `<text x="${l + pw}" y="${H - 8}" text-anchor="end" class="fp-ax">year</text></svg>`;
  }

  // Which prices the storage unit trades on: the run's model DA price, or OMIE's real day-ahead price
  // for the same days. Shared by the Trading margin and Investment case tabs.
  state.flexPrice = "model";
  try { const fp = localStorage.getItem("runviewer.flexPrice"); if (fp === "model" || fp === "real") state.flexPrice = fp; } catch (e) {}
  const FLEX_PRICE = { model: ["Model prices", "the model's day-ahead price", "Model DA price"], real: ["Real prices", "OMIE's real day-ahead price", "Real DA price (OMIE)"] };
  const flexPrices = r => state.flexPrice === "real" ? r.real_price : r.price.DA;
  function flexPriceSeg(id, redraw) {
    seg($(id), [["model", "Model prices"], ["real", "Real prices (OMIE)"]], state.flexPrice, v => {
      state.flexPrice = v; try { localStorage.setItem("runviewer.flexPrice", v); } catch (e) {} redraw(); });
  }
  // Investment case tab: the same unit and trading margin as the Trading margin tab, then CAPEX/OPEX
  function renderInvest(r) {
    if ($("sec-invest").hidden) return;
    const a = FLEX_ASSETS[state.flexAsset], nd = r.days.length, MW = state.flexMW;
    seg($("invest-asset"), Object.entries(FLEX_ASSETS).map(([k, v]) => [k, v.name]), state.flexAsset, v => { pickFlexAsset(v); renderInvest(view()); });
    flexPriceSeg("invest-prices", () => renderInvest(view()));
    const M = flexStats(flexPrices(r), nd, a.h, a.eff / 100);
    const margin = M.days.reduce((t, d) => t + d.value, 0) * MW * 365 / nd;
    $("invest-unit").innerHTML = `<b>${esc(a.name)}</b>: ${sizeText(a, MW)} (${a.h} h), ${a.eff} % round trip ·
      trading margin <b>${eurS(margin)} per year</b> on ${FLEX_PRICE[state.flexPrice][1]}${nd < 360 ? ` (scaled up from ${nd} days)` : ""} ·
      <button type="button" class="invest-link" id="invest-link">change size or efficiency on the Trading margin tab</button>`;
    $("invest-link").onclick = () => pickTab("flex");
    renderFlexNPV(a, M, nd, MW);
  }
  function renderFlex(r) {
    if ($("sec-flex").hidden) return;
    const a = FLEX_ASSETS[state.flexAsset];
    seg($("flex-asset"), Object.entries(FLEX_ASSETS).map(([k, v]) => [k, v.name]), state.flexAsset, v => { pickFlexAsset(v); renderFlex(view()); });
    $("flex-params").innerHTML = `<label>Plant size <input type="number" id="flex-mw" min="1" max="5000" step="10" value="${state.flexMW}"> MW ${state.flexAsset === "tes" ? "of heaters (power in)" : "(power in and out)"}</label>
      <label>Storage size <input type="number" id="flex-h" min="1" max="24" step="1" value="${a.h}"> hours of charging</label>
      <span class="flex-energy" id="flex-energy"></span>
      <label>Round-trip efficiency <input type="number" id="flex-eff" min="5" max="100" step="1" value="${a.eff}"> %</label>
      <span class="fineprint">${esc(a.note)}.</span>`;
    const upd = () => { a.h = Math.max(1, Math.min(24, Math.round(+$("flex-h").value || a.h))); a.eff = Math.max(5, Math.min(100, +$("flex-eff").value || a.eff)); state.flexMW = a.mw = Math.max(1, Math.min(5000, +$("flex-mw").value || state.flexMW)); saveFlex(); renderFlex(view()); };
    $("flex-h").addEventListener("change", upd); $("flex-eff").addEventListener("change", upd); $("flex-mw").addEventListener("change", upd);
    // energy it can hold = plant size × hours, updated while typing
    const showEnergy = () => { const mw = +$("flex-mw").value || 0, hrs = +$("flex-h").value || 0;
      const ef = (+$("flex-eff").value || a.eff) / 100, tes = state.flexAsset === "tes";
      $("flex-energy").innerHTML = `= holds <b>${nf(mw * hrs, 0)} MWh${tes ? " of heat" : ""}</b> <span class="fe-sub">(${nf(mw, 0)} MW × ${nf(hrs, 0)} h)${tes ? ` · gives ${nf(mw * ef, 0)} MW out` : ""}</span>`; };
    $("flex-mw").addEventListener("input", showEnergy); $("flex-h").addEventListener("input", showEnergy); $("flex-eff").addEventListener("input", showEnergy); showEnergy();

    renderFlexExplain(a);
    renderFlexTerms(a);
    const nd = r.days.length, eff = a.eff / 100, MW = state.flexMW;
    flexPriceSeg("flex-prices", () => renderFlex(view()));
    const P = flexPrices(r), PL = FLEX_PRICE[state.flexPrice];
    $("flex-price-h").textContent = `${state.flexPrice === "real" ? "Real" : "Model"} price and when the unit trades`;
    const M = flexStats(P, nd, a.h, eff);
    const tot = (idx, k) => idx.reduce((t, i) => t + M.days[i][k], 0);
    const all = r.days.map((_, i) => i);
    const eur = x => x == null || !isFinite(x) ? "–" : Math.round(x).toLocaleString("en-GB");
    const avg = (idx, eurK, mwhK) => { const m = tot(idx, mwhK); return m > 0 ? tot(idx, eurK) / m : null; };
    const meanSpread = idx => { const v = idx.map(i => M.days[i].spread).filter(x => x != null); return v.length ? v.reduce((x, y) => x + y, 0) / v.length : null; };
    const sum = tot(all, "value"), nRun = M.days.filter(d => d.runs).length;
    const buy = avg(all, "buyEur", "buyMWh"), sell = avg(all, "sellEur", "sellMWh");
    const tiles = [
      [term("Trading margin per year", "f_margin"), `${eurS(sum * MW * 365 / nd).replace(/ €$/, "<small>€ per year</small>")}`, `sales − electricity bought, before all other costs · ${nf(MW, 0)} MW in · ${eur(sum * 365 / nd)} € per MW per year${nd < 360 ? ` · scaled up from ${nd} days` : ""}`],
      ["Days worth running", `${nRun}<small>of ${nd}</small>`, `${nf(100 * nRun / nd, 0)} % of days earn anything`],
      ["Average buying price", `${nf(buy, 1)}<small>€/MWh</small>`, "price paid for the electricity it charges"],
      ["Average selling price", `${nf(sell, 1)}<small>€/MWh</small>`, `needs at least ${nf(100 / a.eff, 2)} × the buying price to earn`],
      ["Daily price spread", `${nf(meanSpread(all), 0)}<small>€/MWh</small>`, "highest − lowest hour, average over the days"],
    ];
    $("flex-kpis").innerHTML = tiles.map(([l, v, s]) => `<div class="kpi"><span class="k-label">${l}</span><span class="k-value">${v}</span><span class="k-sub">${s}</span></div>`).join("");
    $("flex-margin").innerHTML = `<b>Trading margin is not profit.</b> It is the money from selling minus the money paid for the electricity it bought. The investment, staff, maintenance, wear and grid charges are not subtracted; they all have to be paid out of this. See the picture at the bottom.`;

    // model price with the hours the unit trades
    $("flex-price-legend").innerHTML = `<span><i class="sw-line" style="background:${state.flexPrice === "real" ? "var(--real)" : "var(--model)"}"></i>${PL[2]}</span>
      <span><svg width="10" height="10" aria-hidden="true"><circle cx="5" cy="5" r="4" fill="var(--buy)"/></svg>Charges (buys)</span>
      <span><svg width="10" height="10" aria-hidden="true"><circle cx="5" cy="5" r="4" fill="var(--sell)"/></svg>Discharges (sells)</span>`;
    const ph = $("flex-price-chart"), idxOf = v => M.acts.reduce((o, x, i) => (x === v && o.push(i), o), []);
    lineChart(ph, {
      n: nd * 24, height: 320, label: `${PL[2]} with the hours the storage unit charges and discharges`, endLabels: false, yUnit: "€/MWh",
      onZoom: (x0, x1) => zoomFromChart(x0, x1, true),
      xTicks: dayTicks(r.days, true, ph.clientWidth - 60),
      series: [{ name: PL[2], values: P, color: state.flexPrice === "real" ? "var(--real)" : "var(--model)", width: 1.5 }],
      points: [{ idx: idxOf(1), color: "var(--buy)" }, { idx: idxOf(-1), color: "var(--sell)" }],
      tooltip: i => `<b>${dayLabel(r.days[Math.floor(i / 24)])}, ${hh(i % 24)}</b>
        <div class="row">${PL[2]}<span class="v">${nf(P[i])} €/MWh</span></div>
        <div class="row">${M.acts[i] === 1 ? "Charges (buys)" : M.acts[i] === -1 ? "Discharges (sells)" : "Waits"}</div>`,
    });

    $("flex-legend").innerHTML = `<span><i class="sw-line" style="background:var(--ink-2)"></i>Trading margin per day, ${nf(MW, 0)} MW in, in €</span>`;
    const host = $("flex-chart");
    lineChart(host, {
      n: nd, height: 300, label: "Storage trading margin per day on the model's day-ahead price", endLabels: false, yUnit: "€ per day",
      onZoom: (x0, x1) => zoomFromChart(x0, x1, false),
      xTicks: dayTicks(r.days, false, host.clientWidth - 60),
      series: [{ name: "Trading margin", values: M.days.map(d => d.value * MW), color: "var(--ink-2)", width: 2 }],
      tooltip: i => {
        const d = M.days[i];
        return `<b>${dayLabel(r.days[i])}</b>
        <div class="row">Trading margin<span class="v">${eurS(d.value * MW)} (${nf(d.value, 0)} € per MW)</span></div>
        <div class="row">Price spread<span class="v">${nf(d.spread, 0)} €/MWh</span></div>
        ${d.runs ? `<div class="row">Buys at / sells at<span class="v">${nf(d.buyEur / d.buyMWh, 0)} / ${nf(d.sellEur / d.sellMWh, 0)} €/MWh</span></div>` : `<div class="row">Not worth running</div>`}`;
      },
    });

    // charge/discharge profile by hour of day
    const W = 720, H = 220, l = 40, b = 22, t = 12, pw = W - l - 8, half = (H - t - b) / 2, mid = t + half, bw = pw / 24;
    // axis top: the smallest of 10/25/50/100 % that fits the busiest hour
    const top = [0.1, 0.25, 0.5, 1].find(v => v >= Math.max(...M.dis, ...M.chg, 0.01)) || 1, sc = half / top;
    let g = `<svg viewBox="0 0 ${W} ${H}" class="flex-prof" role="img" aria-label="Share of days the unit charges and discharges in each hour of the day">`;
    for (const v of [1, 0.5, -0.5, -1]) g += `<line x1="${l}" x2="${l + pw}" y1="${mid - v * half}" y2="${mid - v * half}" class="fp-grid"/><text x="${l - 5}" y="${mid - v * half + 3}" text-anchor="end" class="fp-ax">${nf(Math.abs(v) * top * 100, Math.abs(v) * top * 100 % 1 ? 1 : 0)} %</text>`;
    for (let k = 0; k < 24; k++) {
      const x = l + k * bw + 1.5, w = bw - 3;
      if (M.dis[k] > 0) g += `<rect x="${x}" y="${mid - M.dis[k] * sc}" width="${w}" height="${M.dis[k] * sc}" rx="2" class="fp-dis"><title>${hh(k)}: discharges on ${nf(100 * M.dis[k], 0)} % of days</title></rect>`;
      if (M.chg[k] > 0) g += `<rect x="${x}" y="${mid}" width="${w}" height="${M.chg[k] * sc}" rx="2" class="fp-chg"><title>${hh(k)}: charges on ${nf(100 * M.chg[k], 0)} % of days</title></rect>`;
      if (k % 2 === 0) g += `<text x="${x + w / 2}" y="${H - 6}" text-anchor="middle" class="fp-ax">${hh(k)}</text>`;
    }
    g += `<line x1="${l}" x2="${l + pw}" y1="${mid}" y2="${mid}" class="fp-axis"/>`
      + `<text x="${l + 6}" y="${t + 12}" class="fp-ax">discharges ↑</text><text x="${l + 6}" y="${H - b - 6}" class="fp-ax">charges ↓</text></svg>`;
    $("flex-profiles").innerHTML = `<div class="legend"><span><i class="sw-box" style="background:var(--sell)"></i>Discharges (sells)</span><span><i class="sw-box" style="background:var(--buy)"></i>Charges (buys)</span></div>${g}`;

    // per month
    const months = {};
    r.days.forEach((d, i) => { const k = d.slice(0, 7); (months[k] = months[k] || []).push(i); });
    const rowsM = Object.entries(months).map(([k, idx]) => {
      const n = idx.filter(i => M.days[i].runs).length;
      return `<tr><td>${MON[+k.slice(5) - 1]} ${k.slice(0, 4)}</td><td>${nf(meanSpread(idx), 0)}</td><td>${n} of ${idx.length}</td><td>${nf(avg(idx, "buyEur", "buyMWh"), 1)}</td><td>${nf(avg(idx, "sellEur", "sellMWh"), 1)}</td><td>${eur(tot(idx, "value") * MW)}</td></tr>`;
    }).join("");
    $("flex-table").innerHTML = `<thead><tr><th>Month</th><th>Price spread<br>€/MWh</th><th>Days worth running</th><th>Buys at<br>€/MWh</th><th>Sells at<br>€/MWh</th><th>Trading margin<br>€, ${nf(MW, 0)} MW</th></tr></thead><tbody>${rowsM}</tbody>`;
    $("flex-note").innerHTML = `How it is worked out: each day on its own, starting and ending empty; in each hour the unit charges 1 MW, discharges or waits, and the plan with the highest trading margin (discharge price × efficiency − charge price) is chosen, knowing the whole day's prices. Prices: ${PL[1]}${state.flexPrice === "real" ? " (hours without a real price, the daylight-saving hour, are skipped)" : ""}. Totals are for the plant size above (earnings grow in proportion to it); per year scales the period to 365 days. Not included: intraday and balancing markets, grid limits, wear, heat losses in the tank, start-up of the steam cycle, carrying energy over to the next day. The unit does not move the price (price-taker).`;
  }

  // ---------- compare: the run you are viewing (A) next to a second run (B) ----------
  // Only the days both runs have (and the days shown in the period bar) are compared.
  // B is loaded the first time it is picked, like any run.
  const FEAT_LABEL = { chain: ["Market stage order", v => v === "day" ? "day by day" : "stage by stage"], res: ["Solar/wind", v => v],
    xb: ["Cross-border split", v => v ? "on" : "off"], gas: ["Gas and coal", v => v ? "on" : "off"],
    markup: ["Tax and mark-ups", v => v ? "on" : "off"], hydro: ["Improved hydro planning", v => v ? "on" : "off"] };
  state.cmpRes = "day";
  function defaultB(a) {
    const others = MANIFEST.filter(m => m.id !== a.id && m.last_day >= a.first_day && m.first_day <= a.last_day);
    // the twin (same run with the other solar/wind input), else the run published just before
    const twin = others.find(m => m.id === a.id.replace(/-offered$/, "") || m.id === a.id + "-offered");
    return (twin || others[0] || {}).id || null;
  }
  function renderCompare(v) {
    if ($("sec-compare").hidden) return;
    const A = run(), aMeta = A.meta || {};
    const options = MANIFEST.filter(m => m.id !== A.id && m.last_day >= v.days[0] && m.first_day <= v.days[v.days.length - 1]);
    if (!options.some(m => m.id === state.cmpB)) state.cmpB = defaultB(aMeta.id ? aMeta : { id: A.id, first_day: A.days[0], last_day: A.days[A.days.length - 1] });
    $("cmp-pick").innerHTML = `<span class="cmp-a"><i class="sw-line" style="background:var(--model)"></i><b>A</b> ${esc(A.name)}</span>
      <label class="cmp-b"><i class="sw-line sw-dash"></i><b>B</b>
        <select id="cmp-select">${options.map(m => `<option value="${esc(m.id)}"${m.id === state.cmpB ? " selected" : ""}>${esc(m.name)} · ${period([m.first_day, m.last_day])}</option>`).join("")}</select></label>`;
    $("cmp-select").addEventListener("change", ev => { state.cmpB = ev.target.value; renderCompare(view()); });
    const body = $("cmp-body");
    if (!state.cmpB) { body.innerHTML = `<p class="fineprint">No other run shares days with this one.</p>`; return; }
    const B = D.runs.find(r => r.id === state.cmpB);
    if (!B) {
      body.innerHTML = `<p class="fineprint">Loading run B …</p>`;
      const want = state.cmpB;
      loadRun(want).then(() => { if (state.cmpB === want) renderCompare(view()); })
        .catch(e => { body.innerHTML = `<p class="fineprint">${esc(e.message)}. Is this run in your copy of runs/? Try git pull.</p>`; });
      return;
    }

    // hours both runs have, within the days shown
    const bDay = new Map(B.days.map((d, i) => [d, i]));
    const days = [], ia = [], ib = [];
    v.days.forEach((d, di) => { if (!bDay.has(d)) return; days.push(d); for (let h = 0; h < 24; h++) { ia.push(di * 24 + h); ib.push(bDay.get(d) * 24 + h); } });
    if (!days.length) { body.innerHTML = `<p class="fineprint">The two runs share no days in the period shown.</p>`; return; }
    const pick = (arr, idx) => idx.map(i => arr[i]);
    const real = pick(v.real_price, ia), pa = pick(v.price.DA, ia), pb = pick(B.price.DA, ib);
    const nd = days.length;
    const meanOf = x => { const y = x.filter(z => z != null && !Number.isNaN(z)); return y.length ? y.reduce((s, z) => s + z, 0) / y.length : null; };
    const mae = (m, idx) => meanOf(idx.map(i => m[i] != null && real[i] != null ? Math.abs(m[i] - real[i]) : null));
    const all = real.map((_, i) => i);
    const spread = p => meanOf(Array.from({ length: nd }, (_, d) => { const q = p.slice(d * 24, d * 24 + 24).filter(z => z != null); return q.length ? Math.max(...q) - Math.min(...q) : null; }));
    const solved = (st, idx) => 100 * idx.filter(i => st[i] === 1).length / idx.length;
    const twh = (r, idx, cat) => (r.mix.DA[cat] ? idx.reduce((s, i) => s + (r.mix.DA[cat][i] || 0), 0) / 1e6 : null);
    const flexYr = (p, key) => { const f = FLEX_ASSETS[key]; return flexStats(p, nd, f.h, f.eff / 100).days.reduce((s, d) => s + d.value, 0) * f.mw * 365 / nd; };

    // what differs between the two runs
    const fa = (A.meta && A.meta.features) || {}, fb = (B.meta && B.meta.features) || {};
    const diffs = Object.keys(FEAT_LABEL).filter(k => fa[k] !== undefined && fb[k] !== undefined && fa[k] !== fb[k])
      .map(k => `<li><b>${FEAT_LABEL[k][0]}</b>: A ${FEAT_LABEL[k][1](fa[k])}, B ${FEAT_LABEL[k][1](fb[k])}</li>`);
    const diffHtml = !A.meta?.features || !B.meta?.features ? `<p class="fineprint">The model changes are not recorded for one of the runs.</p>`
      : diffs.length ? `<ul class="cmp-diff">${diffs.join("")}</ul>` : `<p class="fineprint">Same model changes; they differ in code version (${esc(A.info.commit)} vs ${esc(B.info.commit)}) or settings.</p>`;

    // key numbers: [label, A, B, unit, digits, better ("low"/"high"/null), real]
    const rows = [
      ["Price error vs OMIE (MAE)", mae(pa, all), mae(pb, all), "€/MWh", 1, "low", null],
      ["Average day-ahead price", meanOf(pa), meanOf(pb), "€/MWh", 1, null, meanOf(real)],
      ["Daily price spread", spread(pa), spread(pb), "€/MWh", 1, null, spread(real)],
      ["AC hours solved", solved(v.status, ia), solved(B.status, ib), "%", 1, "high", null],
      ...D.categories.map(c => [`${c} (day-ahead)`, twh(v, ia, c), twh(B, ib, c), "TWh", 2, null, null]),
      [`TES trading margin (${FLEX_ASSETS.tes.h} h, ${FLEX_ASSETS.tes.eff} %, ${nf(FLEX_ASSETS.tes.mw, 0)} MW)`, flexYr(pa, "tes"), flexYr(pb, "tes"), "€/yr", 0, null, null],
      [`Battery trading margin (${FLEX_ASSETS.battery.h} h, ${FLEX_ASSETS.battery.eff} %, ${nf(FLEX_ASSETS.battery.mw, 0)} MW)`, flexYr(pa, "battery"), flexYr(pb, "battery"), "€/yr", 0, null, null],
    ];
    const fmt = (x, dgt) => x == null ? "–" : dgt === 0 ? Math.round(x).toLocaleString("en-GB").replace("-", "−") : nf(x, dgt);
    const tbl = `<table id="cmp-table"><thead><tr><th>Measure</th><th>Unit</th><th class="cmp-ha">A</th><th class="cmp-hb">B</th><th>B − A</th><th>Real</th></tr></thead><tbody>${rows.map(([l, a, b, u, dg, better, re]) => {
      const win = better && a != null && b != null && Math.abs(a - b) > 1e-9 ? ((better === "low") === (b < a) ? "b" : "a") : null;
      return `<tr><td>${l}</td><td class="cmp-u">${u}</td><td class="${win === "a" ? "cmp-win" : ""}">${fmt(a, dg)}</td><td class="${win === "b" ? "cmp-win" : ""}">${fmt(b, dg)}</td><td>${a == null || b == null ? "–" : (b - a > 0 ? "+" : "") + fmt(b - a, dg)}</td><td class="cmp-real">${re == null ? "" : fmt(re, dg)}</td></tr>`;
    }).join("")}</tbody></table>`;

    body.innerHTML = `
      <div class="cmp-what"><h4 class="flex-h4">What differs</h4>${diffHtml}
        <p class="fineprint">${nd} day${nd === 1 ? "" : "s"} compared (${period(days)}): the days both runs have, within the period shown above.</p></div>
      <h4 class="flex-h4">Key numbers</h4>
      <div class="table-wrap">${tbl}</div>
      <p class="fineprint">Bold = closer to reality (price error) or more hours solved. Generation is the day-ahead stage. Trading margin = sales − electricity bought, before investment and running costs, with the settings on the Trading margin tab.</p>
      <div class="cmp-head"><h4 class="flex-h4">Price</h4><div class="seg" role="group" aria-label="Time resolution" id="cmp-res"></div></div>
      <div class="chart" id="cmp-chart"></div>
      <h4 class="flex-h4">Generation: how much more or less B produces than A</h4>
      <div id="cmp-mix"></div>
      <h4 class="flex-h4">Per month</h4>
      <div class="table-wrap"><table id="cmp-month"></table></div>`;

    // price chart
    seg($("cmp-res"), [["day", "Daily mean"], ["hour", "Hourly"]], state.cmpRes, x => { state.cmpRes = x; renderCompare(view()); });
    const hourly = state.cmpRes === "hour", dm = a => hourly ? a : dailyMean(a, nd);
    const host = $("cmp-chart");
    lineChart(host, {
      n: hourly ? nd * 24 : nd, height: 340, label: "Day-ahead price, run A vs run B", endLabels: true, yUnit: "€/MWh",
      xTicks: dayTicks(days, hourly, host.clientWidth - 110),
      series: [
        { name: "Real (OMIE)", values: dm(real), color: "var(--real)", width: 2 },
        { name: "Run A", values: dm(pa), color: "var(--model)", width: 2.25 },
        { name: "Run B", values: dm(pb), color: "var(--model)", width: 2.25, dash: "7 5" },
      ],
      tooltip: i => { const a = dm(pa)[i], b = dm(pb)[i], re = dm(real)[i];
        return `<b>${hourly ? dayLabel(days[Math.floor(i / 24)]) + ", " + hh(i % 24) : dayLabel(days[i]) + " (daily mean)"}</b>
          <div class="row"><i class="sw-line" style="background:var(--model)"></i>A<span class="v">${nf(a)} €/MWh</span></div>
          <div class="row"><i class="sw-line sw-dash"></i>B<span class="v">${nf(b)} €/MWh</span></div>
          <div class="row"><i class="sw-line" style="background:var(--real)"></i>Real<span class="v">${nf(re)} €/MWh</span></div>`; },
    });

    // generation difference per technology, B − A, TWh
    const dif = D.categories.map(c => [c, (twh(B, ib, c) ?? 0) - (twh(v, ia, c) ?? 0)]);
    const mx = Math.max(0.01, ...dif.map(d => Math.abs(d[1])));
    const W = 760, lab = 120, mid = lab + (W - lab - 70) / 2, half = (W - lab - 70) / 2, rh = 26;
    let g = `<svg viewBox="0 0 ${W} ${dif.length * rh + 28}" class="cmp-bars" role="img" aria-label="Generation difference per technology, B minus A">
      <text x="${mid - half}" y="14" class="cb-ax">A produces more ←</text><text x="${mid + half}" y="14" text-anchor="end" class="cb-ax">→ B produces more</text>
      <line x1="${mid}" x2="${mid}" y1="20" y2="${dif.length * rh + 24}" class="cb-axis"/>`;
    dif.forEach(([c, d], k) => {
      const y = 24 + k * rh, w = Math.abs(d) / mx * (half - 80);   // room left for the value label
      g += `<text x="${lab - 8}" y="${y + 15}" text-anchor="end" class="cb-lab">${c}</text>
        <rect x="${d >= 0 ? mid : mid - w}" y="${y + 4}" width="${Math.max(w, 1)}" height="${rh - 8}" rx="3" fill="${d >= 0 ? "var(--cat-2)" : "var(--model)"}"><title>${c}: B ${d >= 0 ? "+" : ""}${nf(d, 2)} TWh vs A</title></rect>
        <text x="${d >= 0 ? mid + w + 6 : mid - w - 6}" y="${y + 15}" text-anchor="${d >= 0 ? "start" : "end"}" class="cb-val">${d >= 0 ? "+" : "−"}${nf(Math.abs(d), 2)} TWh</text>`;
    });
    $("cmp-mix").innerHTML = g + `</svg>`;

    // per month
    const months = {};
    days.forEach((d, i) => { const k = d.slice(0, 7); (months[k] = months[k] || []).push(i); });
    $("cmp-month").innerHTML = `<thead><tr><th>Month</th><th>Real<br>€/MWh</th><th class="cmp-ha">A<br>€/MWh</th><th class="cmp-hb">B<br>€/MWh</th><th>Error A<br>€/MWh</th><th>Error B<br>€/MWh</th></tr></thead><tbody>`
      + Object.entries(months).map(([k, dl]) => {
        const idx = dl.flatMap(d => Array.from({ length: 24 }, (_, h) => d * 24 + h));
        const ea = mae(pa, idx), eb = mae(pb, idx);
        return `<tr><td>${MON[+k.slice(5) - 1]} ${k.slice(0, 4)}</td><td>${nf(meanOf(idx.map(i => real[i])))}</td><td>${nf(meanOf(idx.map(i => pa[i])))}</td><td>${nf(meanOf(idx.map(i => pb[i])))}</td>
          <td class="${ea != null && eb != null && ea < eb ? "cmp-win" : ""}">${nf(ea)}</td><td class="${ea != null && eb != null && eb < ea ? "cmp-win" : ""}">${nf(eb)}</td></tr>`;
      }).join("") + `</tbody>`;
  }

  // Order of the market stages, old (stage by stage) next to new (day by day), with the
  // panel of the picked run highlighted, and that run's model version (meta.features).
  function renderStageOrder(r) {
    const f = (r.meta && r.meta.features) || null, chain = f && f.chain, carry = !!(f && f.gas);
    const STG = ["DA", "ID2", "ID3", "CID", "BAL"], DAYS = ["Day 1", "Day 2", "Day 3"];
    const cx = (x0, c) => x0 + 128 + c * 112, cy = rI => 84 + rI * 42, CW = 80, CH = 28;
    const arr = (d, cls = "") => `<path d="${d}" class="ar ${cls}" marker-end="url(#pv-head2)"/>`;
    function panel(x0, kind) {
      const on = chain === kind, dayKind = kind === "day";
      let s = `<rect x="${x0}" y="6" width="456" height="312" rx="10" class="pnl${on ? " on" : ""}"/>
        <text x="${x0 + 16}" y="32" class="ti">${dayKind ? "Day by day (new)" : "Stage by stage (old)"}</text>
        ${on ? `<text x="${x0 + 440}" y="32" class="tag" text-anchor="end">this run</text>` : ""}
        <text x="${x0 + 16}" y="50" class="sm">${dayKind ? "branch day-by-day-chain, from 15 Oct 2026" : "all runs before 15 Oct 2026"}</text>`;
      DAYS.forEach((d, c) => { s += `<text x="${cx(x0, c)}" y="74" class="hd2" text-anchor="middle">${d}</text>`; });
      STG.forEach((st, rI) => {
        DAYS.forEach((_, c) => {
          const n = dayKind ? c * 5 + rI + 1 : rI * 3 + c + 1, x = cx(x0, c) - CW / 2, y = cy(rI);
          s += `<rect x="${x}" y="${y}" width="${CW}" height="${CH}" rx="5" class="st"/>
            <text x="${x + 10}" y="${y + 19}" class="lb">${st}</text><text x="${x + CW - 8}" y="${y + 18}" class="ord" text-anchor="end">${n}</text>`;
        });
      });
      if (!dayKind) {
        // along each row, then back to the first day for the next stage
        STG.forEach((_, rI) => {
          for (let c = 0; c < 2; c++) s += arr(`M${cx(x0, c) + CW / 2 + 2},${cy(rI) + CH / 2} H${cx(x0, c + 1) - CW / 2 - 3}`);
          if (rI < 4) s += arr(`M${cx(x0, 2)},${cy(rI) + CH + 1} V${cy(rI) + CH + 7} H${cx(x0, 0)} V${cy(rI + 1) - 3}`, "back");
        });
      } else {
        DAYS.forEach((_, c) => {
          for (let rI = 0; rI < 4; rI++) s += arr(`M${cx(x0, c)},${cy(rI) + CH + 1} V${cy(rI + 1) - 3}`);
          if (c < 2) {
            const mx = cx(x0, c) + 56;
            s += arr(`M${cx(x0, c) + CW / 2 + 2},${cy(4) + CH / 2} H${mx} V${cy(0) + CH / 2} H${cx(x0, c + 1) - CW / 2 - 3}`, carry || chain !== "day" ? "carry" : "carry off");
          }
        });
        s += `<text x="${cx(x0, 0) + 56}" y="${cy(4) + CH + 22}" class="sm" text-anchor="middle">${chain === "day" && !carry ? "on/off state: not used in this run" : "on/off state at midnight"}</text>`;
      }
      return s;
    }
    $("pv-order").innerHTML = `<svg class="pv-svg" viewBox="0 0 960 372" role="img" aria-label="Order in which the model solves the market stages: stage by stage (old) or day by day (new)">
      <defs><marker id="pv-head2" viewBox="0 0 10 10" refX="9" refY="5" markerUnits="userSpaceOnUse" markerWidth="9" markerHeight="9" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" class="hd"/></marker></defs>
      ${panel(12, "stage")}${panel(492, "day")}
      <rect x="12" y="330" width="936" height="34" rx="6" class="gr"/>
      <text x="480" y="352" class="lb" text-anchor="middle">Then the AC redispatch on the grid: each hour on its own, after the market stages (hours can run in parallel)</text>
    </svg>`;
    $("pv-order-cap").innerHTML = `<b>Numbers = the order the model solves them.</b> Stage by stage: the DA is cleared for every day, then ID2 for every day, and so on. Each stage of a day only reads that day's earlier stages, so nothing passes from one day to the next. Day by day: each day runs its whole chain DA → ID2 → ID3 → CID → BAL before the next day starts. That is the real calendar: the DA for day D+1 clears at 12:00 on D, after D's IDA3 at 10:00. A day can then hand on which gas and coal plants are running at midnight (the arrow), so a plant started late on Day 1 stays on into Day 2 (minimum up/down time, start costs). Without on/off rules nothing is handed on, and both orders give the same prices (tested, model change §16). Full-year runs with the hand-over are run as split runs: the market chunks one after another, then the redispatch in parallel.`;
    const yes = b => b ? `${icon("good")} on` : "off";
    $("pv-version").innerHTML = !f ? `<div><dt>This run's model version</dt><dd>Not recorded for this run.</dd></div>` : `
      <div><dt>${term("Market stage order", "f_chain")}</dt><dd>${f.chain === "day" ? "Day by day" : f.chain === "stage" ? "Stage by stage" : "–"}</dd></div>
      <div><dt>On/off state passed to the next day</dt><dd>${f.chain === "day" ? yes(f.gas) : "no (stage by stage)"}</dd></div>
      <div><dt>${term("Solar/wind", "f_res")}</dt><dd>${f.res === "offered" ? "Offered" : "Accepted"}</dd></div>
      <div><dt>${term("Cross-border split", "f_xb")}</dt><dd>${yes(f.xb)}</dd></div>
      <div><dt>${term("Gas and coal", "f_gas")}</dt><dd>${yes(f.gas)}</dd></div>
      <div><dt>${term("Tax and mark-ups", "f_markup")}</dt><dd>${yes(f.markup)}</dd></div>
      <div><dt>${term("Improved hydro planning", "f_hydro")}</dt><dd>${yes(f.hydro)}</dd></div>`;
  }

  function renderAll() {
    const v = view();
    renderRunList(); renderHead(run()); renderTabs(v); renderPeriod(); renderKpis(v); renderPrice(v); renderMix(v); renderStatus(v); renderCsp(v); renderRedispatch(v); renderBalancing(v); renderGrid(v); renderPlants(v); renderFlex(v); renderInvest(v); renderCompare(v); renderStages(); renderStageOrder(run()); renderTraded(v);
  }

  // ---------- loading runs ----------
  const pending = { run: {}, months: {} };
  window.VIEWER = {
    addRun(pkg) { pending.run[pkg.id] = pkg; },
    addMonth(id, month, part) { (pending.months[id] = pending.months[id] || {})[month] = part; },
  };
  const loadScript = src => new Promise((ok, fail) => {
    const s = document.createElement("script");
    s.src = src; s.onload = ok; s.onerror = () => fail(new Error("Could not load " + src));
    document.head.appendChild(s);
  });
  const decodeB64 = s => Uint8Array.from(atob(s), ch => ch.charCodeAt(0));
  // packages store the hourly map data hour by hour; the drawing code reads one row per line or plant
  function byItem(bytes, n, H, Type) {
    const src = new Type(bytes.buffer), out = new Type(n * H);
    for (let h = 0; h < H; h++) for (let i = 0; i < n; i++) out[i * H + h] = src[h * n + i];
    return out;
  }
  function runInfo(meta) {
    const i = meta.info || {}, m = i.runtime_min;
    const rt = m == null ? "–" : m >= 60 ? `${Math.floor(m / 60)} h ${Math.round(m % 60)} min` : `${Math.round(m)} min`;
    return { ran_by: i.ran_by || "–", branch: i.branch || "–", commit: i.commit || "–", commit_msg: i.commit_message || "",
      dirty: i.uncommitted_files || [], power_flow: i.power_flow || "AC",
      solver: i.linear_solver ? `Ipopt + ${String(i.linear_solver).toUpperCase()}` : "–",
      finished: i.finished || "–", runtime: rt, reconstructed: !!i.reconstructed };
  }
  async function loadRun(id) {
    if (D.runs.some(r => r.id === id)) return;
    const base = `runs/${encodeURIComponent(id)}/`;
    await loadScript(base + "data.js");
    const pkg = pending.run[id];
    if (!pkg) throw new Error(`runs/${id}/data.js does not contain the run`);
    await Promise.all(pkg.months.map(m => loadScript(`${base}${m}.js`)));
    const parts = pkg.months.map(m => pending.months[id][m]);
    const H = pkg.days.length * 24;
    const join = (key, Type, n) => {
      const all = new Uint8Array(H * n * Type.BYTES_PER_ELEMENT);
      let off = 0;
      for (const p of parts) { const b = decodeB64(p[key]); all.set(b, off); off += b.length; }
      return byItem(all, n, H, Type);
    };
    const C = pkg.grid.corridors.length, NG = pkg.plants.groups.length, NS = pkg.sites.sites.length;
    gridCache[id] = { H, load: join("grid_load", Uint8Array, C), flow: null };
    const out = join("plant_out", Uint8Array, NG), chg = join("plant_chg", Int8Array, NG);
    let maxChg = 1;
    pkg.plants.groups.forEach((p, i) => { for (let h = 0; h < H; h++) { const v = chg[i * H + h]; if (v !== -128) maxChg = Math.max(maxChg, Math.abs(v) / 127 * p.cap); } });
    plantCache[id] = { H, out, chg, maxChg };
    realCache[id] = { H, model: join("site_model", Uint16Array, NS), real: join("site_real", Uint16Array, NS) };
    const meta = MANIFEST.find(m => m.id === id) || {};
    D.runs.push({ ...pkg, name: meta.name || id, note: meta.note || "", info: runInfo(meta), meta });
    delete pending.run[id]; delete pending.months[id];
  }
  async function selectRun(id) {
    stopPlay("gh"); stopPlay("ph");
    state.run = id; state.zoom = null; state.gridHour = null; state.gridSel = null; state.plantHour = null; state.plantSel = null;
    try { history.replaceState(null, "", "#" + id); } catch (e) {}
    renderRunList();
    const note = $("status-note");
    note.hidden = false; note.textContent = "Loading the run …";
    $("report").classList.add("loading");
    try { await loadRun(id); }
    catch (e) { note.textContent = `${e.message}. Is this run in your copy of runs/? Try git pull.`; return; }
    if (state.run !== id) return;   // another run was picked while this one loaded
    const r = run();
    G.corridors = r.grid.corridors; G.frame = r.grid.frame;
    PD.groups = r.plants.groups; maxCap = Math.max(1, ...PD.groups.map(p => p.cap));
    RP.sites = r.sites.sites; RP.coverage = r.sites.coverage;
    PD.siteOf = new Map(RP.sites.map((s, i) => [`${s.x},${s.y},${s.f}`, i]));
    PD.searchIdx = new Map(PD.groups.map((p, i) => [plantOption(p, i), i]));
    $("plant-search-list").innerHTML = [...PD.groups.keys()].sort((a, b) => (plantName(PD.groups[b]) ? 1 : 0) - (plantName(PD.groups[a]) ? 1 : 0) || PD.groups[b].cap - PD.groups[a].cap)
      .map(i => `<option value="${esc(plantOption(PD.groups[i], i))}"></option>`).join("");
    D.categories = r.categories; D.categories_phys = r.categories_phys;
    note.hidden = true; $("report").classList.remove("loading");
    renderAll();
  }
  function foldExplanations() {
    document.querySelectorAll(".sec-head > div > p").forEach(p => {
      const h = p.innerHTML, m = h.match(/\.\s+(?=[A-Z"“(])/);
      if (!m || h.length < 140) return;
      const cut = m.index + 1, rest = h.slice(cut).trim();
      p.innerHTML = h.slice(0, cut);
      const d = document.createElement("details"); d.className = "howto";
      d.innerHTML = `<summary>How to read this</summary><p>${rest}</p>`;
      p.after(d);
    });
    document.querySelectorAll("section.card > p.fineprint:not([id])").forEach(p => {
      if (p.textContent.length < 200) return;
      const d = document.createElement("details"); d.className = "howto more";
      d.innerHTML = "<summary>Sources and details</summary>";
      p.replaceWith(d); d.appendChild(p);
    });
  }
  function start() {
    foldExplanations();
    document.querySelector(".layout").classList.toggle("runs-closed", !runsOpen);
    document.querySelector(".layout > .runs").id = "runs-nav";
    renderRunList();
    if (!MANIFEST.length) {
      $("status-note").hidden = false;
      $("status-note").textContent = "No runs published yet. Publish one with scripts/publish_run.py in the model repo.";
      return;
    }
    selectRun(state.run);
  }

  start();
  // Redraw the charts whenever the report column changes width (also covers the frame
  // settling to its final size after the first render, and late web-font loads).
  const redraw = () => { if (!run()) return; const v = view(); renderPrice(v); renderMix(v); renderStatus(v); renderCsp(v); renderRedispatch(v); renderBalancing(v); renderGrid(v); renderPlants(v); renderFlex(v); renderInvest(v); renderCompare(v); };
  let rt, lastW = $("report").clientWidth;
  new ResizeObserver(() => {
    const w = $("report").clientWidth;
    if (Math.abs(w - lastW) < 4) return;
    lastW = w;
    clearTimeout(rt); rt = setTimeout(redraw, 120);
  }).observe($("report"));
  window.addEventListener("load", redraw);
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(redraw);
})();
