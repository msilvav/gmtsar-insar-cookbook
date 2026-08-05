#!/usr/bin/env bash
# deramp.sh — Fase ③: quita la rampa orbital (ajuste de plano robusto) de la fase desenrollada
# y recalcula el LOS sin rampa, geocodificando. REPRODUCIBLE (antes se corría a mano).
# Requiere unwrap.sh ya corrido en merge/ (unwrap_mask.grd, trans.dat, *.PRM).
#
# Parámetros por entorno: MERGE_DIR, NMODEL (orden del modelo grdtrend; 3 = plano).
set -uo pipefail
export GMTSAR=${GMTSAR:-/usr/local/GMTSAR}
export PATH="$GMTSAR/bin:$PATH"
export LC_ALL=C
MERGE=${MERGE_DIR:-"$(cd "$(dirname "$0")" && pwd)/merge"}
NMODEL=${NMODEL:-3}                                # -N3 = plano (mean + x + y); +r = robusto
cd "$MERGE" || { echo "ERROR: no existe $MERGE"; exit 1; }

[ -s unwrap_mask.grd ] || { echo "ERROR: falta unwrap_mask.grd (corré unwrap.sh primero)"; exit 1; }
[ -f trans.dat ]       || { echo "ERROR: falta trans.dat"; exit 1; }
PRM=$(ls *.PRM 2>/dev/null | head -1)
WAVEL=$(grep -m1 radar_wavelength "$PRM" 2>/dev/null | awk '{print $3}'); WAVEL=${WAVEL:-0.0554658}

echo "== DERAMP START $(date '+%F %T') =="
echo "modelo=grdtrend -N${NMODEL}+r (plano robusto)  wavel=$WAVEL  merge=$MERGE"

# 1) ajustar plano robusto -> residual (fase sin rampa, -D) y el plano ajustado (-T)
gmt grdtrend unwrap_mask.grd -N${NMODEL}+r -Dunwrap_detrend.grd -Ttrend.grd \
  || { echo "ERROR: grdtrend"; exit 1; }
# 2) LOS sin rampa (mm) — mismo factor que unwrap.sh y GMTSAR (geocode.csh): -1000/(4π)=-79.58
gmt grdmath unwrap_detrend.grd $WAVEL MUL -79.58 MUL = los_detrend.grd \
  || { echo "ERROR: los_detrend"; exit 1; }
# 3) geocodificar
proj_ra2ll.csh trans.dat unwrap_detrend.grd unwrap_detrend_ll.grd || { echo "ERROR: proj unwrap_detrend"; exit 1; }
proj_ra2ll.csh trans.dat los_detrend.grd     los_detrend_ll.grd    || { echo "ERROR: proj los_detrend"; exit 1; }

# 4) KML de LOS sin rampa (con guarda contra all-NaN)
BL=$(gmt grdinfo -C los_detrend_ll.grd | awk '{print $6}'); BT=$(gmt grdinfo -C los_detrend_ll.grd | awk '{print $7}')
case "$BL$BT" in
  *[Nn][Aa][Nn]*|"") echo "WARN: los_detrend sin datos válidos; salto KML";;
  *) gmt makecpt -Cpolar -T-50/50/2 -Z > los_detrend.cpt \
       && grd2kml.csh los_detrend_ll los_detrend.cpt || echo "WARN: KML los_detrend falló";;
esac

echo "== DERAMP END $(date '+%F %T') =="
echo "Salidas: unwrap_detrend(_ll).grd, los_detrend(_ll).grd, trend.grd (+KML)"
echo "NOTA: el plano robusto elimina CUALQUIER gradiente lineal; en zonas con deformación"
echo "      tectónica de gran longitud de onda esto puede borrar señal real (no solo órbita)."
