#!/usr/bin/env bash
# Enciende la infraestructura del contest y deja los autojudges corriendo.
#
# Existe porque el paso más fácil de olvidar no es prender las VMs (eso se ve en la consola)
# sino arrancar `boca-autojudge`: NO es un servicio de systemd, no arranca al bootear, y si
# falta los envíos quedan en `openrun` sin ningún error visible en la web.
#
# Idempotente: se puede correr varias veces. Si algo ya está prendido o corriendo, no lo toca.
#
# La arquitectura es: UNA main (web + base, no juzga nunca) y N máquinas judge que corren el
# autojudge y se conectan a la base de la main por red. La main no corre autojudge ni siquiera
# como respaldo: juzgar es la parte que consume CPU y no querés que compita con la web justo
# cuando todos los equipos están enviando.
#
# Uso:
#   ./04-start-contest.sh                            # main + boca-judge-1
#   JUDGES="boca-judge-1 boca-judge-2" ./04-start-contest.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-aapc-sistemas-tap}"
ZONE="${ZONE:-us-central1-a}"
MAIN_VM="${MAIN_VM:-boca-main}"
# Máquinas judge. Se pueden agregar más: cada una se crea con 02-setup-judge-vm.sh.
JUDGES="${JUDGES-boca-judge-1}"

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
#
# Dos sutilezas, las dos aprendidas a golpes:
#
# 1) El que juzga de verdad es `php autojudging.php`, hijo del wrapper `boca-autojudge`. Hay que
#    chequear el worker y no sólo el wrapper: si alguien mató el wrapper con pkill, el worker
#    queda huérfano (reparentado a init) y SIGUE juzgando. Arrancar otro encima daría dos
#    autojudges compitiendo por el mismo trabajo.
#
# 2) Se usa `pgrep -x -f` (match EXACTO de la línea de comandos completa). Con `pgrep -f` a secas
#    el patrón matchea el propio `bash -c` que ejecuta este bloque, porque el texto del script
#    contiene esos nombres: da falsos positivos. Y con `pkill -f` es peor, porque mata su propia
#    sesión de SSH y aborta con "return code [255]", como si la VM se hubiera caído.
start_autojudge() {
  local vm="$1"
  gssh "$vm" '
    if ! sudo test -e /bocajail; then
      echo "  *** falta el jail: correr sudo boca-createjail (tarda 5-10 min) ***"
      exit 1
    fi
    if sudo pgrep -x -f "php autojudging.php" >/dev/null 2>&1; then
      if sudo pgrep -x -f "/bin/bash /usr/sbin/boca-autojudge" >/dev/null 2>&1; then
        echo "  autojudge: ya estaba corriendo"
      else
        echo "  autojudge: ya corría un worker php HUERFANO (sin wrapper); no arranco otro"
        echo "             para reiniciarlo limpio: sudo pkill -x -f \"php autojudging.php\""
      fi
    else
      sudo bash -c "nohup setsid boca-autojudge > /tmp/autojudge.log 2>&1 < /dev/null &"
      sleep 8
      if sudo pgrep -x -f "php autojudging.php" >/dev/null 2>&1; then
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

if [[ -z "${JUDGES// /}" ]]; then
  warn "No hay máquinas judge en JUDGES, y la main no juzga por diseño: nadie evaluaría los"
  warn "envíos y quedarían todos en 'openrun'. Creá una con 02-setup-judge-vm.sh."
  exit 1
fi

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

for j in $JUDGES; do
  log "Autojudge en $j"
  start_autojudge "$j"
done

# La main no debería estar juzgando. Si quedó un autojudge suelto ahí (por ejemplo de una prueba),
# avisar: no es fatal, pero le come CPU a la web y confunde el diagnóstico.
log "Verificando que $MAIN_VM NO esté juzgando"
gssh "$MAIN_VM" '
  N=$(sudo pgrep -x -f "php autojudging.php" | wc -l)
  if [ "$N" -gt 0 ]; then
    echo "  ! hay $N autojudge(s) corriendo en la main, que no debería juzgar."
    echo "  ! para apagarlo:"
    echo "  !   sudo pkill -x -f \"/bin/bash /usr/sbin/boca-autojudge\""
    echo "  !   sudo pkill -x -f \"php autojudging.php\""
  else
    echo "  OK: la main no juzga, solo web + base"
  fi
'

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
