#!/usr/bin/env bash

# ==============================================================================
# destroy-cluster.sh — Tear down Pathfinder EKS spend to zero
# ==============================================================================
# Deletes the Pathfinder workloads and EKS cluster resources so compute/network
# cost goes to zero.
#
# What this script removes:
#   - Pathfinder Helm release in the cluster
#   - ALB/ingress-backed resources created for the app
#   - The EKS cluster and its managed node group/VPC resources via eksctl
#
# What this script intentionally keeps:
#   - ECR repositories and images
#   - IAM policies/roles used for bootstrap (zero-cost resources)
#
# Usage:
#   chmod +x destroy-cluster.sh && ./destroy-cluster.sh
# ==============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
CLUSTER_NAME="pathfinder"
REGION="us-east-1"
AWS_ACCOUNT="002823001366"
APP_NAMESPACE="pathfinder"
APP_RELEASE="pathfinder"
LBC_NAMESPACE="kube-system"
LBC_RELEASE="aws-load-balancer-controller"

# ─────────────────────────────────────────────
# Colours
# ─────────────────────────────────────────────
GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
log()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success(){ echo -e "${GREEN}[OK]${NC}    $*"; }
header() { echo -e "\n${BOLD}═══════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════${NC}"; }
error()  { echo "❌ $*"; exit 1; }

cluster_exists() {
  aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" >/dev/null 2>&1
}

cluster_stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "eksctl-${CLUSTER_NAME}-cluster" >/dev/null 2>&1
}

helm_release_exists() {
  helm status "$1" -n "$2" >/dev/null 2>&1
}

namespace_exists() {
  kubectl get namespace "$1" >/dev/null 2>&1
}

# ─────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────
header "Preflight checks"

command -v eksctl  &>/dev/null || error "eksctl not found. Install: brew tap weaveworks/tap && brew install weaveworks/tap/eksctl"
command -v helm    &>/dev/null || error "helm not found. Install: brew install helm"
command -v kubectl &>/dev/null || error "kubectl not found. Install: brew install kubectl"
command -v aws     &>/dev/null || error "aws cli not found. Install: brew install awscli"

aws sts get-caller-identity --region "$REGION" &>/dev/null \
  || error "AWS credentials not set. Paste your SSO export lines first."

CALLER=$(aws sts get-caller-identity --region "$REGION" --query 'Arn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --region "$REGION" --query 'Account' --output text)
[[ "$ACCOUNT_ID" = "$AWS_ACCOUNT" ]] || error "Authenticated account $ACCOUNT_ID does not match configured AWS_ACCOUNT $AWS_ACCOUNT."

log "AWS identity : $CALLER"
log "Cluster name : $CLUSTER_NAME"
log "Region       : $REGION"
log "ECR          : preserved"
echo ""
echo "⚠️  This will delete the EKS cluster, worker nodes, VPC resources, and Pathfinder workloads."
echo "⚠️  ECR repositories and images will NOT be deleted."
read -p "Proceed with teardown? (y/N) " -n 1 -r; echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ─────────────────────────────────────────────
# Step 1: Remove Pathfinder workloads
# ─────────────────────────────────────────────
header "Step 1 / 3 — Removing Pathfinder workloads"

if cluster_exists; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION" >/dev/null
  success "kubeconfig updated for cluster teardown."

  if helm_release_exists "$APP_RELEASE" "$APP_NAMESPACE"; then
    log "Uninstalling Helm release '$APP_RELEASE'..."
    helm uninstall "$APP_RELEASE" -n "$APP_NAMESPACE" --wait
    success "Pathfinder Helm release removed."
  else
    log "Helm release '$APP_RELEASE' not found. Skipping."
  fi

  if namespace_exists "$APP_NAMESPACE"; then
    log "Deleting namespace '$APP_NAMESPACE'..."
    kubectl delete namespace "$APP_NAMESPACE" --wait=true --timeout=180s || true
    success "Namespace cleanup requested."
  else
    log "Namespace '$APP_NAMESPACE' not found. Skipping."
  fi

  if helm_release_exists "$LBC_RELEASE" "$LBC_NAMESPACE"; then
    log "Uninstalling AWS Load Balancer Controller Helm release..."
    helm uninstall "$LBC_RELEASE" -n "$LBC_NAMESPACE" --wait
    success "AWS Load Balancer Controller Helm release removed."
  else
    log "AWS Load Balancer Controller Helm release not found. Skipping."
  fi
else
  log "Cluster '$CLUSTER_NAME' not found. Skipping in-cluster workload cleanup."
fi

# ─────────────────────────────────────────────
# Step 2: Delete EKS cluster and cloud resources
# ─────────────────────────────────────────────
header "Step 2 / 3 — Deleting EKS cluster"

if cluster_exists; then
  log "Deleting EKS cluster '$CLUSTER_NAME' with eksctl..."
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" --wait
  success "EKS cluster deleted."
elif cluster_stack_exists; then
  log "Cluster is absent but CloudFormation stack still exists. Deleting stack..."
  aws cloudformation update-termination-protection \
    --region "$REGION" \
    --stack-name "eksctl-${CLUSTER_NAME}-cluster" \
    --no-enable-termination-protection >/dev/null 2>&1 || true
  aws cloudformation delete-stack \
    --region "$REGION" \
    --stack-name "eksctl-${CLUSTER_NAME}-cluster"
  aws cloudformation wait stack-delete-complete \
    --region "$REGION" \
    --stack-name "eksctl-${CLUSTER_NAME}-cluster"
  success "Residual CloudFormation stack deleted."
else
  log "No EKS cluster or eksctl stack found. Nothing to delete."
fi

# ─────────────────────────────────────────────
# Step 3: Summary
# ─────────────────────────────────────────────
header "Step 3 / 3 — Teardown complete"

echo ""
if cluster_exists; then
  error "Cluster still exists after teardown attempt. Check eksctl/CloudFormation output."
fi

echo -e "${GREEN}✅  Pathfinder compute/network resources removed.${NC}"
echo ""
echo "   Deleted : EKS control plane, worker nodes, ALB-backed app resources, Pathfinder workloads"
echo "   Kept    : ECR repositories and images"
echo ""
echo "   Verify remaining zero-cost state with:"
echo "   aws ecr describe-repositories --region ${REGION}"
echo "   aws eks list-clusters --region ${REGION}"
