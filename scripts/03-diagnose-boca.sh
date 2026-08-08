#!/usr/bin/env bash
# Diagnóstico read-only del estado de un BOCA corriendo en una VM de GCP.
# No modifica nada: sirve para saber en qué estado quedó el sistema antes de tocarlo.
#
# Responde las preguntas que más cuesta contestar a mano:
#   - ¿Está BOCA instalado y corriendo?
#   - ¿Existe el jail? ¿Está corriendo el autojudge? (las dos causas de "envío colgado")
#   - ¿Qué contest, usuarios, problemas y runs hay en la base?
#   - ¿Coinciden las extensiones de langtable con las carpetas de los paquetes cargados?
#
# Uso:
#   ./03-diagnose-boca.sh                      # diagnostica boca-main
#   VM_NAME=boca-judge-1 ./03-diagnose-boca.sh

set -euo pipefail

PROJECT_ID="${PROJECT_ID:-aapc-sistemas-tap}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-boca-main}"
MAIN_VM="${MAIN_VM:-boca-main}"
CONTEST="${CONTEST:-1}"

# La main no juzga por diseño (web + base solamente), así que ahí "no corre el autojudge" es el
# estado correcto y no un problema. En las judges es lo contrario.
if [[ "$VM_NAME" == "$MAIN_VM" ]]; then
  EXPECTS_AUTOJUDGE="${EXPECTS_AUTOJUDGE:-false}"
else
  EXPECTS_AUTOJUDGE="${EXPECTS_AUTOJUDGE:-true}"
fi

log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }

log "Diagnosticando $VM_NAME (zona $ZONE, proyecto $PROJECT_ID, contest $CONTEST)"

STATUS=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
  --format='value(status)' 2>/dev/null || echo "NO_EXISTE")
echo "  estado de la VM: $STATUS"
if [[ "$STATUS" != "RUNNING" ]]; then
  echo "  La VM no está corriendo. Arrancala con:"
  echo "    gcloud compute instances start $VM_NAME --zone=$ZONE --project=$PROJECT_ID"
  exit 1
fi

# Todo el diagnóstico va en un solo SSH para no pagar el handshake varias veces.
# `cd /tmp` evita el ruido de 'could not change directory' al usar sudo -u postgres.
gcloud compute ssh "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" \
  --strict-host-key-checking=no --command="
set -u
CONTEST=$CONTEST
EXPECTS_AUTOJUDGE=$EXPECTS_AUTOJUDGE
cd /tmp

echo '=== SISTEMA ==='
lsb_release -ds
dpkg -l 2>/dev/null | awk '/^ii  (boca|maratona)/ {print \"  \" \$2 \" \" \$3}'
echo \"  postgresql: \$(systemctl is-active postgresql 2>&1)\"
echo \"  apache2:    \$(systemctl is-active apache2 2>&1)\"
echo \"  web local:  \$(curl -s -o /dev/null -w '%{http_code}' http://localhost/boca/ 2>/dev/null)\"

echo
echo '=== AUTOJUDGE (las dos causas de envios colgados) ==='
if [ -e /bocajail ]; then
  echo \"  jail:      OK (\$(sudo du -sh /home/bocajail 2>/dev/null | cut -f1))\"
else
  echo '  jail:      *** NO EXISTE *** -> correr: sudo boca-createjail'
fi
if mount | grep -q /home/bocajail; then
  echo \"  montajes:  \$(mount | grep -o '/home/bocajail[^ ]*' | tr '\n' ' ')\"
