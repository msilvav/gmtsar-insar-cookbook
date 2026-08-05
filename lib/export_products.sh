#!/usr/bin/env bash
# =============================================================================
# export_products.sh  —  Capa de ENTREGABLES del cookbook GMTSAR
# -----------------------------------------------------------------------------
# Convierte los grids geocodificados de GMTSAR (merge/*_ll.grd) en productos
# listos para DATA SCIENCE y para futura fusion con Sentinel-2:
#
#   * GeoTIFF COG (Cloud-Optimized) en $OUT_CRS (def EPSG:4326) -> QGIS/rasterio/xarray
#   * <producto>.json  (sidecar: unidad, bbox, rango)
#   * run_metadata.json (procedencia: fechas, baseline temporal, wavelength, params)
#
# El COG lleva el VALOR real por pixel; el KML es solo una imagen para mirar.
#
# Uso:   export_products.sh <merge_dir> <out_dir>
#   Metadata/params por entorno (o `source config.env`):
#     M_DATE S_DATE THRESH DEFOMAX WAVELENGTH OUT_CRS UTM_EPSG PY
#
# Requiere: GMTSAR (gmt), gdal_translate, y $PY (python con env geoai). LC_ALL=C.
# Sale con codigo != 0 si algun producto o el metadata fallan.
# =============================================================================
set -uo pipefail
export GMTSAR=${GMTSAR:-/usr/local/GMTSAR}
export PATH="$GMTSAR/bin:$PATH"
export LC_ALL=C
PY=${PY:-/home/manuel/miniconda3/envs/geoai/bin/python}

MERGE=${1:?uso: export_products.sh <merge_dir> <out_dir>}
OUT=${2:?uso: export_products.sh <merge_dir> <out_dir>}
mkdir -p "$OUT/cog"

# El metadata necesita $PY: validar ANTES para no escribir JSON invalido despues.
if ! command -v "$PY" >/dev/null 2>&1; then
  echo "ERROR: interprete Python PY='$PY' no encontrado. Exporta PY=<python del env geoai>."; exit 1
fi

# --- metadata / params del experimento (defaults = ejemplo Nicaragua 2018) ---
M_DATE=${M_DATE:-2018-03-17}; S_DATE=${S_DATE:-2018-03-29}
THRESH=${THRESH:-0.1}; DEFOMAX=${DEFOMAX:-0}; WAVELENGTH=${WAVELENGTH:-0.0554658}
OUT_CRS=${OUT_CRS:-EPSG:4326}; UTM_EPSG=${UTM_EPSG:-32616}

# --- manifest de productos:  nombre | grd geocodificado | unidad | descripcion
PRODUCTS=(
  "los|los_ll.grd|mm|Desplazamiento LOS (crudo, con rampa orbital)"
  "los_detrend|los_detrend_ll.grd|mm|Desplazamiento LOS sin rampa (plano removido)"
  "coherence|corr_ll.grd|0-1|Coherencia interferometrica"
  "unwrapped|unwrap_ll.grd|rad|Fase desenrollada"
  "unwrapped_detrend|unwrap_detrend_ll.grd|rad|Fase desenrollada sin rampa"
  "wrapped|phasefilt_ll.grd|rad|Fase envuelta filtrada"
)

