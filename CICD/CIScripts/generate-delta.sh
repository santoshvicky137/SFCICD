#!/bin/bash
set -e
set -o pipefail

# === CONFIGURATION ===
API_VERSION="${API_VERSION:-63.0}"
DELTA_DIR="delta"
PACKAGE_DIR="$DELTA_DIR/package"
PACKAGE_XML="$PACKAGE_DIR/package.xml"
DESTRUCTIVE_XML="$DELTA_DIR/destructiveChanges.xml"
INPUT_FILE="changed-files.txt"
DELETIONS_FILE="deleted-files.txt"
ENVIRONMENT="${environment:-SF-QA}"  # Injected from GitHub workflow env
FALLBACK_DEPTH="${FALLBACK_DEPTH:-3}"
ORG_ALIAS="${ORG_ALIAS:-MyTargetOrg}"

# === MAP ENVIRONMENT TO BRANCH & ICON ===
case "$ENVIRONMENT" in
  SF-QA) BASE_BRANCH="origin/SF-QA"; ENV_ICON="🔬" ;;
  SF-UAT) BASE_BRANCH="origin/SF-UAT"; ENV_ICON="🧪" ;;
  SF-Release) BASE_BRANCH="origin/SF-Release"; ENV_ICON="🚦" ;;
  *) BASE_BRANCH=""; ENV_ICON="🧩" ;; # Feature validation context
esac

echo "🌍 Environment: $ENVIRONMENT"
[[ -n "$BASE_BRANCH" ]] && echo "🔗 Base Branch: $BASE_BRANCH"

export GIT_DIR="$(pwd)/.git"
export GIT_WORK_TREE="$(pwd)"

# === SAFETY CHECK ===
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  echo "❌ Not inside a Git repository. Aborting."
  exit 1
fi

# === STEP 1: Determine delta range ===
USE_LAST_SHA=false
BASE_COMMIT=""

if [[ "$ENVIRONMENT" =~ SF-QA|SF-UAT|SF-Release ]]; then
  echo "🔍 Retrieving last deploy SHA from org..."
  CMDT_QUERY_RESULT=$(sf data query "SELECT Last_Deployed_SHA__c  FROM Deployment_Metadata__mdt" \
    --target-org "$ORG_ALIAS" --json || true)

  DEPLOYED_SHA=$(echo "$CMDT_QUERY_RESULT" | jq -r '.result.records[0].Last_Deployed_SHA__c')

  if [[ -n "$DEPLOYED_SHA" && "$DEPLOYED_SHA" != "null" ]]; then
    BASE_COMMIT="$DEPLOYED_SHA"
    USE_LAST_SHA=true
    echo "✅ Found SHA: $BASE_COMMIT"
  else
    echo "⚠️ No SHA found. Using fallback: last $FALLBACK_DEPTH commits."
    BASE_COMMIT=$(git log -n $FALLBACK_DEPTH --pretty=format:"%H" | tail -n 1)
    USE_LAST_SHA=true
    echo "🪃 Fallback SHA: $BASE_COMMIT"
  fi
else
  BASE_COMMIT=$(git merge-base "$BASE_BRANCH" HEAD)
  if [[ -z "$BASE_COMMIT" ]]; then
    echo "⚠️ Merge-base not found. Using HEAD~${FALLBACK_DEPTH}"
    BASE_COMMIT="HEAD~${FALLBACK_DEPTH}"
  fi
fi

RANGE="${BASE_COMMIT}..HEAD"
echo "📊 Diff range: $RANGE"
git diff --name-status $RANGE -- 'force-app/**' > "$INPUT_FILE"

echo "📋 Changed files:"
cat "$INPUT_FILE" || echo "None"

# === STEP 2: Exit early if no changes ===
if [[ ! -s "$INPUT_FILE" ]]; then
  echo "🚫 No changes detected. Exiting."
  exit 0
fi

# === STEP 3: Prepare delta directory ===
echo "🧹 Creating delta directory..."
rm -rf "$DELTA_DIR"
mkdir -p "$PACKAGE_DIR"

# === STEP 4: Copy modified files ===
> "$DELETIONS_FILE"
while read -r status file; do
  if [[ "$status" == "D" ]]; then
    echo "$file" >> "$DELETIONS_FILE"
    continue
  fi
  [[ ! -f "$file" ]] && continue
  dest="$PACKAGE_DIR/$file"
  mkdir -p "$(dirname "$dest")"
  cp "$file" "$dest"
done < "$INPUT_FILE"

# === STEP 5: Generate package.xml ===
echo "📦 Generating package.xml..."
sf project manifest generate \
  --source-dir "$PACKAGE_DIR" \
  --api-version "$API_VERSION"
mv ./package.xml "$PACKAGE_XML"

# === STEP 6: Build destructiveChanges.xml (for deploy jobs only) ===
if [[ "$USE_LAST_SHA" == "true" ]]; then
  echo "🗑️ Building destructiveChanges.xml..."
  echo '<?xml version="1.0" encoding="UTF-8"?>' > "$DESTRUCTIVE_XML"
  echo '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' >> "$DESTRUCTIVE_XML"

  cut -d '/' -f2- <<< "$(grep . "$DELETIONS_FILE")" \
    | sed 's/\.[^.]*$//' \
    | awk -F '/' '{print $1, $2}' \
    | sort | uniq \
    | while read type name; do
        echo "  <types>" >> "$DESTRUCTIVE_XML"
        echo "    <members>$name</members>" >> "$DESTRUCTIVE_XML"
        echo "    <name>$type</name>" >> "$DESTRUCTIVE_XML"
        echo "  </types>" >> "$DESTRUCTIVE_XML"
      done

  echo "  <version>$API_VERSION</version>" >> "$DESTRUCTIVE_XML"
  echo '</Package>' >> "$DESTRUCTIVE_XML"
else
  echo "ℹ️ Skipping destructive deploy — validation context."
fi

# === STEP 7: List included components ===
echo "📜 Delta package contents:"
find "$PACKAGE_DIR" -type f ! -name "package.xml" | sed "s|^$PACKAGE_DIR/|- |"

# === STEP 8: Write summary if supported ===
if [[ -n "$GITHUB_STEP_SUMMARY" ]]; then
  echo "📝 Writing summary to GitHub step summary..."
  {
    echo "### ${ENV_ICON} Delta Deployment Summary"
    echo "- **Target Environment**: ${ENVIRONMENT}"
    echo "- **Base Branch Used**: ${BASE_BRANCH:-(feature validation)}"
    echo "- **Merge Base Commit**: ${BASE_COMMIT}"
    echo "- **Run ID**: ${GITHUB_RUN_ID:-N/A}"
    echo "- **Timestamp**: $(date +'%Y-%m-%d %H:%M:%S')"
    echo "- **Metadata Components Deployed:**"
    grep "<name>" "$PACKAGE_XML" | sed 's/ *<[^>]*>//g' | sort | uniq | sed 's/^/- /'

    if [[ -s "$DESTRUCTIVE_XML" && "$USE_LAST_SHA" == "true" ]]; then
      echo "- **Destructive Components Removed:**"
      grep "<name>" "$DESTRUCTIVE_XML" | sed 's/ *<[^>]*>//g' | sort | uniq | sed 's/^/- /'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
else
  echo "⚠️ GITHUB_STEP_SUMMARY not set. Skipping summary output."
fi

echo ""
echo "✅ Delta script completed successfully."
