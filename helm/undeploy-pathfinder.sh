#!/usr/bin/env bash

# ==============================================================================
# undeploy-pathfinder.sh — Remove Pathfinder workloads from EKS
# ==============================================================================
# Deletes the Pathfinder Helm release from the EKS cluster so the app pods,
# services, ingress, and other workload resources are removed.
#
# What this script removes:
#   - Pathfinder Helm release resources in namespace "pathfinder"
#   - Optional namespace cleanup if it becomes empty
#
# What this script keeps:
#   - EKS cluster and node groups
#   - AWS Load Balancer Controller
#   - ECR repositories and images
#
# Usage:
#   chmod +x undeploy-pathfinder.sh && ./undeploy-pathfinder.sh
# ==============================================================================

set -euo pipefail

CLUSTER_NAME="pathfinder"
REGION="us-east-1"
NAMESPACE="pathfinder"
RELEASE_NAME="pathfinder"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success(){ echo -e "${GREEN}[OK]${NC}    $*"; }
header() { echo -e "\n${BOLD}═══════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════${NC}"; }
error()  { echo "❌ $*"; exit 1; }

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
}

namespace_exists() {
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1
}

release_exists() {
  helm status "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1
}

namespace_phase() {
  kubectl get namespace "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

header "Preflight checks"

command -v aws >/dev/null 2>&1 || error "aws cli not found. Install: brew install awscli"
command -v kubectl >/dev/null 2>&1 || error "kubectl not found. Install: brew install kubectl"
command -v helm >/dev/null 2>&1 || error "helm not found. Install: brew install helm"

aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 \
  || error "AWS credentials not set. Paste your SSO export lines first."

cluster_exists || error "EKS cluster '$CLUSTER_NAME' not found in $REGION."

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
log "Kubernetes context : $(kubectl config current-context)"

echo ""
echo "⚠️  This will remove the Pathfinder app from EKS."
echo "⚠️  It will not delete the EKS cluster or any ECR images."
read -p "Proceed with undeploy? (y/N) " -n 1 -r; echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

header "Removing Pathfinder release"

if release_exists; then
  log "Uninstalling Helm release '$RELEASE_NAME' from namespace '$NAMESPACE'..."
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" --wait
  success "Helm release removed."
else
  log "Helm release '$RELEASE_NAME' not found."
fi

if namespace_exists; then
  REMAINING=$(kubectl get all -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
  if [[ "${REMAINING:-0}" = "0" ]]; then
    log "Deleting empty namespace '$NAMESPACE'..."
    kubectl delete namespace "$NAMESPACE" --wait=true --timeout=180s || true
    success "Namespace deleted."
  else
    log "Namespace '$NAMESPACE' still has remaining resources. Leaving it in place."
    kubectl get all -n "$NAMESPACE" || true
  fi
fi

if namespace_exists && [[ "$(namespace_phase)" = "Terminating" ]]; then
  log "Namespace '$NAMESPACE' is stuck in Terminating. Forcing pod cleanup and clearing finalizers..."
  kubectl delete pod --all -n "$NAMESPACE" --force --grace-period=0 >/dev/null 2>&1 || true
  kubectl patch namespace "$NAMESPACE" -p '{"metadata":{"finalizers":[]}}' --type=merge >/dev/null 2>&1 || true
  success "Forced namespace finalization requested."
fi

header "Done"
echo ""
echo -e "${GREEN}✅  Pathfinder workloads removed from EKS.${NC}"
echo ""
echo "   Kept    : EKS cluster, node groups, ALB controller, ECR images"
echo "   Removed : Helm release resources in namespace '$NAMESPACE'"
