"""
Build the Ethiopia network coverage & speed dataset from Ookla Speedtest Open Data.

Pipeline (no cloud creds needed — the S3 bucket is public over HTTPS):
  1. Download the quarter's global mobile + fixed tile Parquet files (teamookla/ookla-open-data).
  2. Use DuckDB to read them locally and pre-filter to an Ethiopia quadkey range
     (Ookla Parquet is sorted by quadkey, so a range + coarse-prefix filter isolates the region).
  3. Decode each ~610 m zoom-16 tile's centroid from its quadkey, clip precisely to the
     Ethiopia ADM0 polygon (geoBoundaries), and assign ADM1 regions.
  4. Emit two browser data files consumed by eth_ookla_map.html:
       data/eth_ookla_data.js  — per-tile metrics + national & regional test-weighted means
       data/eth_adm1.js        — ADM1 region boundaries for the overlay

Requirements (this machine's Python 3.12): duckdb, pandas, geopandas, shapely, numpy, requests.
  pip install duckdb   # the only one not already present

Usage:  python build_ookla_ethiopia.py            # uses QUARTER below
Re-downloaded Parquet is cached in a temp dir and reused on re-runs.
"""
import os, math, json, tempfile, urllib.request
import numpy as np, pandas as pd, geopandas as gpd, shapely, duckdb
from shapely.geometry import shape

# ---- pick the quarter (snapshot released ~1 quarter after it ends) ----
QUARTER_DATE = "2026-07-01"          # Ookla file key date for 2026 Q3
QUARTER_LABEL = "2026 Q3 (Jul–Sep 2026)"

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
CACHE = os.path.join(tempfile.gettempdir(), "ookla_eth_cache")
os.makedirs(CACHE, exist_ok=True)

S3 = "https://ookla-open-data.s3.amazonaws.com/parquet/performance"
GB = "https://github.com/wmgeolab/geoBoundaries/raw/9469f09/releaseData/gbOpen/ETH"

# Ethiopia bbox (padded) -> coarse zoom-6 quadkey prefixes for cheap pre-filtering
LON_MIN, LON_MAX, LAT_MIN, LAT_MAX = 32.9, 48.1, 3.2, 15.1

def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = int((lon + 180.0) / 360.0 * n)
    y = int((1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n)
    return max(0, min(n - 1, x)), max(0, min(n - 1, y))

def tile_to_quadkey(x, y, z):
    return "".join(str((1 if x & (1 << (i - 1)) else 0) + (2 if y & (1 << (i - 1)) else 0))
                   for i in range(z, 0, -1))

def coarse_prefixes(zc=6):
    x0, y0 = lonlat_to_tile(LON_MIN, LAT_MAX, zc)
    x1, y1 = lonlat_to_tile(LON_MAX, LAT_MIN, zc)
    return sorted({tile_to_quadkey(x, y, zc)
                   for x in range(min(x0, x1), max(x0, x1) + 1)
                   for y in range(min(y0, y1), max(y0, y1) + 1)})

def decode_centroids(quadkeys):
    arr = np.array([list(q) for q in quadkeys]); z = 16
    x = np.zeros(len(arr), dtype=np.int64); y = np.zeros(len(arr), dtype=np.int64)
    for i in range(z):
        d = arr[:, i].astype(np.int64); bit = z - i - 1
        x |= (d & 1) << bit; y |= ((d >> 1) & 1) << bit
    n = 2 ** z
    lon = (x + 0.5) / n * 360.0 - 180.0
    lat = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * (y + 0.5) / n))))
    return lon, lat

