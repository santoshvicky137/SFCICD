#!/bin/bash
set -e
set -o pipefail

# === CONFIGURATION ===
PACKAGE_XML="delta/package/package.xml"
BACKUP_DIR="${BACKUP_DIR:-deltabackup-$(date +%Y%m%d-%H%M%S)}"
ORG_ALIAS="${ORG_ALIAS:-target-org}"

# === VALIDATION ===
if [[ ! -f "sfdx-project.json" ]]; then
  echo "❌ Missing sfdx-project.json. Not a valid Salesforce DX workspace."
  exit 1
fi

if [[ ! -f "$PACKAGE_XML" ]]; then
  echo "❌ package.xml not found at '$PACKAGE_XML'. Skipping backup."
  exit 0  # Don't break pipeline — assume empty delta or first-time deploy
fi

echo "📦 Backing up metadata from org '$ORG_ALIAS'..."
mkdir -p "$BACKUP_DIR"

# === RETRIEVE METADATA ===
sf project retrieve start \
  --ignore-conflicts \
  --target-org "$ORG_ALIAS" \
  --manifest "$PACKAGE_XML" \
  --output-dir "$BACKUP_DIR" || {
    echo "⚠️ Metadata retrieval failed. Possibly first-time components or unsupported types."
    exit 0  # Skip backup gracefully
  }

# === POST-CHECK: Did anything actually get retrieved? ===
if [[ -z "$(find "$BACKUP_DIR" -type f -name '*.xml' 2>/dev/null)" ]]; then
  echo "⚠️ No metadata files retrieved. Likely new components not present in org."
  echo "🧩 Continuing pipeline without backup."
else
  echo "✅ Backup completed to '$BACKUP_DIR'."
fi

# === OPTIONAL: GitHub Summary ===
if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then
  {
    echo "### 📦 Delta Backup Summary"
    echo "- Org Alias: $ORG_ALIAS"
    echo "- Backup Directory: $BACKUP_DIR"
    echo "- Manifest: $PACKAGE_XML"
    echo "- Timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
  } >> "$GITHUB_STEP_SUMMARY"
fi