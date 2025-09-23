#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/config.json}"
DRY_RUN=false
INSTALL_VERSION_OVERRIDE=""
ACTION=""
declare -a ACTION_ARGS=()
declare -a CLEANUP_FILES=()

usage() {
  cat <<'USAGE'
Usage: deploy-kind.sh [--config <path>] <command> [args]

Commands:
  install [version] [--dry-run]   Deploy the chart, optionally pinning the chart version.
  set <KEY> <VALUE...>            Update a configuration entry in config.json.
  set-docker-username <VALUE>     Shortcut for setting DOCKER_USERNAME.
  set-docker-pat <VALUE>          Shortcut for setting DOCKER_PAT.
  list                            List available chart versions from the configured Helm repo.
  current                         Show the last recorded installed chart version.

Options:
  --config <path>                 Override the path to config.json (default: alongside the script).
  -h, --help                      Show this help.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --config" >&2
        exit 1
      fi
      CONFIG_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -gt 0 ]]; then
  COMMAND="$1"
  shift
else
  COMMAND="install"
fi

case "$COMMAND" in
  install)
    ACTION="install"
    ACTION_ARGS=("$@")
    ;;
  set)
    ACTION="set"
    ACTION_ARGS=("$@")
    ;;
  set-docker-username)
    ACTION="set"
    ACTION_ARGS=("DOCKER_USERNAME" "$@")
    ;;
  set-docker-pat)
    ACTION="set"
    ACTION_ARGS=("DOCKER_PAT" "$@")
    ;;
  list)
    ACTION="list"
    ACTION_ARGS=("$@")
    ;;
  current)
    ACTION="current"
    ACTION_ARGS=("$@")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    echo "Unknown command: $COMMAND" >&2
    usage
    exit 1
    ;;
esac

cd "$SCRIPT_DIR"

log() {
  printf '[%s] %s
' "$(date '+%H:%M:%S')" "$1"
}

die() {
  echo "Error: $1" >&2
  exit 1
}

run_cmd() {
  if $DRY_RUN; then
    log "DRY-RUN: $*"
  else
    "$@"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    die "Config file not found: $CONFIG_FILE"
  fi
}

load_config() {
  ensure_config
  require_cmd python3
  while IFS= read -r __kv_line; do
    [[ -z "$__kv_line" ]] && continue
    export "$__kv_line"
  done < <(python3 - "$CONFIG_FILE" <<'PYCFG'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text().strip()
if not text:
    data = {}
else:
    data = json.loads(text)

if not isinstance(data, dict):
    raise SystemExit('Config file must contain a JSON object at the top level')

for key, value in data.items():
    if value is None:
        value_str = ''
    elif isinstance(value, bool):
        value_str = 'true' if value else 'false'
    else:
        value_str = str(value)
    print(f"{key}={value_str}")
PYCFG
  )
}

set_config_value() {
  local key="$1"
  local value="$2"
  require_cmd python3
  python3 - "$CONFIG_FILE" "$key" "$value" <<'PYSET'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

if path.exists():
    text = path.read_text().strip()
    data = json.loads(text) if text else {}
else:
    data = {}

if not isinstance(data, dict):
    raise SystemExit('Config file must contain a JSON object at the top level')

data[key] = value
path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PYSET
}

get_config_value() {
  local key="$1"
  ensure_config
  require_cmd python3
  python3 - "$CONFIG_FILE" "$key" <<'PYGET'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]

if not path.exists():
    sys.exit(0)

text = path.read_text().strip()
if not text:
    sys.exit(0)

data = json.loads(text)
value = data.get(key, '')
if value is None:
    value = ''
print(value, end='')
PYGET
}

