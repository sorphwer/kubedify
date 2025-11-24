# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

KubeDify is a Kubernetes-based installer for Dify that deploys into Kind (Kubernetes in Docker) clusters. It provides a Node.js CLI wrapper (`kubedify`) around a comprehensive Bash orchestration script (`deploy-kind.sh`). The tool manages multi-version deployments with isolated storage, profile-based configuration, and credential management.

## Architecture

### Dual Interface Design

The project exposes two equivalent entry points:
- **Node.js CLI** (`bin/cli.js`): Production interface with progress tracking, colored output, and enhanced UX
- **Bash Script** (`deploy-kind.sh`): Direct shell execution for debugging or shell-only workflows

Both interfaces accept identical commands and options. The Node.js CLI spawns `deploy-kind.sh` as a child process and enhances its output with spinners, progress bars, and formatted logging.

### Core Components

**bin/cli.js** (558 lines)
- Command-line argument parsing via `commander`
- Subprocess management for `deploy-kind.sh`
- Real-time output streaming with formatting (chalk, ora)
- Progressive installation tracking (INSTALL_PROGRESS_STAGES at line 161)
- Configuration path resolution and writability validation
- Signal forwarding (SIGINT/SIGTERM) to child processes

**deploy-kind.sh** (1770 lines)
- Profile-based configuration system with migration support
- Helm chart version resolution and PVC naming derivation
- Template variable substitution for values files
- Kind cluster provisioning with port mapping
- Kubernetes resource orchestration (namespaces, PVCs, secrets, ingress)
- Sensitive credential isolation in `secrets.env` files

**generate-image-repo-secret.sh**
- Generates Kubernetes image pull secrets for private registries
- Called by `deploy-kind.sh` during installation

### Configuration System

**Profile Structure** (stored in `~/.config/kubedify/profiles/<name>/` by default):
```
<profile-name>/
├── config.json       # Non-sensitive settings (cluster, helm, PVC config)
├── values.yaml       # Helm chart overrides with template placeholders
└── secrets.env       # Sensitive credentials (DOCKER_USERNAME, DOCKER_PAT)
```

**Template Placeholders** in values.yaml:
- `{{DIFY_BACKEND_PVC}}` → Resolved PVC name for backend storage
- `{{DIFY_BACKEND_PV}}` → Resolved PV name for backend storage
- `{{DIFY_POSTGRES_PVC}}` → Resolved PVC name for PostgreSQL
- `{{IMAGE_REPO_PREFIX}}` → Docker registry prefix (e.g., `docker.io/username`)
- `{{IMAGE_REPO_TYPE}}` → Registry type (docker, gcr, etc.)

**Profile State Management**:
- Active profile tracked in `~/.config/kubedify/.config-profile`
- Legacy migration from `profiles/` in script directory to user config directory
- `--config <path>` disables profile management for one-off configurations
- `--profile <name>` temporarily overrides active profile without switching

### Version-Based Storage Isolation

Each Helm chart version gets dedicated PVCs to enable smooth switching:
```
dify-backend-pvc-3-5-0    # For chart version 3.5.0
dify-backend-pvc-3-5-2    # For chart version 3.5.2
dify-postgres-pvc-3-5-0
dify-postgres-pvc-3-5-2
```

PVC names are derived automatically in `derive_pvc_name()` (deploy-kind.sh:1332) and `derive_postgres_pvc_name()` (deploy-kind.sh:1372) using sanitized chart versions or Helm binary versions as fallbacks.

## Common Commands

### Development Setup
```bash
# Local development (first time)
npm install
npm link                    # Makes kubedify available globally

# Testing changes
npm pack                    # Create distributable tarball
npm install -g kubedify-1.0.2.tgz  # Install from local package
```

### Primary Workflow
```bash
# Initial setup
kubedify set-docker-username <username>
kubedify set-docker-pat <token>

# Deploy specific chart version
kubedify install 3.5.2

# Upgrade to new version (preserves old data)
kubedify install 3.6.0

# Check current version
kubedify current

# List available chart versions
kubedify list

# View active configuration
kubedify show
```

### Profile Management
```bash
# Create and switch profiles
kubedify profile create production
kubedify profile use production

# List all profiles (active marked with *)
kubedify profile list

# Delete a profile
kubedify profile delete old-env
```

### Configuration
```bash
# Update config values
kubedify set K8S_NAMESPACE dify-prod
kubedify set HELM_TIMEOUT 20m
kubedify set PVC_SIZE 50Gi

# Dry-run to preview changes
kubedify install 3.5.2 --dry-run

# Override profile temporarily
kubedify --profile dev install 3.5.0
```

### Direct Bash Usage
```bash
# Equivalent to kubedify commands
./deploy-kind.sh install 3.5.2 --dry-run
./deploy-kind.sh show
./deploy-kind.sh profile list
```

## Key Implementation Details

### Helm Binary Management
The script can download and cache specific Helm versions (deploy-kind.sh:1184):
- Set `HELM_VERSION` in config.json to download a specific version
- Downloaded to `.bin/helm-<version>` and reused across runs
- Falls back to system `helm` if `HELM_VERSION` is "latest" or unset
- Supports multi-architecture fallback (arm64 → amd64 on Apple Silicon)

