# KubeDify: Kubernetes Dify Installer For You

This repository provides `deploy-kind.sh`, a helper for installing the Dify Helm chart into a local [Kind](https://kind.sigs.k8s.io/) cluster. The script wraps the end-to-end workflow—cluster creation, PVC management, registry secrets, and Helm installation—behind a small CLI so you can move between versions quickly and keep all configuration in a single JSON file.

## Prerequisites

Make sure the following tools are available on your machine:

- Docker (with permissions to create containers)
- Kind
- kubectl
- Helm (any version; the script can download other releases on demand)

The commands assume you can reach the internet to pull Helm charts unless you maintain a local mirror.

## Getting Started

1. **Create a working profile (recommended)**
   ```bash
 ./deploy-kind.sh profile create dev   # copies profiles/default/
 ./deploy-kind.sh profile use dev      # set dev as the active profile
 ```
  The tracked `profiles/default/` stays as your clean template; customize `profiles/dev/config.json` and `profiles/dev/values.yaml` (ignored by git).
  
  You can always inspect the current config with `./deploy-kind.sh show`.

2. **Provide credentials and overrides**
   Use the bundled setters to update common values without editing JSON by hand:
   ```bash
   ./deploy-kind.sh set-docker-username <username>
   ./deploy-kind.sh set-docker-pat <personal-access-token>
   ```
   Any key can be updated in the same way:
   ```bash
   ./deploy-kind.sh set K8S_NAMESPACE dify-dev
   ./deploy-kind.sh set HELM_VALUES_FILE values.yaml
   ```

3. **Review the remaining options**
   The default profile includes sensible starting values for cluster names, PVC sizing, Helm chart coordinates, and ingress settings. Open `profiles/default/config.json` (or your profile’s `config.json`) and its sibling `values.yaml` before running your first install.

## Installing Dify

Run `install` to create (or reuse) the Kind cluster, prepare Kubernetes resources, and deploy the chart:

```bash
./deploy-kind.sh install
```

You can pin a specific chart release or run in dry-run mode:

```bash
./deploy-kind.sh install 3.5.1
./deploy-kind.sh install 3.5.1 --dry-run
```

During installation the script:

- Downloads a matching Helm binary when `HELM_VERSION` is set.
- Resolves the requested chart version, deriving PVC suffixes automatically when not supplied.
- Substitutes placeholders like `{{DIFY_BACKEND_PVC}}` inside your Helm values file and stores a timestamped copy under `log/`.
- Creates/updates PVCs, namespaces, and the image-pull secret using the registry credentials from the config.
- Runs `helm upgrade --install` with any extra flags from `HELM_ADDITIONAL_ARGS`.

After a successful (non-dry) run, the chosen chart version is recorded as `LAST_INSTALLED_VERSION` so you can revisit it later.

## Command Reference

| Command | Description |
| --- | --- |
| `./deploy-kind.sh install [version] [--dry-run]` | Executes the deployment flow. An optional `version` pins the Helm chart release for this run. |
| `./deploy-kind.sh set <KEY> <VALUE...>` | Writes or updates a field in the active profile's config. Additional words are concatenated with spaces. |
| `./deploy-kind.sh set-docker-username <VALUE>` | Convenience wrapper for `set DOCKER_USERNAME`. |
| `./deploy-kind.sh set-docker-pat <VALUE>` | Convenience wrapper for `set DOCKER_PAT`. |
| `./deploy-kind.sh list` | Lists available chart versions from the configured Helm repo. |
| `./deploy-kind.sh current` | Prints the last chart version recorded during installation. |
| `./deploy-kind.sh show` | Prints the active profile name, config path, and formatted JSON contents. |
| `./deploy-kind.sh profile list` | Shows all stored profiles and marks the active one. |
| `./deploy-kind.sh profile create <name>` | Creates a new profile directory (copied from `profiles/default/`). |
| `./deploy-kind.sh profile use <name>` | Switches the default profile used by subsequent commands. |

All commands honour `--config <path>` if you need to work with an ad-hoc file, and `--profile <name>` when you want to temporarily target another stored profile without switching the default.

Configurations are stored per profile. The script provisions a `default` profile under `profiles/default/` (`config.json` + `values.yaml`) and keeps additional profiles in their own directories (`profiles/<name>/`). Use the `profile` subcommands to create or switch profiles; once switched, subsequent invocations reuse that profile automatically.

## Configuration Highlights

Key settings in the active profile's config include:

- `KIND_CLUSTER_NAME`, `KIND_CONFIG_FILE`, `KIND_HTTP_PORT`, `KIND_HTTPS_PORT` – control Kind cluster naming and port exposure.
- `K8S_NAMESPACE`, `HELM_NAMESPACE`, `HELM_RELEASE_NAME` – namespaces and release name for Kubernetes resources.
- `HELM_CHART`, `HELM_CHART_VERSION`, `HELM_REPO_NAME`, `HELM_REPO_URL`, `HELM_VALUES_FILE`, `HELM_ADDITIONAL_ARGS` – Helm chart location and runtime options. Set `HELM_VERSION` to download a specific Helm binary if required.
- `HELM_TIMEOUT` – Helm upgrade timeout (defaults to `10m` if omitted).
- `DOCKER_USERNAME`, `DOCKER_PAT`, `IMAGE_REGISTRY_*`, `IMAGE_REPO_SECRET_NAME` – credentials used to craft the image pull secret.
- `PVC_BASE_NAME`, `POSTGRES_PVC_BASE_NAME`, `PVC_SIZE`, `PVC_STORAGE_CLASS`, `PVC_VERSION_TAG` – storage configuration for both the application and postgres volumes.
- `LOCAL_DOCKER_IMAGES` – comma-separated list of images to preload into the Kind cluster.
- `VALUES_LOG_DIR` – destination for the prepared Helm values snapshots.

Values may be left empty when you want the script to fall back to sane defaults (for example, `K8S_CONTEXT` defaults to `kind-<cluster>` and `IMAGE_REPO_PREFIX` defaults to `docker.io/<DOCKER_USERNAME>`).

## Typical Workflow

1. Update secrets and environment-specific values with `set` commands.
2. Inspect the currently available chart releases:
   ```bash
   ./deploy-kind.sh list | head
   ```
3. Deploy or upgrade Dify to the desired version:
   ```bash
   ./deploy-kind.sh install 3.5.1
   ```
4. Confirm the chart version recorded by the last run:
   ```bash
   ./deploy-kind.sh current
   ```
5. Rerun `install` whenever you need to upgrade; the script is idempotent and will reuse existing resources where possible.

## Notes & Tips

- Keep each profile’s `values.yaml` under source control. The script only swaps placeholder tokens; all other chart configuration remains manual.
- The prepared values snapshot stored in `log/` helps reproduce the exact settings used for a deployment.
- When experimenting with multiple environments, create dedicated profiles (for example, `profile create dev`) and switch between them with `profile use <name>`; use `--profile <name>` when you want a one-off override without changing the default.
- If you switch Docker credentials, rerun `set-docker-username` and `set-docker-pat` before installing to refresh the image pull secret.

For deeper background on the deployment flow, refer to `agent.md`.