parse_install_args() {
  INSTALL_VERSION_OVERRIDE=""
  DRY_RUN=false
  local positional=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --)
        shift
        positional+=("$@")
        break
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if ((${#positional[@]} > 1)); then
    die "install accepts at most one version argument"
  fi

  if ((${#positional[@]} == 1)); then
    INSTALL_VERSION_OVERRIDE="${positional[0]}"
  fi
}

handle_set_command() {
  if ((${#ACTION_ARGS[@]} < 2)); then
    die "Usage: deploy-kind.sh set <KEY> <VALUE...>"
  fi
  local key="${ACTION_ARGS[0]}"
  if [[ -z "$key" ]]; then
    die "Configuration key must not be empty"
  fi
  local value_parts=("${ACTION_ARGS[@]:1}")
  local value=""
  if ((${#value_parts[@]} > 0)); then
    value="$(printf '%s ' "${value_parts[@]}")"
    value="${value% }"
  fi
  set_config_value "$key" "$value"
  log "Updated ${key} in ${CONFIG_FILE}"
}

handle_current_command() {
  if ((${#ACTION_ARGS[@]} > 0)); then
    die "current command does not accept additional arguments"
  fi
  ensure_config
  local current
  current=$(get_config_value "LAST_INSTALLED_VERSION") || current=""
  if [[ -z "$current" ]]; then
    echo "No recorded installation yet"
  else
    echo "$current"
  fi
}

handle_list_command() {
  if ((${#ACTION_ARGS[@]} > 0)); then
    die "list command does not accept additional arguments"
  fi
  ensure_config
  load_config
  require_cmd helm
  local helm_cmd
  helm_cmd=$(command -v helm)
  if [[ -z "${HELM_CHART:-}" ]]; then
    die "HELM_CHART is not configured in ${CONFIG_FILE}"
  fi
  if [[ -n "${HELM_REPO_NAME:-}" && -n "${HELM_REPO_URL:-}" ]]; then
    "$helm_cmd" repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
  fi
  "$helm_cmd" repo update >/dev/null 2>&1 || true
  "$helm_cmd" search repo "$HELM_CHART" --versions
}

record_install_metadata() {
  if $DRY_RUN; then
    log "Dry-run enabled; skipped recording install metadata."
    return
  fi

  local recorded_version=""
  if [[ -n "${HELM_CHART_VERSION_RAW:-}" ]]; then
    recorded_version="$HELM_CHART_VERSION_RAW"
  elif [[ -n "${HELM_CHART_VERSION_OVERRIDE:-}" ]]; then
    recorded_version="$HELM_CHART_VERSION_OVERRIDE"
  elif [[ -n "${HELM_CHART_VERSION:-}" ]]; then
    recorded_version="$HELM_CHART_VERSION"
  fi

  if [[ -z "$recorded_version" ]]; then
    log "Warning: unable to determine chart version to record."
    return
  fi

  set_config_value "LAST_INSTALLED_VERSION" "$recorded_version"
  if [[ -n "${INSTALL_VERSION_OVERRIDE:-}" ]]; then
    local desired="$recorded_version"
    if [[ -n "${HELM_CHART_VERSION_RAW:-}" ]]; then
      desired="$HELM_CHART_VERSION_RAW"
    fi
    set_config_value "HELM_CHART_VERSION" "$desired"
  fi
  log "Recorded last installed chart version: ${recorded_version}"
}

install_flow() {
  parse_install_args "${ACTION_ARGS[@]}"
  ensure_config
  log "Using config file: $CONFIG_FILE"
  load_config

  if [[ -n "$INSTALL_VERSION_OVERRIDE" ]]; then
    export HELM_CHART_VERSION="$INSTALL_VERSION_OVERRIDE"
  fi

  : "${KIND_CLUSTER_NAME:?KIND_CLUSTER_NAME is required}"
  K8S_NAMESPACE=${K8S_NAMESPACE:-dify}
  K8S_CONTEXT=${K8S_CONTEXT:-"kind-${KIND_CLUSTER_NAME}"}
  HELM_NAMESPACE=${HELM_NAMESPACE:-$K8S_NAMESPACE}
  HELM_VALUES_FILE=${HELM_VALUES_FILE:-values.yaml}
  HELM_VERSION=${HELM_VERSION:-latest}
  HELM_RELEASE_NAME=${HELM_RELEASE_NAME:-dify}
  HELM_CHART=${HELM_CHART:-dify/dify}
  HELM_REPO_NAME=${HELM_REPO_NAME:-}
  HELM_REPO_URL=${HELM_REPO_URL:-}
  HELM_ADDITIONAL_ARGS=${HELM_ADDITIONAL_ARGS:-}
  DOCKER_USERNAME=${DOCKER_USERNAME:-}
  DOCKER_PAT=${DOCKER_PAT:-}
  IMAGE_REGISTRY_SERVER=${IMAGE_REGISTRY_SERVER:-https://index.docker.io/v1/}
  IMAGE_REGISTRY_USERNAME=${IMAGE_REGISTRY_USERNAME:-"${DOCKER_USERNAME:-}"}
  IMAGE_REGISTRY_PASSWORD=${IMAGE_REGISTRY_PASSWORD:-"${DOCKER_PAT:-}"}
  PVC_BASE_NAME=${PVC_BASE_NAME:-dify-backend-pvc}
  PV_BASE_NAME=${PV_BASE_NAME:-dify-backend-pv}
  PVC_VERSION_TAG=${PVC_VERSION_TAG:-}
  PVC_ACCESS_MODE=${PVC_ACCESS_MODE:-ReadWriteOnce}
  PVC_SIZE=${PVC_SIZE:-10Gi}
  PVC_STORAGE_CLASS=${PVC_STORAGE_CLASS:-}
  PVC_ANNOTATIONS=${PVC_ANNOTATIONS:-}
  POSTGRES_PVC_BASE_NAME=${POSTGRES_PVC_BASE_NAME:-dify-postgres-pvc}
  POSTGRES_PVC_VERSION_TAG=${POSTGRES_PVC_VERSION_TAG:-}
  POSTGRES_PVC_ACCESS_MODE=${POSTGRES_PVC_ACCESS_MODE:-ReadWriteOnce}
  POSTGRES_PVC_SIZE=${POSTGRES_PVC_SIZE:-10Gi}
  POSTGRES_PVC_STORAGE_CLASS=${POSTGRES_PVC_STORAGE_CLASS:-${PVC_STORAGE_CLASS:-}}
  POSTGRES_PVC_ANNOTATIONS=${POSTGRES_PVC_ANNOTATIONS:-${PVC_ANNOTATIONS:-}}
  IMAGE_REPO_SECRET_NAME=${IMAGE_REPO_SECRET_NAME:-image-repo-secret}
  IMAGE_REGISTRY_EMAIL=${IMAGE_REGISTRY_EMAIL:-unused@example.com}
  IMAGE_REPO_PREFIX=${IMAGE_REPO_PREFIX:-"docker.io/${DOCKER_USERNAME:-}"}
  IMAGE_REPO_TYPE=${IMAGE_REPO_TYPE:-docker}
  INGRESS_CONTROLLER_MANIFEST=${INGRESS_CONTROLLER_MANIFEST:-https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml}
  LOCAL_DOCKER_IMAGES=${LOCAL_DOCKER_IMAGES:-}
  VALUES_LOG_DIR=${VALUES_LOG_DIR:-"${SCRIPT_DIR}/log"}
  IMAGE_REPO_SECRET_SCRIPT=${IMAGE_REPO_SECRET_SCRIPT:-"${SCRIPT_DIR}/generate-image-repo-secret.sh"}

  require_cmd docker
  require_cmd kind
  require_cmd kubectl

  if [[ -f "$HELM_VALUES_FILE" ]]; then
    HELM_VALUES_PATH="$HELM_VALUES_FILE"
  elif [[ -f "${SCRIPT_DIR}/$HELM_VALUES_FILE" ]]; then
    HELM_VALUES_PATH="${SCRIPT_DIR}/$HELM_VALUES_FILE"
  else
    die "Helm values file not found: $HELM_VALUES_FILE"
  fi

  if $DRY_RUN; then
    log "Dry-run enabled; commands will not be executed."
  fi

  HELM_CMD="helm"
  BIN_DIR="${SCRIPT_DIR}/.bin"
  HELM_ACTUAL_VERSION=""
  if [[ -z "${HELM_CHART_VERSION:-}" || "${HELM_CHART_VERSION}" == "latest" ]]; then
    HELM_CHART_VERSION_OVERRIDE=""
  else
    HELM_CHART_VERSION_OVERRIDE=${HELM_CHART_VERSION}
  fi
  HELM_CHART_VERSION_EFFECTIVE=""
  HELM_CHART_VERSION_RAW=""
  PVC_VERSION_SUFFIX=""
  POSTGRES_PVC_VERSION_SUFFIX=""
  POSTGRES_PVC_NAME=""
  PREPARED_HELM_VALUES_PATH=""
  CLEANUP_FILES=()

  trap cleanup EXIT

  setup_helm_version
  resolve_helm_actual_version
  resolve_chart_version
  derive_pvc_name
  derive_pv_name
  derive_postgres_pvc_name
  prepare_values_file
  persist_prepared_values_file
  main
  record_install_metadata
}

cleanup() {
  if [[ ${#CLEANUP_FILES[@]} -eq 0 ]]; then
    return
  fi
  for file in "${CLEANUP_FILES[@]}"; do
    [[ -n "$file" && -f "$file" ]] && rm -f "$file"
  done
}

setup_helm_version() {
  if [[ -z "$HELM_VERSION" || "$HELM_VERSION" == "latest" ]]; then
    require_cmd helm
    HELM_CMD=$(command -v helm)
    log "Using helm binary: $HELM_CMD"
    return
  fi

  local target_path="${BIN_DIR}/helm-${HELM_VERSION}"
  if [[ -x "$target_path" ]]; then
    HELM_CMD="$target_path"
    log "Using cached helm ${HELM_VERSION} at ${target_path}"
    return
  fi

  if $DRY_RUN; then
    log "DRY-RUN: would download helm ${HELM_VERSION} to ${target_path}"
    HELM_CMD="$target_path"
    return
  fi

  require_cmd curl
  require_cmd tar

  mkdir -p "$BIN_DIR"

  local os machine
  os=$(uname | tr '[:upper:]' '[:lower:]')
  machine=$(uname -m)
  local arch_candidates=()
  case "$machine" in
    x86_64|amd64)
      arch_candidates=(amd64)
      ;;
    arm64|aarch64)
      arch_candidates=(arm64 amd64)
      ;;
    *)
      die "Unsupported architecture for helm download: $machine"
      ;;
  esac

  local tarball="${BIN_DIR}/helm-${HELM_VERSION}.tgz"
  local downloaded_arch=""
  for arch in "${arch_candidates[@]}"; do
    local url="https://get.helm.sh/helm-v${HELM_VERSION}-${os}-${arch}.tar.gz"
    log "Downloading helm ${HELM_VERSION} from ${url}"
    if curl -fsSL "$url" -o "$tarball"; then
      downloaded_arch="$arch"
      break
    fi
    log "Download failed for architecture '${arch}', trying fallback if available"
    rm -f "$tarball"
  done

  if [[ -z "$downloaded_arch" ]]; then
    die "Failed to download helm ${HELM_VERSION} for platform ${os}-${machine}"
  fi

  tar -xzf "$tarball" -C "$BIN_DIR" || die "Failed to extract helm ${HELM_VERSION}"
  mv "${BIN_DIR}/${os}-${downloaded_arch}/helm" "$target_path" || die "Failed to stage helm ${HELM_VERSION}"
  rm -rf "${BIN_DIR}/${os}-${downloaded_arch}" "$tarball"
  chmod +x "$target_path"
  HELM_CMD="$target_path"
  log "Using freshly downloaded helm ${HELM_VERSION} at ${target_path}"
}

resolve_helm_actual_version() {
  if [[ $DRY_RUN == true && ! -x "$HELM_CMD" ]]; then
    log "Skipping helm version detection (binary not available during dry-run)"
    return
  fi

  if [[ ! -x "$HELM_CMD" ]]; then
    log "Helm binary '$HELM_CMD' not executable; skipping version detection"
    return
  fi

  local version_output
  if ! version_output=$("$HELM_CMD" version --short --client 2>/dev/null); then
    log "Unable to determine helm version from '$HELM_CMD'"
    return
  fi

  version_output=${version_output#v}
  version_output=${version_output%%+*}
  HELM_ACTUAL_VERSION=$(sanitize_dns_label "$version_output")
  log "Helm actual version detected: ${HELM_ACTUAL_VERSION:-unknown}"
}

sanitize_dns_label() {
  local input="$1"
  local lowered
  lowered=$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')
  while [[ "$lowered" == *"--"* ]]; do
    lowered=${lowered//--/-}
  done
  while [[ "$lowered" == -* ]]; do
    lowered=${lowered#-}
  done
  while [[ "$lowered" == *- ]]; do
    lowered=${lowered%-}
  done
  printf '%s' "$lowered"
}

resolve_chart_version() {
  if [[ -n "$HELM_CHART_VERSION_EFFECTIVE" ]]; then
    return
  fi

  if [[ -z "$HELM_CHART" ]]; then
    return
  fi

  local chart_repo="${HELM_CHART%%/*}"
  if [[ -n "$HELM_REPO_NAME" && -n "$HELM_REPO_URL" && "$chart_repo" == "$HELM_REPO_NAME" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: ${HELM_CMD} repo add ${HELM_REPO_NAME} ${HELM_REPO_URL}"
      log "DRY-RUN: ${HELM_CMD} repo update"
    else
      "$HELM_CMD" repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
      "$HELM_CMD" repo update >/dev/null 2>&1 || true
    fi
  fi

  local show_args=(show chart "$HELM_CHART")
  if [[ -n "$HELM_CHART_VERSION_OVERRIDE" ]]; then
    show_args+=(--version "$HELM_CHART_VERSION_OVERRIDE")
  fi

  local output
  if ! output=$("$HELM_CMD" "${show_args[@]}" 2>/dev/null | grep '^version:' | head -n1); then
    log "Unable to determine chart version for ${HELM_CHART}"
    if [[ -n "$HELM_CHART_VERSION_OVERRIDE" ]]; then
      HELM_CHART_VERSION_EFFECTIVE=$(sanitize_dns_label "$HELM_CHART_VERSION_OVERRIDE")
      HELM_CHART_VERSION_RAW="$HELM_CHART_VERSION_OVERRIDE"
    fi
    return
  fi
  local version_raw version
  version_raw=$(printf '%s' "$output" | awk '{print $2}')
  HELM_CHART_VERSION_RAW="$version_raw"
  version=$(sanitize_dns_label "$version_raw")
  HELM_CHART_VERSION_EFFECTIVE="$version"
  log "Helm chart version detected: ${HELM_CHART_VERSION_EFFECTIVE:-unknown}"
}

derive_pvc_name() {
  [[ -n "$PVC_BASE_NAME" ]] || die "PVC_BASE_NAME must not be empty"
  local final_name="$PVC_BASE_NAME"
  local version_tag="$PVC_VERSION_TAG"
  if [[ -z "$version_tag" ]]; then
    if [[ -n "$HELM_CHART_VERSION_EFFECTIVE" ]]; then
      version_tag="$HELM_CHART_VERSION_EFFECTIVE"
    elif [[ -n "$HELM_ACTUAL_VERSION" ]]; then
      version_tag="$HELM_ACTUAL_VERSION"
    fi
  fi
  if [[ -n "$version_tag" ]]; then
    local sanitized
    sanitized=$(sanitize_dns_label "$version_tag")
    [[ -n "$sanitized" ]] || die "PVC version tag '${version_tag}' sanitizes to empty; use letters and numbers."
    PVC_VERSION_SUFFIX="$sanitized"
    final_name="${PVC_BASE_NAME}-${sanitized}"
  else
    PVC_VERSION_SUFFIX=""
  fi
  if ((${#final_name} > 63)); then
    die "PVC name '${final_name}' exceeds Kubernetes 63 character limit"
  fi
  PVC_NAME="$final_name"
  log "Using PVC name: ${PVC_NAME}"
}

derive_pv_name() {
  local base="$PV_BASE_NAME"
  [[ -n "$base" ]] || die "PV_BASE_NAME must not be empty"
  local final_name="$base"
  if [[ -n "$PVC_VERSION_SUFFIX" ]]; then
    final_name="${base}-${PVC_VERSION_SUFFIX}"
  fi
  if ((${#final_name} > 63)); then
    die "PV name '${final_name}' exceeds Kubernetes 63 character limit"
  fi
  PV_NAME="$final_name"
  log "Using PV name: ${PV_NAME}"
}
derive_postgres_pvc_name() {
  [[ -n "$POSTGRES_PVC_BASE_NAME" ]] || die "POSTGRES_PVC_BASE_NAME must not be empty"
  local final_name="$POSTGRES_PVC_BASE_NAME"
  local suffix=""
  local requested_tag="$POSTGRES_PVC_VERSION_TAG"
  if [[ -n "$requested_tag" ]]; then
    suffix=$(sanitize_dns_label "$requested_tag")
    [[ -n "$suffix" ]] || die "Postgres PVC version tag '${requested_tag}' sanitizes to empty; use letters and numbers."
  elif [[ -n "$PVC_VERSION_SUFFIX" ]]; then
    suffix="$PVC_VERSION_SUFFIX"
  fi
  if [[ -n "$suffix" ]]; then
    final_name="${POSTGRES_PVC_BASE_NAME}-${suffix}"
  fi
  if ((${#final_name} > 63)); then
    die "Postgres PVC name '${final_name}' exceeds Kubernetes 63 character limit"
  fi
  POSTGRES_PVC_VERSION_SUFFIX="$suffix"
  POSTGRES_PVC_NAME="$final_name"
  log "Using Postgres PVC name: ${POSTGRES_PVC_NAME}"
}
prepare_values_file() {
  if [[ -z "$HELM_VALUES_PATH" ]]; then
    return
  fi

  if $DRY_RUN; then
    log "DRY-RUN: would substitute PVC/PV placeholders in ${HELM_VALUES_PATH}"
    PREPARED_HELM_VALUES_PATH="$HELM_VALUES_PATH"
    return
  fi

  if ! grep -Fq '{{DIFY_BACKEND_PVC}}' "$HELM_VALUES_PATH"; then
    log "Warning: placeholder {{DIFY_BACKEND_PVC}} not found in ${HELM_VALUES_PATH}"
  fi
  if ! grep -Fq '{{DIFY_BACKEND_PV}}' "$HELM_VALUES_PATH"; then
    log "Warning: placeholder {{DIFY_BACKEND_PV}} not found in ${HELM_VALUES_PATH}"
  fi
  if ! grep -Fq '{{DIFY_POSTGRES_PVC}}' "$HELM_VALUES_PATH"; then
    log "Warning: placeholder {{DIFY_POSTGRES_PVC}} not found in ${HELM_VALUES_PATH}"
  fi
  if ! grep -Fq '{{IMAGE_REPO_PREFIX}}' "$HELM_VALUES_PATH"; then
    log "Warning: placeholder {{IMAGE_REPO_PREFIX}} not found in ${HELM_VALUES_PATH}"
  fi
  if ! grep -Fq '{{IMAGE_REPO_TYPE}}' "$HELM_VALUES_PATH"; then
    log "Warning: placeholder {{IMAGE_REPO_TYPE}} not found in ${HELM_VALUES_PATH}"
  fi

  local tmp
  if tmp=$(mktemp "${SCRIPT_DIR}/.tmp-values-XXXXXX" 2>/dev/null); then
    cp "$HELM_VALUES_PATH" "$tmp"
  else
    tmp="${SCRIPT_DIR}/.tmp-values-${K8S_NAMESPACE:-default}-$$-$(date +%s)"
    cp "$HELM_VALUES_PATH" "$tmp" || die "Failed to create temp values file at ${tmp}"
  fi

  if [[ "$OSTYPE" == darwin* ]]; then
    sed -i '' \
      -e "s|{{DIFY_BACKEND_PVC}}|${PVC_NAME}|g" \
      -e "s|{{DIFY_BACKEND_PV}}|${PV_NAME}|g" \
      -e "s|{{DIFY_POSTGRES_PVC}}|${POSTGRES_PVC_NAME}|g" \
      -e "s|{{IMAGE_REPO_PREFIX}}|${IMAGE_REPO_PREFIX}|g" \
      -e "s|{{IMAGE_REPO_TYPE}}|${IMAGE_REPO_TYPE}|g" \
      "$tmp" || {
        rm -f "$tmp"
        die "Failed to substitute PVC/PV placeholders in ${HELM_VALUES_PATH}"
      }
  else
    sed -i \
      -e "s|{{DIFY_BACKEND_PVC}}|${PVC_NAME}|g" \
      -e "s|{{DIFY_BACKEND_PV}}|${PV_NAME}|g" \
      -e "s|{{DIFY_POSTGRES_PVC}}|${POSTGRES_PVC_NAME}|g" \
      -e "s|{{IMAGE_REPO_PREFIX}}|${IMAGE_REPO_PREFIX}|g" \
      -e "s|{{IMAGE_REPO_TYPE}}|${IMAGE_REPO_TYPE}|g" \
      "$tmp" || {
        rm -f "$tmp"
        die "Failed to substitute PVC/PV placeholders in ${HELM_VALUES_PATH}"
      }
  fi

  PREPARED_HELM_VALUES_PATH="$tmp"
  CLEANUP_FILES+=("$tmp")
  log "Prepared Helm values file with PVC/PV names: ${tmp}"
}

persist_prepared_values_file() {
  if $DRY_RUN; then
    log "Skipping values snapshot because dry-run is enabled"
    return
  fi

  if [[ -z "$PREPARED_HELM_VALUES_PATH" || ! -f "$PREPARED_HELM_VALUES_PATH" ]]; then
    log "Prepared values file not found; skipping snapshot"
    return
  fi

  mkdir -p "$VALUES_LOG_DIR"
  local timestamp
  timestamp=$(date '+%Y%m%d-%H%M%S')
  local snapshot_name="values-${timestamp}.yaml"
  local destination="${VALUES_LOG_DIR}/${snapshot_name}"

  cp "$PREPARED_HELM_VALUES_PATH" "$destination"
  log "Saved prepared Helm values to ${destination}"
}

install_ingress_controller() {
  if [[ -z "$INGRESS_CONTROLLER_MANIFEST" ]]; then
    log "Skipping ingress installation because INGRESS_CONTROLLER_MANIFEST is empty"
    return
  fi

  if kubectl --context "$K8S_CONTEXT" get namespace ingress-nginx >/dev/null 2>&1 && \
     kubectl --context "$K8S_CONTEXT" -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
    log "Ingress nginx controller already present"
    return
  fi

  log "Installing ingress controller from ${INGRESS_CONTROLLER_MANIFEST}"
  run_cmd kubectl --context "$K8S_CONTEXT" apply -f "$INGRESS_CONTROLLER_MANIFEST"

  if $DRY_RUN; then
    return
  fi

  log "Waiting for ingress-nginx-controller rollout"
  kubectl --context "$K8S_CONTEXT" -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=180s >/dev/null || \
    die "Ingress controller failed to become ready"
}

load_local_images() {
  if [[ -z "$LOCAL_DOCKER_IMAGES" ]]; then
    return
  fi

  IFS=',' read -ra images <<< "$LOCAL_DOCKER_IMAGES"
  local image
  for image in "${images[@]}"; do
    image="${image#${image%%[![:space:]]*}}"
    image="${image%${image##*[![:space:]]}}"
    [[ -z "$image" ]] && continue

    if ! docker image inspect "$image" >/dev/null 2>&1; then
      log "Warning: local image '${image}' not found; skipping kind load"
      continue
    fi

    log "Loading image '${image}' into kind cluster"
    run_cmd kind load docker-image "$image" --name "$KIND_CLUSTER_NAME"
  done
}

render_annotations() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    return
  fi
  local entry
  printf "  annotations:\n"
  IFS=',' read -ra entries <<< "$raw"
  for entry in "${entries[@]}"; do
    entry="${entry#${entry%%[![:space:]]*}}"  # trim leading space
    entry="${entry%${entry##*[![:space:]]}}"  # trim trailing space
    [[ -z "$entry" ]] && continue
    local key="${entry%%=*}"
    local value=""
    if [[ "$entry" == *"="* ]]; then
      value="${entry#*=}"
    fi
    key="${key#${key%%[![:space:]]*}}"; key="${key%${key##*[![:space:]]}}"
    value="${value#${value%%[![:space:]]*}}"; value="${value%${value##*[![:space:]]}}"
    [[ -z "$key" ]] && continue
    if [[ -n "$value" ]]; then
      printf "    %s: \"%s\"\n" "$key" "$value"
    else
      printf "    %s: \"\"\n" "$key"
    fi
  done
}

ensure_kind_cluster() {
  if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log "Kind cluster '${KIND_CLUSTER_NAME}' already exists"
    return
  fi

  log "Creating kind cluster '${KIND_CLUSTER_NAME}'"
  if [[ -n "${KIND_CONFIG_FILE:-}" ]]; then
    [[ -f "$KIND_CONFIG_FILE" ]] || die "KIND_CONFIG_FILE not found: $KIND_CONFIG_FILE"
    if $DRY_RUN; then
      log "DRY-RUN: kind create cluster --name ${KIND_CLUSTER_NAME} --config ${KIND_CONFIG_FILE}"
    else
      kind create cluster --name "$KIND_CLUSTER_NAME" --config "$KIND_CONFIG_FILE"
    fi
    return
  fi

  local tmp_config
  tmp_config=$(mktemp)
  cat >"$tmp_config" <<CFG
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 80
    hostPort: ${KIND_HTTP_PORT:-80}
    protocol: TCP
  - containerPort: 443
    hostPort: ${KIND_HTTPS_PORT:-443}
    protocol: TCP
CFG

  if $DRY_RUN; then
    log "DRY-RUN: kind create cluster --name ${KIND_CLUSTER_NAME} --config ${tmp_config}"
  else
    kind create cluster --name "$KIND_CLUSTER_NAME" --config "$tmp_config"
  fi

  if ! $DRY_RUN; then
    rm -f "$tmp_config"
  fi
}

ensure_namespace() {
  if kubectl --context "$K8S_CONTEXT" get namespace "$K8S_NAMESPACE" >/dev/null 2>&1; then
    log "Namespace '${K8S_NAMESPACE}' already exists"
  else
    log "Creating namespace '${K8S_NAMESPACE}'"
    run_cmd kubectl --context "$K8S_CONTEXT" create namespace "$K8S_NAMESPACE"
  fi

  if [[ "$HELM_NAMESPACE" != "$K8S_NAMESPACE" ]]; then
    if kubectl --context "$K8S_CONTEXT" get namespace "$HELM_NAMESPACE" >/dev/null 2>&1; then
      log "Helm namespace '${HELM_NAMESPACE}' already exists"
    else
      log "Creating helm namespace '${HELM_NAMESPACE}'"
      run_cmd kubectl --context "$K8S_CONTEXT" create namespace "$HELM_NAMESPACE"
    fi
  fi
}

apply_single_pvc() {
  local name="$1"
  local access_mode="$2"
  local size="$3"
  local storage_class="$4"
  local annotations="$5"

  [[ -n "$name" ]] || return

  log "Applying PVC '${name}'"
  if $DRY_RUN; then
    log "DRY-RUN: kubectl apply pvc ${name}"
    return
  fi

  local tmp_yaml
  tmp_yaml=$(mktemp)
  {
    echo "apiVersion: v1"
    echo "kind: PersistentVolumeClaim"
    echo "metadata:"
    echo "  name: ${name}"
    echo "  namespace: ${K8S_NAMESPACE}"
    render_annotations "$annotations"
    echo "spec:"
    echo "  accessModes:"
    echo "  - ${access_mode}"
    if [[ -n "$storage_class" ]]; then
      echo "  storageClassName: ${storage_class}"
    fi
    echo "  resources:"
    echo "    requests:"
    echo "      storage: ${size}"
  } >"$tmp_yaml"
  kubectl --context "$K8S_CONTEXT" apply -f "$tmp_yaml"
  rm -f "$tmp_yaml"
}

apply_pvc() {
  apply_single_pvc "$PVC_NAME" "$PVC_ACCESS_MODE" "$PVC_SIZE" "$PVC_STORAGE_CLASS" "$PVC_ANNOTATIONS"
  if [[ "$POSTGRES_PVC_NAME" == "$PVC_NAME" ]]; then
    log "Postgres PVC name matches backend PVC; skipping duplicate apply"
    return
  fi
  apply_single_pvc "$POSTGRES_PVC_NAME" "$POSTGRES_PVC_ACCESS_MODE" "$POSTGRES_PVC_SIZE" "$POSTGRES_PVC_STORAGE_CLASS" "$POSTGRES_PVC_ANNOTATIONS"
}

create_image_secret() {
  if [[ -z "$IMAGE_REGISTRY_SERVER" ]]; then
    log "Skipping image pull secret because IMAGE_REGISTRY_SERVER is empty"
    return
  fi

  if [[ -z "$IMAGE_REGISTRY_USERNAME" || -z "$IMAGE_REGISTRY_PASSWORD" ]]; then
    die "IMAGE_REGISTRY_USERNAME and IMAGE_REGISTRY_PASSWORD must be set when IMAGE_REGISTRY_SERVER is provided"
  fi

  if [[ ! -f "$IMAGE_REPO_SECRET_SCRIPT" ]]; then
    die "Secret generator script not found: $IMAGE_REPO_SECRET_SCRIPT"
  fi

  log "Creating/updating image pull secret '${IMAGE_REPO_SECRET_NAME}' via ${IMAGE_REPO_SECRET_SCRIPT##*/}"

  if $DRY_RUN; then
    log "DRY-RUN: ${IMAGE_REPO_SECRET_SCRIPT##*/} ${IMAGE_REGISTRY_USERNAME} **** $K8S_NAMESPACE $IMAGE_REGISTRY_SERVER ${IMAGE_REPO_SECRET_NAME} ${K8S_CONTEXT:-}"
    return
  fi

  if ! bash "$IMAGE_REPO_SECRET_SCRIPT" \
      "$IMAGE_REGISTRY_USERNAME" \
      "$IMAGE_REGISTRY_PASSWORD" \
      "$K8S_NAMESPACE" \
      "$IMAGE_REGISTRY_SERVER" \
      "$IMAGE_REPO_SECRET_NAME" \
      "$K8S_CONTEXT"; then
    die "Failed to generate image pull secret using ${IMAGE_REPO_SECRET_SCRIPT}"
  fi
}

deploy_helm_chart() {
  if [[ -n "${HELM_REPO_NAME:-}" && -n "${HELM_REPO_URL:-}" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: ${HELM_CMD} repo add ${HELM_REPO_NAME} ${HELM_REPO_URL}"
    else
      "$HELM_CMD" repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
      "$HELM_CMD" repo update >/dev/null 2>&1 || true
    fi
  fi

  log "Deploying helm release '${HELM_RELEASE_NAME}'"
  local extra_args=()
  if [[ -n "$HELM_ADDITIONAL_ARGS" ]]; then
    # shellcheck disable=SC2206
    extra_args=($HELM_ADDITIONAL_ARGS)
  fi
  local helm_cmd=(
    "$HELM_CMD" upgrade --install "$HELM_RELEASE_NAME" "$HELM_CHART"
    --namespace "$HELM_NAMESPACE"
    --kube-context "$K8S_CONTEXT"
    --values "$PREPARED_HELM_VALUES_PATH"
  )
  if [[ -n "$HELM_CHART_VERSION_OVERRIDE" ]]; then
    helm_cmd+=(--version "$HELM_CHART_VERSION_OVERRIDE")
  fi
  if [[ ${#extra_args[@]} -gt 0 ]]; then
    helm_cmd+=("${extra_args[@]}")
  fi
  if $DRY_RUN; then
    log "DRY-RUN: ${helm_cmd[*]}"
    return
  fi
  "${helm_cmd[@]}"
}

main() {
  ensure_kind_cluster
  ensure_namespace
  install_ingress_controller
  load_local_images
  prepare_values_file
  persist_prepared_values_file
  apply_pvc
  create_image_secret
  deploy_helm_chart
  log "Deployment flow completed."
}

case "$ACTION" in
  set)
    handle_set_command
    ;;
  list)
    handle_list_command
    ;;
  current)
    handle_current_command
    ;;
  install)
    install_flow
    ;;
  *)
    die "Unhandled action: $ACTION"
    ;;
esac
