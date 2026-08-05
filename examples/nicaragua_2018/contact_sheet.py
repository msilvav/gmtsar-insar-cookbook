#!/usr/bin/env python
# Contact-sheet del datacube: coherencia, fase envuelta y LOS sin rampa.
# Uso: python contact_sheet.py [products_dir]   (def: carpeta del script / products)
import os, sys, numpy as np, matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import rioxarray

_here = os.path.dirname(os.path.abspath(__file__))
PRODUCTS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, "products")
D = os.path.join(PRODUCTS, "cog")

def read(name, target=1200):
    da = rioxarray.open_rasterio(f"{D}/{name}.tif", masked=True).squeeze("band", drop=True)
    s = max(1, da.shape[1] // target)
    a = da.values[::s, ::s]
    x, y = da.x.values, da.y.values
    ext = [float(x.min()), float(x.max()), float(y.min()), float(y.max())]
    org = "lower" if y[0] < y[-1] else "upper"
    return a, ext, org

panels = [
    ("coherence",  "Coherencia (0-1)",            "viridis", 0.0, 1.0),
    ("wrapped",    "Fase envuelta (rad)",         "twilight_shifted", -np.pi, np.pi),
    ("los_detrend","LOS sin rampa (mm)",          "RdBu_r",  None, None),
]
fig, axs = plt.subplots(1, 3, figsize=(19, 6.2), constrained_layout=True)
for ax, (name, title, cmap, vmin, vmax) in zip(axs, panels):
    a, ext, org = read(name)
    if vmin is None:
        f = a[np.isfinite(a)]; p2, p50, p98 = np.nanpercentile(f, [2, 50, 98])
        lim = float(max(abs(p2 - p50), abs(p98 - p50))); vmin, vmax = p50 - lim, p50 + lim
    im = ax.imshow(a, extent=ext, origin=org, cmap=cmap, vmin=vmin, vmax=vmax, interpolation="nearest")
    ax.set_title(title); ax.set_xlabel("Lon"); ax.set_ylabel("Lat")
    plt.colorbar(im, ax=ax, shrink=0.8)
fig.suptitle("Datacube Nicaragua 2018-03-17 -> 03-29  |  capas del cubo (grilla comun EPSG:4326)", fontsize=13)
out = os.path.join(_here, "contact_sheet.png")
fig.savefig(out, dpi=125, bbox_inches="tight")
print("OK ->", out)
