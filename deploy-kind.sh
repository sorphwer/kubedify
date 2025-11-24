#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}" )" && pwd)
TEMPLATE_PROFILES_DIR="${SCRIPT_DIR}/profiles"
DEFAULT_PROFILE_NAME="default"

CONFIG_HOME_OVERRIDE="${KUBEDIFY_CONFIG_HOME:-}"
if [[ -n "$CONFIG_HOME_OVERRIDE" ]]; then
  CONFIG_ROOT="$CONFIG_HOME_OVERRIDE"
else
  CONFIG_ROOT="${XDG_CONFIG_HOME:-${HOME}/.config}/kubedify"
fi

case "$CONFIG_ROOT" in
  "~")
    CONFIG_ROOT="${HOME}"
    ;;
  "~/"*)
    CONFIG_ROOT="${HOME}/${CONFIG_ROOT:2}"
    ;;
esac

CONFIG_DIR="${CONFIG_ROOT}/profiles"
PROFILE_STATE_FILE="${CONFIG_ROOT}/.config-profile"
LEGACY_CONFIG_DIR="${SCRIPT_DIR}/profiles"
LEGACY_PROFILE_STATE_FILE="${SCRIPT_DIR}/.config-profile"

SENSITIVE_CONFIG_KEYS=(DOCKER_PAT DOCKER_USERNAME)

INITIAL_CONFIG_FILE="${CONFIG_FILE:-}"
CONFIG_FILE_OVERRIDE=""
PROFILE_OVERRIDE=""
PROFILE_STATE_WRITABLE=true
CONFIG_FILE=""
PROFILE_DIR=""
PROFILE_SECRETS_FILE=""
ACTIVE_PROFILE=""
DRY_RUN=false
INSTALL_VERSION_OVERRIDE=""
ACTION=""
declare -a ACTION_ARGS=()
declare -a CLEANUP_FILES=()

is_sensitive_config_key() {
  local key="$1"
  for sensitive in "${SENSITIVE_CONFIG_KEYS[@]}"; do
    if [[ "$sensitive" == "$key" ]]; then
      return 0
    fi
  done
  return 1
}

mask_secret_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '<unset>'
    return
  fi
  local length=${#value}
  if (( length <= 4 )); then
    printf '%s' "$(printf '%*s' "$length" '' | tr ' ' '*')"
    return
  fi
  local prefix="${value:0:2}"
  local suffix="${value: -2}"
  local middle_len=$((length - 4))
  local middle
  middle=$(printf '%*s' "$middle_len" '' | tr ' ' '*')
  printf '%s%s%s' "$prefix" "$middle" "$suffix"
}

usage() {
  cat <<'USAGE'
Usage: deploy-kind.sh [--config <path>] [--profile <name>] <command> [args]

Commands:
  install [version] [--dry-run]   Deploy the chart, optionally pinning the chart version.
  set <KEY> <VALUE...>            Update a configuration entry in the active config.
  set-docker-username <VALUE>     Store DOCKER_USERNAME in the profile secrets file.
  set-docker-pat <VALUE>          Store DOCKER_PAT in the profile secrets file.
  list                            List available chart versions from the configured Helm repo.
  current                         Show the last recorded installed chart version.
  show                            Print the active configuration JSON.
  profile list                    List known profiles (the active one is marked with *).
  profile create <name>           Create a new profile configuration from the example template.
  profile delete <name>           Delete a stored profile directory and its secrets.
  profile use <name>              Switch the default profile used by subsequent runs.

Options:
  --config <path>                 Provide an explicit config path (disables profile management).
  --profile <name>                Temporarily use the given profile for this invocation.
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
      CONFIG_FILE_OVERRIDE="$2"
      PROFILE_STATE_WRITABLE=false
      shift 2
      ;;
    --profile)
      if [[ $# -lt 2 ]]; then
        echo "Missing value for --profile" >&2
        exit 1
      fi
      PROFILE_OVERRIDE="$2"
      PROFILE_STATE_WRITABLE=false
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

if [[ -z "$CONFIG_FILE_OVERRIDE" && -n "$INITIAL_CONFIG_FILE" ]]; then
  CONFIG_FILE_OVERRIDE="$INITIAL_CONFIG_FILE"
  PROFILE_STATE_WRITABLE=false
fi

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
    ACTION="set-docker-username"
    ACTION_ARGS=("$@")
    ;;
  set-docker-pat)
    ACTION="set-docker-pat"
    ACTION_ARGS=("$@")
    ;;
  list)
    ACTION="list"
    ACTION_ARGS=("$@")
    ;;
  current)
    ACTION="current"
    ACTION_ARGS=("$@")
    ;;
  show)
    ACTION="show"
    ACTION_ARGS=("$@")
    ;;
  profile)
    ACTION="profile"
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

get_local_lan_ip() {
  local ip=""
  
  # Try different methods based on OS
  if [[ "$OSTYPE" == darwin* ]]; then
    # macOS: get IP from en0 (WiFi) or en1 (Ethernet)
    ip=$(ifconfig | grep -A 1 'en0' | grep 'inet ' | awk '{print $2}' | head -n1)
    if [[ -z "$ip" ]]; then
      ip=$(ifconfig | grep -A 1 'en1' | grep 'inet ' | awk '{print $2}' | head -n1)
    fi
  else
    # Linux: use ip command or fallback to ifconfig
    if command -v ip >/dev/null 2>&1; then
      ip=$(ip route get 8.8.8.8 | grep -oP 'src \K\S+' 2>/dev/null || true)
    fi
    if [[ -z "$ip" ]] && command -v ifconfig >/dev/null 2>&1; then
      ip=$(ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | head -n1 | sed 's/addr://')
    fi
  fi
  
  # Validate IP format
  if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s' "$ip"
    return 0
  fi
  
  return 1
}

