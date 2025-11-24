#!/usr/bin/env bash
set -euo pipefail

# Script to list Helm chart versions and their corresponding image versions
# Focuses on dify-enterprise image tags

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Default configuration
HELM_REPO_NAME="${HELM_REPO_NAME:-dify}"
HELM_REPO_URL="${HELM_REPO_URL:-https://langgenius.github.io/dify-helm}"
HELM_CHART="${HELM_CHART:-dify/dify}"
MAX_VERSIONS="${MAX_VERSIONS:-10}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-table}"  # table, csv, json

usage() {
  cat <<'USAGE'
Usage: list-chart-images.sh [options]

Options:
  --repo-name <name>      Helm repository name (default: dify)
  --repo-url <url>        Helm repository URL (default: https://langgenius.github.io/dify-helm)
  --chart <chart>         Helm chart name (default: dify/dify)
  --max <number>          Maximum number of versions to display (default: 10, 0 for all)
  --format <format>       Output format: table, csv, json (default: table)
  --service <service>     Service to extract image tag for (default: enterprise)
  -h, --help              Show this help message

Examples:
  # List latest 10 chart versions with enterprise image tags
  ./list-chart-images.sh

  # List all versions
  ./list-chart-images.sh --max 0

  # Output as CSV
  ./list-chart-images.sh --format csv

  # Output as JSON
  ./list-chart-images.sh --format json
USAGE
}

# Parse command line arguments
SERVICE_NAME="enterprise"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-name)
      HELM_REPO_NAME="$2"
      shift 2
      ;;
    --repo-url)
      HELM_REPO_URL="$2"
      shift 2
      ;;
    --chart)
      HELM_CHART="$2"
      shift 2
      ;;
    --max)
      MAX_VERSIONS="$2"
      shift 2
      ;;
    --format)
      OUTPUT_FORMAT="$2"
      shift 2
      ;;
    --service)
      SERVICE_NAME="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# Validate output format
case "$OUTPUT_FORMAT" in
  table|csv|json)
    ;;
  *)
    echo "Invalid format: $OUTPUT_FORMAT. Must be table, csv, or json." >&2
    exit 1
    ;;
esac

# Check required commands
for cmd in helm grep awk sed; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: Required command '$cmd' not found" >&2
    exit 1
  fi
done

# Add or update Helm repository
echo "[INFO] Updating Helm repository..." >&2
if ! helm repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1; then
  echo "[WARN] Failed to add repository, it may already exist" >&2
fi

if ! helm repo update >/dev/null 2>&1; then
  echo "[ERROR] Failed to update Helm repositories" >&2
  exit 1
fi

# Get list of chart versions
echo "[INFO] Fetching chart versions..." >&2
chart_versions=$(helm search repo "$HELM_CHART" --versions | tail -n +2 | awk '{print $2}')

if [[ -z "$chart_versions" ]]; then
  echo "[ERROR] No chart versions found for $HELM_CHART" >&2
  exit 1
fi

# Limit number of versions if specified
if [[ "$MAX_VERSIONS" -gt 0 ]]; then
  chart_versions=$(echo "$chart_versions" | head -n "$MAX_VERSIONS")
fi

# Extract image tags for each version
declare -a chart_version_array=()
declare -a app_version_array=()
declare -a image_tag_array=()
declare -a image_repo_array=()

echo "[INFO] Extracting image information for $SERVICE_NAME service..." >&2

while IFS= read -r version; do
  [[ -z "$version" ]] && continue

  # Get app version from chart metadata
  app_version=$(helm search repo "$HELM_CHART" --version "$version" | tail -n +2 | awk '{print $3}' | head -n 1)

  # Extract image repository and tag from values
  values_output=$(helm show values "$HELM_CHART" --version "$version" 2>/dev/null)

  # Extract enterprise section - get more context to ensure we capture the tag line
  image_info=$(echo "$values_output" | awk "/^${SERVICE_NAME}:/{flag=1; next} /^[a-z]/ && flag{flag=0} flag")

  # Extract repository and tag
  image_repo=$(echo "$image_info" | grep "repository:" | sed 's/.*repository: *//; s/ *$//' | tr -d '"' | head -n 1)
  image_tag=$(echo "$image_info" | grep "tag:" | sed 's/.*tag: *//; s/ *$//' | tr -d '"' | head -n 1)

  # Store results
  chart_version_array+=("$version")
  app_version_array+=("${app_version:-unknown}")
  image_repo_array+=("${image_repo:-unknown}")
  image_tag_array+=("${image_tag:-unknown}")

done <<< "$chart_versions"

# Output results based on format
case "$OUTPUT_FORMAT" in
  table)
    # Calculate column widths
    max_chart_len=13
    max_app_len=11
    max_repo_len=25
    max_tag_len=14

    for i in "${!chart_version_array[@]}"; do
      [[ ${#chart_version_array[$i]} -gt $max_chart_len ]] && max_chart_len=${#chart_version_array[$i]}
      [[ ${#app_version_array[$i]} -gt $max_app_len ]] && max_app_len=${#app_version_array[$i]}
      [[ ${#image_repo_array[$i]} -gt $max_repo_len ]] && max_repo_len=${#image_repo_array[$i]}
      [[ ${#image_tag_array[$i]} -gt $max_tag_len ]] && max_tag_len=${#image_tag_array[$i]}
    done

    # Print header
    service_upper=$(echo "$SERVICE_NAME" | tr '[:lower:]' '[:upper:]')
    printf "%-${max_chart_len}s  %-${max_app_len}s  %-${max_repo_len}s  %-${max_tag_len}s\n" \
      "CHART VERSION" "APP VERSION" "IMAGE REPOSITORY" "${service_upper} TAG"

    # Print separator
    printf "%s  %s  %s  %s\n" \
      "$(printf '%*s' "$max_chart_len" '' | tr ' ' '-')" \
      "$(printf '%*s' "$max_app_len" '' | tr ' ' '-')" \
      "$(printf '%*s' "$max_repo_len" '' | tr ' ' '-')" \
      "$(printf '%*s' "$max_tag_len" '' | tr ' ' '-')"

    # Print data
    for i in "${!chart_version_array[@]}"; do
      printf "%-${max_chart_len}s  %-${max_app_len}s  %-${max_repo_len}s  %-${max_tag_len}s\n" \
        "${chart_version_array[$i]}" \
        "${app_version_array[$i]}" \
        "${image_repo_array[$i]}" \
        "${image_tag_array[$i]}"
    done
    ;;

  csv)
    # Print CSV header
    echo "chart_version,app_version,image_repository,${SERVICE_NAME}_tag"

    # Print CSV data
    for i in "${!chart_version_array[@]}"; do
      echo "${chart_version_array[$i]},${app_version_array[$i]},${image_repo_array[$i]},${image_tag_array[$i]}"
    done
    ;;

  json)
    # Print JSON array
    echo "["
    for i in "${!chart_version_array[@]}"; do
      printf "  {\n"
      printf "    \"chart_version\": \"%s\",\n" "${chart_version_array[$i]}"
      printf "    \"app_version\": \"%s\",\n" "${app_version_array[$i]}"
      printf "    \"image_repository\": \"%s\",\n" "${image_repo_array[$i]}"
      printf "    \"%s_tag\": \"%s\"\n" "$SERVICE_NAME" "${image_tag_array[$i]}"
      if [[ $i -eq $((${#chart_version_array[@]} - 1)) ]]; then
        printf "  }\n"
      else
        printf "  },\n"
      fi
    done
    echo "]"
    ;;
esac

echo "[INFO] Complete! Displayed ${#chart_version_array[@]} chart versions." >&2
