# Ethiopia network coverage & speed — Ookla Speedtest Open Data

Interactive map of mobile and fixed-broadband **coverage and performance** across Ethiopia,
built from the [Ookla Speedtest Open Data](https://github.com/teamookla/ookla-open-data).

- **Map:** `eth_ookla_map.html` (standalone, open in a browser or via `serve.ps1`)
- **Build script:** `build_ookla_ethiopia.py` — downloads the data and regenerates the two
  data files below. Run with `python build_ookla_ethiopia.py` (needs `pip install duckdb`;
  pandas/geopandas/shapely/numpy are already installed).
- **Data files:** `data/eth_ookla_data.js` (per-tile metrics + national/regional summaries),
  `data/eth_adm1.js` (ADM1 boundaries for the overlay).

## What it shows

Ookla publishes speed-test results aggregated to **~610 m (zoom-16 web-mercator) tiles**,
quarterly, for mobile and fixed networks. Each tile carries the average **download**, **upload**,
and **latency** of all tests there, plus the number of tests and devices. The map plots every
Ethiopia tile as a dot coloured by the selected metric, so the dot pattern itself is the
**measured coverage footprint** — overwhelmingly the highland corridor (Addis Ababa, Amhara,
Oromia, Tigray) and regional towns. Toggle network and metric, filter sparse tiles by a minimum
test count, and hover regions for test-weighted averages.

## Current snapshot — **2026 Q3 (Jul–Sep 2026)**

Test-weighted national means:

| Network | Download | Upload | Latency | Tiles w/ coverage | Tests | Devices |
|---|---|---|---|---|---|---|
| Mobile | **61.0 Mbps** | 19.7 Mbps | 42.8 ms | 2,757 | 24,822 | 6,463 |
| Fixed broadband | **21.5 Mbps** | 21.0 Mbps | 21.9 ms | 1,661 | 18,435 | 5,727 |

Notable: like many African markets, Ethiopia is **mobile-first** — median-tile mobile download
(~61 Mbps) runs well ahead of fixed broadband (~21.5 Mbps). Regional mobile download ranges from
~92 Mbps in Addis Ababa and ~81 in Harari down to ~16 Mbps in conflict-affected Tigray.

## Method notes

- Tiles are isolated with an Ethiopia **quadkey range + coarse-prefix** filter (DuckDB), then
  each tile centroid is clipped precisely to the Ethiopia ADM0 polygon and tagged with its ADM1
  region (geoBoundaries).
- Values are **averages of Speedtest samples**, not a census of service — tiles exist only where
  users ran tests, so absence of a dot means "no measured tests," not necessarily "no service."
  Sample counts are low in a country of ~120 M, so read town/region patterns rather than
  individual tiles. Boundaries use the geoBoundaries ADM1 vintage (11 regions; pre-dates the
  newer Sidama / South West regions).
- Source: Ookla® Speedtest Open Data (CC BY-NC-SA 4.0). Boundaries © geoBoundaries. Basemap © Esri.
