#!/usr/bin/env bash
# Renders diagrams/*.mmd to images/*.svg with Mermaid CLI.
# Usage: scripts/render.sh   (set PUPPETEER_CONFIG to a puppeteer JSON config if Chromium needs custom flags/path)
set -euo pipefail
cd "$(dirname "$0")/.."
MMDC_VERSION="11.4.2"
args=()
[[ -n "${PUPPETEER_CONFIG:-}" ]] && args+=(-p "$PUPPETEER_CONFIG")
for src in diagrams/*.mmd; do
  out="images/$(basename "${src%.mmd}").svg"
  echo "Rendering $src -> $out"
  npx -y "@mermaid-js/mermaid-cli@${MMDC_VERSION}" "${args[@]}" -b white -i "$src" -o "$out"
done
