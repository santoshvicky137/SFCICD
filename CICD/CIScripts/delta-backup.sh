#!/bin/bash
set -e
set -o pipefail

# === PATH AWARENESS ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PACKAGE_XML="$PROJECT_ROOT/delta/package/package.xml"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/deltabackup-$(date +%Y%m%d-%H%M%S)}"
ORG_ALIAS="${ORG_ALIAS:-target-org}"

echo "📁 Script location: $SCRIPT_DIR"
echo "📁 Project root: $PROJECT_ROOT"
echo "📂 Backup destination: $BACKUP_DIR"
echo "📄 Manifest path: $PACKAGE_XML"

# === VALIDATION ===
if [[ ! -f "$PROJECT_ROOT/sfdx-project.json" ]]; then
  echo "❌ Missing sfdx-project.json in '$PROJECT_ROOT'. Not a valid Salesforce DX workspace."
  exit 1
fi

if [[ ! -f "$PACKAGE_XML" ]]; then
  echo "📭 No package.xml found at '$PACKAGE_XML'. Skipping backup."
  exit 0
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
    exit 0
  }

# === POST-CHECK ===
if [[ -z "$(find "$BACKUP_DIR" -type f -name '*.xml' 2>/dev/null)" ]]; then
  echo "⚠️ No metadata files retrieved. Likely new components not present in org."
  echo "🧩 Continuing pipeline without backup."
else
  echo "✅ Backup completed to '$BACKUP_DIR'."
fi

# === GITHUB STEP SUMMARY ===
if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then
  {
    echo "### 📦 Delta Backup Summary"
    echo "- **Org Alias**: $ORG_ALIAS"
    echo "- **Backup Directory**: $(basename "$BACKUP_DIR")"
    echo "- **Manifest Used**: $(basename "$PACKAGE_XML")"
    echo "- **Timestamp**: $(date +'%Y-%m-%d %H:%M:%S')"
  } >> "$GITHUB_STEP_SUMMARY"
fi