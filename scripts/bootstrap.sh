#!/usr/bin/env bash
#
# bootstrap.sh — rebuild the entire devops-practice environment from Git.
#
# Everything this project runs is declared in the repository. This script
# stands up a local kind cluster and lets Argo CD pull and deploy the rest:
# the app (Helm chart), Postgres, secrets, and Gateway API ingress.
#
# Usage:   ./scripts/bootstrap.sh
# Teardown: kind delete cluster --name devops
#
# Prerequisites: docker (running), kind, kubectl, helm.

set -euo pipefail

# --- config ---------------------------------------------------------------
CLUSTER_NAME="devops"
ARGOCD_NS="argocd"
EG_NS="envoy-gateway-system"
EG_VERSION="v1.8.3"
GATEWAY_NAME="visits-gateway"
APP_NODEPORT="8080"          # host port mapped in kind-config.yaml
# Resolve repo root so the script works from anywhere.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- pretty output --------------------------------------------------------
step() { printf "\n\033[1;34m==> %s\033[0m\n" "$1"; }
info() { printf "    %s\n" "$1"; }
ok()   { printf "\033[1;32m    ✓ %s\033[0m\n" "$1"; }
warn() { printf "\033[1;33m    ! %s\033[0m\n" "$1"; }

# --- 0. preflight ---------------------------------------------------------
step "Checking prerequisites"
for tool in docker kind kubectl helm; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: '$tool' not found in PATH. Install it and retry." >&2
    exit 1
  fi
done
if ! docker info >/dev/null 2>&1; then
  echo "ERROR: Docker is not running. Start Docker Desktop and retry." >&2
  exit 1
fi
ok "docker, kind, kubectl, helm present and Docker is running"

# --- 1. cluster -----------------------------------------------------------
step "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  warn "Cluster '$CLUSTER_NAME' already exists — reusing it"
else
  kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
  ok "Cluster created"
fi
kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
ok "Control plane reachable"

# --- 2. Argo CD -----------------------------------------------------------
step "Installing Argo CD"
kubectl create namespace "$ARGOCD_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$ARGOCD_NS" --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
info "Waiting for Argo CD server to become available (up to 3 min)..."
kubectl -n "$ARGOCD_NS" rollout status deploy/argocd-server --timeout=180s
ok "Argo CD is up"

# --- 3. Envoy Gateway -----------------------------------------------------
step "Installing Envoy Gateway ($EG_VERSION)"
if helm status eg -n "$EG_NS" >/dev/null 2>&1; then
  warn "Envoy Gateway already installed — skipping"
else
  helm install eg oci://docker.io/envoyproxy/gateway-helm \
    --version "$EG_VERSION" -n "$EG_NS" --create-namespace
fi
info "Waiting for Envoy Gateway control plane (up to 5 min)..."
kubectl wait --timeout=5m -n "$EG_NS" \
  deployment/envoy-gateway --for=condition=Available
ok "Envoy Gateway is up"

# --- 4. Argo Applications -------------------------------------------------
step "Applying Argo CD Applications (app + gateway)"
kubectl apply -f argocd-app.yaml
kubectl apply -f argocd-gateway-app.yaml
ok "Applications registered — Argo will now pull and deploy from Git"

info "Waiting for the 'visits' app to sync and become healthy (up to 4 min)..."
# Poll Argo's Application status until Synced+Healthy or timeout.
deadline=$(( $(date +%s) + 240 ))
while true; do
  sync=$(kubectl -n "$ARGOCD_NS" get application visits \
          -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")
  health=$(kubectl -n "$ARGOCD_NS" get application visits \
          -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")
  if [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ]; then
    ok "visits app: Synced / Healthy"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    warn "Timed out waiting for Synced/Healthy (got: ${sync:-none}/${health:-none})"
    warn "This can be normal on first run — check 'kubectl -n visits get pods'"
    break
  fi
  sleep 5
done

# --- 5. Envoy NodePort reconcile -----------------------------------------
# On a fresh cluster the Envoy proxy Service can be provisioned before the
# EnvoyProxy NodePort config is read, leaving it as a pending LoadBalancer.
# Deleting it once forces the controller to recreate it against the config.
step "Reconciling Envoy proxy Service to NodePort ${APP_NODEPORT}"
svc=$(kubectl -n "$EG_NS" get svc \
        -l "gateway.envoyproxy.io/owning-gateway-name=${GATEWAY_NAME}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$svc" ]; then
  svc_type=$(kubectl -n "$EG_NS" get svc "$svc" -o jsonpath='{.spec.type}')
  if [ "$svc_type" != "NodePort" ]; then
    info "Service is '$svc_type' — deleting so it is recreated as NodePort"
    kubectl -n "$EG_NS" delete svc "$svc"
    sleep 12
    ok "Envoy Service recreated"
  else
    ok "Envoy Service already NodePort"
  fi
else
  warn "Envoy proxy Service not found yet — Gateway may still be programming"
fi

# --- 6. verify ------------------------------------------------------------
step "Verifying the application responds"
sleep 3
if curl -sf "localhost:${APP_NODEPORT}/health" >/dev/null 2>&1; then
  ok "Health check passed: http://localhost:${APP_NODEPORT}/health"
  echo
  info "App response:"
  curl -s "localhost:${APP_NODEPORT}" || true
  echo
else
  warn "App not reachable yet on localhost:${APP_NODEPORT}."
  warn "Give it a minute, then try:  curl localhost:${APP_NODEPORT}"
fi

# --- done -----------------------------------------------------------------
step "Done"
cat <<DONE

  Environment is up. Useful next steps:

    Argo CD UI:
      kubectl -n ${ARGOCD_NS} port-forward svc/argocd-server 8081:443
      open https://localhost:8081  (user: admin)
      password:
        kubectl -n ${ARGOCD_NS} get secret argocd-initial-admin-secret \\
          -o jsonpath='{.data.password}' | base64 -d; echo

    App:
      curl localhost:${APP_NODEPORT}
      curl localhost:${APP_NODEPORT}/api

    Tear it all down:
      kind delete cluster --name ${CLUSTER_NAME}

DONE