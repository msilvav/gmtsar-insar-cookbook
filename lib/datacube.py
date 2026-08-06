#!/usr/bin/env python
# =============================================================================
# datacube.py  —  Producto FUSION-READY del cookbook GMTSAR
# -----------------------------------------------------------------------------
# Construye un DATACUBE (xarray.Dataset) a partir de los COG exportados por
# export_products.sh: apila LOS, coherencia y fase en una GRILLA COMUN, con la
# metadata del run como atributos y una dimension `time` (preparada para SBAS /
# serie temporal: cada corrida es un slice de tiempo, se van APENDANDO).
#
# Formato de salida por defecto: ZARR (chunked, comprimido, lazy, appendable en
# `time`) -> ideal para data science / ML / series temporales. NetCDF opcional.
#
# Uso (CLI):
#   python datacube.py <products_dir> [--out cube.zarr] [--format zarr|netcdf]
#                                     [--utm] [--epsg 32616]
#
# Uso (libreria):
#   from datacube import build_cube, add_raster, to_utm, save, open_cube, append_time
#   ds = build_cube("examples/nicaragua_2018/products")   # -> (time=1, y, x)
#   save(ds, "cube.zarr")                                  # Zarr por defecto
#   append_time("cube.zarr", build_cube("examples/otra_fecha/products"))  # SBAS: suma fecha
#   ds = add_raster(ds, "ndvi_s2.tif", "ndvi")            # <-- fusion Sentinel-2 (1 o N bandas)
#   ds = to_utm(ds)                                        # metros (UTM 16N)
#
# Requiere el env 'geoai': xarray, rioxarray, rasterio, pyproj, numpy, zarr.
# =============================================================================
import argparse, glob, json, os
import numpy as np
import xarray as xr
import rioxarray  # noqa: F401  (registra el accessor .rio)
from rasterio.enums import Resampling

CRS_COORD = "spatial_ref"   # coordenada donde rioxarray guarda el CRS
_CHUNK = 1024               # tamano de chunk espacial (px) para Zarr


def _open(path, band=None):
    """Abre un raster como DataArray, enmascarando NoData.
    - 1 banda  -> DataArray 2D (y, x).
    - N bandas -> conserva la dim 'band' (para que add_raster la expanda).
    - band=<n> -> selecciona esa banda y devuelve 2D."""
    da = rioxarray.open_rasterio(path, masked=True)
    if band is not None:
        da = da.sel(band=band)
    if "band" in da.dims and da.sizes["band"] == 1:
        da = da.squeeze("band", drop=True)
    return da


def _data_vars(ds):
    """data_vars reales, excluyendo la coord de CRS si se filtro como variable."""
    return [v for v in ds.data_vars if v != CRS_COORD]


def _ref2d(da):
    """Slice 2D (y,x) de una variable que puede tener dim `time` — para usar de
    grilla de referencia en reproject_match."""
    return da.isel(time=0, drop=True) if "time" in da.dims else da


def _strip_gdal_attrs(da):
    """Quita atributos que rioxarray/GDAL inyecta y que rompen el encoder CF de xarray
    (scale_factor/add_offset ya vienen aplicados por masked=True; son identidad)."""
    for k in ("scale_factor", "add_offset", "_FillValue"):
        da.attrs.pop(k, None)
    return da


def _attr(v):
    """Serializa un valor de metadata a un tipo que NetCDF/Zarr acepten.
    Ojo: en Python isinstance(True, int) es True, asi que bool va PRIMERO."""
    if isinstance(v, bool):
        return json.dumps(v)                 # -> "true"/"false"
    if isinstance(v, (str, int, float)):
        return v
    return json.dumps(v, ensure_ascii=False)  # listas/dicts/None -> string JSON


def _add_time(ds, meta):
    """Agrega una dimension `time` de largo 1 (esquema listo para serie temporal).
    time = fecha secundaria (slave); reference_time = fecha master. Si no hay fechas,
    usa un indice entero 0 (igual queda appendable)."""
    sec, ref = meta.get("slave_date"), meta.get("master_date")
    try:
        t = np.array([np.datetime64(sec)]) if sec else np.array([0])
    except Exception:
        t = np.array([0])
    ds = ds.expand_dims(time=t)
    if ref:
        try:
            ds = ds.assign_coords(reference_time=("time", np.array([np.datetime64(ref)])))
        except Exception:
            pass
    return ds


def build_cube(products_dir):
    """Lee todos los COG de <products_dir>/cog/ y arma un Dataset (time=1, y, x) en
    grilla comun. La grilla de referencia es la de MAYOR extension (no la primera
    alfabetica): alinear con reproject_match nunca RECORTA datos reales, solo rellena NaN."""
    cogdir = os.path.join(products_dir, "cog")
    cogs = sorted(glob.glob(os.path.join(cogdir, "*.tif")))
    if not cogs:
        raise SystemExit(f"No hay COG en {cogdir}. Corre export_products.sh primero.")

    meta_path = os.path.join(products_dir, "run_metadata.json")
    meta = json.load(open(meta_path)) if os.path.exists(meta_path) else {}

    raw = {os.path.splitext(os.path.basename(p))[0]: _open(p) for p in cogs}
    ref_name = max(raw, key=lambda k: raw[k].size)   # grilla de mayor extension
    ref = raw[ref_name]

    das = {}
    for name, da in raw.items():
        if name != ref_name:
            da = da.rio.reproject_match(ref, resampling=Resampling.bilinear)
        _strip_gdal_attrs(da)      # scale_factor/add_offset (identidad) chocan con el encoder CF
        sc = os.path.join(cogdir, name + ".json")
        if os.path.exists(sc):
            s = json.load(open(sc))
            da.attrs.update(units=s.get("units", ""), long_name=s.get("description", ""))
        das[name] = da

    ds = xr.Dataset(das)
    ds = _add_time(ds, meta)                    # (time=1, y, x)
    ds.rio.write_crs(ref.rio.crs, inplace=True)
    for k, v in meta.items():
        ds.attrs[k] = _attr(v)
    ds.attrs["grid_reference"] = ref_name
    return ds


