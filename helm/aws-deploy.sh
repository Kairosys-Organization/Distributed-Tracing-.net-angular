#!/usr/bin/env bash

# ==============================================================================
# Pathfinder AWS EKS Deployment Script
# ==============================================================================
# This script deploys the pathfinder stack to an AWS EKS cluster.
# It uses the ALB ingress controller and configures your custom domains.
# 
# Usage:
#   1. Fill in ALL the variables below
#   2. chmod +x aws-deploy.sh
#   3. ./aws-deploy.sh
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# 1. Global Setup
# ------------------------------------------------------------------------------
# Your AWS ECR Registry (e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com)
ECR_REGISTRY=""

# Base domain (e.g. yourdomain.com)
DOMAIN=""

# AWS ACM Certificate ARN (for HTTPS)
CERT_ARN=""

# ------------------------------------------------------------------------------
# 2. Image Configuration
# ------------------------------------------------------------------------------
API_IMAGE_TAG="latest"
UI_IMAGE_TAG="latest"
NEWAPP_IMAGE_TAG="latest"

# Ops-Agent Image location in ECR
OPS_AGENT_IMAGE_REPO="pathfinder/ops-agent"
OPS_AGENT_IMAGE_TAG="latest"

# ------------------------------------------------------------------------------
# 3. Ops-Agent Credentials (SECRETS)
# ------------------------------------------------------------------------------
OPENAI_API_KEY=""
AZURE_OPENAI_API_KEY=""
AZURE_OPENAI_ENDPOINT=""            # e.g. https://yourinstance.openai.azure.com/
AZURE_OPENAI_DEPLOYMENT_NAME=""     # e.g. gpt-4o
AZURE_OPENAI_API_VERSION=""         # e.g. 2024-10-21

# Azure Data Factory / Service Principal
AZURE_TENANT_ID=""
AZURE_CLIENT_ID=""
AZURE_CLIENT_SECRET=""
AZURE_SUBSCRIPTION_ID=""

# Databricks
DATABRICKS_TOKEN=""

# Confluence
CONFLUENCE_CLIENT_ID=""
CONFLUENCE_CLIENT_SECRET=""

# ServiceNow
SERVICENOW_USER_PASSWORD=""

# Slack Bot
SLACK_BOT_BOT_TOKEN=""
SLACK_BOT_SIGNING_SECRET=""

# Web App Crew Notifications
WEBAPP_TEAMS_WEBHOOK_URL=""
WEBAPP_SLACK_WEBHOOK_URL=""
WEBAPP_SERVICENOW_PASSWORD=""


# Quick validation
if [ -z "$ECR_REGISTRY" ] || [ -z "$DOMAIN" ] || [ -z "$CERT_ARN" ]; then
    echo "❌ Error: ECR_REGISTRY, DOMAIN, and CERT_ARN must be set."
    exit 1
fi

echo "🚀 Deploying Pathfinder to AWS EKS ($DOMAIN)..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm upgrade --install pathfinder "$SCRIPT_DIR/pathfinder" \
  --namespace pathfinder \
  --create-namespace \
  --set registry="$ECR_REGISTRY" \
  --set api.tag="$API_IMAGE_TAG" \
  --set ui.tag="$UI_IMAGE_TAG" \
  --set newapp.tag="$NEWAPP_IMAGE_TAG" \
  --set opsAgent.image.repository="$ECR_REGISTRY/$OPS_AGENT_IMAGE_REPO" \
  --set opsAgent.image.tag="$OPS_AGENT_IMAGE_TAG" \
  --set opsAgent.image.pullPolicy="Always" \
  --set opsAgent.secrets.OPENAI_API_KEY="$OPENAI_API_KEY" \
  --set opsAgent.secrets.AZURE_OPENAI_API_KEY="$AZURE_OPENAI_API_KEY" \
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
  --set opsAgent.secrets.AZURE_OPENAI_ENDPOINT="$AZURE_OPENAI_ENDPOINT" \
  --set opsAgent.secrets.AZURE_OPENAI_DEPLOYMENT_NAME="$AZURE_OPENAI_DEPLOYMENT_NAME" \
  --set opsAgent.secrets.AZURE_OPENAI_API_VERSION="$AZURE_OPENAI_API_VERSION" \
  --set ingress.className="alb" \
  --set ingress.annotations."kubernetes\.io/ingress\.class"="alb" \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/scheme"="internet-facing" \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/target-type"="ip" \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/listen-ports"='[{"HTTP": 80}, {"HTTPS": 443}]' \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/ssl-redirect"="443" \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/healthcheck-path"="/health" \
  --set ingress.annotations."alb\.ingress\.kubernetes\.io/certificate-arn"="$CERT_ARN" \
  --set ingress.hosts.ui="${DOMAIN}" \
  --set ingress.hosts.api="api.${DOMAIN}" \
  --set ingress.hosts.jaeger="jaeger.${DOMAIN}" \
  --set ingress.hosts.otel="otel.${DOMAIN}" \
  --set ui.env.API_URL="https://api.${DOMAIN}/api" \
  --set ui.env.OTEL_URL="https://otel.${DOMAIN}/v1/traces" \
  --set ui.env.JAEGER_URL="https://jaeger.${DOMAIN}" \
  --set api.env.CORS_ORIGINS="https://${DOMAIN}\\,https://www.${DOMAIN}"

echo "✅ Success!"
echo "   UI      : https://${DOMAIN}"
echo "   API     : https://api.${DOMAIN}/api/swagger"
echo "   Jaeger  : https://jaeger.${DOMAIN}"
echo "   OTel    : https://otel.${DOMAIN}"
