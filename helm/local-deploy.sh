#!/usr/bin/env bash

# ==============================================================================
# Pathfinder Local Deployment Script (Docker Desktop)
# ==============================================================================
# This script deploys the pathfinder stack to your local Kubernetes cluster
# using Docker Desktop. It automatically uses the 'nginx' ingress class
# and 'pathfinder.localhost' domains.
# 
# Usage:
#   1. Fill in the variables below
#   2. chmod +x local-deploy.sh
#   3. ./local-deploy.sh
# ==============================================================================

set -e

# ------------------------------------------------------------------------------
# 1. Image Configuration
# ------------------------------------------------------------------------------
# Set to the tags you built locally (e.g. 'dev-1.0.0' or 'latest')
API_IMAGE_TAG="dev-1.0.0"
UI_IMAGE_TAG="dev-1.0.0"
NEWAPP_IMAGE_TAG="dev-1.0.0"

# Ops-Agent Image (built locally via: docker build -t ops-agent:local ...)
OPS_AGENT_IMAGE_REPO="ops-agent"
OPS_AGENT_IMAGE_TAG="local"

# ------------------------------------------------------------------------------
# 2. Ops-Agent Credentials (SECRETS)
# ------------------------------------------------------------------------------
# Fill these in with your real keys. Leave as "" if not needed.
OPENAI_API_KEY=""                # e.g., "sk-..."
AZURE_OPENAI_API_KEY=""          # e.g., "..."
AZURE_OPENAI_ENDPOINT=""
AZURE_OPENAI_DEPLOYMENT_NAME="gpt-4o"
AZURE_OPENAI_API_VERSION="2024-10-21"
# Azure Data Factory / Service Principal
AZURE_TENANT_ID="local-dev"      # Must not be empty for pydantic validation
AZURE_CLIENT_ID="local-dev"
AZURE_CLIENT_SECRET="local-dev"
AZURE_SUBSCRIPTION_ID="local-dev"

# Databricks
DATABRICKS_TOKEN=""

# Confluence
CONFLUENCE_CLIENT_ID="local-dev"
CONFLUENCE_CLIENT_SECRET="local-dev"

# ServiceNow
SERVICENOW_USER_PASSWORD="local-dev"

# Slack Bot
SLACK_BOT_BOT_TOKEN=""
SLACK_BOT_SIGNING_SECRET=""

# Web App Crew Notifications
WEBAPP_TEAMS_WEBHOOK_URL="https://default23c2b29f23d7488d8a9f6a48630109.4a.environment.api.powerplatform.com:443/powerautomate/automations/direct/workflows/b72e1e0c69e443278ba7bde2c0542993/triggers/manual/paths/invoke?api-version=1&sp=%2Ftriggers%2Fmanual%2Frun&sv=1.0&sig=lnMoQLzN3STM2DHWspJiQ0EpwjJ0ClNW7RvHjmyUdsE"
WEBAPP_SLACK_WEBHOOK_URL=""
WEBAPP_SERVICENOW_PASSWORD=""

echo "🚀 Deploying Pathfinder to local Docker Desktop..."

# Remind user about /etc/hosts if entries are missing
if ! grep -q "pathfinder.localhost" /etc/hosts; then
  echo ""
  echo "⚠️  WARNING: /etc/hosts is missing the required entries."
  echo "   Run this once:"
  echo "   echo '127.0.0.1 pathfinder.localhost api.pathfinder.localhost jaeger.pathfinder.localhost otel.pathfinder.localhost' | sudo tee -a /etc/hosts"
  echo ""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

helm upgrade --install pathfinder "$SCRIPT_DIR/pathfinder" \
  --namespace pathfinder \
  --create-namespace \
  --set api.tag="$API_IMAGE_TAG" \
  --set ui.tag="$UI_IMAGE_TAG" \
  --set newapp.tag="$NEWAPP_IMAGE_TAG" \
  --set opsAgent.image.repository="$OPS_AGENT_IMAGE_REPO" \
  --set opsAgent.image.tag="$OPS_AGENT_IMAGE_TAG" \
  --set opsAgent.image.pullPolicy="IfNotPresent" \
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
  --set ingress.className="nginx" \
  --set ingress.hosts.ui="pathfinder.localhost" \
  --set ingress.hosts.api="api.pathfinder.localhost" \
  --set ingress.hosts.jaeger="jaeger.pathfinder.localhost" \
  --set ingress.hosts.otel="otel.pathfinder.localhost" \
  --set ui.env.API_URL="http://api.pathfinder.localhost/api" \
  --set ui.env.OTEL_URL="http://otel.pathfinder.localhost/v1/traces" \
  --set ui.env.JAEGER_URL="http://jaeger.pathfinder.localhost" \
  --set api.env.CORS_ORIGINS="http://localhost:4200\,http://localhost:4201\,http://pathfinder.localhost"

echo "✅ Success!"
echo "   UI      : http://pathfinder.localhost"
echo "   API     : http://api.pathfinder.localhost/api/swagger"
echo "   Jaeger  : http://jaeger.pathfinder.localhost"
echo "   OTel    : http://otel.pathfinder.localhost"
