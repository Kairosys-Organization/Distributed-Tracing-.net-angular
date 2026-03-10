#!/usr/bin/env bash

# ==============================================================================
# Pathfinder AWS EKS Deployment Script
# ==============================================================================
# Works WITHOUT a custom domain — AWS ALB auto-generates a DNS name.
# Everything is served over HTTP on a single ALB:
#
#   http://<alb-dns>/        → UI
#   http://<alb-dns>/api     → PathfinderApi (Swagger: /api/swagger)
#   http://<alb-dns>/jaeger  → Jaeger UI
#   http://<alb-dns>/otel    → OTel Collector (HTTP)
#
# Optional: set DOMAIN + CERT_ARN to switch to custom domain + HTTPS.
#
# Prerequisites:
#   - kubectl configured pointing to your EKS cluster  (aws eks update-kubeconfig ...)
#   - Helm installed
#   - AWS Load Balancer Controller installed in EKS
#
# Usage:
#   chmod +x aws-deploy.sh && ./aws-deploy.sh
# ==============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
# 1. Config
# ─────────────────────────────────────────────
ECR_REGISTRY="002823001366.dkr.ecr.us-east-1.amazonaws.com"

# Tag that was pushed to ECR (e.g. latest, 1.0.0)
IMAGE_TAG="latest"

# ECR repositories that were pushed by push-to-ecr.sh / docker push
API_IMAGE_REPO="pftc/dummy-backend1"
NEWAPP_IMAGE_REPO="pftc/dummy-backend2"
UI_IMAGE_REPO="pftc/dummy-frontend"
OPS_AGENT_IMAGE_REPO="pftc/kairosysv1"

# ── Custom domain (OPTIONAL) ──────────────────
# Leave both empty to use auto-assigned ALB DNS (HTTP only, no cert needed)
DOMAIN=""       # e.g. pathfinder.example.com
CERT_ARN=""     # arn:aws:acm:us-east-1:002823001366:certificate/xxxx

# ─────────────────────────────────────────────
# 2. Ops-Agent Credentials
# ─────────────────────────────────────────────
# DO NOT put real secrets here — this file can be committed to git.
# Instead, create helm/ops-agent-secrets.sh (it is gitignored) and set
# the variables there. That file is sourced automatically if it exists.
#
# Example helm/ops-agent-secrets.sh:
#   OPENAI_API_KEY="sk-..."
#   AZURE_OPENAI_API_KEY="..."
#   AZURE_OPENAI_ENDPOINT="https://my-resource.openai.azure.com/"
#
OPENAI_API_KEY=""
AZURE_OPENAI_API_KEY=""
AZURE_OPENAI_ENDPOINT=""
AZURE_OPENAI_DEPLOYMENT_NAME="gpt-4o"
AZURE_OPENAI_API_VERSION="2024-10-21"
AZURE_TENANT_ID="placeholder"
AZURE_CLIENT_ID="placeholder"
AZURE_CLIENT_SECRET="placeholder"
AZURE_SUBSCRIPTION_ID="placeholder"
DATABRICKS_TOKEN=""
CONFLUENCE_CLIENT_ID="placeholder"
CONFLUENCE_CLIENT_SECRET="placeholder"
SERVICENOW_USER_PASSWORD="placeholder"
SLACK_BOT_BOT_TOKEN=""
SLACK_BOT_SIGNING_SECRET=""
WEBAPP_TEAMS_WEBHOOK_URL=""
WEBAPP_SLACK_WEBHOOK_URL=""
WEBAPP_SERVICENOW_PASSWORD=""

# Source local secrets file if it exists (gitignored — safe to put real keys there)
SECRETS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ops-agent-secrets.sh"
if [ -f "$SECRETS_FILE" ]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  echo "🔑  Loaded secrets from ops-agent-secrets.sh"
fi

# ─────────────────────────────────────────────
# Determine mode (domain vs no-domain)
# ─────────────────────────────────────────────
if [ -n "$DOMAIN" ] && [ -n "$CERT_ARN" ]; then
  MODE="domain"
  PROTOCOL="https"
else
  MODE="nodomain"
  PROTOCOL="http"
  DOMAIN=""   # ensure empty so ingress uses path-based routing
fi

