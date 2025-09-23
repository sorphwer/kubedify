# Dify EE One-Click Deployment on Kind

## Goal & Scope
Use this guide to spin up a fully functional Dify Enterprise Edition (Dify-EE) environment on a local Kind cluster with a single command. The workflow now:
- provisions the required PersistentVolumeClaim automatically,
- bootstraps a local, insecure container registry that Kind can pull from, and
- creates the `imageRepoSecret` using credentials sourced from an env file so the plugin connector can read images from that registry.

## Quickstart (one-time setup)
1. Review prerequisites: Docker, Kind, kubectl, Helm (Kui optional for UI visualization).
2. Copy the provided env template (to be added as `.env.kind.example`) and override only the values you need, such as the namespace, PVC/PV base names, storage size, registry credentials, image repo prefix/type, the Helm values file path (defaults to `values.yaml`), the Helm binary version (defaults to `latest`), the optional Helm chart version (for example `3.4.0`), the PVC version tag (for example `3.4.1`), and the comma-separated list of local Docker images to preload—leave the tag empty to reuse the detected Helm chart version automatically.
3. Run the helper script (to be added as `./deploy-kind.sh`) and hand it the env file, for example:
   ```bash
   ./deploy-kind.sh --env .env.kind.local
   ```
   The script is idempotent: it creates the Kind cluster if missing, wires it to the local registry, applies the PVC manifest, creates/updates the image-pull secret, and rolls out Helm with the supplied values.
4. Validate the installation (see "Post-deploy validation") and add host entries so your browser resolves the Dify endpoints.

## What the script will automate
- **Cluster & ingress** – Creates or reuses a Kind cluster, ensures ingress-nginx is installed (using the manifest URL in the env file), exposes HTTP/HTTPS ports, loads any images listed in `LOCAL_DOCKER_IMAGES`, and connects the Kind network to the local registry container.
- **Persistent volume** – Applies the backend and postgres PVCs (name, size, access mode, storage class) straight from env configuration, removing the need for manual YAML edits.
- **Image registry** – Boots (or reuses) a `registry:2` container bound to `localhost:<PORT>`, optionally logs in with the provided credentials, and prepares it for the Helm release by creating the `imageRepoSecret` inside the target namespace.
- **Helm release** – Runs `helm upgrade --install` with your chosen release name, namespace, chart repo, and values file so Dify EE comes online without extra commands.

## Post-deploy validation
- **Cluster health**
  ```bash
  kubectl cluster-info --context kind-${KIND_CLUSTER_NAME}
  kubectl get nodes
  kubectl get pods -n ${K8S_NAMESPACE}
  ```
- **Hosts entries** – Add the following lines to `/etc/hosts` (or the Windows equivalent) after the first deployment so browser requests resolve locally:
  ```text
  127.0.0.1 console.dify.local
  127.0.0.1 api.dify.local
  127.0.0.1 app.dify.local
  127.0.0.1 upload.dify.local
  127.0.0.1 enterprise.dify.local
  ```
- **Port-forward (when needed)**
  ```bash
  kubectl -n ingress-nginx port-forward service/ingress-nginx-controller 80:80 --address 0.0.0.0
  kubectl -n ${K8S_NAMESPACE} port-forward statefulset/dify-postgresql 5432:5432
  ```

## Before running the script
- **Helm values** – Keep `values.yaml` (or `values-local.yaml`) up to date. Make sure `plugin_connector.imageRepoSecret` matches the secret name from the env file. Leave placeholders like `{{DIFY_BACKEND_PVC}}`, `{{DIFY_BACKEND_PV}}`, `{{DIFY_POSTGRES_PVC}}`, `{{IMAGE_REPO_PREFIX}}`, and `{{IMAGE_REPO_TYPE}}` untouched—the script substitutes them with values derived from your env file on every run; other chart settings remain manual.
- **Helm version pinning** – Set `HELM_VERSION` in your env file if you need to pin or switch Helm releases frequently (for example `3.13.0`). When left as `latest`, the script uses whichever Helm binary is already on your path.
- **Chart version pinning** – Set `HELM_CHART_VERSION` when you want `helm upgrade` to target a specific chart release (for example `3.4.0`); the script also uses it for PVC naming when no explicit suffix is provided.
- **Versioned PVCs** – Provide `PVC_VERSION_TAG` (for example `3.4.1`) so the script creates version-specific PVC/PV resources for both backend and postgres (`<PVC_BASE_NAME>-<tag>` and `<POSTGRES_PVC_BASE_NAME>-<tag>`, plus `<PV_BASE_NAME>-<tag>`). This keeps application and database volumes isolated per deployment. Leaving it empty automatically reuses the chart version (falls back to the Helm binary version if the chart version can’t be resolved).
- **Local images** – List any locally built images (for example `dify-enterprise-dev:0.11.3-arm64`) in `LOCAL_DOCKER_IMAGES`; the script will run `kind load docker-image` for each entry before deploying Helm.
- **Idempotency expectations** – The script can be re-run to upgrade the Helm release or refresh secrets. It will skip work when resources already exist unless `--force` options (to be added) are supplied.

## Manual fallbacks (if automation fails)
Should the automation script abort, the previous manual steps remain valid: create the Kind cluster, install ingress-nginx, apply the PVC manifest, create the namespace, run Helm, and then manually invoke `kubectl create secret docker-registry ...` to establish the image repo secret. The new script intentionally uses the same resource names so you can switch between automated and manual flows without cleanup.