fi
# El que juzga de verdad es 'php autojudging.php'; 'boca-autojudge' es solo el wrapper de bash.
# Hay que mirar los dos: si matás el wrapper con pkill, el worker php queda huerfano y SIGUE
# juzgando, con lo cual mirar solo el wrapper da un falso 'no corre'.
#
# Se usa 'pgrep -x -f' (match EXACTO de la linea de comandos completa) porque este script
# menciona esos nombres en sus propios mensajes: con 'pgrep -f' a secas se matchea a si mismo y
# reporta procesos que no existen.
# 'pgrep -c' imprime 0 y ADEMAS sale con codigo 1 cuando no encuentra nada, asi que un
# '|| echo 0' duplicaria la salida. Contar lineas siempre sale bien.
WRAPPER=\$(sudo pgrep -x -f '/bin/bash /usr/sbin/boca-autojudge' 2>/dev/null | wc -l)
WORKER=\$(sudo pgrep -x -f 'php autojudging.php' 2>/dev/null | wc -l)
echo \"  wrapper (boca-autojudge): \$WRAPPER   worker (php autojudging.php): \$WORKER\"
if [ \"\$WORKER\" -gt 0 ] && [ \"\$WRAPPER\" -gt 0 ]; then
  if [ \"\$EXPECTS_AUTOJUDGE\" = true ]; then
    echo '  proceso:   OK (corriendo)'
  else
    echo '  proceso:   *** ESTA JUZGANDO Y NO DEBERIA *** (esta maquina es solo web + base)'
    echo \"             sudo pkill -x -f '/bin/bash /usr/sbin/boca-autojudge'\"
    echo \"             sudo pkill -x -f 'php autojudging.php'\"
  fi
elif [ \"\$WORKER\" -gt 0 ]; then
  echo '  proceso:   worker php HUERFANO (sin wrapper): sigue juzgando, pero no se reinicia solo'
  echo \"             para detenerlo de verdad: sudo pkill -x -f 'php autojudging.php'\"
elif [ \"\$WRAPPER\" -gt 0 ]; then
  echo '  proceso:   wrapper vivo pero sin worker php: revisar /tmp/autojudge.log'
elif [ \"\$EXPECTS_AUTOJUDGE\" = true ]; then
  echo '  proceso:   *** NO CORRE *** -> correr:'
  echo \"             sudo bash -c 'nohup setsid boca-autojudge > /tmp/autojudge.log 2>&1 < /dev/null &'\"
else
  echo '  proceso:   no corre, y esta bien: esta maquina es solo web + base, no juzga'
fi
echo '  (recordar: boca-autojudge NO es un servicio de systemd, no sobrevive un reboot)'
echo '  compiladores en el jail:'
# Hay que preguntar DENTRO del chroot: varios binarios son symlinks a /etc/alternatives/...,
# que desde el host resuelven contra el root equivocado y parecen no existir.
for b in gcc g++ javac java kotlinc python3 python2; do
  printf '    %-9s %s\n' \"\$b\" \"\$(sudo chroot /home/bocajail which \$b 2>/dev/null || echo NO)\"
done

echo
echo '=== LIMITES DE UPLOAD DE PHP (solo importa el de fpm) ==='
for f in /etc/php/*/fpm/php.ini; do
  [ -f \"\$f\" ] && echo \"  \$f: \$(grep -hE '^\s*(upload_max_filesize|post_max_size)' \"\$f\" | tr '\n' ' ')\"
done

echo
echo '=== CONTESTS ==='
sudo -u postgres psql -d bocadb -P pager=off -c \
  'select contestnumber, contestname, contestactive from contesttable order by 1;' 2>/dev/null

echo '=== USUARIOS por tipo ==='
sudo -u postgres psql -d bocadb -P pager=off -c \
  \"select contestnumber, usertype, count(*) from usertable group by 1,2 order by 1,2;\" 2>/dev/null

echo '=== PROBLEMAS ==='
sudo -u postgres psql -d bocadb -P pager=off -c \
  \"select problemnumber, problemname, problemfullname, probleminputfilename
      from problemtable where contestnumber=\$CONTEST order by problemnumber;\" 2>/dev/null

echo '=== LENGUAJES (la extension debe matchear las carpetas del paquete) ==='
sudo -u postgres psql -d bocadb -P pager=off -c \
  \"select langnumber, langname, langextension
      from langtable where contestnumber=\$CONTEST order by langnumber;\" 2>/dev/null

echo '=== RUNS (openrun = sin juzgar; autoip/autoanswer no vacios = lo juzgo el autojudge) ==='
sudo -u postgres psql -d bocadb -P pager=off -c \
  \"select r.runnumber, u.username, p.problemname, l.langname, l.langextension,
          r.runstatus, a.runanswer as veredicto, r.runjudge, r.runfilename,
          r.autoip, r.autoanswer, to_timestamp(r.rundate) as enviado
     from runtable r
     left join usertable    u on (u.contestnumber=r.contestnumber and u.usernumber=r.usernumber
                                  and u.usersitenumber=r.runsitenumber)
     left join problemtable p on (p.contestnumber=r.contestnumber and p.problemnumber=r.runproblem)
     left join langtable    l on (l.contestnumber=r.contestnumber and l.langnumber=r.runlangnumber)
     left join answertable  a on (a.contestnumber=r.contestnumber and a.answernumber=r.runanswer)
    order by r.rundate;\" 2>/dev/null

echo '=== CARPETAS DE LENGUAJE DE CADA PAQUETE CARGADO ==='
echo '(comparar con langextension de arriba: si no matchean, el autojudge falla)'
for PN in \$(sudo -u postgres psql -d bocadb -tAc \
      \"select problemnumber from problemtable
         where contestnumber=\$CONTEST and probleminputfile is not null order by problemnumber;\" 2>/dev/null); do
  OID=\$(sudo -u postgres psql -d bocadb -tAc \
    \"select probleminputfile from problemtable where contestnumber=\$CONTEST and problemnumber=\$PN;\" 2>/dev/null | tr -d ' ')
  NAME=\$(sudo -u postgres psql -d bocadb -tAc \
    \"select problemname from problemtable where contestnumber=\$CONTEST and problemnumber=\$PN;\" 2>/dev/null | tr -d ' ')
  sudo rm -f /tmp/_diag_pkg.zip
  sudo -u postgres psql -d bocadb -c \"\\lo_export \$OID /tmp/_diag_pkg.zip\" >/dev/null 2>&1 || continue
  sudo chmod 644 /tmp/_diag_pkg.zip 2>/dev/null
  echo \"  -- problema \$NAME (problemnumber \$PN)\"
  python3 -c \"
import zipfile
n = zipfile.ZipFile('/tmp/_diag_pkg.zip').namelist()
for d in ('limits','run','compare','compile','tests'):
    got = sorted(x.split('/',1)[1] for x in n
                 if x.startswith(d+'/') and x.count('/')==1 and not x.endswith('/'))
    print('       %-9s %s' % (d+'/:', got))
print('       %-9s %d' % ('tests:', sum(1 for x in n if x.startswith('input/') and not x.endswith('/'))))
\" 2>/dev/null
  sudo rm -f /tmp/_diag_pkg.zip
done
"
