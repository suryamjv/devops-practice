#!/usr/bin/env bash
set -euo pipefail

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then
    echo "  PASS  $1"; PASS=$((PASS+1))
  else
    echo "  FAIL  $1"; FAIL=$((FAIL+1))
  fi
}

echo "== Phase 1: container =="
docker compose up -d --build >/dev/null 2>&1
sleep 8
check "app responds"            "curl -sf localhost:8000"
check "health endpoint healthy" "curl -sf localhost:8000/health | grep -q healthy"
check "counter increments"      '[ $(curl -s localhost:8000 | grep -o "[0-9]*$\|[0-9]*}" | tr -d "}") -gt 0 ]'
check "runs as non-root"        'docker compose exec -T web id | grep -q "uid=1000"'
docker compose down >/dev/null 2>&1

echo "== Phase 2: CI artefact =="
check "image pullable from GHCR" "docker pull ghcr.io/suryamjv/devops-practice:latest"
check "workflow file present"    "test -s .github/workflows/ci.yml"

echo "== Phase 3: kubernetes =="
kind create cluster --name verify --config kind-config.yaml >/dev/null 2>&1
kubectl create namespace visits >/dev/null 2>&1
check "helm chart lints"    "helm lint chart/"
check "helm chart renders"  "helm template visits chart/"
helm install visits chart/ -n visits >/dev/null 2>&1
check "web rollout ready"   "kubectl -n visits rollout status deploy/visits-web --timeout=120s"
check "postgres ready"      "kubectl -n visits rollout status deploy/visits-postgres --timeout=120s"
check "2 endpoints exist"   '[ $(kubectl -n visits get endpointslice -l kubernetes.io/service-name=visits-web -o jsonpath="{.items[0].endpoints[*].addresses[0]}" | wc -w) -eq 2 ]'
check "secret is mounted"   "kubectl -n visits get secret visits-db"
check "readonly rootfs set" 'kubectl -n visits get deploy visits-web -o jsonpath="{.spec.template.spec.containers[0].securityContext.readOnlyRootFilesystem}" | grep -q true'
check "helm rollback works" "helm -n visits upgrade visits chart/ --set replicaCount=3 && helm -n visits rollback visits 1"

echo
echo "  $PASS passed, $FAIL failed"
echo "  cleanup: kind delete cluster --name verify"
[ $FAIL -eq 0 ]