def fetch(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        print("  cached", os.path.basename(dest)); return dest
    print("  downloading", url)
    urllib.request.urlretrieve(url, dest)
    return dest

def round_coords(c):
    if isinstance(c[0], (int, float)):
        return [round(c[0], 4), round(c[1], 4)]
    return [round_coords(x) for x in c]

def main():
    pref = coarse_prefixes(6)
    lo, hi = min(pref) + "0" * 10, max(pref) + "3" * 10
    inlist = ",".join("'%s'" % p for p in pref)

    # boundaries
    print("Boundaries:")
    adm0_p = fetch(f"{GB}/ADM0/geoBoundaries-ETH-ADM0.geojson", os.path.join(CACHE, "adm0.geojson"))
    adm1_p = fetch(f"{GB}/ADM1/geoBoundaries-ETH-ADM1.geojson", os.path.join(CACHE, "adm1.geojson"))
    adm0 = json.load(open(adm0_p, encoding="utf-8"))
    eth = shapely.unary_union([shape(f["geometry"]) for f in adm0["features"]])
    adm1_gdf = gpd.read_file(adm1_p)[["shapeName", "geometry"]].rename(columns={"shapeName": "region"})

    con = duckdb.connect()
    out = {"meta": {"quarter": QUARTER_LABEL,
                    "source": "Ookla Speedtest Open Data (teamookla/ookla-open-data), AWS S3",
                    "tile_m": 610}}
    national, regions = {}, {}

    for net in ["mobile", "fixed"]:
        print(f"{net}:")
        url = f"{S3}/type={net}/year={QUARTER_DATE[:4]}/quarter={(int(QUARTER_DATE[5:7])-1)//3+1}/{QUARTER_DATE}_performance_{net}_tiles.parquet"
        pq = fetch(url, os.path.join(CACHE, f"{net}.parquet"))
        df = con.execute(f"""
            SELECT quadkey, avg_d_kbps, avg_u_kbps, avg_lat_ms, tests, devices
            FROM read_parquet('{pq.replace(os.sep,"/")}')
            WHERE quadkey >= '{lo}' AND quadkey <= '{hi}' AND substr(quadkey,1,6) IN ({inlist})
        """).fetch_df()
        lon, lat = decode_centroids(df["quadkey"].tolist())
        df["lon"], df["lat"] = lon, lat
        df = df[shapely.contains_xy(eth, df["lon"].values, df["lat"].values)].reset_index(drop=True)
        df["d"] = df["avg_d_kbps"] / 1000.0; df["u"] = df["avg_u_kbps"] / 1000.0
        df["lat_ms"] = df["avg_lat_ms"].astype(float)

        pts = gpd.GeoDataFrame(df, geometry=gpd.points_from_xy(df.lon, df.lat), crs="EPSG:4326")
        j = gpd.sjoin(pts, adm1_gdf, how="left", predicate="within")
        df["region"] = j[~j.index.duplicated(keep="first")]["region"].values

        out[net] = [[round(float(r.lat), 4), round(float(r.lon), 4), round(float(r.d), 1),
                     round(float(r.u), 1), round(float(r.lat_ms), 0), int(r.tests)]
                    for r in df.itertuples()]
        w = df["tests"].values
        national[net] = {"tiles": int(len(df)), "tests": int(w.sum()), "devices": int(df["devices"].sum()),
                         "d": round(float(np.average(df["d"], weights=w)), 1),
                         "u": round(float(np.average(df["u"], weights=w)), 1),
                         "lat": round(float(np.average(df["lat_ms"], weights=w)), 1)}
        for reg, g in df.dropna(subset=["region"]).groupby("region"):
            wr = g["tests"].values
            regions.setdefault(reg, {})[net] = {
                "tiles": int(len(g)), "tests": int(wr.sum()),
                "d": round(float(np.average(g["d"], weights=wr)), 1),
                "u": round(float(np.average(g["u"], weights=wr)), 1),
                "lat": round(float(np.average(g["lat_ms"], weights=wr)), 1)}
        print(f"  {len(df)} tiles in Ethiopia")

    out["national"], out["regions"] = national, regions
    with open(os.path.join(DATA, "eth_ookla_data.js"), "w", encoding="utf-8") as f:
        f.write("// Ookla Speedtest Open Data for Ethiopia — generated by build_ookla_ethiopia.py\n")
        f.write("window.OOKLA = "); json.dump(out, f, separators=(",", ":")); f.write(";\n")

    # ADM1 boundaries for the overlay (coords rounded to 4 dp to shrink)
    a1 = json.load(open(adm1_p, encoding="utf-8"))
    for ft in a1["features"]:
        ft["geometry"]["coordinates"] = round_coords(ft["geometry"]["coordinates"])
        ft["properties"] = {"region": ft["properties"].get("shapeName")}
    with open(os.path.join(DATA, "eth_adm1.js"), "w", encoding="utf-8") as f:
        f.write("window.ETH_ADM1 = "); json.dump(a1, f, separators=(",", ":")); f.write(";\n")

    print("\nDone. National test-weighted means:")
    print(json.dumps(national, indent=2))

if __name__ == "__main__":
    main()
