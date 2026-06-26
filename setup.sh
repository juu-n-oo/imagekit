#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

REPOS=(
  "imagekit-backend       https://github.com/ten1010-io/imagekit-backend.git"
  "imagekit-web           https://github.com/ten1010-io/imagekit-web.git"
  "image-build-controller https://github.com/ten1010-io/image-build-controller.git"
)

for entry in "${REPOS[@]}"; do
  name=$(echo "$entry" | awk '{print $1}')
  url=$(echo "$entry" | awk '{print $2}')

  if [ -d "${name}/.git" ]; then
    current=$(git -C "${name}" rev-parse --abbrev-ref HEAD)
    if [ "${current}" = "main" ]; then
      echo "[PULL] ${name} (main)"
      git -C "${name}" pull --ff-only origin main || echo "[WARN] ${name}: pull --ff-only failed (working tree dirty or diverged)"
    else
      echo "[FETCH] ${name} (current=${current}, not main — fetching only)"
      git -C "${name}" fetch --prune origin || echo "[WARN] ${name}: fetch failed"
    fi
  elif [ -d "${name}" ]; then
    echo "[SKIP] ${name} exists but is not a git repo"
  else
    echo "[CLONE] ${name} from ${url}"
    git clone "${url}" "${name}"
  fi
done

echo "Done."
