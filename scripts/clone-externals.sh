#!/usr/bin/env bash
# Clona los repos externos (no versionados acá) dentro de externals/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXTERNALS_DIR="$REPO_ROOT/externals"

# repo_url  carpeta_destino
EXTERNALS=(
  "git@github.com:elsantodel90/icpc-latam-user-mgmt.git icpc-latam-user-mgmt"
)

mkdir -p "$EXTERNALS_DIR"

for entry in "${EXTERNALS[@]}"; do
  read -r url dir <<<"$entry"
  dest="$EXTERNALS_DIR/$dir"
  if [ -d "$dest/.git" ]; then
    echo "[skip] $dir ya existe en externals/ (para actualizar: git -C externals/$dir pull)"
  else
    echo "[clone] $url -> externals/$dir"
    git clone "$url" "$dest"
  fi
done

echo "Listo."
