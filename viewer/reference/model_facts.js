// Facts about the model's data for the Market stages tab. Built by tools/build_model_facts.py.
window.MODEL_FACTS = {
 "model_commit": "b9e8933",
 "line_rating_factor": 0.8,
 "capacity": {
  "rows": [
   {
    "item": "Wind (onshore + offshore)",
    "model": 30434,
    "real": 30159,
    "unit": "MW"
   },
   {
    "item": "Solar (PV + solar thermal)",
    "model": 33186,
    "model_note": "PV 30,696 + thermal 2,490",
    "real": 23867,
    "unit": "MW"
   },
   {
    "item": "Mean load",
    "model": 29320,
    "model_note": "364 days of 2024",
    "real": 26444,
    "unit": "MW"
   }
  ],
  "model_src": "Data/generations.csv; Data/ES_old/load (day-ahead baseline)",
  "real_src": "ENTSO-E installed capacity per production type, 2024; ENTSO-E actual total load, 2024"
 },
 "lines": [
  {
   "kv": 132,
   "dc": false,
   "lines": 65,
   "circuits": 151,
   "imax_ka": 0.74,
   "mva": 169,
   "limit": 135,
   "uniform": true,
   "r": 0.0949,
   "x": 0.38,
   "c": 9.2
  },
  {
   "kv": 220,
   "dc": false,
   "lines": 1481,
   "circuits": 2519,
   "imax_ka": 1.29,
   "mva": 492,
   "limit": 393,
   "uniform": true,
   "r": 0.06,
   "x": 0.301,
   "c": 12.5
  },
  {
   "kv": 225,
   "dc": false,
   "lines": 2,
   "circuits": 2,
   "imax_ka": 1.29,
   "mva": 503,
   "limit": 402,
   "uniform": true,
   "r": 0.06,
   "x": 0.301,
   "c": 12.5
  },
  {
   "kv": 250,
   "dc": true,
   "lines": 1,
   "circuits": 1,
   "imax_ka": 0.8,
   "mva": 346,
   "limit": 277,
   "uniform": true,
   "r": 0.022,
   "x": 1e-06,
   "c": 200.0
  },
  {
   "kv": 320,
   "dc": false,
   "lines": 4,
   "circuits": 4,
   "imax_ka": 2.58,
   "mva": 1430,
   "limit": 1144,
   "uniform": true,
   "r": 0.04,
   "x": 0.265,
   "c": 13.2
  },
  {
   "kv": 400,
   "dc": false,
   "lines": 624,
   "circuits": 1128,
   "imax_ka": 2.58,
   "mva": 1787,
   "limit": 1430,
   "uniform": true,
   "r": 0.03,
   "x": 0.246,
   "c": 13.8
  }
 ],
 "trafos": [
  {
   "hv": 220,
   "unit_mva": 100,
   "units": 2,
   "count": 29,
   "installed": 200,
   "limit": 160
  },
  {
   "hv": 220,
   "unit_mva": 100,
   "units": 3,
   "count": 8,
   "installed": 300,
   "limit": 240
  },
  {
   "hv": 220,
   "unit_mva": 160,
   "units": 3,
   "count": 2,
   "installed": 480,
   "limit": 384
  },
  {
   "hv": 225,
   "unit_mva": 100,
   "units": 3,
   "count": 1,
   "installed": 300,
   "limit": 240
  },
  {
   "hv": 225,
   "unit_mva": 160,
   "units": 3,
   "count": 1,
   "installed": 480,
   "limit": 384
  },
  {
   "hv": 400,
   "unit_mva": 100,
   "units": 2,
   "count": 37,
   "installed": 200,
   "limit": 160
  },
  {
   "hv": 400,
   "unit_mva": 100,
   "units": 3,
   "count": 30,
   "installed": 300,
   "limit": 240
  },
  {
   "hv": 400,
   "unit_mva": 160,
   "units": 3,
   "count": 28,
   "installed": 480,
   "limit": 384
  },
  {
   "hv": 400,
   "unit_mva": 250,
   "units": 3,
   "count": 18,
   "installed": 750,
   "limit": 600
  },
  {
   "hv": 400,
   "unit_mva": 315,
   "units": 3,
   "count": 7,
   "installed": 945,
   "limit": 756
  },
  {
   "hv": 400,
   "unit_mva": 500,
   "units": 3,
   "count": 3,
   "installed": 1500,
   "limit": 1200
  },
  {
   "hv": 400,
   "unit_mva": 630,
   "units": 3,
   "count": 1,
   "installed": 1890,
   "limit": 1512
  },
  {
   "hv": 400,
   "unit_mva": 800,
   "units": 3,
   "count": 1,
   "installed": 2400,
   "limit": 1920
  },
  {
   "hv": 400,
   "unit_mva": 1000,
   "units": 3,
   "count": 3,
   "installed": 3000,
   "limit": 2400
  },
  {
   "hv": 400,
   "unit_mva": 1250,
   "units": 3,
   "count": 1,
   "installed": 3750,
   "limit": 3000
  }
 ],
 "trafo_x": [
  0.12,
  0.14
 ],
 "n_trafos": 170,
 "n_buses": 1236,
 "n_units": 973
};