### Security Model
Sensitive keys (`DOCKER_PAT`, `DOCKER_USERNAME`) are:
1. Never stored in config.json (blocked in `set_config_value()` at deploy-kind.sh:640)
2. Isolated in per-profile `secrets.env` with 600 permissions
3. Parsed using Python for safe shell quoting (deploy-kind.sh:462)
4. Masked in output via `mask_secret_value()` (deploy-kind.sh:55)

### Kind Cluster Configuration
Default cluster setup (deploy-kind.sh:1552):
- Cluster name from `KIND_CLUSTER_NAME` (default: dify-kind)
- Port mappings: 80 → KIND_HTTP_PORT, 443 → KIND_HTTPS_PORT
- Ingress controller auto-installed from `INGRESS_CONTROLLER_MANIFEST`
- Local images preloaded via `LOCAL_DOCKER_IMAGES` (comma-separated)

### Values File Preparation
Before each deployment (deploy-kind.sh:1393):
1. Copy values.yaml to temporary file
2. Substitute all `{{PLACEHOLDER}}` variables
3. Save timestamped snapshot to `log/values-<timestamp>.yaml`
4. Use prepared file for `helm upgrade --install`

### Installation Flow
Main deployment sequence in `install_flow()` (deploy-kind.sh:1070):
1. Parse arguments and load configuration
2. Setup/validate Helm binary
3. Resolve chart version from repo
4. Derive PVC/PV names based on version
5. Prepare and persist values file
6. Ensure Kind cluster exists
7. Create namespaces
8. Install ingress controller
9. Load local Docker images
10. Apply PVCs
11. Create/update image pull secret
12. Deploy Helm chart
13. Record installed version in config

## Configuration Reference

**Essential Settings** (profiles/default/config.json):
- `KIND_CLUSTER_NAME`: Name of the Kind cluster
- `K8S_NAMESPACE`: Target namespace for Dify (default: dify)
- `HELM_CHART`: Chart name (default: dify/dify)
- `HELM_CHART_VERSION`: Pinned version or "latest"
- `HELM_REPO_NAME`/`HELM_REPO_URL`: Chart repository coordinates
- `PVC_BASE_NAME`: Base name for backend PVC (suffixed with version)
- `POSTGRES_PVC_BASE_NAME`: Base name for PostgreSQL PVC
- `PVC_SIZE`/`POSTGRES_PVC_SIZE`: Storage allocations (default: 2Gi/1Gi)
- `LOCAL_DOCKER_IMAGES`: Comma-separated list for preloading into Kind

**Values File Structure** (profiles/default/values.yaml):
- Global configuration (domains, secrets, integrations)
- Component-specific settings (api, worker, web, sandbox, enterprise)
- Resource limits and replica counts
- Database configuration (PostgreSQL with init scripts)
- Object storage (MinIO) and vector DB (Qdrant)
- Persistence configuration using template placeholders

## Testing and Debugging

### Dry-Run Mode
All commands support `--dry-run` to preview actions without execution:
```bash
kubedify install 3.5.2 --dry-run
```

### Log Files
Prepared values snapshots saved to `log/` directory:
```bash
ls -lt log/           # View recent deployments
cat log/values-20250111-160230.yaml  # Inspect actual values used
```

### Common Issues

**Permission Errors**: If install directory is read-only (e.g., global npm install), profiles automatically use `~/.config/kubedify`. Override with `KUBEDIFY_CONFIG_HOME` or `--config` flag.

**Missing Credentials**: Image pull will fail if `DOCKER_USERNAME`/`DOCKER_PAT` are unset. Set via `kubedify set-docker-username` and `kubedify set-docker-pat`.

**Chart Version Resolution**: If offline or repo unavailable, explicitly set `HELM_CHART_VERSION` in config to avoid lookup failures.

**PVC Naming Conflicts**: Each chart version creates unique PVCs. To reuse storage across versions, manually set `PVC_VERSION_TAG` to a fixed value.

## Code Patterns

### Adding New Commands
1. Add command handler in `bin/cli.js` using `program.command()`
2. Add corresponding case in `deploy-kind.sh` (line 144)
3. Implement handler function in bash (e.g., `handle_<command>_command`)
4. Add to usage text in `deploy-kind.sh` (line 74)

### Configuration Keys
- Non-sensitive keys: Stored in config.json via `set_config_value()`
- Sensitive keys: Add to `SENSITIVE_CONFIG_KEYS` array (deploy-kind.sh:29) and use `set_secret_value()`

### Progress Tracking Enhancement
To add new installation stages, extend `INSTALL_PROGRESS_STAGES` in bin/cli.js:161 with:
- `id`: Unique identifier
- `label`: User-facing description
- `test`: Regex function to match bash output

## Dependencies

**Node.js**: chalk (terminal styling), commander (CLI parsing), ora (spinners)
**System**: docker, kind, kubectl, helm, python3 (for JSON/credential parsing)

## Project Structure

```
kubedify/
├── bin/cli.js                    # Node.js CLI entry point
├── deploy-kind.sh                # Bash orchestration script
├── generate-image-repo-secret.sh # Secret generation utility
├── profiles/default/             # Built-in profile template
│   ├── config.json              # Default configuration
│   ├── values.yaml              # Default Helm overrides
│   └── secrets.env              # Credential template
├── log/                          # Timestamped values snapshots
├── .bin/                         # Downloaded Helm binaries (cached)
└── package.json                  # NPM package definition
```

User profiles live outside the repository in `~/.config/kubedify/profiles/` by default.
