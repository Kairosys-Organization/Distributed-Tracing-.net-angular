#!/usr/bin/env bash
# ==============================================================================
# push-to-ecr.sh — Build & Push all Pathfinder images to AWS ECR
# ==============================================================================
# Builds linux/amd64 (EKS default) images and pushes them to ECR.
#
# Usage:
#   ./push-to-ecr.sh [version-tag]
#
# Examples:
#   ./push-to-ecr.sh            # uses 'latest' as tag
#   ./push-to-ecr.sh 1.0.0      # pushes :1.0.0 AND :latest
#
# Prerequisites:
#   - AWS CLI installed & configured  (aws configure)
#   - Docker Desktop running with Buildx enabled
# ==============================================================================

set -euo pipefail

# ─────────────────────────────────────────────
#  Config
# ─────────────────────────────────────────────
AWS_REGION="us-east-1"
AWS_ACCOUNT="002823001366"
ECR_REGISTRY="${AWS_ACCOUNT}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ECR repo:source_directory
REPOS=(
  "pftc/dummy-backend1:PathfinderApi"
  "pftc/dummy-backend2:NewApp"
  "pftc/dummy-frontend:pathfinder-ui-zoneless"
)

# EKS target platform (change to linux/arm64 if using Graviton nodes)
PLATFORM="linux/amd64"

# Tag from first argument, default to 'latest'
VERSION="${1:-latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────
#  Colours
# ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
header()  { echo -e "\n${BOLD}═══════════════════════════════════════${NC}"; echo -e "${BOLD}  $*${NC}"; echo -e "${BOLD}═══════════════════════════════════════${NC}"; }

# ─────────────────────────────────────────────
#  Preflight checks
# ─────────────────────────────────────────────
header "Preflight checks"

command -v aws    &>/dev/null || error "AWS CLI not found. Install with: brew install awscli"
command -v docker &>/dev/null || error "Docker not found. Is Docker Desktop running?"

# Verify AWS credentials are configured
aws sts get-caller-identity --region "$AWS_REGION" &>/dev/null \
  || error "AWS credentials not configured. Please paste your SSO credentials into the terminal first."

log "AWS region  : $AWS_REGION"
log "ECR registry: $ECR_REGISTRY"
log "Platform    : $PLATFORM"
log "Tag         : $VERSION"

# ─────────────────────────────────────────────
#  Ensure Buildx builder exists (for --platform)
# ─────────────────────────────────────────────
header "Setting up Docker Buildx"

if ! docker buildx inspect ecr-builder &>/dev/null; then
  log "Creating buildx builder 'ecr-builder'..."
  docker buildx create --name ecr-builder --driver docker-container --use
else
  log "Using existing buildx builder 'ecr-builder'."
  docker buildx use ecr-builder
fi
docker buildx inspect --bootstrap &>/dev/null
success "Buildx ready."

# ─────────────────────────────────────────────
#  ECR Login
# ─────────────────────────────────────────────
header "Authenticating with ECR"

log "Retrieving ECR login token..."
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"
success "ECR login successful."

# ─────────────────────────────────────────────
#  Build & Push each image
# ─────────────────────────────────────────────
for ITEM in "${REPOS[@]}"; do
  REPO="${ITEM%%:*}"
  SRC_DIR="${ITEM##*:}"
  
  FULL_REPO="${ECR_REGISTRY}/${REPO}"
  BUILD_CTX="${SCRIPT_DIR}/${SRC_DIR}"

  header "Building: ${REPO}"
  log "  Source : $BUILD_CTX"
  log "  Target : $FULL_REPO"

  # Build tag list
  TAGS="--tag ${FULL_REPO}:latest"
  if [[ "$VERSION" != "latest" ]]; then
    TAGS="$TAGS --tag ${FULL_REPO}:${VERSION}"
  fi

  docker buildx build \
    --platform "$PLATFORM" \
    --file "${BUILD_CTX}/Dockerfile" \
    $TAGS \
    --push \
    "$BUILD_CTX"

  success "Pushed → ${FULL_REPO}:latest"
  [[ "$VERSION" != "latest" ]] && success "Pushed → ${FULL_REPO}:${VERSION}"
done

# ─────────────────────────────────────────────
#  Summary
# ─────────────────────────────────────────────
header "All images pushed ✅"
echo ""
for ITEM in "${REPOS[@]}"; do
  REPO="${ITEM%%:*}"
  echo -e "  ${GREEN}✔${NC}  ${ECR_REGISTRY}/${REPO}:${VERSION}"
  [[ "$VERSION" != "latest" ]] && echo -e "  ${GREEN}✔${NC}  ${ECR_REGISTRY}/${REPO}:latest"
done
echo ""
log "Done! Update your Helm values to use tag: ${VERSION}"
