#!/usr/bin/env bash
# Apaga la infraestructura del contest.
#
# Apagar las VMs corta el costo de vCPU y RAM, que es el grande. Los discos y la IP externa
# estática se siguen pagando igual (ver docs/session-2026-08-08.md, sección de costos), pero eso
# es del orden de USD 20/mes contra los ~USD 400/mes de un n2-standard-16 olvidado prendido.
#
# Uso:
#   ./05-stop-contest.sh
#   JUDGES="boca-judge-1 boca-judge-2" ./05-stop-contest.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-aapc-sistemas-tap}"
ZONE="${ZONE:-us-central1-a}"
MAIN_VM="${MAIN_VM:-boca-main}"
JUDGES="${JUDGES-boca-judge-1}"

log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }

stop_vm() {
  local vm="$1"
  local status
  status=$(gcloud compute instances describe "$vm" --zone="$ZONE" --project="$PROJECT_ID" \
    --format='value(status)' 2>/dev/null || echo "NO_EXISTE")
  case "$status" in
    TERMINATED) echo "  $vm: ya estaba apagada" ;;
    NO_EXISTE)  echo "  $vm: no existe, nada que hacer" ;;
    *)
      echo "  $vm: estaba en $status, apagando..."
      gcloud compute instances stop "$vm" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null
      echo "  $vm: apagada"
      ;;
  esac
}

log "Apagando VMs"
for j in $JUDGES; do stop_vm "$j"; done
stop_vm "$MAIN_VM"

log "Estado final"
gcloud compute instances list --project="$PROJECT_ID" \
  --format='table(name,zone.basename(),machineType.basename(),status)'

cat <<'EOF'

  Los discos y la IP externa estática se siguen facturando con las VMs apagadas.
  Para volver a levantar todo:  ./04-start-contest.sh

EOF
