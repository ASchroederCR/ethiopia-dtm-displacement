# Ethiopia internal displacement — origin→destination analysis (IOM DTM)

Extracts IOM Displacement Tracking Matrix (DTM) data for Ethiopia, builds annual
origin→destination (O-D) matrices of internally displaced persons (IDPs), and
renders them as (1) a series of heat-map charts and (2) an interactive flow map.

## Deliverables

| File | What it is |
|------|------------|
| `extract_dtm_ethiopia.ps1` | Reproducible extraction + processing (PowerShell). Re-run to refresh all data. |
| `build_admin2_centroids.ps1` | One-time helper: downloads OCHA COD-AB Admin2 boundaries and computes zone centroids (needed for the site-level map). |
| `build_refugee_sites.ps1` | Builds the UNHCR refugee-site reference layer from the UNHCR CSV → `data/eth_refugee_sites.js`. |
| `eth_od_heatmaps.html` | **Heat maps** — one origin→destination matrix per year (2020–2024). Open in a browser. |
| `eth_flow_map.html` | **Interactive flow map (Admin1)** — curved arrows region→region, sized by IDP volume. |
| `eth_flow_map_sites.html` | **Interactive flow map (site / Admin2 level)** — arrows from origin region → host zone, with origin filter + min-flow slider. |
| `serve.ps1` | Tiny local static server (`http://localhost:8777`) for viewing the HTML. |
| `data/eth_admin2_raw.json` | Raw API pull (all Admin2 records, both operations). |
| `data/eth_sites_long.csv` | Site-level table: each displacement site (Admin2) × origin (Admin1), all rounds. |
| `data/eth_od_long.csv` | Tidy year-end O-D table (the matrix values). |
| `data/eth_admin2_centroids.json` | Admin2 zone centroids (pcode → lat/lon), derived from OCHA COD-AB. |
| `data/eth_od_matrices.json` / `data/eth_data.js` | Region-level payload for the heat maps + Admin1 flow map. |
| `data/eth_sites_matrices.json` / `data/eth_sites_data.js` | Site-level (Admin1→Admin2) payload for the site flow map. |

## How to run

```powershell
# 1. one-time: build Admin2 zone centroids (needed for the site-level flow map)
powershell -ExecutionPolicy Bypass -File build_admin2_centroids.ps1
#    and the UNHCR refugee-site reference layer (needs the UNHCR CSV in this folder)
powershell -ExecutionPolicy Bypass -File build_refugee_sites.ps1

# 2. (re)extract + process — needs DTM_Primary_Key.txt in this folder
powershell -ExecutionPolicy Bypass -File extract_dtm_ethiopia.ps1

# 3. view the visualisations
powershell -ExecutionPolicy Bypass -File serve.ps1
#    then open http://localhost:8777/eth_od_heatmaps.html
#             http://localhost:8777/eth_flow_map.html         (region level)
#             http://localhost:8777/eth_flow_map_sites.html   (site / Admin2 level)
```

The HTML files also open by double-click (`file://`) — data is loaded via
`data/eth_data.js` rather than `fetch()` specifically so this works offline.
(The flow map still needs internet for the Leaflet library and map tiles.)

## Data source & endpoint

- **API:** DTM API v3 — `https://dtmapi.iom.int/v3/displacement/admin2`
- **Auth:** header `Ocp-Apim-Subscription-Key` (read from `DTM_Primary_Key.txt`)
- **Query:** `CountryName=Ethiopia`, `FromReportingDate=2020-01-01`, `ToReportingDate=2026-07-31`
- The Admin2 endpoint returns, per site: current location (Admin1/Admin2), IDP
  count (`numPresentIdpInd`), reporting date/round, displacement reason, sex
  disaggregation, and **origin at Admin1** (`idpOriginAdmin1Name`) — which is what
  makes the O-D matrix possible.

## Methodology (decisions that shape the numbers)

- **Coverage:** the API currently holds Ethiopia data through **August 2024**
  (round 37). There are no 2025/2026 records yet, so "through July 2026" resolves
  to the latest available.
- **Operation:** only **"Countrywide monitoring"** (national coverage) is used.
  The overlapping "Northern Ethiopia Crisis" (Tigray) operation is excluded to
  avoid double-counting the same people.
- **Yearly value = year-end snapshot.** DTM figures are *stock* (a point-in-time
  count), reported in several rounds per year. Summing rounds would multiply-count
  the same IDPs, so each year uses the **latest reporting round that carries origin
  data** (≥ 50 % of IDPs with a known origin). Rounds selected: 2020→R23 (Sep),
  2021→R27 (Sep), 2022→R31 (Sep), 2023→R35 (Dec), 2024→R37 (Aug).
- **O-D level:** origin is only reported at **Admin 1**, so the matrix is
  Admin 1 origin → Admin 1 current/host region. Metric = present IDP individuals.
- **Region names** are normalised across origin/destination labels
  (e.g. "South Ethiopian"/"South Ethiopia People" → "South Ethiopia").
- **Unknown origin:** IDPs with origin "Not available" are excluded from the O-D
  pairs (counts noted per year in the heat-map footer); they remain in the raw
  data and site-level CSV.

## Reading the visualisations

- **Heat maps** — rows = origin, columns = host region, colour = IDP count. The
  orange-ringed diagonal is displacement *within* a region. Toggle log/linear
  colour and shared/per-year scaling; hover any cell for exact figures.
- **Flow map** — arrows point from origin to the region now hosting people, width
  ∝ IDPs; orange circles = IDPs currently hosted in each region (area-scaled).
  Switch year, filter by minimum flow, and toggle "cross-region only". Hover
  arrows/circles for detail.

## Site-level (Admin2) flow map

`eth_flow_map_sites.html` drills the destination down to the **Admin 2 "zone"** —
the finest unit the DTM public API exposes. Note:

- **Origin stays at Admin 1** (the API never reports origin below Admin1), so
  arrows are Admin1 origin → Admin2 host zone.
- **The API contains no coordinates.** Zone centroids come from the OCHA COD-AB
  boundaries (HDX `cod-ab-eth`), joined to DTM on `admin2Pcode`; centroids are
  computed from polygon geometry by `build_admin2_centroids.ps1` (the COD file's
  own `center_lat/lon` fields are empty).
- **100 of 102** DTM zones matched a COD polygon by pcode. Two were filled
  manually because they aren't in the current COD vintage: `ET1600` (DTM codes all
  of Sidama as one zone → placed at the mean of the five COD Sidama zones) and
  `ET0105` "Western" (Western Tigray → placed manually).
- Individual **physical sites/camps with point coordinates are NOT available** —
  DTM publishes only non-sensitive aggregates (admin0/1/2) via the API.

### UNHCR refugee-site reference layer

The site map has an optional layer (checkbox, off by default) plotting **UNHCR
Verified Refugee Sites** in Ethiopia (15 points) as green triangles. These are
**refugee** camps — people who fled *into* Ethiopia from other countries — a
**different population** from the internally displaced people (IDPs) in the flow
data, shown only as reference point locations (the source has no population
figures). Built by `build_refugee_sites.ps1` from the UNHCR CSV in the project
root.

## Caveats

- Figures are displacement **stock**, not directional migration flows over time;
  the O-D pair means "people currently in X who report origin Y", a reasonable
  proxy for displacement direction but not a measured movement count.
- Flow-map centroids (Admin1 in the extraction script; Admin2 from COD-AB) are
  representative points for placement only — not authoritative boundaries.
- "Contested" denotes areas of contested administration (largely Western Tigray).
