#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: generate-image-repo-secret.sh <username> <password> <namespace> [registry] [secret-name] [kube-context]

Arguments:
  username      Registry username
  password      Registry password or token
  namespace     Kubernetes namespace for the secret
  registry      Optional registry URL (default: https://index.docker.io/v1/)
  secret-name   Optional secret name (default: image-repo-secret)
  kube-context  Optional kubectl context (default: current context)
USAGE
}

if [[ $# -lt 3 ]]; then
  usage >&2
  exit 1
fi

USERNAME="$1"
PASSWORD="$2"
NAMESPACE="$3"
REGISTRY="${4:-https://index.docker.io/v1/}"
SECRET_NAME="${5:-image-repo-secret}"
KUBE_CONTEXT="${6:-}"
EMAIL="${IMAGE_REGISTRY_EMAIL:-unused@example.com}"

KUBECTL_ARGS=()
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL_ARGS+=(--context "$KUBE_CONTEXT")
fi
KUBECTL_ARGS+=(-n "$NAMESPACE")

TMP_YAML=$(mktemp)
trap 'rm -f "$TMP_YAML"' EXIT

# Create Docker config JSON content
DOCKER_CONFIG_JSON=$(cat <<EOF
{
  "auths": {
    "$REGISTRY": {
      "username": "$USERNAME",
      "password": "$PASSWORD",
      "email": "$EMAIL",
      "auth": "$(echo -n "$USERNAME:$PASSWORD" | base64 | tr -d '\n')"
    }
  }
}
EOF
)

# Create secret with both .dockerconfigjson (for standard K8s) and config.json (for Kaniko)
kubectl "${KUBECTL_ARGS[@]}" create secret generic "$SECRET_NAME" \
  --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
  --from-literal=config.json="$DOCKER_CONFIG_JSON" \
  --dry-run=client -o yaml >"$TMP_YAML"

# Add the docker-registry type label for compatibility
cat >>"$TMP_YAML" <<EOF
type: kubernetes.io/dockerconfigjson
EOF

kubectl "${KUBECTL_ARGS[@]}" apply -f "$TMP_YAML"

echo "Image registry secret '$SECRET_NAME' applied to namespace '$NAMESPACE'"
