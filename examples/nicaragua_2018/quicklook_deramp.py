#!/usr/bin/env python
# Comparativa LOS: con rampa (crudo) vs sin rampa (plano removido).
# Uso: python quicklook_deramp.py [merge_dir]   (def: carpeta del script / merge)
import os, sys, xarray as xr, numpy as np, matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
_here = os.path.dirname(os.path.abspath(__file__))
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, "merge")

def load(p):
    ds = xr.open_dataset(p)
    v = [k for k in ds.data_vars if ds[k].ndim == 2][0]
    da = ds[v]
    yn, xn = da.dims
    return da, da[xn].values, da[yn].values

def prep(path, target=1600):
    da, lon, lat = load(path)
    s = max(1, da.shape[1] // target)
    arr = da.values[::s, ::s]
    ext = [float(lon.min()), float(lon.max()), float(lat.min()), float(lat.max())]
    org = 'lower' if lat[0] < lat[-1] else 'upper'
    return arr, ext, org

raw, ext, org = prep(f"{D}/los_ll.grd")
det, _, _ = prep(f"{D}/los_detrend_ll.grd")

def rlim(a):
    f = a[np.isfinite(a)]
    p2, p50, p98 = np.nanpercentile(f, [2, 50, 98])
    return p50, float(max(abs(p2 - p50), abs(p98 - p50))), np.nanstd(f)

fig, axs = plt.subplots(1, 2, figsize=(15, 7), constrained_layout=True)
for ax, a, tit in [(axs[0], raw, "CRUDO (con rampa orbital)"),
                   (axs[1], det, "SIN RAMPA (plano robusto removido)")]:
    c, lim, sd = rlim(a)
    im = ax.imshow(a, extent=ext, origin=org, cmap='RdBu_r',
                   vmin=c - lim, vmax=c + lim, interpolation='nearest')
    ax.set_title(f"{tit}\nσ = {sd:.1f} mm")
    ax.set_xlabel("Lon"); ax.set_ylabel("Lat")
    plt.colorbar(im, ax=ax, shrink=0.8, label="LOS (mm)")

fig.suptitle("Nicaragua S1 2018-03-17→03-29 — LOS: efecto de quitar la rampa\n"
             "El residual (der.) es atmósfera troposférica, no deformación", fontsize=13)
out = os.path.join(_here, "quicklook_deramp.png")
fig.savefig(out, dpi=130, bbox_inches='tight')
print("OK ->", out)
