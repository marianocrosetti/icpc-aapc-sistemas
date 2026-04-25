#!/usr/bin/env bash
# Genera los .zip de cada problema (formato BOCA) listos para subir al juez.
#
# Pipeline por cada problema:
#   1. `box build` para producir build/tests/<n>/<i>.in y <i>.sol.
#   2. `mpkg.py <letra> --problem=problems/<carpeta> --output=packages`.
#
# Idempotente: re-correrlo sólo regenera lo que box considere desactualizado.
# Para forzar todo desde cero: borrar los `build/` antes (`box clean` por problema).
#
# Pre-requisitos:
#   - python3 con paquete `click` (usado por mpkg.py).
#   - g++ con soporte de <bits/stdc++.h>. En macOS Apple-clang NO sirve;
#     instalá GCC con `brew install gcc` y el script usa `g++-15` automáticamente.
#   - javac, java, python3 (compilan/corren reference solutions).
#   - kotlinc opcional (algunas soluciones .kt fallan sin él, pero no bloquea
#     mientras haya una solución good en C++/Java/Python que compile).
#
# Notas:
#   - pdflatex no es necesario: mpkg.py usa el PDF combinado en print/.
#   - El paquete K.zip (color-queries) puede pesar ~67MB. BOCA por defecto
#     limita upload PHP a ~2MB; ver paso "Subir problemas pesados" del README
#     principal y subir php upload_max_filesize/post_max_size a 100M.

set -euo pipefail

# ---------- Parámetros ----------
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROBLEMSET_DIR="${PROBLEMSET_DIR:-$(cd "$SCRIPT_DIR/../.." && pwd)/tap-2025-problemset}"
OUTPUT_DIR="${OUTPUT_DIR:-$PROBLEMSET_DIR/packages}"

# Letra -> carpeta del problema (mapeo del contest 2025, sacado de contest/tap.tex)
PROBLEMS=(
  "A:tap"
  "B:ksumas"
  "C:semifijos"
  "D:brisca"
  "E:teg"
  "F:cabra"
  "G:caramelos"
  "H:divisores"
  "I:haz-compitas"
  "J:stacks"
  "K:color-queries"
  "L:barquitos"
  "M:peregrinando"
  "N:rebotando3"
)

# ---------- Helpers ----------
log() { printf '\n\033[1;34m▸ %s\033[0m\n' "$*"; }
err() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; }

# ---------- Detección de compiladores ----------
# Box lee CXX/CC del entorno; en macOS preferimos brew gcc-15 porque Apple
# clang no incluye <bits/stdc++.h>.
if [[ -z "${CXX:-}" ]] && command -v g++-15 >/dev/null 2>&1; then
  export CXX=g++-15
fi
if [[ -z "${CC:-}" ]] && command -v gcc-15 >/dev/null 2>&1; then
  export CC=gcc-15
fi
: "${CXX:=g++}"
: "${CC:=gcc}"

# ---------- 0) Validaciones ----------
if [[ ! -d "$PROBLEMSET_DIR" ]]; then
  err "PROBLEMSET_DIR no existe: $PROBLEMSET_DIR"
  echo "  Cloná el repo: git clone git@github.com:elsantodel90/tap-2025-problemset.git \"$PROBLEMSET_DIR\"" >&2
  exit 1
fi
if [[ ! -f "$PROBLEMSET_DIR/mpkg.py" ]]; then
  err "No encuentro $PROBLEMSET_DIR/mpkg.py"
  exit 1
fi
if ! python3 -c 'import click' 2>/dev/null; then
  err "Falta el paquete python 'click' (lo usa mpkg.py)"
  echo "  Instalalo con: pip3 install click" >&2
  exit 1
fi

BOX="$PROBLEMSET_DIR/problems/.box/bin/box"

# ---------- 1) Submódulo box ----------
if [[ ! -x "$BOX" ]]; then
  log "Inicializando submódulo box (problems/.box)"
  (cd "$PROBLEMSET_DIR" && git submodule update --init --recursive)
fi

mkdir -p "$OUTPUT_DIR"
log "Output dir: $OUTPUT_DIR"
log "Compilers: CXX=$CXX  CC=$CC"

# ---------- 2) box build por problema ----------
declare -a FAILED=()
for entry in "${PROBLEMS[@]}"; do
  letter="${entry%%:*}"
  folder="${entry##*:}"
  problem_dir="$PROBLEMSET_DIR/problems/$folder"

  if [[ ! -d "$problem_dir" ]]; then
    err "[$letter] $folder — carpeta no existe, salteando"
    FAILED+=("$letter ($folder)")
    continue
  fi

  log "[$letter] $folder — box build"
  if (cd "$problem_dir" && CXX="$CXX" CC="$CC" "$BOX" build) >/dev/null 2>&1; then
    :
  else
    # box puede salir != 0 por warnings (pdflatex faltante, etc); chequeamos
    # si terminó produciendo .in/.sol coherentes en lugar de fiarnos del exit.
    :
  fi

  in_count=$(find "$problem_dir/build/tests" -name "*.in"  2>/dev/null | wc -l | xargs)
  sol_count=$(find "$problem_dir/build/tests" -name "*.sol" 2>/dev/null | wc -l | xargs)
  if [[ "$in_count" == "0" || "$sol_count" == "0" || "$in_count" != "$sol_count" ]]; then
    err "[$letter] $folder — build incompleto (in=$in_count, sol=$sol_count)"
    FAILED+=("$letter ($folder): in=$in_count sol=$sol_count")
    continue
  fi
  printf '   %s tests OK (in=%s sol=%s)\n' "$letter" "$in_count" "$sol_count"
done

# ---------- 3) Empaquetado con mpkg.py ----------
for entry in "${PROBLEMS[@]}"; do
  letter="${entry%%:*}"
  folder="${entry##*:}"
  problem_dir="$PROBLEMSET_DIR/problems/$folder"

  in_count=$(find "$problem_dir/build/tests" -name "*.in"  2>/dev/null | wc -l | xargs)
  sol_count=$(find "$problem_dir/build/tests" -name "*.sol" 2>/dev/null | wc -l | xargs)
  if [[ "$in_count" == "0" || "$sol_count" == "0" || "$in_count" != "$sol_count" ]]; then
    continue
  fi

  log "[$letter] empaquetando -> $OUTPUT_DIR/$letter.zip"
  (cd "$PROBLEMSET_DIR" && python3 mpkg.py "$letter" \
    --problem="problems/$folder" \
    --output="$OUTPUT_DIR")
done

# ---------- Resumen ----------
log "Resumen"
ls -lh "$OUTPUT_DIR"/*.zip 2>/dev/null || true

if (( ${#FAILED[@]} > 0 )); then
  echo
  err "Problemas con build incompleto (sin paquete generado):"
  for f in "${FAILED[@]}"; do echo "   - $f"; done
  exit 1
fi

echo
echo "  OK. Listo para subir desde el panel admin de BOCA (Problems -> Choose file)."
