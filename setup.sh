#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

REPOS=(
  "dockerizer-backend https://github.com/juu-n-oo/dockerizer-backend.git"
  "dockerizer-web     https://github.com/juu-n-oo/dockerizer-web.git"
)

for entry in "${REPOS[@]}"; do
  name=$(echo "$entry" | awk '{print $1}')
  url=$(echo "$entry" | awk '{print $2}')

  if [ -d "${name}" ]; then
    echo "[SKIP] ${name} already exists"
  else
    echo "[CLONE] ${name} from ${url}"
    git clone "${url}" "${name}"
  fi
done

echo "Done."