def add_raster(ds, path, name, resampling=Resampling.bilinear, band=None):
    """PUNTO DE ENGANCHE DE FUSION.  Resamplea un raster externo (NDVI o bandas de
    Sentinel-2) a la grilla EXACTA del cubo y lo agrega. Multibanda -> una variable por
    banda (<name>_b1, ...). Se agrega como capa estatica (sin dim time).

    Idea fisica de arranque: coherencia (radar) vs NDVI (S2) -> la vegetacion hace perder
    coherencia. Primer experimento de fusion con sentido."""
    ref = _ref2d(ds[_data_vars(ds)[0]])
    da = _strip_gdal_attrs(_open(path, band=band))
    if "band" in da.dims:                          # multibanda -> expandir
        for b in np.atleast_1d(da["band"].values):
            ds[f"{name}_b{int(b)}"] = da.sel(band=b).rio.reproject_match(ref, resampling=resampling)
    else:
        ds[name] = da.rio.reproject_match(ref, resampling=resampling)
    return ds


def to_utm(ds, epsg=32616):
    """Reproyecta el cubo a UTM (metros). 32616 = UTM 16N (Nicaragua; zona de los tiles
    Sentinel-2 de la region). Mejor para ML pixel-a-pixel y distancias."""
    return ds.rio.reproject(f"EPSG:{epsg}")


def _fmt_of(path, fmt):
    if fmt:
        return fmt
    return "zarr" if str(path).endswith(".zarr") else "netcdf"


def save(ds, path, fmt=None):
    """Guarda el cubo. fmt='zarr' (def, chunked/comprimido/appendable) o 'netcdf'.
    Preserva el CRS: el grid_mapping se mantiene en el encoding de cada variable
    (sin esto, al reabrir to_utm()/add_raster() fallan con MissingCRS)."""
    fmt = _fmt_of(path, fmt)
    dvars = _data_vars(ds)
    if fmt == "zarr":
        enc = {}
        for v in dvars:
            dims = ds[v].dims
            enc[v] = {"chunks": tuple(1 if d == "time" else min(_CHUNK, ds.sizes[d]) for d in dims),
                      "grid_mapping": CRS_COORD}
        ds.to_zarr(path, mode="w", encoding=enc, consolidated=True)
    else:
        enc = {v: {"zlib": True, "complevel": 4, "grid_mapping": CRS_COORD} for v in dvars}
        ds.to_netcdf(path, encoding=enc)
    return path


def append_time(store_path, ds_new):
    """SBAS / serie temporal: agrega el cubo de OTRA fecha al store Zarr existente a lo
    largo de `time`. ds_new debe compartir grilla (x,y) y variables con el store."""
    for v in _data_vars(ds_new):
        ds_new[v].encoding.pop("chunks", None)     # dejar que zarr reuse los chunks del store
    ds_new.to_zarr(store_path, append_dim="time", consolidated=True)
    return store_path


def open_cube(path):
    """Reabre un cubo (Zarr o NetCDF) CON su CRS (decode_coords='all')."""
    if str(path).endswith(".zarr"):
        return xr.open_zarr(path, decode_coords="all", consolidated=True)
    return xr.open_dataset(path, decode_coords="all")


def summary(ds):
    dims = {k: int(v) for k, v in ds.sizes.items()}
    print("Datacube:", dims, "| CRS:", ds.rio.crs, "| grilla ref:", ds.attrs.get("grid_reference", "?"))
    for v in _data_vars(ds):
        a = ds[v]; u = a.attrs.get("units", "")
        vals = a.values; finite = np.isfinite(vals)
        cov = 100.0 * finite.sum() / vals.size if vals.size else 0.0
        mean = float(np.nanmean(vals)) if finite.any() else float("nan")
        print(f"  {v:20s} [{u:>4}]  cobertura={cov:5.1f}%  media={mean:8.2f}")


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Construye un datacube xarray (Zarr) desde COG de GMTSAR")
    ap.add_argument("products_dir", help="carpeta con cog/ y run_metadata.json")
    ap.add_argument("--out", default=None, help="salida (def: <products_dir>/datacube.<zarr|nc>)")
    ap.add_argument("--format", choices=["zarr", "netcdf"], default="zarr", help="formato (def zarr)")
    ap.add_argument("--utm", action="store_true", help="reproyectar a UTM (metros)")
    ap.add_argument("--epsg", type=int, default=32616, help="EPSG UTM destino (def 32616 = UTM 16N)")
    a = ap.parse_args()

    ds = build_cube(a.products_dir)
    summary(ds)
    if a.utm:
        ds = to_utm(ds, a.epsg); print(f"-> reproyectado a UTM (EPSG:{a.epsg})")
    ext = "zarr" if a.format == "zarr" else "nc"
    suffix = "_utm" if a.utm else ""      # --utm no debe pisar el cubo EPSG:4326 (misma ruta)
    out = a.out or os.path.join(a.products_dir, f"datacube{suffix}.{ext}")
    save(ds, out, fmt=a.format)
    print("Guardado ->", out, f"({a.format})")
