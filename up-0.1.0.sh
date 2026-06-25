#!/bin/bash
# Migration up-0.1.0 — provision the RoMa matcher weights on the device.
#
# Idempotent: fetches the two weight files only if missing or checksum-mismatched, then
# SHA-256-verifies them. The data dir persists across updates; weights are never baked into
# the image (~1.6 GB).

set -euo pipefail

VERSION="0.1.0"
MODELS_DIR="/var/docker/data/roma-matcher/models"
WEIGHTS_REF="docker.modelingevolution.com/roma-matcher/weights:${VERSION}"

# filename  sha256  (computed from the canonical weight files)
ROMA_FILE="roma_outdoor.pth"
ROMA_SHA="c7a45c80d41ad788a63c641d1b686d7cb3f297f40097c6f4e75039889e5cc8ba"
DINOV2_FILE="dinov2_vitl14_pretrain.pth"
DINOV2_SHA="d5383ea8f4877b2472eb973e0fd72d557c7da5d3611bd527ceeb1d7162cbf428"

echo "Running up-${VERSION} — RoMa matcher weights provisioning..."

# Verify a file matches its expected SHA-256.
verify_sha() {
    local path="$1" expected="$2" actual
    [ -f "$path" ] || return 1
    actual=$(sha256sum "$path" | awk '{print $1}')
    [ "$actual" = "$expected" ]
}

echo "Ensuring models directory $MODELS_DIR ..."
sudo mkdir -p "$MODELS_DIR"
sudo chown -R "$USER":"$USER" "$MODELS_DIR"

if verify_sha "$MODELS_DIR/$ROMA_FILE" "$ROMA_SHA" \
   && verify_sha "$MODELS_DIR/$DINOV2_FILE" "$DINOV2_SHA"; then
    echo "✓ Weights already present and verified — nothing to fetch."
    echo "up-${VERSION} completed successfully"
    exit 0
fi

if ! command -v oras >/dev/null 2>&1; then
    echo "ERROR: 'oras' is required to fetch the weights artifact but is not installed." >&2
    echo "       Install oras (https://oras.land) on this device, then re-run the update." >&2
    exit 1
fi

# oras reuses the docker credential store; export HARBOR_USERNAME/HARBOR_PASSWORD to override.
oras_auth=()
if [ -n "${HARBOR_USERNAME:-}" ] && [ -n "${HARBOR_PASSWORD:-}" ]; then
    oras_auth=(--username "$HARBOR_USERNAME" --password "$HARBOR_PASSWORD")
fi

echo "Fetching weights from $WEIGHTS_REF ..."
oras pull "${oras_auth[@]}" -o "$MODELS_DIR" "$WEIGHTS_REF"

echo "Verifying SHA-256 checksums..."
if ! verify_sha "$MODELS_DIR/$ROMA_FILE" "$ROMA_SHA"; then
    echo "ERROR: $ROMA_FILE failed SHA-256 verification (expected $ROMA_SHA)." >&2
    exit 1
fi
if ! verify_sha "$MODELS_DIR/$DINOV2_FILE" "$DINOV2_SHA"; then
    echo "ERROR: $DINOV2_FILE failed SHA-256 verification (expected $DINOV2_SHA)." >&2
    exit 1
fi

echo "✓ Weights fetched and verified."
echo "up-${VERSION} completed successfully"
