#!/usr/bin/env bash

# ==============================================================================
# create-cluster.sh — Create EKS cluster + AWS Load Balancer Controller
# ==============================================================================
# Creates an EKS cluster in us-east-1 with:
#   - a small managed node group for Pathfinder dev/demo use
#   - AWS Load Balancer Controller (required for ALB ingress)
#   - ECR pull access for nodes
#
# Runtime: ~15-20 minutes
# Cost: EKS control plane + EC2 worker nodes
#
# Prerequisites:
#   - eksctl installed  (brew tap weaveworks/tap && brew install weaveworks/tap/eksctl)
#   - helm installed    (brew install helm)
#   - kubectl installed (brew install kubectl)
#   - curl installed
#   - AWS SSO credentials exported in terminal
#
# Usage:
#   chmod +x create-cluster.sh && ./create-cluster.sh
# ==============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────
CLUSTER_NAME="pathfinder"
REGION="us-east-1"
AWS_ACCOUNT="002823001366"
LBC_VERSION="v2.14.1"
LBC_POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
LBC_ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
LBC_SERVICE_ACCOUNT_NAME="aws-load-balancer-controller"
LBC_NAMESPACE="kube-system"

# Node group config
NODE_TYPE="t3.medium"          # cost-effective for dev/demo (~$0.047/hr per node)
NODE_MIN=2
NODE_MAX=3
NODE_DESIRED=2

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

policy_exists() {
  aws iam get-policy --policy-arn "$1" >/dev/null 2>&1
}

# ─────────────────────────────────────────────
# Preflight checks
# ─────────────────────────────────────────────
header "Preflight checks"

command -v eksctl  &>/dev/null || { echo "❌ eksctl not found. Install: brew tap weaveworks/tap && brew install weaveworks/tap/eksctl"; exit 1; }
command -v helm    &>/dev/null || { echo "❌ helm not found. Install: brew install helm"; exit 1; }
command -v kubectl &>/dev/null || { echo "❌ kubectl not found. Install: brew install kubectl"; exit 1; }
command -v aws     &>/dev/null || { echo "❌ aws cli not found. Install: brew install awscli"; exit 1; }
command -v curl    &>/dev/null || { echo "❌ curl not found. Install curl first."; exit 1; }

aws sts get-caller-identity --region "$REGION" &>/dev/null \
  || { echo "❌ AWS credentials not set. Paste your SSO export lines first."; exit 1; }

CALLER=$(aws sts get-caller-identity --region "$REGION" --query 'Arn' --output text)
ACCOUNT_ID=$(aws sts get-caller-identity --region "$REGION" --query 'Account' --output text)
[[ "$ACCOUNT_ID" = "$AWS_ACCOUNT" ]] || error "Authenticated account $ACCOUNT_ID does not match configured AWS_ACCOUNT $AWS_ACCOUNT."

LBC_POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT}:policy/${LBC_POLICY_NAME}"
LBC_POLICY_URL="https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json"

log "AWS identity : $CALLER"
log "Cluster name : $CLUSTER_NAME"
log "Region       : $REGION"
log "Node type    : $NODE_TYPE x$NODE_DESIRED"
log "LBC version  : $LBC_VERSION"

if cluster_stack_exists && ! cluster_exists; then
  error "CloudFormation stack eksctl-${CLUSTER_NAME}-cluster already exists but the EKS cluster does not. Clean it up first with: aws cloudformation delete-stack --region ${REGION} --stack-name eksctl-${CLUSTER_NAME}-cluster"
fi

echo ""
echo "⚠️  This will create AWS resources that cost money (~\$0.30/hr while running)."
read -p "Proceed? (y/N) " -n 1 -r; echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ─────────────────────────────────────────────
# Step 1: Create EKS cluster
# ─────────────────────────────────────────────
header "Step 1 / 4 — Creating EKS cluster (~15 min)"

if cluster_exists; then
  log "Cluster '$CLUSTER_NAME' already exists. Skipping creation."