echo ""
echo "🎯  Kubernetes context : $(kubectl config current-context)"
echo "📦  ECR registry       : $ECR_REGISTRY"
echo "🏷️   Image tag          : $IMAGE_TAG"
echo "🧩  API image          : ${ECR_REGISTRY}/${API_IMAGE_REPO}:${IMAGE_TAG}"
echo "🧩  NewApp image       : ${ECR_REGISTRY}/${NEWAPP_IMAGE_REPO}:${IMAGE_TAG}"
echo "🧩  UI image           : ${ECR_REGISTRY}/${UI_IMAGE_REPO}:${IMAGE_TAG}"
echo "🧩  Ops Agent image    : ${ECR_REGISTRY}/${OPS_AGENT_IMAGE_REPO}:${IMAGE_TAG}"
echo "🌐  Mode               : ${MODE} (${PROTOCOL})"
[ "$MODE" = "domain" ] && echo "🔒  Domain             : $DOMAIN"
echo ""
read -p "Proceed with deployment? (y/N) " -n 1 -r; echo
[[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
# Build ALB annotations
# ─────────────────────────────────────────────
ALB_COMMON_ARGS=(
  --set ingress.className="alb"
  --set ingress.annotations."kubernetes\.io/ingress\.class"="alb"
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"="internet-facing"
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"="ip"
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/healthcheck-path"="/api/health"
)

if [ "$MODE" = "domain" ]; then
  ALB_EXTRA_ARGS=(
    --set ingress.annotations."alb\.ingress\.kubernetes\.io/listen-ports"='[{"HTTP": 80}, {"HTTPS": 443}]'
    --set ingress.annotations."alb\.ingress\.kubernetes\.io/ssl-redirect"="443"
    --set ingress.annotations."alb\.ingress\.kubernetes\.io/certificate-arn"="$CERT_ARN"
    --set ingress.hosts.ui="${DOMAIN}"
    --set ingress.hosts.api="api.${DOMAIN}"
    --set ingress.hosts.jaeger="jaeger.${DOMAIN}"
    --set ingress.hosts.otel="otel.${DOMAIN}"
    --set ui.env.API_URL="https://api.${DOMAIN}/api"
    --set ui.env.OTEL_URL="https://otel.${DOMAIN}/v1/traces"
    --set ui.env.JAEGER_URL="https://jaeger.${DOMAIN}"
    --set api.env.CORS_ORIGINS="https://${DOMAIN}"
  )
else
  # No domain → hosts left empty → ingress template uses path-based routing.
  # Use relative browser URLs so the same ALB hostname serves UI, API, Jaeger,
  # and OTEL without needing a rebuild after the ALB DNS is assigned.
  ALB_EXTRA_ARGS=(
    --set ingress.annotations."alb\.ingress\.kubernetes\.io/listen-ports"='[{"HTTP": 80}]'
    --set ingress.hosts.ui=""
    --set ingress.hosts.api=""
    --set ingress.hosts.jaeger=""
    --set ingress.hosts.otel=""
    --set ui.env.API_URL="/api"
    --set ui.env.OTEL_URL="/v1/traces"
    --set ui.env.JAEGER_URL="/jaeger"
  )
fi

# ─────────────────────────────────────────────
# Helm deploy
# ─────────────────────────────────────────────
helm upgrade --install pathfinder "$SCRIPT_DIR/pathfinder" \
  --namespace pathfinder \
  --create-namespace \
  \
  --set registry="$ECR_REGISTRY" \
  \
  --set api.image="$API_IMAGE_REPO" \
  --set api.tag="$IMAGE_TAG" \
  --set api.imagePullPolicy="Always" \
  \
  --set newapp.image="$NEWAPP_IMAGE_REPO" \
  --set newapp.tag="$IMAGE_TAG" \
  --set newapp.imagePullPolicy="Always" \
  \
  --set ui.image="$UI_IMAGE_REPO" \
  --set ui.tag="$IMAGE_TAG" \
  --set ui.imagePullPolicy="Always" \
  \
  --set opsAgent.image.repository="$ECR_REGISTRY/$OPS_AGENT_IMAGE_REPO" \
  --set opsAgent.image.tag="$IMAGE_TAG" \
  --set opsAgent.image.pullPolicy="Always" \
  \
  --set opsAgent.secrets.OPENAI_API_KEY="$OPENAI_API_KEY" \
  --set opsAgent.secrets.AZURE_OPENAI_API_KEY="$AZURE_OPENAI_API_KEY" \
  --set opsAgent.secrets.AZURE_OPENAI_ENDPOINT="$AZURE_OPENAI_ENDPOINT" \
  --set opsAgent.secrets.AZURE_OPENAI_DEPLOYMENT_NAME="$AZURE_OPENAI_DEPLOYMENT_NAME" \
  --set opsAgent.secrets.AZURE_OPENAI_API_VERSION="$AZURE_OPENAI_API_VERSION" \
  --set opsAgent.secrets.AZURE_TENANT_ID="$AZURE_TENANT_ID" \
  --set opsAgent.secrets.AZURE_CLIENT_ID="$AZURE_CLIENT_ID" \
  --set opsAgent.secrets.AZURE_CLIENT_SECRET="$AZURE_CLIENT_SECRET" \
  --set opsAgent.secrets.AZURE_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID" \
  --set opsAgent.secrets.DATABRICKS_TOKEN="$DATABRICKS_TOKEN" \
  --set opsAgent.secrets.CONFLUENCE_CLIENT_ID="$CONFLUENCE_CLIENT_ID" \
  --set opsAgent.secrets.CONFLUENCE_CLIENT_SECRET="$CONFLUENCE_CLIENT_SECRET" \
  --set opsAgent.secrets.SERVICENOW_USER_PASSWORD="$SERVICENOW_USER_PASSWORD" \
  --set opsAgent.secrets.SLACK_BOT_BOT_TOKEN="$SLACK_BOT_BOT_TOKEN" \
  --set opsAgent.secrets.SLACK_BOT_SIGNING_SECRET="$SLACK_BOT_SIGNING_SECRET" \
  --set opsAgent.secrets.WEBAPP_TEAMS_WEBHOOK_URL="$WEBAPP_TEAMS_WEBHOOK_URL" \
  --set opsAgent.secrets.WEBAPP_SLACK_WEBHOOK_URL="$WEBAPP_SLACK_WEBHOOK_URL" \
  --set opsAgent.secrets.WEBAPP_SERVICENOW_PASSWORD="$WEBAPP_SERVICENOW_PASSWORD" \
  \
  "${ALB_COMMON_ARGS[@]}" \
  "${ALB_EXTRA_ARGS[@]}"

# ─────────────────────────────────────────────
# Wait for pods
# ─────────────────────────────────────────────
echo ""
echo "⌛  Waiting for pods to be ready..."
kubectl rollout status deployment/api    -n pathfinder --timeout=180s
kubectl rollout status deployment/newapp -n pathfinder --timeout=180s
kubectl rollout status deployment/ui     -n pathfinder --timeout=180s
kubectl rollout status deployment/ops-agent -n pathfinder --timeout=180s
echo ""
kubectl get pods -n pathfinder

# ─────────────────────────────────────────────
# Print ALB DNS (takes ~60s for AWS to assign)
# ─────────────────────────────────────────────
echo ""
echo "⏳  Waiting for ALB DNS to be assigned (this can take 1-2 minutes)..."
for i in $(seq 1 24); do
  ALB_DNS=$(kubectl get ingress pathfinder-ingress -n pathfinder \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [ -n "$ALB_DNS" ]; then break; fi
  sleep 5
done

echo ""
if [ "$MODE" = "domain" ]; then
  echo "✅  Deployment complete!"
  echo ""
  echo "   UI      : https://${DOMAIN}"
  echo "   API     : https://api.${DOMAIN}/api/swagger"
  echo "   Jaeger  : https://jaeger.${DOMAIN}"
else
  echo "✅  Deployment complete!"
  echo ""
  if [ -n "$ALB_DNS" ]; then
    echo "   ┌──────────────────────────────────────────────────────────────────┐"
    echo "   │  UI      : http://${ALB_DNS}/"
    echo "   │  API     : http://${ALB_DNS}/api/swagger"
    echo "   │  Jaeger  : http://${ALB_DNS}/jaeger"
    echo "   │  OTel    : http://${ALB_DNS}/otel"
    echo "   └──────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "   💡 UI is already configured to use relative URLs on this ALB."
  else
    echo "   ⚠️  ALB DNS not ready yet. Run this to get it:"
    echo "   kubectl get ingress pathfinder-ingress -n pathfinder"
  fi
fi
