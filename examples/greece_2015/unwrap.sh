#!/usr/bin/env bash
# unwrap.sh — Desenrolla (SNAPHU) el interferograma YA fusionado en merge/ y geocodifica,
# SIN recalcular preproc/align/intf/merge. Replica merge_unwrap_geocode_tops.csh, incluida
# la geocodificación de phasefilt y corr (que el oficial también produce: líneas 242 y 246).
#
# Por defecto usa snaphu.csh (SIN nearest_grid): con mucha NaN (baja coherencia) el relleno
# por vecino de snaphu_interp.csh (nearest_grid r=300, 1 hilo) se cuelga >14 h. Para forzar
# el modo interp: SNAPHU_MODE=interp.
#
# Parámetros por entorno (o vía `source config.env`): MERGE_DIR THRESH DEFOMAX TGEO SNAPHU_MODE.
set -uo pipefail
export GMTSAR=${GMTSAR:-/usr/local/GMTSAR}
export PATH="$GMTSAR/bin:$PATH"
export LC_ALL=C                                   # CRÍTICO: locale C/POSIX (ver run.sh)

MERGE=${MERGE_DIR:-"$(cd "$(dirname "$0")" && pwd)/merge"}
THRESH=${THRESH:-0.1}                             # threshold_snaphu (coherencia mínima)
DEFOMAX=${DEFOMAX:-0}                             # 0 = continuo/interseísmico ; >0 rupturas
TGEO=${TGEO:-0.10}                                # threshold_geocode
SNAPHU_MODE=${SNAPHU_MODE:-plain}                 # plain=snaphu.csh ; interp=snaphu_interp.csh

cd "$MERGE" || { echo "ERROR: no existe merge dir: $MERGE"; exit 1; }

# Derivar REGION y WAVEL del propio dato (portable; no hardcode) — igual que el oficial.
[ -s phasefilt.grd ] || { echo "ERROR: falta phasefilt.grd en $MERGE (¿corriste run.sh?)"; exit 1; }
REGION=$(gmt grdinfo phasefilt.grd -I- | cut -c3-)          # p.ej. 0/68448/0/13062
PRM=$(ls *.PRM 2>/dev/null | head -1)
WAVEL=$(grep -m1 radar_wavelength "$PRM" 2>/dev/null | awk '{print $3}'); WAVEL=${WAVEL:-0.0554658}

echo "== UNWRAP START $(date '+%F %T') =="
echo "merge=$MERGE  region=$REGION  thr=$THRESH  defomax=$DEFOMAX  wavel=$WAVEL  snaphu=$SNAPHU_MODE"

# 0) Prerrequisito para geocodificar: trans.dat. El oficial lo autogenera; aquí exigimos que
#    exista y fallamos claro (evita que los proj_ra2ll fallen en silencio).
if [ ! -f trans.dat ]; then
  echo "ERROR: falta trans.dat en $MERGE. Genéralo con el geocode de GMTSAR"
  echo "       (una corrida previa de merge_unwrap_geocode_tops.csh) antes de usar unwrap.sh."
  exit 1
fi

# 1) landmask en coordenadas radar (mask_water=1)
if [ ! -f landmask_ra.grd ]; then
  echo ">> landmask.csh $REGION"
  landmask.csh $REGION || { echo "ERROR: landmask.csh falló"; exit 1; }
fi

# 2) desenrollado (PASO LARGO)
if [ "$SNAPHU_MODE" = interp ]; then
  echo ">> snaphu_interp.csh $THRESH $DEFOMAX $REGION  (OJO: nearest_grid puede colgarse con mucha NaN)"
  snaphu_interp.csh $THRESH $DEFOMAX $REGION
else
  echo ">> snaphu.csh $THRESH $DEFOMAX $REGION"
  snaphu.csh $THRESH $DEFOMAX $REGION
fi
[ -s unwrap.grd ] || { echo "ERROR: no se generó unwrap.grd"; exit 1; }
echo ">> unwrap.grd OK: rango $(gmt grdinfo -C unwrap.grd | awk '{print $6" a "$7}') rad"

# 3) máscara por coherencia + desplazamiento LOS (mm)
gmt grdmath corr.grd $TGEO GE 0 NAN mask.grd MUL = mask2.grd     || { echo "ERROR: mask2";       exit 1; }
gmt grdmath unwrap.grd mask2.grd MUL = unwrap_mask.grd           || { echo "ERROR: unwrap_mask"; exit 1; }
gmt grdmath unwrap_mask.grd $WAVEL MUL -79.58 MUL = los.grd      || { echo "ERROR: los";         exit 1; }
[ -s los.grd ] || { echo "ERROR: no se generó los.grd"; exit 1; }

# 4) geocodificar TODAS las capas que el oficial produce (incl. phasefilt y corr, antes omitidas)
for pair in \
  "phasefilt.grd phasefilt_ll.grd" \
  "corr.grd corr_ll.grd" \
  "unwrap.grd unwrap_ll.grd" \
  "unwrap_mask.grd unwrap_mask_ll.grd" \
  "los.grd los_ll.grd"; do
  set -- $pair
  proj_ra2ll.csh trans.dat "$1" "$2" || { echo "ERROR: proj_ra2ll $1"; exit 1; }
  [ -s "$2" ] || { echo "ERROR: no se generó $2"; exit 1; }
done

# 5) CPTs + KML (con guarda: si el grid quedó todo-NaN, avisa y salta en vez de dejar un CPT roto)
make_kml () {   # <grd_ll_stem> <src_grd_para_rango> <cpt_step>
  local stem=$1 src=$2 step=$3 BL BT
  BL=$(gmt grdinfo -C "$src" | awk '{print $6}'); BT=$(gmt grdinfo -C "$src" | awk '{print $7}')
  case "$BL$BT" in
    *[Nn][Aa][Nn]*|"") echo "WARN: $src sin datos válidos (rango [$BL,$BT]); salto KML de $stem"; return 0;;
  esac
  awk -v a="$BL" -v b="$BT" 'BEGIN{exit !(a+0 < b+0)}' \
    || { echo "WARN: rango inválido [$BL,$BT]; salto KML de $stem"; return 0; }
  gmt makecpt -T"$BL"/"$BT"/"$step" -Z > "$stem.cpt" || { echo "WARN: makecpt falló ($stem)"; return 0; }
  grd2kml.csh "$stem" "$stem.cpt" || echo "WARN: grd2kml falló ($stem)"
}
make_kml unwrap_mask_ll unwrap.grd 0.5
make_kml unwrap_ll      unwrap.grd 0.5
make_kml los_ll         los.grd    2

echo "== UNWRAP END $(date '+%F %T') =="
echo "Geocodificados: phasefilt_ll, corr_ll, unwrap_ll, unwrap_mask_ll, los_ll (+KMLs)"
