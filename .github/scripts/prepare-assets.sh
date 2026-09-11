#!/usr/bin/env bash
# .github/scripts/prepare-assets.sh
#
# Packages the Helm charts into dist/ so semantic-release can attach them
# as GitHub Release assets.
#
# Runs inside the github.com/IBM/ibm-bob repo after artifacts have been
# synced from ibm-bob-bundle by publish-release.sh.

set -euo pipefail

# Ensure helm is available
if ! command -v helm >/dev/null 2>&1; then
  echo "Installing helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

mkdir -p dist

echo "Packaging ibm-bob chart..."
helm package charts/ibm-bob --destination dist/

echo "Packaging ibm-bob-cluster-scoped chart..."
helm package charts/ibm-bob-cluster-scoped --destination dist/

echo "Assets prepared:"
ls -lh dist/