ensure_local_registry() {
  local registry_port="${LOCAL_REGISTRY_PORT:-17488}"
  local registry_name="${LOCAL_REGISTRY_NAME:-kind-registry}"
  
  # Check if registry container already exists and is running
  if docker ps --format '{{.Names}}' | grep -q "^${registry_name}$"; then
    log "Local registry '${registry_name}' is already running on port ${registry_port}"
    return 0
  fi
  
  # Check if container exists but is stopped
  if docker ps -a --format '{{.Names}}' | grep -q "^${registry_name}$"; then
    log "Starting existing local registry '${registry_name}'"
    if $DRY_RUN; then
      log "DRY-RUN: docker start ${registry_name}"
    else
      docker start "$registry_name" || die "Failed to start local registry"
    fi
    return 0
  fi
  
  # Create new registry container
  log "Creating local registry '${registry_name}' on port ${registry_port}"
  if $DRY_RUN; then
    log "DRY-RUN: docker run -d --restart=always -p ${registry_port}:5000 --name ${registry_name} registry:2"
  else
    docker run -d --restart=always \
      -p "${registry_port}:5000" \
      --name "${registry_name}" \
      registry:2 || die "Failed to create local registry"
  fi
  
  log "Local registry '${registry_name}' is now running on port ${registry_port}"
}

