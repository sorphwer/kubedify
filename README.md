```
.─. .─')             .─. .─')    ('─.  _ .─') _                                  
╲  ( OO )            ╲  ( OO ) _(  OO)( (  OO) )                                 
,──. ,──. ,──. ,──.   ;─────.╲(,──────.╲     .'_   ,─.─')    ,──────. ,──.   ,──.
│  .'   ╱ │  │ │  │   │ .─.  │ │  .───',`'──..._)  │  │OO)('─│ _.───'  ╲  `.'  ╱ 
│      ╱, │  │ │ .─') │ '─' ╱_)│  │    │  │  ╲  '  │  │  ╲(OO│(_╲    .─')     ╱  
│     ' _)│  │_│( OO )│ .─. `.(│  '──. │  │   ' │  │  │(_╱╱  │  '──.(OO  ╲   ╱   
│  .   ╲  │  │ │ `─' ╱│ │  ╲  ││  .──' │  │   ╱ : ,│  │_.'╲_)│  .──' │   ╱  ╱╲_  
│  │╲   ╲('  '─'(_.─' │ '──'  ╱│  `───.│  '──'  ╱(_│  │     ╲│  │_)  `─.╱  ╱.__) 
`──' '──'  `─────'    `──────' `──────'`───────'   `──'      `──'      `──'      
```
# KubeDify: Kubernetes Dify Installer For You

- Install Dify on a k8s with one line command `kubedify install`
- You can run `kubedify install 3.5.0` and rerun it!
- You can run `kubedify install 3.4.1` and just run `kubedify install 3.5.2` , the swtich will be smooth since each version has own PV
- All operations are in your Kind container, you can just delete this container to remove anything

## Quick Start

> Default enterprise image is : dify-enterprise-dev:0.11.3-arm64 , prepare yours in your local images or config it in ` ~/.config/kubedify `

```bash
npm install -g kubedify
#kubedify profile create dev
#kubedify profile use dev
kubedify set-docker-username <username>
kubedify set-docker-pat <personal-access-token>

kubedify install 3.5.2
```
Other helpful commands:
```bash
kubedify show #show current config
kubedify list #show helm chart versions
kubedify profile list #show all profiles and activated one
./list-chart-images.sh --max 10 #show chart versions with corresponding dify-enterprise image tags
```


## Installing the CLI

- **Published package (once released):**
  ```bash
  npm install -g kubedify
  kubedify --help
  ```
- **Local development:**
  ```bash
  npm install
  npm link          # expose kubedify globally from this repo
  kubedify install --dry-run
  ```
  You can also test the distributable artifact with `npm pack` and `npm install <path-to-tgz>` from any scratch directory. All `kubedify` binaries resolve to the same `bin/cli.js` entrypoint that proxies calls to `deploy-kind.sh`.

The Bash script remains executable directly (`./deploy-kind.sh`) if you prefer shell-only workflows; both interfaces accept the same commands and options.

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
  kubedify profile create dev   # copies profiles/default/
  kubedify profile use dev      # set dev as the active profile
  # kubedify profile delete dev # remove the profile again when you no longer need it
  ```
  Kubedify copies the built-in template into your user config directory (default `~/.config/kubedify/profiles/<name>/`). Edit `config.json` and `values.yaml` under that path to customise your environment.
  
  You can always inspect the current config with `kubedify show`.

2. **Provide credentials and overrides**
   Use the bundled setters to update non-secret fields without editing JSON by hand. Secrets are stored in the profile-specific `secrets.env` file:
   ```bash
   kubedify set-docker-username <username>
   kubedify set-docker-pat <personal-access-token>
   ```
   The values stay outside of source control and are scoped per profile; you can still override them per-run with environment variables (for example `DOCKER_PAT=... kubedify install`).
   Any key can be updated in the same way:
   ```bash
   kubedify set K8S_NAMESPACE dify-dev
   kubedify set HELM_VALUES_FILE values.yaml
   ```

3. **Review the remaining options**
   The default profile includes sensible starting values for cluster names, PVC sizing, Helm chart coordinates, and ingress settings. Open `~/.config/kubedify/profiles/default/config.json` (or your profile’s `config.json`) and its sibling `values.yaml` before running your first install. Replace `~/.config` with `$XDG_CONFIG_HOME` or `$KUBEDIFY_CONFIG_HOME` if you have customised the location.

## Installing Dify

Run `install` to create (or reuse) the Kind cluster, prepare Kubernetes resources, and deploy the chart:

```bash
kubedify install
```

You can pin a specific chart release or run in dry-run mode:

```bash
kubedify install 3.5.1
kubedify install 3.5.1 --dry-run
```

During installation the script:

- Downloads a matching Helm binary when `HELM_VERSION` is set.
- Resolves the requested chart version, deriving PVC suffixes automatically when not supplied.
- Substitutes placeholders like `{{DIFY_BACKEND_PVC}}` inside your Helm values file and stores a timestamped copy under the active profile directory (for example `~/.config/kubedify/profiles/<name>/log/`).
- Creates/updates PVCs, namespaces, and the image-pull secret using the registry credentials from the config.
- Runs `helm upgrade --install` with any extra flags from `HELM_ADDITIONAL_ARGS`.

After a successful (non-dry) run, the chosen chart version is recorded as `LAST_INSTALLED_VERSION` so you can revisit it later.


## Command Reference

| Command | Description |
| --- | --- |
| `kubedify install [version] [--dry-run]` | Executes the deployment flow. An optional `version` pins the Helm chart release for this run. |
| `kubedify set <KEY> <VALUE...>` | Writes or updates a field in the active profile's config (sensitive keys such as `DOCKER_USERNAME`/`DOCKER_PAT` are stored via dedicated commands). |
| `kubedify set-docker-username <VALUE>` | Stores `DOCKER_USERNAME` in the profile secrets file. |
| `kubedify set-docker-pat <VALUE>` | Stores `DOCKER_PAT` in the profile secrets file. |
| `kubedify list` | Lists available chart versions from the configured Helm repo. |
| `kubedify current` | Prints the last chart version recorded during installation. |
| `kubedify show` | Prints the active profile name, config path, and formatted JSON contents. |
| `kubedify profile list` | Shows all stored profiles and marks the active one. |
| `kubedify profile create <name>` | Creates a new profile directory (copied from `profiles/default/`). |
| `kubedify profile delete <name>` | Removes a stored profile directory, including its config, values, and secrets. |
| `kubedify profile use <name>` | Switches the default profile used by subsequent commands. |

All commands honour `--config <path>` if you need to work with an ad-hoc file, and `--profile <name>` when you want to temporarily target another stored profile without switching the default.

Configurations are stored per profile under your user config directory (default `~/.config/kubedify/profiles/<name>/`, overrideable via `$XDG_CONFIG_HOME` or `$KUBEDIFY_CONFIG_HOME`). Each profile contains `config.json`, `values.yaml`, and a companion `secrets.env` that holds Docker credentials. The CLI seeds that directory from the bundled templates the first time you reference a profile. Use the `profile` subcommands to create, delete, or switch profiles; once switched, subsequent invocations reuse that profile automatically.

## Configuration Highlights

Key settings in the active profile's config include:

- `KIND_CLUSTER_NAME`, `KIND_CONFIG_FILE`, `KIND_HTTP_PORT`, `KIND_HTTPS_PORT`, `KIND_POSTGRES_PORT` – control Kind cluster naming and port exposure.
- `K8S_NAMESPACE`, `HELM_NAMESPACE`, `HELM_RELEASE_NAME` – namespaces and release name for Kubernetes resources.
- `HELM_CHART`, `HELM_CHART_VERSION`, `HELM_REPO_NAME`, `HELM_REPO_URL`, `HELM_VALUES_FILE`, `HELM_ADDITIONAL_ARGS` – Helm chart location and runtime options. Set `HELM_VERSION` to download a specific Helm binary if required.
- `HELM_TIMEOUT` – Helm upgrade timeout (defaults to `10m` if omitted).
- `DOCKER_USERNAME`, `DOCKER_PAT`, `IMAGE_REGISTRY_*`, `IMAGE_REPO_SECRET_NAME` – credentials used to craft the image pull secret. `DOCKER_USERNAME`/`DOCKER_PAT` live in `secrets.env`; you can still override them per-run via environment variables.
- `PVC_BASE_NAME`, `POSTGRES_PVC_BASE_NAME`, `PVC_SIZE`, `PVC_STORAGE_CLASS`, `PVC_VERSION_TAG` – storage configuration for both the application and postgres volumes.
- `LOCAL_DOCKER_IMAGES` – comma-separated list of images to preload into the Kind cluster.
- `VALUES_LOG_DIR` – destination for the prepared Helm values snapshots (defaults to the active profile's `log/` directory; relative paths resolve against the profile directory).

Values may be left empty when you want the script to fall back to sane defaults (for example, `K8S_CONTEXT` defaults to `kind-<cluster>` and `IMAGE_REPO_PREFIX` defaults to `docker.io/<DOCKER_USERNAME>`).

## Typical Workflow

1. Update secrets and environment-specific values with `set` commands.
2. Inspect the currently available chart releases:
   ```bash
   kubedify list | head
   ```
3. Deploy or upgrade Dify to the desired version:
   ```bash
   kubedify install 3.5.1
   ```
4. Confirm the chart version recorded by the last run:
   ```bash
   kubedify current
   ```
5. Rerun `install` whenever you need to upgrade; the workflow is idempotent and will reuse existing resources where possible.

## Notes & Tips

- Keep each profile’s `values.yaml` under source control. Kubedify only swaps placeholder tokens; all other chart configuration remains manual.
- The prepared values snapshot stored under each profile (for example `~/.config/kubedify/profiles/<name>/log/`; relative `VALUES_LOG_DIR` entries are resolved against that profile directory) helps reproduce the exact settings used for a deployment.
- When experimenting with multiple environments, create dedicated profiles (for example, `kubedify profile create dev`) and switch between them with `kubedify profile use <name>`; add `--profile <name>` when you want a one-off override without changing the default.
- If you switch Docker credentials, rerun `kubedify set-docker-username` and `kubedify set-docker-pat <token>` to refresh the stored secrets (or override them per-run with environment variables).
- Environment variables always win over values stored in `config.json`, making them ideal for per-run overrides or secrets you do not want to commit to disk.
