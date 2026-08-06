#!/usr/bin/env bash
# run.sh — Frame completo Sentinel-1 TOPS (ejemplo oficial GMTSAR, Nicaragua 2018-03-17/29)
# 3 subswaths (IW1/IW2/IW3) + merge. Parametrizable por entorno (source config.env):
#   M_SAFE/M_EOF/A_SAFE/A_EOF, POL (def vv), CONFIG (def config.s1a.txt),
#   PARALLEL (7º arg de p2p: 0=subswaths secuenciales, 1=en paralelo).
# Config "tal cual" del ejemplo: threshold_snaphu=0 -> NO desenrolla (fase envuelta).
#
# INTENTO 2: la RESORB (restituida) de 03-29 provocaba "hermite interpolation not in
# center interval" -> baseline no calculado -> sin interferograma. Reemplazada por la
# POEORB (precisa) descargada de ESA STEP. Intento 1 fallido guardado en _intento1_resorb/.
set -euo pipefail
export GMTSAR=/usr/local/GMTSAR
export PATH="$GMTSAR/bin:$PATH"
# CRÍTICO: GMTSAR/GMT requieren locale C/POSIX (punto decimal). El sistema está en
# es_ES.UTF-8 (coma decimal) -> strtod corta el SC_clock en el punto y los printf/awk
# escriben comas -> hermite NaN en SAT_baseline y coregistración inf/nan en fitoffset.
export LC_ALL=C
cd "$(cd "$(dirname "$0")" && pwd)"          # portable: carpeta del propio script

# Valores por defecto = ejemplo Nicaragua; se pueden fijar por entorno (source config.env).
M_SAFE=${M_SAFE:-S1A_IW_SLC__1SDV_20180317T235700_20180317T235727_021062_0242D6_6F45.SAFE}
M_EOF=${M_EOF:-S1A_OPER_AUX_POEORB_OPOD_20180406T120838_V20180316T225942_20180318T005942.EOF}
A_SAFE=${A_SAFE:-S1A_IW_SLC__1SDV_20180329T235700_20180329T235727_021237_024860_7623.SAFE}
A_EOF=${A_EOF:-S1A_OPER_AUX_POEORB_OPOD_20210306T222918_V20180328T225942_20180330T005942.EOF}
POL=${POL:-vv}
CONFIG=${CONFIG:-config.s1a.txt}             # config GMTSAR (Nicaragua: config.s1a.txt ; Grecia: config.txt)
PARALLEL=${PARALLEL:-0}                       # 0 = subswaths secuenciales ; 1 = en paralelo

echo "== START $(date '+%F %T') =="
echo "GMTSAR=$GMTSAR ; gmt=$(gmt --version)"
echo "config=$CONFIG  pol=$POL  parallel=$PARALLEL"
p2p_S1_TOPS_Frame.csh "$M_SAFE" "$M_EOF" "$A_SAFE" "$A_EOF" "$CONFIG" "$POL" "$PARALLEL"
echo "== END $(date '+%F %T') =="