echo "== EXPORT START $(date '+%F %T') =="
echo "   merge=$MERGE  out=$OUT  crs=$OUT_CRS"
made=(); failed=0
for row in "${PRODUCTS[@]}"; do
  IFS='|' read -r name grd unit desc <<< "$row"
  src="$MERGE/$grd"
  if [ ! -f "$src" ]; then echo "  -- $name: falta $grd (omito)"; continue; fi
  tmp="$OUT/cog/.${name}_tmp.tif"; cog="$OUT/cog/${name}.tif"
  rm -f "$tmp" "$cog"
  # grd (GMT) -> GeoTIFF -> COG (GDAL). Verificar CADA paso; sin verificacion el COG
  # podia quedar ausente y el script reportar OK igual.
  if ! gmt grdconvert "$src" "${tmp}=gd:GTiff" 2>/dev/null || [ ! -s "$tmp" ]; then
    echo "  !! $name: gmt grdconvert FALLO (no se genero $grd.tif)"; failed=1; rm -f "$tmp"; continue
  fi
  if ! gdal_translate -q -of COG -a_srs "$OUT_CRS" -a_nodata nan \
        -co COMPRESS=DEFLATE -co PREDICTOR=3 "$tmp" "$cog" 2>/dev/null || [ ! -s "$cog" ]; then
    echo "  !! $name: gdal_translate/COG FALLO"; failed=1; rm -f "$tmp" "$cog"; continue
  fi
  rm -f "$tmp"
  read -r xmin xmax ymin ymax zmin zmax <<< "$(gmt grdinfo -C "$src" | awk '{print $2,$3,$4,$5,$6,$7}')"
  cat > "$OUT/cog/${name}.json" <<JSON
{
  "product": "$name",
  "description": "$desc",
  "units": "$unit",
  "crs": "$OUT_CRS",
  "source_grd": "$grd",
  "cog": "cog/${name}.tif",
  "bbox_lonlat_wsen": [$xmin, $ymin, $xmax, $ymax],
  "value_range": [$zmin, $zmax]
}
JSON
  echo "  OK $name -> cog/${name}.tif  ($unit, z=[$zmin, $zmax])"
  made+=("$name")
done

# --- run_metadata.json (procedencia). Validar los calculos antes de escribir. ---
DAYS=$($PY -c "from datetime import date;print((date.fromisoformat('$S_DATE')-date.fromisoformat('$M_DATE')).days)" 2>/dev/null || true)
SCALE=$($PY -c "import math;print(round(-$WAVELENGTH/(4*math.pi)*1000,4))" 2>/dev/null || true)
case "$DAYS"  in ''|*[!0-9-]*)        echo "ERROR: temporal_baseline_days invalido (DAYS='$DAYS'); revisa M_DATE/S_DATE/PY"; exit 1;; esac
case "$SCALE" in ''|*[!0-9.eE+-]*)    echo "ERROR: los_scale invalido (SCALE='$SCALE'); revisa WAVELENGTH/PY"; exit 1;; esac

# products como array JSON valido tambien con 0 elementos ([] en vez de [""]).
if [ "${#made[@]}" -eq 0 ]; then
  prod_json="[]"
else
  prod_json=$(printf '"%s", ' "${made[@]}"); prod_json="[${prod_json%, }]"
fi
cat > "$OUT/run_metadata.json" <<JSON
{
  "mission": "Sentinel-1 TOPS (IW, VV)",
  "processor": "GMTSAR",
  "master_date": "$M_DATE",
  "slave_date": "$S_DATE",
  "temporal_baseline_days": $DAYS,
  "radar_wavelength_m": $WAVELENGTH,
  "los_scale_mm_per_rad": $SCALE,
  "los_convention": "los_mm = phase_rad * (-1000/(4*pi)) * lambda_m ; positivo = movimiento HACIA el satelite (disminucion de rango) [GMTSAR geocode.csh 'equals negative range']",
  "unwrap": {"tool": "snaphu", "threshold": $THRESH, "defomax": $DEFOMAX},
  "crs": "$OUT_CRS",
  "utm_hint_epsg": $UTM_EPSG,
  "products": $prod_json,
  "generated_by": "cookbook/lib/export_products.sh",
  "caveat": "Par unico: senal dominada por atmosfera troposferica. Para deformacion real usar SBAS/stacking. El deramp (fase 3) puede remover deformacion real de gran longitud de onda."
}
JSON
echo "  OK run_metadata.json  (baseline ${DAYS} d, escala ${SCALE} mm/rad, crs ${OUT_CRS})"
echo "== EXPORT END $(date '+%F %T') =="
if [ "$failed" -ne 0 ]; then echo "AVISO: al menos un producto FALLO (ver '!!' arriba)"; exit 2; fi