connect_registry_to_kind() {
  local registry_name="${LOCAL_REGISTRY_NAME:-kind-registry}"
  local kind_network="kind"
  
  # Check if registry is connected to kind network
  local network_connected
  network_connected=$(docker inspect "$registry_name" --format '{{range $net, $v := .NetworkSettings.Networks}}{{$net}} {{end}}' 2>/dev/null || true)
  
  if [[ "$network_connected" == *"kind"* ]]; then
    log "Registry already connected to kind network"
    return 0
  fi
  
  # Connect registry to kind network
  log "Connecting registry to kind network"
  if $DRY_RUN; then
    log "DRY-RUN: docker network connect ${kind_network} ${registry_name}"
  else
    docker network connect "$kind_network" "$registry_name" 2>/dev/null || true
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

ensure_profiles_dir() {
  if ! mkdir -p "$CONFIG_DIR"; then
    cat <<EOF >&2
Failed to prepare Kubedify configuration directory at ${CONFIG_DIR}.
Ensure the path is writable or rerun with --config <path> (or set KUBEDIFY_CONFIG_HOME) pointing to a writable location.
EOF
    exit 1
  fi
}

validate_profile_name() {
  local name="$1"
  if [[ -z "$name" ]]; then
    die "Profile name must not be empty"
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "Profile name '$name' may only contain letters, numbers, '.', '_' and '-'"
  fi
}

profile_dir_for_name() {
  local name="$1"
  printf '%s/%s' "$CONFIG_DIR" "$name"
}

config_path_for_profile() {
  local name="$1"
  printf '%s/config.json' "$(profile_dir_for_name "$name")"
}

values_path_for_profile() {
  local name="$1"
  printf '%s/values.yaml' "$(profile_dir_for_name "$name")"
}

secrets_path_for_profile() {
  local name="$1"
  printf '%s/secrets.env' "$(profile_dir_for_name "$name")"
}

migrate_legacy_profile_structure() {
  local name="$1"
  local legacy_config="${CONFIG_DIR}/${name}.json"
  local profile_dir
  profile_dir=$(profile_dir_for_name "$name")
  local target_config="$profile_dir/config.json"
  if [[ -f "$legacy_config" ]]; then
    mkdir -p "$profile_dir"
    mv "$legacy_config" "$target_config"
    log "Moved legacy profile '${name}' config to ${target_config}"
  fi
}

migrate_legacy_profile_root() {
  if [[ "$CONFIG_DIR" == "$LEGACY_CONFIG_DIR" ]]; then
    return
  fi
  if [[ ! -d "$LEGACY_CONFIG_DIR" ]]; then
    return
  fi

  shopt -s dotglob nullglob
  for legacy_profile_dir in "$LEGACY_CONFIG_DIR"/*; do
    [[ -d "$legacy_profile_dir" ]] || continue
    local name
    name=$(basename "$legacy_profile_dir")
    local target
    target=$(profile_dir_for_name "$name")
    if [[ -d "$target" ]]; then
      continue
    fi
    mkdir -p "$target"
    cp -R "$legacy_profile_dir"/. "$target"/
    log "Seeded profile '${name}' at ${target}"
  done
  shopt -u dotglob nullglob

  if [[ -f "$LEGACY_PROFILE_STATE_FILE" && ! -f "$PROFILE_STATE_FILE" ]]; then
    mkdir -p "$(dirname "$PROFILE_STATE_FILE")"
    cp "$LEGACY_PROFILE_STATE_FILE" "$PROFILE_STATE_FILE"
    log "Seeded profile state at ${PROFILE_STATE_FILE}"
  fi
}

migrate_legacy_default_assets() {
  local target_config=$(config_path_for_profile "$DEFAULT_PROFILE_NAME")
  local target_dir
  target_dir=$(profile_dir_for_name "$DEFAULT_PROFILE_NAME")
  local legacy_config="${SCRIPT_DIR}/config.json"
  if [[ -f "$legacy_config" && ! -f "$target_config" ]]; then
    mkdir -p "$target_dir"
    mv "$legacy_config" "$target_config"
    log "Moved legacy config.json to ${target_config}"
  fi
  local target_values=$(values_path_for_profile "$DEFAULT_PROFILE_NAME")
  local legacy_values="${SCRIPT_DIR}/values.yaml"
  if [[ -f "$legacy_values" && ! -f "$target_values" ]]; then
    mkdir -p "$target_dir"
    mv "$legacy_values" "$target_values"
    log "Moved legacy values.yaml to ${target_values}"
  fi

  local template_dir="${TEMPLATE_PROFILES_DIR}/${DEFAULT_PROFILE_NAME}"
  if [[ -d "$template_dir" ]]; then
    local template_config="${template_dir}/config.json"
    local template_values="${template_dir}/values.yaml"
    if [[ ! -f "$target_config" && -f "$template_config" ]]; then
      mkdir -p "$target_dir"
      cp "$template_config" "$target_config"
      log "Seeded default config from template at ${template_config}"
    fi
    if [[ ! -f "$target_values" && -f "$template_values" ]]; then
      mkdir -p "$target_dir"
      cp "$template_values" "$target_values"
      log "Seeded default values from template at ${template_values}"
    fi
  fi
}

current_profile_from_state() {
  if [[ ! -f "$PROFILE_STATE_FILE" ]]; then
    return 0
  fi
  local value
  value=$(<"$PROFILE_STATE_FILE")
  value=${value%$'\r'}
  value=${value%$'\n'}
  printf '%s' "$value"
}

write_profile_state() {
  if [[ "$PROFILE_STATE_WRITABLE" != true ]]; then
    return
  fi
  [[ -n "$ACTIVE_PROFILE" ]] || return
  mkdir -p "$(dirname "$PROFILE_STATE_FILE")"
  printf '%s\n' "$ACTIVE_PROFILE" >"$PROFILE_STATE_FILE"
}

bootstrap_profile_dir() {
  local name="$1"
  migrate_legacy_profile_structure "$name"
  local dir
  dir=$(profile_dir_for_name "$name")
  local config="$dir/config.json"
  local values="$dir/values.yaml"
  local template_dir="${TEMPLATE_PROFILES_DIR}/${name}"
  local template_config="${template_dir}/config.json"
  local template_values="${template_dir}/values.yaml"
  local template_secrets="${template_dir}/secrets.env"
  local default_template_config="${TEMPLATE_PROFILES_DIR}/${DEFAULT_PROFILE_NAME}/config.json"
  local default_template_values="${TEMPLATE_PROFILES_DIR}/${DEFAULT_PROFILE_NAME}/values.yaml"
  local default_template_secrets="${TEMPLATE_PROFILES_DIR}/${DEFAULT_PROFILE_NAME}/secrets.env"
  mkdir -p "$dir"

  if [[ ! -f "$config" ]]; then
    if [[ "$name" != "$DEFAULT_PROFILE_NAME" && -f "$(config_path_for_profile "$DEFAULT_PROFILE_NAME")" ]]; then
      cp "$(config_path_for_profile "$DEFAULT_PROFILE_NAME")" "$config"
    elif [[ -f "$template_config" ]]; then
      cp "$template_config" "$config"
    elif [[ -f "$default_template_config" ]]; then
      cp "$default_template_config" "$config"
    elif [[ -f "$SCRIPT_DIR/config.example.json" ]]; then
      cp "$SCRIPT_DIR/config.example.json" "$config"
    else
      printf '{}\n' >"$config"
    fi
    log "Created config for profile '${name}' at ${config}"
  fi

  if [[ ! -f "$values" ]]; then
    if [[ "$name" != "$DEFAULT_PROFILE_NAME" && -f "$(values_path_for_profile "$DEFAULT_PROFILE_NAME")" ]]; then
      cp "$(values_path_for_profile "$DEFAULT_PROFILE_NAME")" "$values"
    elif [[ -f "$template_values" ]]; then
      cp "$template_values" "$values"
    elif [[ -f "$default_template_values" ]]; then
      cp "$default_template_values" "$values"
    elif [[ -f "$SCRIPT_DIR/values.example.yaml" ]]; then
      cp "$SCRIPT_DIR/values.example.yaml" "$values"
    elif [[ -f "$SCRIPT_DIR/values.yaml" ]]; then
      cp "$SCRIPT_DIR/values.yaml" "$values"
    else
      printf '# add chart overrides here\n' >"$values"
    fi
    log "Created values file for profile '${name}' at ${values}"
  fi

  local secrets="$dir/secrets.env"
  if [[ ! -f "$secrets" ]]; then
    if [[ -f "$template_secrets" ]]; then
      cp "$template_secrets" "$secrets"
    elif [[ -f "$default_template_secrets" ]]; then
      cp "$default_template_secrets" "$secrets"
    else
      : >"$secrets"
    fi
    chmod 600 "$secrets" 2>/dev/null || true
    log "Created secrets file for profile '${name}' at ${secrets}"
  fi
}

ensure_profile_config_exists() {
  local target="$1"
  local profile="$2"
  if [[ -z "$profile" ]]; then
    if [[ ! -f "$target" ]]; then
      if [[ -f "$SCRIPT_DIR/config.example.json" ]]; then
        cp "$SCRIPT_DIR/config.example.json" "$target"
        log "Created config at ${target} from config.example.json"
      else
        printf '{}\n' >"$target"
        log "Created empty config at ${target}"
      fi
    fi
    return
  fi
  bootstrap_profile_dir "$profile"
}

ensure_profile_secrets_file() {
  if [[ -z "$PROFILE_SECRETS_FILE" ]]; then
    die "Secret storage is unavailable when --config is supplied."
  fi
  local secrets_dir
  secrets_dir=$(dirname "$PROFILE_SECRETS_FILE")
  mkdir -p "$secrets_dir"
  if [[ ! -f "$PROFILE_SECRETS_FILE" ]]; then
    local old_umask
    old_umask=$(umask)
    umask 0077
    : >"$PROFILE_SECRETS_FILE"
    umask "$old_umask"
  fi
  chmod 600 "$PROFILE_SECRETS_FILE" 2>/dev/null || true
}

load_profile_secrets() {
  if [[ -z "$PROFILE_SECRETS_FILE" || ! -f "$PROFILE_SECRETS_FILE" ]]; then
    return
  fi
  require_cmd python3
  while IFS= read -r __secret_line; do
    [[ -z "$__secret_line" ]] && continue
    local __key=${__secret_line%%=*}
    local __value=${__secret_line#*=}
    if [[ -n "${!__key+x}" ]]; then
      continue
    fi
    export "${__key}=${__value}"
  done < <(python3 - "$PROFILE_SECRETS_FILE" <<'PYSECRETS'
import pathlib
import shlex
import sys
import re

path = pathlib.Path(sys.argv[1])
if not path.exists():
    sys.exit(0)

pattern = re.compile(r'^[A-Z_][A-Z0-9_]*$')

for lineno, raw in enumerate(path.read_text().splitlines(), 1):
    line = raw.strip()
    if not line or line.startswith('#'):
        continue
    if '=' not in line:
        raise SystemExit(f"Invalid secrets entry on line {lineno}: {raw}")
    key, value = line.split('=', 1)
    key = key.strip()
    if not pattern.match(key):
        raise SystemExit(f"Invalid secret key '{key}' on line {lineno}")
    decoded_parts = shlex.split(value, posix=True)
    if len(decoded_parts) > 1:
        raise SystemExit(f"Invalid secret value on line {lineno}: {raw}")
    decoded = decoded_parts[0] if decoded_parts else ''
    print(f"{key}={decoded}")
PYSECRETS
  )
}

set_secret_value() {
  local key="$1"
  local value="$2"
  ensure_profile_secrets_file
  require_cmd python3
  python3 - "$PROFILE_SECRETS_FILE" "$key" "$value" <<'PYSETSECRET'
import os
import shlex
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

lines = []
if path.exists():
    lines = path.read_text().splitlines()

written = False
new_lines = []
for raw in lines:
    if not raw.strip() or raw.lstrip().startswith('#'):
        new_lines.append(raw)
        continue
    if '=' not in raw:
        new_lines.append(raw)
        continue
    current_key, _ = raw.split('=', 1)
    if current_key == key:
        new_lines.append(f"{key}={shlex.quote(value)}")
        written = True
    else:
        new_lines.append(raw)

if not written:
    new_lines.append(f"{key}={shlex.quote(value)}")

path.write_text("\n".join(new_lines).rstrip("\n") + "\n")
try:
    os.chmod(path, 0o600)
except OSError:
    pass
PYSETSECRET
  export "${key}=${value}"
}

init_profile_environment() {
  ensure_profiles_dir
  migrate_legacy_profile_root
  migrate_legacy_default_assets
  if [[ -n "$CONFIG_FILE_OVERRIDE" ]]; then
    CONFIG_FILE="$CONFIG_FILE_OVERRIDE"
    PROFILE_DIR=$(dirname "$CONFIG_FILE")
    PROFILE_SECRETS_FILE=""
    ACTIVE_PROFILE=""
    return
  fi

  local selected=""
  if [[ -n "$PROFILE_OVERRIDE" ]]; then
    selected="$PROFILE_OVERRIDE"
  else
    selected=$(current_profile_from_state)
  fi
  if [[ -z "$selected" ]]; then
    selected="$DEFAULT_PROFILE_NAME"
  fi
  validate_profile_name "$selected"
  ACTIVE_PROFILE="$selected"
  bootstrap_profile_dir "$ACTIVE_PROFILE"
  PROFILE_DIR=$(profile_dir_for_name "$ACTIVE_PROFILE")
  CONFIG_FILE=$(config_path_for_profile "$ACTIVE_PROFILE")
  PROFILE_SECRETS_FILE=$(secrets_path_for_profile "$ACTIVE_PROFILE")
  write_profile_state
}

ensure_config_for_writing() {
  if [[ -n "$CONFIG_FILE_OVERRIDE" ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    ensure_profile_config_exists "$CONFIG_FILE" ""
    return
  fi
  ensure_profile_config_exists "$CONFIG_FILE" "$ACTIVE_PROFILE"
  write_profile_state
}

ensure_config() {
  if [[ -n "$CONFIG_FILE_OVERRIDE" ]]; then
    if [[ ! -f "$CONFIG_FILE" ]]; then
      die "Config file not found: $CONFIG_FILE"
    fi
    return
  fi
  ensure_profile_config_exists "$CONFIG_FILE" "$ACTIVE_PROFILE"
  write_profile_state
}

init_profile_environment

load_config() {
  ensure_config
  load_profile_secrets
  require_cmd python3
  local warned_sensitive_keys=""
  while IFS= read -r __kv_line; do
    [[ -z "$__kv_line" ]] && continue
    local __key=${__kv_line%%=*}
    local __value=${__kv_line#*=}
    if is_sensitive_config_key "$__key"; then
      if [[ -n "$__value" && $warned_sensitive_keys != *" ${__key} "* ]]; then
        log "Ignoring stored value for sensitive key '${__key}'; provide it via environment variables instead."
        warned_sensitive_keys+=" ${__key} "
      fi
      continue
    fi
    if [[ -n "${!__key+x}" ]]; then
      continue
    fi
    export "${__key}=${__value}"
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
  if is_sensitive_config_key "$key"; then
    die "Configuration key '$key' is managed via the profile secrets file. Use 'kubedify set-docker-username'/'kubedify set-docker-pat' or export the variable manually."
  fi
  ensure_config_for_writing
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
  if is_sensitive_config_key "$key"; then
    die "Configuration key '$key' cannot be persisted in config.json. Use 'kubedify set-docker-username'/'kubedify set-docker-pat' or provide it via environment variables."
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

handle_set_docker_username_command() {
  if ((${#ACTION_ARGS[@]} != 1)); then
    die "Usage: deploy-kind.sh set-docker-username <VALUE>"
  fi
  local value="${ACTION_ARGS[0]}"
  set_secret_value "DOCKER_USERNAME" "$value"
  log "Stored DOCKER_USERNAME in ${PROFILE_SECRETS_FILE}"
}

handle_set_docker_pat_command() {
  if ((${#ACTION_ARGS[@]} != 1)); then
    die "Usage: deploy-kind.sh set-docker-pat <VALUE>"
  fi
  local value="${ACTION_ARGS[0]}"
  set_secret_value "DOCKER_PAT" "$value"
  log "Stored DOCKER_PAT in ${PROFILE_SECRETS_FILE}"
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

handle_show_command() {
  if ((${#ACTION_ARGS[@]} > 0)); then
    die "show command does not accept additional arguments"
  fi
  ensure_config
  load_profile_secrets
  require_cmd python3
  if [[ -n "$ACTIVE_PROFILE" ]]; then
    echo "Active profile: $ACTIVE_PROFILE"
  fi
  echo "Config path: $CONFIG_FILE"
  if [[ -n "$PROFILE_SECRETS_FILE" ]]; then
    echo "Secrets path: $PROFILE_SECRETS_FILE"
  fi
  python3 - "$CONFIG_FILE" "${SENSITIVE_CONFIG_KEYS[@]}" <<'PYSHOW'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text().strip()
if not text:
    data = {}
else:
    data = json.loads(text)

sensitive = set(sys.argv[2:])
for key in sensitive:
    if key in data:
        if data[key] in (None, ""):
            data[key] = "<managed via secrets.env>"
        else:
            data[key] = "<redacted>"

print(json.dumps(data, indent=2, sort_keys=True))
PYSHOW
  print_secrets_summary
}

print_secrets_summary() {
  if [[ -z "$PROFILE_SECRETS_FILE" || ! -f "$PROFILE_SECRETS_FILE" ]]; then
    return
  fi
  local username="${DOCKER_USERNAME:-}"
  local pat="${DOCKER_PAT:-}"
  echo "Secrets summary:"
  if [[ -n "$username" ]]; then
    echo "  DOCKER_USERNAME: $username"
  else
    echo "  DOCKER_USERNAME: <unset>"
  fi
  echo "  DOCKER_PAT: $(mask_secret_value "$pat")"
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

profile_list() {
  ensure_profiles_dir
  shopt -s nullglob
  for legacy in "$CONFIG_DIR"/*.json; do
    local legacy_name
    legacy_name=$(basename "$legacy" .json)
    migrate_legacy_profile_structure "$legacy_name"
    [[ -n "$legacy_name" ]] && bootstrap_profile_dir "$legacy_name"
  done
  shopt -u nullglob

  bootstrap_profile_dir "$DEFAULT_PROFILE_NAME"

  local active="$ACTIVE_PROFILE"
  if [[ -n "$CONFIG_FILE_OVERRIDE" || -n "$PROFILE_OVERRIDE" ]]; then
    active=$(current_profile_from_state)
  fi
  if [[ -z "$active" ]]; then
    active="$DEFAULT_PROFILE_NAME"
  fi

  local names=()
  if [[ -d "$(profile_dir_for_name "$DEFAULT_PROFILE_NAME")" ]]; then
    names+=("$DEFAULT_PROFILE_NAME")
  fi
  shopt -s nullglob
  for dir in "$CONFIG_DIR"/*; do
    [[ -d "$dir" ]] || continue
    local base
    base=$(basename "$dir")
    [[ "$base" == "$DEFAULT_PROFILE_NAME" ]] && continue
    names+=("$base")
  done
  shopt -u nullglob

  if ((${#names[@]} == 0)); then
    echo "No profiles found."
    return
  fi

  local name
  for name in "${names[@]}"; do
    local marker=" "
    if [[ -n "$active" && "$name" == "$active" ]]; then
      marker="*"
    fi
    printf '%s %s (%s)\n' "$marker" "$name" "$(profile_dir_for_name "$name")"
  done
  echo "[* denotes the active profile]"
}

profile_create() {
  local name="$1"
  if [[ -z "$name" ]]; then
    die "Usage: deploy-kind.sh profile create <name>"
  fi
  validate_profile_name "$name"
  if [[ "$name" == "$DEFAULT_PROFILE_NAME" ]]; then
    die "Profile '$name' already exists"
  fi
  local dir
  dir=$(profile_dir_for_name "$name")
  if [[ -d "$dir" ]]; then
    die "Profile '$name' already exists at $dir"
  fi
  bootstrap_profile_dir "$name"
}

profile_delete() {
  local name="$1"
  if [[ -z "$name" ]]; then
    die "Usage: deploy-kind.sh profile delete <name>"
  fi
  validate_profile_name "$name"
  migrate_legacy_profile_structure "$name"
  local dir
  dir=$(profile_dir_for_name "$name")
  if [[ ! -d "$dir" ]]; then
    die "Profile '$name' does not exist."
  fi
  if [[ "$name" == "$ACTIVE_PROFILE" && "$PROFILE_STATE_WRITABLE" != true ]]; then
    die "Cannot delete the active profile when --profile or --config is supplied."
  fi
  if ! rm -rf "$dir"; then
    die "Failed to delete profile directory at ${dir}"
  fi
  log "Deleted profile '${name}' at ${dir}"

  if [[ "$ACTIVE_PROFILE" == "$name" ]]; then
    local fallback=""
    if [[ "$name" != "$DEFAULT_PROFILE_NAME" && -d "$(profile_dir_for_name "$DEFAULT_PROFILE_NAME")" ]]; then
      fallback="$DEFAULT_PROFILE_NAME"
    else
      shopt -s nullglob
      local candidate=""
      for candidate_dir in "$CONFIG_DIR"/*; do
        [[ -d "$candidate_dir" ]] || continue
        candidate=$(basename "$candidate_dir")
        [[ "$candidate" == "$name" ]] && continue
        fallback="$candidate"
        break
      done
      shopt -u nullglob
    fi

    if [[ -n "$fallback" ]]; then
      ACTIVE_PROFILE="$fallback"
      PROFILE_DIR=$(profile_dir_for_name "$ACTIVE_PROFILE")
      CONFIG_FILE=$(config_path_for_profile "$ACTIVE_PROFILE")
      PROFILE_SECRETS_FILE=$(secrets_path_for_profile "$ACTIVE_PROFILE")
      bootstrap_profile_dir "$ACTIVE_PROFILE"
      write_profile_state
      log "Set active profile to '${ACTIVE_PROFILE}'"
    else
      ACTIVE_PROFILE=""
      PROFILE_DIR=""
      CONFIG_FILE=""
      PROFILE_SECRETS_FILE=""
      if [[ "$PROFILE_STATE_WRITABLE" == true ]]; then
        rm -f "$PROFILE_STATE_FILE"
      fi
      log "Cleared active profile state; no profiles remain."
    fi
  fi
}

profile_use() {
  local name="$1"
  if [[ -z "$name" ]]; then
    die "Usage: deploy-kind.sh profile use <name>"
  fi
  validate_profile_name "$name"
  migrate_legacy_profile_structure "$name"
  local dir
  dir=$(profile_dir_for_name "$name")
  local path
  path=$(config_path_for_profile "$name")
  if [[ "$name" == "$DEFAULT_PROFILE_NAME" ]]; then
    bootstrap_profile_dir "$DEFAULT_PROFILE_NAME"
  fi
  if [[ ! -f "$path" ]]; then
    bootstrap_profile_dir "$name"
  fi
  if [[ ! -f "$path" ]]; then
    die "Profile '$name' does not exist. Run 'deploy-kind.sh profile create $name' first."
  fi
  ACTIVE_PROFILE="$name"
  CONFIG_FILE="$path"
  PROFILE_DIR="$dir"
  PROFILE_SECRETS_FILE=$(secrets_path_for_profile "$name")
  CONFIG_FILE_OVERRIDE=""
  PROFILE_OVERRIDE=""
  PROFILE_STATE_WRITABLE=true
  write_profile_state
  log "Switched active profile to '$name' (${path})"
}

handle_profile_command() {
  if [[ -n "$CONFIG_FILE_OVERRIDE" ]]; then
    die "Profile management is unavailable when --config is supplied"
  fi
  if ((${#ACTION_ARGS[@]} == 0)); then
    die "Usage: deploy-kind.sh profile <list|create|delete|use> [...]"
  fi
  local subcommand="${ACTION_ARGS[0]}"
  case "$subcommand" in
    list)
      profile_list
      ;;
    create)
      profile_create "${ACTION_ARGS[1]:-}"
      ;;
    delete)
      profile_delete "${ACTION_ARGS[1]:-}"
      ;;
    use)
      profile_use "${ACTION_ARGS[1]:-}"
      ;;
    *)
      die "Unknown profile subcommand: $subcommand"
      ;;
  esac
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
  HELM_TIMEOUT=${HELM_TIMEOUT:-10m}
  KIND_POSTGRES_PORT=${KIND_POSTGRES_PORT:-5432}
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
  LOCAL_REGISTRY_PORT=${LOCAL_REGISTRY_PORT:-17488}
  LOCAL_REGISTRY_NAME=${LOCAL_REGISTRY_NAME:-kind-registry}
  
  # Setup local registry and get LAN IP
  log "Setting up local Docker registry..."
  ensure_local_registry
  
  local lan_ip
  if ! lan_ip=$(get_local_lan_ip); then
    die "Failed to detect local LAN IP address. Please set IMAGE_REPO_PREFIX manually."
  fi
  log "Detected local LAN IP: ${lan_ip}"
  
  # Use internal registry address for K8s pods (registry container listens on port 5000 internally)
  IMAGE_REPO_PREFIX="${LOCAL_REGISTRY_NAME}:5000"
  IMAGE_REPO_TYPE=${IMAGE_REPO_TYPE:-docker}
  log "Using IMAGE_REPO_PREFIX: ${IMAGE_REPO_PREFIX}"
  log "Note: External access (from host) uses ${lan_ip}:${LOCAL_REGISTRY_PORT}"
  
  INGRESS_CONTROLLER_MANIFEST=${INGRESS_CONTROLLER_MANIFEST:-https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml}
  LOCAL_DOCKER_IMAGES=${LOCAL_DOCKER_IMAGES:-}
  local resolved_values_log_dir=""
  if [[ -n "${VALUES_LOG_DIR:-}" ]]; then
    if [[ "${VALUES_LOG_DIR}" == /* ]]; then
      resolved_values_log_dir="${VALUES_LOG_DIR}"
    elif [[ -n "${PROFILE_DIR:-}" ]]; then
      resolved_values_log_dir="${PROFILE_DIR}/${VALUES_LOG_DIR}"
    else
      resolved_values_log_dir="${SCRIPT_DIR}/${VALUES_LOG_DIR}"
    fi
  elif [[ -n "${PROFILE_DIR:-}" ]]; then
    resolved_values_log_dir="${PROFILE_DIR}/log"
  else
    resolved_values_log_dir="${SCRIPT_DIR}/log"
  fi
  VALUES_LOG_DIR="$resolved_values_log_dir"
  IMAGE_REPO_SECRET_SCRIPT=${IMAGE_REPO_SECRET_SCRIPT:-"${SCRIPT_DIR}/generate-image-repo-secret.sh"}

  require_cmd docker
  require_cmd kind
  require_cmd kubectl

  local values_reference="${HELM_VALUES_FILE:-}"
  if [[ -z "$values_reference" ]]; then
    values_reference="values.yaml"
  fi
  local resolved_values=""
  if [[ -f "$values_reference" ]]; then
    resolved_values="$values_reference"
  elif [[ "$values_reference" != /* && -n "$PROFILE_DIR" && -f "$PROFILE_DIR/$values_reference" ]]; then
    resolved_values="$PROFILE_DIR/$values_reference"
  elif [[ "$values_reference" != /* && -f "${SCRIPT_DIR}/$values_reference" ]]; then
    resolved_values="${SCRIPT_DIR}/$values_reference"
  fi

  if [[ -z "$resolved_values" ]]; then
    die "Helm values file not found: $values_reference"
  fi
  HELM_VALUES_PATH="$resolved_values"

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

resolve_values_file_for_update() {
  local reference="${HELM_VALUES_FILE:-values.yaml}"

  if [[ -n "${HELM_VALUES_PATH:-}" && -f "$HELM_VALUES_PATH" ]]; then
    printf '%s' "$HELM_VALUES_PATH"
    return 0
  fi

  if [[ "$reference" == /* && -f "$reference" ]]; then
    printf '%s' "$reference"
    return 0
  fi

  if [[ -n "${PROFILE_DIR:-}" && -f "${PROFILE_DIR}/${reference}" ]]; then
    printf '%s' "${PROFILE_DIR}/${reference}"
    return 0
  fi

  if [[ -f "$reference" ]]; then
    printf '%s' "$reference"
    return 0
  fi

  if [[ -f "${SCRIPT_DIR}/${reference}" ]]; then
    printf '%s' "${SCRIPT_DIR}/${reference}"
    return 0
  fi

  return 1
}

resolve_enterprise_chart_image() {
  if [[ -n "${ENTERPRISE_CHART_IMAGE_REPOSITORY:-}" && -n "${ENTERPRISE_CHART_IMAGE_TAG:-}" ]]; then
    return
  fi

  require_cmd helm
  if [[ -z "${HELM_CMD:-}" ]]; then
    HELM_CMD=$(command -v helm)
  fi

  local chart_repo="${HELM_CHART%%/*}"
  if [[ -n "${HELM_REPO_NAME:-}" && -n "${HELM_REPO_URL:-}" && "$chart_repo" == "$HELM_REPO_NAME" ]]; then
    if $DRY_RUN; then
      log "DRY-RUN: ${HELM_CMD} repo add ${HELM_REPO_NAME} ${HELM_REPO_URL}"
      log "DRY-RUN: ${HELM_CMD} repo update"
    else
      "$HELM_CMD" repo add "$HELM_REPO_NAME" "$HELM_REPO_URL" >/dev/null 2>&1 || true
      "$HELM_CMD" repo update >/dev/null 2>&1 || true
    fi
  fi

  local show_args=(show values "$HELM_CHART")
  if [[ -n "${HELM_CHART_VERSION_OVERRIDE:-}" ]]; then
    show_args+=(--version "$HELM_CHART_VERSION_OVERRIDE")
  elif [[ -n "${HELM_CHART_VERSION:-}" && "${HELM_CHART_VERSION}" != "latest" ]]; then
    show_args+=(--version "$HELM_CHART_VERSION")
  fi

  local values_output
  if ! values_output=$("$HELM_CMD" "${show_args[@]}"); then
    die "Failed to retrieve Helm values for ${HELM_CHART}"
  fi

  local enterprise_block
  enterprise_block=$(printf '%s\n' "$values_output" | awk '
    /^enterprise:/ {flag=1; next}
    flag && /^[^[:space:]]/ {exit}
    flag {print}
  ')

  local repository tag
  repository=$(printf '%s\n' "$enterprise_block" | awk '
    /repository:/ {
      sub(/^[^:]*:[[:space:]]*/, "", $0);
      gsub(/"/, "", $0);
      print;
      exit
    }')
  tag=$(printf '%s\n' "$enterprise_block" | awk '
    /tag:/ {
      sub(/^[^:]*:[[:space:]]*/, "", $0);
      gsub(/"/, "", $0);
      print;
      exit
    }')

  if [[ -z "$repository" || -z "$tag" ]]; then
    die "Unable to determine enterprise image repository/tag from Helm chart ${HELM_CHART}"
  fi

  ENTERPRISE_CHART_IMAGE_REPOSITORY="$repository"
  ENTERPRISE_CHART_IMAGE_TAG="$tag"
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

check_registry_config_in_cluster() {
  if $DRY_RUN; then
    return 0
  fi
  
  local registry_ip="${1:-}"
  local registry_port="${2:-17488}"
  
  if [[ -z "$registry_ip" ]]; then
    return 0
  fi
  
  # Get control plane node name
  local node_name
  node_name=$(kind get nodes --name "$KIND_CLUSTER_NAME" 2>/dev/null | head -n1)
  
  if [[ -z "$node_name" ]]; then
    return 0
  fi
  
  # Check if containerd config has our registry configuration
  if ! docker exec "$node_name" cat /etc/containerd/config.toml 2>/dev/null | grep -q "${registry_ip}:${registry_port}"; then
    log "WARNING: Existing cluster lacks proper local registry configuration."
    log "To enable local registry support, please delete and recreate the cluster:"
    log "  kind delete cluster --name ${KIND_CLUSTER_NAME}"
    log "  ./deploy-kind.sh install"
    return 1
  fi
  
  return 0
}

ensure_kind_cluster() {
  if kind get clusters | grep -q "^${KIND_CLUSTER_NAME}$"; then
    log "Kind cluster '${KIND_CLUSTER_NAME}' already exists"
    
    # Check if existing cluster has registry configuration
    local registry_ip
    if registry_ip=$(get_local_lan_ip); then
      check_registry_config_in_cluster "$registry_ip" "${LOCAL_REGISTRY_PORT:-17488}" || true
    fi
    
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
  
  # Get local LAN IP for registry configuration
  local registry_ip
  if registry_ip=$(get_local_lan_ip); then
    local registry_port="${LOCAL_REGISTRY_PORT:-17488}"
    local registry_name="${LOCAL_REGISTRY_NAME:-kind-registry}"
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
  - containerPort: 5432
    hostPort: ${KIND_POSTGRES_PORT:-5432}
    protocol: TCP
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${registry_ip}:${registry_port}"]
    endpoint = ["http://${registry_name}:${registry_port}"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."${registry_ip}:${registry_port}".tls]
    insecure_skip_verify = true
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."${registry_name}:5000"]
    endpoint = ["http://${registry_name}:5000"]
  [plugins."io.containerd.grpc.v1.cri".registry.configs."${registry_name}:5000".tls]
    insecure_skip_verify = true
CFG
  else
    # Fallback without registry configuration
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
  - containerPort: 5432
    hostPort: ${KIND_POSTGRES_PORT:-5432}
    protocol: TCP
CFG
  fi

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
  if [[ ! -f "$IMAGE_REPO_SECRET_SCRIPT" ]]; then
    die "Secret generator script not found: $IMAGE_REPO_SECRET_SCRIPT"
  fi

  # For local registry, use the IMAGE_REPO_PREFIX as the registry URL
  local registry_url="${IMAGE_REPO_PREFIX}"
  local username="${IMAGE_REGISTRY_USERNAME:-unused}"
  local password="${IMAGE_REGISTRY_PASSWORD:-unused}"

  log "Creating/updating image pull secret '${IMAGE_REPO_SECRET_NAME}' for registry ${registry_url}"

  if $DRY_RUN; then
    log "DRY-RUN: ${IMAGE_REPO_SECRET_SCRIPT##*/} ${username} **** $K8S_NAMESPACE ${registry_url} ${IMAGE_REPO_SECRET_NAME} ${K8S_CONTEXT:-}"
    return
  fi

  if ! bash "$IMAGE_REPO_SECRET_SCRIPT" \
      "$username" \
      "$password" \
      "$K8S_NAMESPACE" \
      "$registry_url" \
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
    --timeout "$HELM_TIMEOUT"
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

print_access_info() {
  if $DRY_RUN; then
    return
  fi

  local lan_ip
  if lan_ip=$(get_local_lan_ip); then
    local registry_port="${LOCAL_REGISTRY_PORT:-17488}"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Deployment completed successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Dify Application (if Ingress configured):"
    echo "     Console: http://console.dify.local"

    echo "     Enterprise:     http://enterprise.dify.local"
    echo ""
    echo "  💡 Tips:"
    echo "     - Add entries to /etc/hosts for *.dify.local domains"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  else
    echo ""
    echo "✅ Deployment completed successfully!"
    echo ""
    echo "📦 PostgreSQL is accessible at: localhost:${KIND_POSTGRES_PORT:-5432}"
    echo "🐳 Local Registry: ${LOCAL_REGISTRY_NAME:-kind-registry}:5000 (in-cluster)"
    echo ""
  fi
}

main() {
  ensure_kind_cluster
  connect_registry_to_kind
  ensure_namespace
  install_ingress_controller
  load_local_images
  prepare_values_file
  persist_prepared_values_file
  apply_pvc
  create_image_secret
  deploy_helm_chart
  log "Deployment flow completed."
  print_access_info
}

case "$ACTION" in
  set)
    handle_set_command
    ;;
  set-docker-username)
    handle_set_docker_username_command
    ;;
  set-docker-pat)
    handle_set_docker_pat_command
    ;;
  list)
    handle_list_command
    ;;
  current)
    handle_current_command
    ;;
  show)
    handle_show_command
    ;;
  profile)
    handle_profile_command
    ;;
  install)
    install_flow
    ;;
  *)
    die "Unhandled action: $ACTION"
    ;;
esac