else
  eksctl create cluster \
    --name "$CLUSTER_NAME" \
    --region "$REGION" \
    --nodegroup-name pathfinder-nodes \
    --node-type "$NODE_TYPE" \
    --nodes "$NODE_DESIRED" \
    --nodes-min "$NODE_MIN" \
    --nodes-max "$NODE_MAX" \
    --managed \
    --with-oidc \
    --full-ecr-access \
    --asg-access

  success "Cluster created!"
fi

# Update kubeconfig
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$REGION"
success "kubeconfig updated. kubectl is now pointing to: $CLUSTER_NAME"

# ─────────────────────────────────────────────
# Step 2: Install AWS Load Balancer Controller
# ─────────────────────────────────────────────
header "Step 2 / 4 — Installing AWS Load Balancer Controller"

log "Associating IAM OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --cluster "$CLUSTER_NAME" \
  --region "$REGION" \
  --approve

success "OIDC provider ready."

if policy_exists "$LBC_POLICY_ARN"; then
  log "IAM policy '$LBC_POLICY_NAME' already exists."
else
  log "Creating IAM policy '$LBC_POLICY_NAME' from AWS Load Balancer Controller ${LBC_VERSION} policy document..."
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  curl -fsSL "$LBC_POLICY_URL" -o "$TMP_DIR/iam_policy.json"
  aws iam create-policy \
    --policy-name "$LBC_POLICY_NAME" \
    --policy-document "file://$TMP_DIR/iam_policy.json" >/dev/null
  success "IAM policy created."
fi

# Create IAM service account for the LBC
log "Creating IAM service account..."
eksctl create iamserviceaccount \
  --cluster "$CLUSTER_NAME" \
  --namespace "$LBC_NAMESPACE" \
  --name "$LBC_SERVICE_ACCOUNT_NAME" \
  --role-name "$LBC_ROLE_NAME" \
  --attach-policy-arn "$LBC_POLICY_ARN" \
  --approve \
  --override-existing-serviceaccounts \
  --region "$REGION"

success "IAM service account created."

# Add eks helm chart repo
log "Adding EKS Helm repo..."
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update

VPC_ID=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)

# Install the controller
log "Installing aws-load-balancer-controller via Helm..."
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace "$LBC_NAMESPACE" \
  --create-namespace \
  --set clusterName="$CLUSTER_NAME" \
  --set serviceAccount.create=false \
  --set serviceAccount.name="$LBC_SERVICE_ACCOUNT_NAME" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID"

success "AWS Load Balancer Controller installed."

# ─────────────────────────────────────────────
# Step 3: Verify controller is running
# ─────────────────────────────────────────────
header "Step 3 / 4 — Verifying LBC is running"

log "Waiting for aws-load-balancer-controller to be ready..."
kubectl rollout status deployment/aws-load-balancer-controller \
  -n "$LBC_NAMESPACE" --timeout=300s

ROLE_ARN=$(kubectl get serviceaccount "$LBC_SERVICE_ACCOUNT_NAME" -n "$LBC_NAMESPACE" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null || true)
[ -n "$ROLE_ARN" ] || error "Service account is missing eks.amazonaws.com/role-arn annotation."
log "Service account role: $ROLE_ARN"

success "AWS Load Balancer Controller is running!"

# ─────────────────────────────────────────────
# Step 4: Print cluster info
# ─────────────────────────────────────────────
header "Step 4 / 4 — Cluster ready ✅"

echo ""
kubectl get nodes
echo ""
echo -e "${GREEN}✅  EKS cluster is ready!${NC}"
echo ""
echo "   Cluster  : $CLUSTER_NAME"
echo "   Region   : $REGION"
echo "   Nodes    : $(kubectl get nodes --no-headers | wc -l | tr -d ' ')"
echo ""
echo "────────────────────────────────────────────"
echo "   Next step: deploy the Pathfinder stack"
echo "   ./helm/aws-deploy.sh"
echo "────────────────────────────────────────────"
