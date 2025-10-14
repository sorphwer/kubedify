#!/usr/bin/env bash

set -euo pipefail

# Check required dependencies
check_dependencies() {
  local missing_deps=()
  
  for cmd in docker helm jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing_deps+=("$cmd")
    fi
  done
  
  if [[ ${#missing_deps[@]} -gt 0 ]]; then
    echo "Error: Missing required dependencies: ${missing_deps[*]}" >&2
    echo "Please install the missing dependencies and try again." >&2
    exit 1
  fi
}

# Check dependencies at startup
check_dependencies

trap '[[ -n "${TMP_BUILD_DIR:-}" && -d "$TMP_BUILD_DIR" ]] && rm -rf "$TMP_BUILD_DIR"' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DOCKERFILE="$SCRIPT_DIR/dockerfile"

default_base_repo="langgenius/dify-enterprise"
default_base_tag=""
if [[ -f "$BASE_DOCKERFILE" ]]; then
  if read -r from_line < <(grep -m1 '^FROM ' "$BASE_DOCKERFILE"); then
    from_image=${from_line#FROM }
    default_base_repo=${from_image%%:*}
    [[ -z "$default_base_repo" ]] && default_base_repo="langgenius/dify-enterprise"
    if [[ "$from_image" == *:* ]]; then
      default_base_tag=${from_image#*:}
    fi
  fi
fi

prompt_base_repo() {
  # Always use the default repository
  BASE_REPO="$default_base_repo"
  echo "Using base image repository: $BASE_REPO"
}

# Accept working directory as first argument, default to current directory
WORK_DIR="${1:-$PWD}"
if [[ ! -d "$WORK_DIR" ]]; then
  echo "Error: Working directory '$WORK_DIR' does not exist."
  exit 1
fi
echo "Searching for .so files in: $WORK_DIR"

cursor_blink_on() { tput cnorm 2>/dev/null || true; }
cursor_blink_off() { tput civis 2>/dev/null || true; }
cursor_up() { (( $1 > 0 )) && (tput cuu "$1" 2>/dev/null || true); }
print_option() {
  local current="$1"
  local text="$2"
  if [[ "$current" == "true" ]]; then
    printf "> %s\n" "$text"
  else
    printf "  %s\n" "$text"
  fi
}

select_menu() {
  local prompt="$1"
  shift
  local options=("$@")
  local selected=0
  local key
  local ESC=$'\033'

  printf "%s\n" "$prompt"

  cursor_blink_off

  # Initial render
  for i in "${!options[@]}"; do
    if [[ $i -eq $selected ]]; then
      print_option true "${options[i]}"
    else
      print_option false "${options[i]}"
    fi
  done

  while true; do
    read -rsn1 key
    if [[ $key == "" || $key == $'\n' || $key == $'\r' ]]; then
      break
    elif [[ $key == $ESC ]]; then
      read -rsn1 -t 1 key || continue
      if [[ $key == "[" ]]; then
        read -rsn1 key || continue
        case "$key" in
          A) selected=$(( (selected - 1 + ${#options[@]}) % ${#options[@]} )) ;;
          B) selected=$(( (selected + 1) % ${#options[@]} )) ;;
        esac
        # Re-render menu after arrow key
        cursor_up "${#options[@]}"
        for i in "${!options[@]}"; do
          if [[ $i -eq $selected ]]; then
            print_option true "${options[i]}"
          else
            print_option false "${options[i]}"
          fi
        done
      fi
    fi
  done

  cursor_blink_on
  REPLY=$selected

  # Clear all menu lines and show only the final selection
  cursor_up "${#options[@]}"
  for i in "${!options[@]}"; do
    tput el 2>/dev/null || true
    printf "\n"
  done
  cursor_up "${#options[@]}"
  printf "> %s\n" "${options[selected]}"
}

# Cache configuration
get_cache_dir() {
  # Use the same logic as profile management
  local config_home_override="${KUBEDIFY_CONFIG_HOME:-}"
  if [[ -n "$config_home_override" ]]; then
    echo "$config_home_override"
  elif [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    echo "${XDG_CONFIG_HOME}/kubedify"
  else
    echo "${HOME}/.config/kubedify"
  fi
}

CACHE_DIR="$(get_cache_dir)"
CACHE_FILE="${CACHE_DIR}/versions_cache.json"
CACHE_EXPIRY_DAYS=7

# Create cache directory if it doesn't exist
create_cache_dir() {
  if [[ ! -d "$CACHE_DIR" ]]; then
    mkdir -p "$CACHE_DIR"
  fi
}

# Check if cache is valid (not expired)
is_cache_valid() {
  local cache_file="$1"
  
  if [[ ! -f "$cache_file" ]]; then
    return 1
  fi
  
  # Extract timestamp from cache file
  local cache_timestamp
  cache_timestamp=$(jq -r '.timestamp // empty' "$cache_file" 2>/dev/null)
  
  if [[ -z "$cache_timestamp" ]]; then
    return 1
  fi
  
  # Calculate expiry time (7 days = 604800 seconds)
  local current_time
  current_time=$(date +%s)
  local expiry_time=$((cache_timestamp + (CACHE_EXPIRY_DAYS * 24 * 60 * 60)))
  
  if [[ $current_time -lt $expiry_time ]]; then
    return 0
  else
    return 1
  fi
}

# Read version data from cache
read_cache() {
  local cache_file="$1"
  
  if is_cache_valid "$cache_file"; then
    jq -r '.versions[]' "$cache_file" 2>/dev/null
    return 0
  else
    return 1
  fi
}

# Write version data to cache
write_cache() {
  local cache_file="$1"
  shift
  local version_data=("$@")
  
  create_cache_dir
  
  local current_time
  current_time=$(date +%s)
  
  # Create JSON structure
  local json_data="{\"timestamp\": $current_time, \"versions\": ["
  local first=true
  
  for version in "${version_data[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      json_data+=","
    fi
    json_data+="\"$version\""
  done
  
  json_data+="]}"
  
  echo "$json_data" > "$cache_file"
}

fetch_available_versions() {
  local repo_name="${1:-dify}"
  local repo_url="${2:-https://langgenius.github.io/dify-helm}"
  local chart="${3:-dify/dify}"
  local max_versions=10

  # Try to read from cache first
  echo "Checking version cache..." >&2
  local cached_versions
  if cached_versions=$(read_cache "$CACHE_FILE"); then
    echo "Using cached version data (expires in $CACHE_EXPIRY_DAYS days)" >&2
    echo "$cached_versions"
    return 0
  fi

  echo "Cache not found or expired, fetching available versions from Helm repository..." >&2

  # Add or update Helm repository silently
  helm repo add "$repo_name" "$repo_url" >/dev/null 2>&1 || true
  if ! helm repo update >/dev/null 2>&1; then
    echo "Warning: Failed to update Helm repositories" >&2
    return 1
  fi

  # Get list of chart versions
  local chart_versions
  chart_versions=$(helm search repo "$chart" --versions 2>/dev/null | tail -n +2 | awk '{print $2}' | head -n "$max_versions")

  if [[ -z "$chart_versions" ]]; then
    echo "Warning: No chart versions found" >&2
    return 1
  fi

  # Extract image tags for each version
  declare -a version_data=()

  while IFS= read -r version; do
    [[ -z "$version" ]] && continue

    # Get app version
    local app_version
    app_version=$(helm search repo "$chart" --version "$version" 2>/dev/null | tail -n +2 | awk '{print $3}' | head -n 1)

    # Extract enterprise image tag
    local values_output
    values_output=$(helm show values "$chart" --version "$version" 2>/dev/null)

    local image_info
    image_info=$(echo "$values_output" | awk '/^enterprise:/{flag=1; next} /^[a-z]/ && flag{flag=0} flag')

    local image_tag
    image_tag=$(echo "$image_info" | grep "tag:" | sed 's/.*tag: *//; s/ *$//' | tr -d '"' | head -n 1)

    if [[ -n "$image_tag" ]]; then
      version_data+=("$version|$image_tag")
    fi
  done <<< "$chart_versions"

  # Cache the results
  if [[ ${#version_data[@]} -gt 0 ]]; then
    echo "Caching version data for future use..." >&2
    write_cache "$CACHE_FILE" "${version_data[@]}"
  fi

  # Return the data
  printf '%s\n' "${version_data[@]}"
}

prompt_base_tag() {
  echo ""
  echo "Fetching latest enterprise versions..."

  local version_data
  if ! version_data=$(fetch_available_versions "dify" "https://langgenius.github.io/dify-helm" "dify/dify"); then
    echo "Could not fetch versions from Helm repository."
    echo "Falling back to manual input."

    local input
    if [[ -n "$default_base_tag" ]]; then
      read -rp "Enter base image tag (default: $default_base_tag): " input
      if [[ -z "${input//[[:space:]]/}" ]]; then
        selected_tag="$default_base_tag"
      else
        selected_tag="$input"
      fi
    else
      while true; do
        read -rp "Enter base image tag: " input
        if [[ -z "${input//[[:space:]]/}" ]]; then
          echo "Tag cannot be empty. Please try again."
        else
          selected_tag="$input"
          break
        fi
      done
    fi
    return
  fi

  # Parse version data into arrays
  declare -a chart_versions=()
  declare -a enterprise_tags=()
  declare -a display_options=()

  while IFS='|' read -r chart_ver ent_tag; do
    chart_versions+=("$chart_ver")
    enterprise_tags+=("$ent_tag")
    display_options+=("Chart: $chart_ver -> Enterprise: $ent_tag")
  done <<< "$version_data"

  if [[ ${#display_options[@]} -eq 0 ]]; then
    echo "No versions found. Please enter manually."
    read -rp "Enter base image tag: " selected_tag
    return
  fi

  # Add manual input option
  display_options+=("Enter custom tag manually")

  echo ""
  select_menu "Select enterprise version:" "${display_options[@]}"

  if [[ "${display_options[REPLY]}" == "Enter custom tag manually" ]]; then
    read -rp "Enter base image tag: " selected_tag
    while [[ -z "${selected_tag//[[:space:]]/}" ]]; do
      echo "Tag cannot be empty. Please try again."
      read -rp "Enter base image tag: " selected_tag
    done
  else
    selected_tag="${enterprise_tags[REPLY]}"
    echo "Selected: Chart ${chart_versions[REPLY]} with Enterprise tag ${selected_tag}"
  fi
}

# Check for existing dify-enterprise-dev images
echo ""
echo "Checking for existing dify-enterprise-dev images..."
existing_images=()
while IFS= read -r image; do
  existing_images+=("$image")
done < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep '^dify-enterprise-dev:' | sort)

if (( ${#existing_images[@]} > 0 )); then
  echo "Found ${#existing_images[@]} existing dify-enterprise-dev image(s)"
  echo ""

  # Display version mapping table from cache
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Chart Version → Enterprise Tag Mapping (Latest 10)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ -f "$CACHE_FILE" ]]; then
    if is_cache_valid "$CACHE_FILE"; then
      # Cache is valid, display the data
      printf "  %-16s  →  %-20s\n" "Chart Version" "Enterprise Tag"
      echo "  ────────────────────────────────────────────────────────"

      count=0
      while IFS='|' read -r chart_ver ent_tag; do
        printf "  %-16s  →  %-20s\n" "$chart_ver" "$ent_tag"
        count=$((count + 1))
        [[ $count -ge 10 ]] && break
      done < <(jq -r '.versions[]' "$CACHE_FILE" 2>/dev/null)

      if [[ $count -eq 0 ]]; then
        echo ""
        echo "  ⚠ No cached version data available"
      else
        echo "  ────────────────────────────────────────────────────────"
        echo "  ℹ Cache valid for $CACHE_EXPIRY_DAYS days from last update"
      fi
    else
      # Cache exists but expired
      echo "  ⚠ Version cache expired (>$CACHE_EXPIRY_DAYS days old)"
      echo "  ℹ Run 'kubedify list' to refresh cache"
    fi
  else
    # No cache file exists
    echo "  ℹ No cached version data found"
    echo "  ℹ Cache will be created when you select a version during build"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Present menu with existing images + build option
  image_options=("${existing_images[@]}")
  image_options+=("Build a new dev image")

  select_menu "Select an image to use or build a new one:" "${image_options[@]}"

  if [[ "${image_options[REPLY]}" == "Build a new dev image" ]]; then
    # User chose to build, continue with build flow
    BUILD_NEW_IMAGE=true
  else
    # User selected an existing image
    selected_image="${image_options[REPLY]}"
    echo "Using existing image: $selected_image"

    # Skip build, go directly to enterprise dev mode configuration
    echo ""
    read -rp "Use dev mode of enterprise? This will enable USE_ENTERPRISE_DEV in your kubedify profile. (y/N): " use_dev_mode
    case "$use_dev_mode" in
      [yY][eE][sS]|[yY])
        echo "Enabling enterprise dev mode with existing image..."
        "$SCRIPT_DIR/deploy-kind.sh" set USE_ENTERPRISE_DEV true
        echo "Enterprise dev mode enabled successfully with image: $selected_image"
        ;;
      *)
        echo "Enterprise dev mode not enabled."
        ;;
    esac
    exit 0
  fi
else
  echo "No existing dify-enterprise-dev images found. Will build a new image."
  BUILD_NEW_IMAGE=true
fi

# Only proceed with build flow if user chose to build new image or no existing images
if [[ "$BUILD_NEW_IMAGE" == true ]]; then
  prompt_base_repo

  prompt_base_tag

  so_search_dir="$WORK_DIR"
  so_files=()
  old_ifs=$IFS
  while IFS= read -r file; do
    so_files+=("$file")
  done < <(find "$so_search_dir" -maxdepth 1 -type f -name '*.so' -print 2>/dev/null | sort)
  IFS=$old_ifs
  
  if (( ${#so_files[@]} == 0 )); then
    echo "No .so files found in $so_search_dir."
    read -rp "Enter path to the .so file: " selected_so
    while [[ ! -f "$selected_so" ]]; do
      echo "File not found. Please try again."
      read -rp "Enter path to the .so file: " selected_so
    done
  else
    so_options=("${so_files[@]}")
    so_options+=("Enter custom path")
    select_menu "Select the .so file: " "${so_options[@]}"
    if [[ "${so_options[REPLY]}" == "Enter custom path" ]]; then
      read -rp "Enter path to the .so file: " selected_so
      while [[ ! -f "$selected_so" ]]; do
        echo "File not found. Please try again."
        read -rp "Enter path to the .so file: " selected_so
      done
    else
      selected_so="${so_options[REPLY]}"
    fi
  fi
  
  so_basename=$(basename "$selected_so")
  
  arch_options=("arm64" "amd64")
  select_menu "Select target architecture: " "${arch_options[@]}"
  selected_arch="${arch_options[REPLY]}"
  
  default_image_name="dify-enterprise-dev:${selected_tag}-${selected_arch}"
  read -rp "Enter new image name (default: $default_image_name, which is required if USE_ENTERPRISE_DEV is true): " image_name
  [[ -z "$image_name" ]] && image_name="$default_image_name"
  
  cat <<-EOF

	Build summary:
	  Base image: ${BASE_REPO}:${selected_tag}
	  .so file: ${selected_so}
	  Architecture: ${selected_arch}
	  New image name: ${image_name}

	Dockerfile preview:
	$(printf 'FROM %s:%s\nCOPY %s /usr/lib/%s\n' "$BASE_REPO" "$selected_tag" "$so_basename" "$so_basename")

	EOF
  
  read -rp "Proceed with build? (y/N): " confirm
  case "$confirm" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Build cancelled."; exit 0 ;;
  esac
  
  TMP_BUILD_DIR=$(mktemp -d)
  cp "$selected_so" "$TMP_BUILD_DIR/"
  cat > "$TMP_BUILD_DIR/Dockerfile" <<-EOF
	FROM ${BASE_REPO}:${selected_tag}
	COPY ${so_basename} /usr/lib/${so_basename}
	EOF
  
  echo "Starting Docker build..."
  docker build -t "$image_name" "$TMP_BUILD_DIR"
  echo "Build completed: $image_name"

  # Prompt for enterprise dev mode
  echo ""
  read -rp "Use dev mode of enterprise? This will enable USE_ENTERPRISE_DEV in your kubedify profile. (y/N): " use_dev_mode
  case "$use_dev_mode" in
    [yY][eE][sS]|[yY])
      echo "Enabling enterprise dev mode..."
      # Call deploy-kind.sh to set the configuration
      "$SCRIPT_DIR/deploy-kind.sh" set USE_ENTERPRISE_DEV true
      echo "Enterprise dev mode enabled successfully."
      ;;
    *)
      echo "Enterprise dev mode not enabled."
      ;;
  esac
fi
