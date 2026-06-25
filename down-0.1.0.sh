#!/bin/bash
# Rollback down-0.1.0 — undo up-0.1.0.
#
# Removes the models directory only if it is empty. It never deletes weights: the ~1.6 GB
# artifacts are expensive to re-fetch and shared by every version of this package.

set -euo pipefail

VERSION="0.1.0"
MODELS_DIR="/var/docker/data/roma-matcher/models"

echo "Running down-${VERSION} — RoMa matcher rollback..."

if [ -d "$MODELS_DIR" ] && [ -z "$(ls -A "$MODELS_DIR" 2>/dev/null)" ]; then
    echo "Removing empty models directory $MODELS_DIR ..."
    sudo rmdir "$MODELS_DIR"
    echo "✓ Removed $MODELS_DIR"
else
    echo "Leaving $MODELS_DIR intact (missing or holds weights); weights are never deleted."
fi

echo "down-${VERSION} completed successfully"
