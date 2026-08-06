#!/usr/bin/env python
# Quicklook del desenrollado: LOS (mm) y fase desenrollada (rad), geocodificados.
# Uso: python quicklook_los.py [merge_dir]   (def: carpeta del script / merge)
import os, sys, xarray as xr, numpy as np, matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
_here = os.path.dirname(os.path.abspath(__file__))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, "merge")
# Etiquetas por entorno (source config.env). Defaults = ejemplo Nicaragua.
from datetime import date
M_DATE = os.environ.get("M_DATE", "2018-03-17")
S_DATE = os.environ.get("S_DATE", "2018-03-29")
AOI    = os.environ.get("AOI_DESC", "Nicaragua")
try:
    DAYS = (date.fromisoformat(S_DATE) - date.fromisoformat(M_DATE)).days
except Exception:
    DAYS = "?"

def load(p):
    ds = xr.open_dataset(p)
    v = [k for k in ds.data_vars if ds[k].ndim == 2][0]
    da = ds[v]
    yname, xname = da.dims
    return da, da[xname].values, da[yname].values

def ds_step(a, target=1600):
    return max(1, a.shape[1] // target)

la, lon, lat = load(f"{D}/los_ll.grd")
ua, ulon, ulat = load(f"{D}/unwrap_ll.grd")
s = ds_step(la)
los = la.values[::s, ::s]; unw = ua.values[::s, ::s]
ext = [float(lon.min()), float(lon.max()), float(lat.min()), float(lat.max())]
origin = 'lower' if lat[0] < lat[-1] else 'upper'

f = los[np.isfinite(los)]
p1, p50, p99 = np.nanpercentile(f, [1, 50, 99])
lim = float(max(abs(p1 - p50), abs(p99 - p50)))
frac = 100.0 * np.isfinite(los).sum() / los.size

fig, axs = plt.subplots(1, 2, figsize=(15, 7), constrained_layout=True)
im0 = axs[0].imshow(los, extent=ext, origin=origin, cmap='RdBu_r',
                    vmin=p50 - lim, vmax=p50 + lim, interpolation='nearest')
axs[0].set_title(f"LOS desplazamiento (mm)  |  {M_DATE} → {S_DATE} ({DAYS} d)\n"
                 f"media={np.nanmean(f):.1f}  σ={np.nanstd(f):.1f}  cobertura={frac:.0f}%")
axs[0].set_xlabel("Lon"); axs[0].set_ylabel("Lat")
plt.colorbar(im0, ax=axs[0], shrink=0.8, label="LOS (mm), signo GMTSAR")

uf = unw[np.isfinite(unw)]
uq1, uq99 = np.nanpercentile(uf, [1, 99])
im1 = axs[1].imshow(unw, extent=ext, origin=origin, cmap='jet',
                    vmin=uq1, vmax=uq99, interpolation='nearest')
axs[1].set_title("Fase desenrollada (rad)")
axs[1].set_xlabel("Lon"); axs[1].set_ylabel("Lat")
plt.colorbar(im1, ax=axs[1], shrink=0.8, label="rad")

fig.suptitle(f"GMTSAR S1 TOPS — {AOI} — 3 subswaths merge + SNAPHU (single-tile)", fontsize=13)
out = os.path.join(_here, "quicklook_los.png")
fig.savefig(out, dpi=130, bbox_inches='tight')
print("OK ->", out)
print(f"LOS mm: p1={p1:.1f} p50={p50:.1f} p99={p99:.1f}  media={np.nanmean(f):.1f} std={np.nanstd(f):.1f}  cobertura={frac:.1f}%")
print(f"unwrap rad: p1={uq1:.2f} p99={uq99:.2f}")
