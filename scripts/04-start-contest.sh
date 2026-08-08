#!/usr/bin/env bash
# Enciende la infraestructura del contest y deja los autojudges corriendo.
#
# Existe porque el paso más fácil de olvidar no es prender las VMs (eso se ve en la consola)
# sino arrancar `boca-autojudge`: NO es un servicio de systemd, no arranca al bootear, y si
# falta los envíos quedan en `openrun` sin ningún error visible en la web.
#
# Idempotente: se puede correr varias veces. Si algo ya está prendido o corriendo, no lo toca.
#
# Uso:
#   ./04-start-contest.sh                            # main + boca-judge-1
#   JUDGES="boca-judge-1 boca-judge-2" ./04-start-contest.sh
#   JUDGES="" ./04-start-contest.sh                  # solo la main, con su autojudge local

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-aapc-sistemas-tap}"
ZONE="${ZONE:-us-central1-a}"
MAIN_VM="${MAIN_VM:-boca-main}"
# Máquinas judge dedicadas. Vacío = el autojudge corre en la main.
JUDGES="${JUDGES-boca-judge-1}"
# Correr también un autojudge en la main, además de los judges dedicados.
# Por defecto no, para no competir con los judges dedicados por el mismo trabajo.
AUTOJUDGE_ON_MAIN="${AUTOJUDGE_ON_MAIN:-false}"

log()  { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$*"; }

gssh() {
  local vm="$1"; shift
  gcloud compute ssh "$vm" --zone="$ZONE" --project="$PROJECT_ID" \
    --strict-host-key-checking=no --command="$*"
}

start_vm() {
  local vm="$1"
  local status
  status=$(gcloud compute instances describe "$vm" --zone="$ZONE" --project="$PROJECT_ID" \
    --format='value(status)' 2>/dev/null || echo "NO_EXISTE")
  case "$status" in
    RUNNING)   echo "  $vm: ya estaba corriendo" ;;
    NO_EXISTE) echo "  $vm: NO EXISTE (crear con 01-setup-main-vm.sh / 02-setup-judge-vm.sh)"; return 1 ;;
    *)
      echo "  $vm: estaba en $status, arrancando..."
      gcloud compute instances start "$vm" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null
      echo "  $vm: arrancada"
      ;;
  esac
}

# Espera a que la VM acepte SSH. Recién booteada suele tardar unos segundos.
wait_for_ssh() {
  local vm="$1"
  for _ in $(seq 1 20); do
    if gssh "$vm" 'true' >/dev/null 2>&1; then return 0; fi
    sleep 5
  done
  warn "$vm: no responde SSH después de 100s"
  return 1
}

# Arranca boca-autojudge si no está corriendo.
# El patrón 'boca-auto[j]udge' evita que pgrep/pkill matcheen su propio comando: sin los
# corchetes, el `bash -c` que ejecuta esto contiene el string y se auto-matchea (y con pkill
# eso mata la propia sesión de SSH).
start_autojudge() {
  local vm="$1"
  gssh "$vm" '
    if ! sudo test -e /bocajail; then
      echo "  *** falta el jail: correr sudo boca-createjail (tarda 5-10 min) ***"
      exit 1
    fi
    if sudo pgrep -f "boca-auto[j]udge" >/dev/null 2>&1; then
      echo "  autojudge: ya estaba corriendo"
    else
      sudo bash -c "nohup setsid boca-autojudge > /tmp/autojudge.log 2>&1 < /dev/null &"
      sleep 8
      if sudo pgrep -f "boca-auto[j]udge" >/dev/null 2>&1; then
        echo "  autojudge: arrancado"
      else
        echo "  *** el autojudge no quedó corriendo, ver /tmp/autojudge.log ***"
        sudo tail -5 /tmp/autojudge.log
        exit 1
      fi
    fi
  '
}

# ---------------------------------------------------------------- main

log "Encendiendo VMs"
start_vm "$MAIN_VM"
for j in $JUDGES; do start_vm "$j"; done

log "Esperando SSH"
wait_for_ssh "$MAIN_VM" && echo "  $MAIN_VM: SSH OK"
for j in $JUDGES; do wait_for_ssh "$j" && echo "  $j: SSH OK"; done

log "Verificando servicios en $MAIN_VM"
gssh "$MAIN_VM" '
  echo "  postgresql: $(systemctl is-active postgresql)"
  echo "  apache2:    $(systemctl is-active apache2)"
  echo "  web:        HTTP $(curl -s -o /dev/null -w "%{http_code}" http://localhost/boca/)"
'

if [[ -n "$JUDGES" ]]; then
  for j in $JUDGES; do
    log "Autojudge en $j (judge dedicado)"
    start_autojudge "$j"
  done
  if [[ "$AUTOJUDGE_ON_MAIN" == "true" ]]; then
    log "Autojudge en $MAIN_VM (además de los dedicados)"
    start_autojudge "$MAIN_VM"
  fi
else
  log "Autojudge en $MAIN_VM (no hay judges dedicados)"
  start_autojudge "$MAIN_VM"
fi

EXTERNAL_IP=$(gcloud compute instances describe "$MAIN_VM" --zone="$ZONE" --project="$PROJECT_ID" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || echo '?')

log "Listo"
cat <<EOF

  Web:     http://$EXTERNAL_IP/boca/   (HTTP, no HTTPS: certbot no está configurado)
  Judges:  ${JUDGES:-(ninguno dedicado; juzga la main)}

  Verificar todo:   ./03-diagnose-boca.sh
  Apagar al final:  ./05-stop-contest.sh

  Recordatorio: los autojudges NO sobreviven un reboot. Si reiniciás una VM, volvé a correr
  este script.

EOF
