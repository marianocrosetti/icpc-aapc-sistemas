#!/usr/bin/env bash
# Paso 1 del README: crea la VM "main" (web server + BD) y deja las IPs fijas.
# Idempotente: se puede re-correr sin romper recursos existentes.
#
# Pre-requisitos:
#   - gcloud autenticado con la cuenta dueña del proyecto.
#   - Billing habilitado en el proyecto.
#   - Términos de servicio de GCP aceptados para la cuenta.

set -euo pipefail

# ---------- Parámetros ----------
PROJECT_ID="${PROJECT_ID:-aapc-sistemas-tap}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
VM_NAME="${VM_NAME:-boca-main}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-medium}"        # prueba real: 16 vCPU / 32 GB (e.g. n2-standard-16)
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2204-lts}"
IMAGE_PROJECT="${IMAGE_PROJECT:-ubuntu-os-cloud}"
DISK_SIZE_GB="${DISK_SIZE_GB:-70}"
DISK_TYPE="${DISK_TYPE:-pd-ssd}"
HTTP_TAG="${HTTP_TAG:-http-server}"
INTERNAL_ADDR_NAME="${INTERNAL_ADDR_NAME:-${VM_NAME}-internal}"
EXTERNAL_ADDR_NAME="${EXTERNAL_ADDR_NAME:-${VM_NAME}-external}"

# ---------- Helpers ----------
log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }

# ---------- 1) Proyecto activo ----------
log "Seteando proyecto activo: $PROJECT_ID"
gcloud config set project "$PROJECT_ID" >/dev/null

# ---------- 2) Verificar billing ----------
log "Verificando billing"
billing_enabled=$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)')
if [[ "$billing_enabled" != "True" ]]; then
  echo "ERROR: billing no está habilitado en $PROJECT_ID. Vinculá una billing account y reintentá." >&2
  exit 1
fi

# ---------- 3) Habilitar Compute Engine API ----------
log "Habilitando Compute Engine API (no-op si ya está)"
gcloud services enable compute.googleapis.com --project="$PROJECT_ID"

# ---------- 4) Crear VM ----------
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
    --boot-disk-type="$DISK_TYPE" \
    --tags="$HTTP_TAG"
fi

# ---------- 5) Promover IPs a static ----------
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

if gcloud compute addresses describe "$EXTERNAL_ADDR_NAME" --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "IP externa $EXTERNAL_ADDR_NAME ya reservada"
else
  log "Reservando IP externa estática $EXTERNAL_IP como $EXTERNAL_ADDR_NAME"
  gcloud compute addresses create "$EXTERNAL_ADDR_NAME" \
    --region="$REGION" \
    --addresses="$EXTERNAL_IP" \
    --project="$PROJECT_ID"
fi

# ---------- 6) Firewall HTTP 80 ----------
if gcloud compute firewall-rules describe default-allow-http --project="$PROJECT_ID" >/dev/null 2>&1; then
  log "Regla default-allow-http ya existe"
else
  log "Creando regla firewall default-allow-http (tcp:80 -> tag $HTTP_TAG)"
  gcloud compute firewall-rules create default-allow-http \
    --project="$PROJECT_ID" \
    --network=default \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags="$HTTP_TAG"
fi

# ---------- Resumen ----------
log "Listo"
cat <<EOF

  Proyecto:      $PROJECT_ID
  VM:            $VM_NAME ($MACHINE_TYPE, $ZONE)
  IP interna:    $INTERNAL_IP   (static: $INTERNAL_ADDR_NAME)
  IP externa:    $EXTERNAL_IP   (static: $EXTERNAL_ADDR_NAME)
  HTTP 80:       abierto vía tag '$HTTP_TAG'

  SSH:
    gcloud compute ssh $VM_NAME --zone=$ZONE --project=$PROJECT_ID

EOF

# ---------- Operaciones manuales (no se ejecutan en el flujo) ----------
#
# Reset (hard reboot) de la VM:
#   gcloud compute instances reset boca-main \
#     --zone us-central1-a --project aapc-sistemas-tap
#
# Stop + start (reboot más limpio):
#   gcloud compute instances stop  boca-main --zone us-central1-a --project aapc-sistemas-tap
#   gcloud compute instances start boca-main --zone us-central1-a --project aapc-sistemas-tap
