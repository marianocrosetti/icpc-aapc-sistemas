#!/usr/bin/env bash
# Paso 2 del README: crea una VM judge (auto-judge) y le fija la IP privada.
# Idempotente: se puede re-correr sin romper recursos existentes.
#
# Pre-requisitos:
#   - VM main (con BD) ya creada (ver 01-setup-main-vm.sh).
#   - gcloud autenticado con la cuenta dueña del proyecto.
#
# Uso:
#   ./02-setup-judge-vm.sh                  # crea boca-judge-1
#   VM_NAME=boca-judge-2 ./02-setup-judge-vm.sh

set -euo pipefail

# ---------- Parámetros ----------
PROJECT_ID="${PROJECT_ID:-aapc-sistemas-tap}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-boca-judge-1}"
MACHINE_TYPE="${MACHINE_TYPE:-c2d-highcpu-2}"   # 2 vCPU / 4 GB
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}" # NORMAL, no la minimal
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
DISK_SIZE_GB="${DISK_SIZE_GB:-20}"
DISK_TYPE="${DISK_TYPE:-pd-balanced}"
INTERNAL_ADDR_NAME="${INTERNAL_ADDR_NAME:-${VM_NAME}-internal}"

# ---------- Helpers ----------
log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }

# ---------- 1) Proyecto activo ----------
log "Seteando proyecto activo: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

# ---------- 2) Crear VM ----------
if gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "VM $VM_NAME ya existe, salteando creación"
else
  log "Creando VM $VM_NAME ($MACHINE_TYPE, $IMAGE_FAMILY, ${DISK_SIZE_GB}GB $DISK_TYPE)"
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --image-family="$IMAGE_FAMILY" \
    --image-project="$IMAGE_PROJECT" \
    --boot-disk-size="${DISK_SIZE_GB}GB" \
    --boot-disk-type="$DISK_TYPE"
fi

# ---------- 3) Promover IP privada a static ----------
INTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format='value(networkInterfaces[0].networkIP)')
EXTERNAL_IP=$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" --project="$PROJECT_ID" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')

if gcloud compute addresses describe "$INTERNAL_ADDR_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "IP interna $INTERNAL_ADDR_NAME ya reservada"
else
  log "Reservando IP interna estática $INTERNAL_IP como $INTERNAL_ADDR_NAME"
  gcloud compute addresses create "$INTERNAL_ADDR_NAME" \
    --region="$REGION" \
    --subnet=default \
    --addresses="$INTERNAL_IP" \
    --purpose=GCE_ENDPOINT \
    --project="$PROJECT_ID"
fi

# ---------- 4) IP privada de la VM main (para referencia / paso 3) ----------
MAIN_INTERNAL_IP=$(gcloud compute addresses describe boca-main-internal \
  --region="$REGION" --project="$PROJECT_ID" \
  --format='value(address)' 2>/dev/null || echo "(no encontrada)")

# ---------- Resumen ----------
log "Listo"
cat <<EOF

  Proyecto:           $PROJECT_ID
  VM:                 $VM_NAME ($MACHINE_TYPE, $ZONE)
  IP interna judge:   $INTERNAL_IP   (static: $INTERNAL_ADDR_NAME)
  IP externa judge:   $EXTERNAL_IP   (efímera, sólo para apt/internet)
  IP interna main:    $MAIN_INTERNAL_IP

  SSH:
    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT_ID

  Próximos pasos (dentro de la VM judge):
    sudo su
    apt update && apt dist-upgrade -y
    add-apt-repository ppa:icpc-latam/maratona-linux
    apt update
    apt install boca
      # Ubicación BD: $MAIN_INTERNAL_IP
      # Password: la usada en main
      # Crear nueva BD: NO
    sudo boca-createjail

EOF
