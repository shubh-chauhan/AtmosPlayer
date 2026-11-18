#!/bin/bash
# Applies EngineBundle/patches/*.patch to an AetherEngine checkout.
#   apply-patches.sh <engine checkout>
# A patch that is already in the engine (applied before, or merged upstream) is skipped. One that
# no longer applies to a newer engine fails the build, so a fix is never dropped without notice.
set -euo pipefail
engine="$1"
here="$(cd "$(dirname "$0")" && pwd)"
for patch in "$here"/patches/*.patch; do
  name=$(basename "$patch")
  if git -C "$engine" apply --reverse --check "$patch" 2>/dev/null; then
    echo "already in the engine: $name"
  elif git -C "$engine" apply --check "$patch"; then
    git -C "$engine" apply "$patch"
    echo "applied: $name"
  else
    echo "::error::$name no longer applies to this AetherEngine version"
    exit 1
  fi
done
