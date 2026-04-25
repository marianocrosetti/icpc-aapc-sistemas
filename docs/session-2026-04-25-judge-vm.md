# Sesión 2026-04-25 (follow-up) — Creación de la VM judge

Continuación de [`session-2026-04-25.md`](./session-2026-04-25.md). En esta vuelta sólo ejecutamos el paso 2 del README: la VM auto-judge.

## 1. Estado previo

- VM main `boca-main` ya corriendo en `us-central1-a` (IP interna `10.128.0.2`, externa `34.57.222.36`).
- `scripts/02-setup-judge-vm.sh` figuraba en la bitácora previa como "pendiente de ejecutar", pero el archivo no existía aún en disco.

## 2. Script `02-setup-judge-vm.sh`

Lo escribí siguiendo el mismo patrón idempotente que `01-setup-main-vm.sh`:

- Param defaults: `VM_NAME=boca-judge-1`, `MACHINE_TYPE=c2d-highcpu-2`, `IMAGE_FAMILY=ubuntu-2204-lts` (la **normal**, no la minimal — el README es explícito), `DISK_SIZE_GB=20`, `DISK_TYPE=pd-balanced`.
- Setea proyecto activo, crea la VM si no existe, y promueve la IP privada a estática (`boca-judge-1-internal`). No reserva IP externa: el judge sólo necesita salida a internet para `apt`, no expone HTTP.
- Imprime al final la IP interna del main como referencia para el paso de instalación BOCA en la judge (la BD apunta a `10.128.0.2`).
- Diseñado para correr varias veces y/o crear más judges con `VM_NAME=boca-judge-2 ./02-setup-judge-vm.sh`.

## 3. Ejecución

```
./scripts/02-setup-judge-vm.sh
```

Resultado:

| Parámetro | Valor |
|---|---|
| Nombre | `boca-judge-1` |
| Tipo | `c2d-highcpu-2` (2 vCPU / 4 GB) |
| SO | Ubuntu 22.04 LTS (`ubuntu-2204-lts`, normal) |
| Disco | 20 GB `pd-balanced` |
| Zona | `us-central1-a` |
| IP interna | `10.128.0.3` (static `boca-judge-1-internal`) |
| IP externa | `136.111.54.205` (efímera) |

Mismo warning benigno que con la main ("disk size 20 GB > image size 10 GB"); Ubuntu 22 redimensiona automáticamente al primer boot.

## 4. Pendientes inmediatos (dentro de la VM judge)

```bash
gcloud compute ssh boca-judge-1 --zone=us-central1-a --project=aapc-sistemas-tap

sudo su
apt update && apt dist-upgrade -y
add-apt-repository ppa:icpc-latam/maratona-linux
apt update
apt install boca
  # Ubicación BD: 10.128.0.2
  # Password: la usada en main
  # Crear nueva BD: NO
sudo boca-createjail
```

Después tocan los pasos del README §3 (conectar main ↔ judge): `listen_addresses='*'` en `postgresql.conf`, regla `iptables` para tcp:5432 desde `10.128.0.3`, línea `host all all 10.128.0.3/32 md5` en `pg_hba.conf` de main, y verificar `dbhost`/password en `/var/www/boca/src/private/conf.php` del judge.
