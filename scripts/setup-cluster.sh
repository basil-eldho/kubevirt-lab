#!/usr/bin/env bash
# scripts/setup-cluster.sh — bootstrap a fresh kind cluster with KubeVirt + CDI
#
# Run this once before using the Makefile targets.
# Safe to re-run: every step is idempotent.
#
# Usage:
#   ./scripts/setup-cluster.sh
#
# What it does:
#   1. Creates a kind cluster (kindest/node:v1.35.0)
#   2. Installs KubeVirt v1.8.2 and waits for it to be ready
#   3. Installs CDI v1.65.0 and waits for it to be ready
#
# Prerequisites: kind, kubectl, docker, packer

set -euo pipefail

# ── Versions ──────────────────────────────────────────────────────────────────
KUBEVIRT_VERSION="v1.8.2"
CDI_VERSION="v1.65.0"
KIND_NODE_IMAGE="kindest/node:v1.35.0"
CLUSTER_NAME="kind"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[setup]${NC} $*"; }
warning() { echo -e "${YELLOW}[setup]${NC} $*"; }
step()    { echo -e "${CYAN}──────────────────────────────────────────────${NC}"; echo -e "${CYAN}[setup]${NC} $*"; }

# ── Auto-install: Packer (HashiCorp apt repo) ─────────────────────────────────
# Only handles Debian/Ubuntu (apt). On other distros, install Packer manually:
#   https://developer.hashicorp.com/packer/install
install_packer() {
    if ! command -v apt-get &>/dev/null; then
        echo "ERROR: packer missing and auto-install only supports apt-based distros." >&2
        echo "       Install manually: https://developer.hashicorp.com/packer/install" >&2
        exit 1
    fi
    warning "packer not found — installing from HashiCorp apt repo (needs sudo)"
    wget -qO - https://apt.releases.hashicorp.com/gpg \
        | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) main" \
        | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
    sudo apt-get update -qq && sudo apt-get install -y packer
}

# ── Prerequisites check ───────────────────────────────────────────────────────
step "Checking prerequisites"
for cmd in kind kubectl docker packer; do
    if ! command -v "$cmd" &>/dev/null; then
        if [[ "$cmd" == "packer" ]]; then
            install_packer
        else
            echo "ERROR: $cmd is not installed or not in PATH" >&2
            exit 1
        fi
    fi
    info "$cmd: $(${cmd} version --short 2>/dev/null || ${cmd} version 2>/dev/null | head -1)"
done

# ── Step 1: kind cluster ──────────────────────────────────────────────────────
step "Creating kind cluster (${KIND_NODE_IMAGE})"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    warning "Cluster '${CLUSTER_NAME}' already exists — skipping creation"
else
    kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}"
    info "Cluster created"
fi

kubectl cluster-info --context "kind-${CLUSTER_NAME}" >/dev/null
info "kubectl context: kind-${CLUSTER_NAME}"

# ── Step 2: KubeVirt ──────────────────────────────────────────────────────────
step "Installing KubeVirt ${KUBEVIRT_VERSION}"

KUBEVIRT_BASE="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}"

kubectl apply -f "${KUBEVIRT_BASE}/kubevirt-operator.yaml"
kubectl apply -f "${KUBEVIRT_BASE}/kubevirt-cr.yaml"

info "Waiting for KubeVirt operator to be ready (~3 min)..."
kubectl -n kubevirt wait deployment/virt-operator \
    --for=condition=Available --timeout=5m

info "Waiting for all KubeVirt components to deploy..."
kubectl -n kubevirt wait kv/kubevirt \
    --for=condition=Available --timeout=10m

info "KubeVirt ${KUBEVIRT_VERSION} ready"

# ── Step 3: CDI ───────────────────────────────────────────────────────────────
step "Installing CDI ${CDI_VERSION}"

CDI_BASE="https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}"

kubectl apply -f "${CDI_BASE}/cdi-operator.yaml"
kubectl apply -f "${CDI_BASE}/cdi-cr.yaml"

info "Waiting for CDI to be ready (~2 min)..."
kubectl -n cdi wait deployment/cdi-operator \
    --for=condition=Available --timeout=5m

kubectl -n cdi wait cdi/cdi \
    --for=condition=Available --timeout=5m

info "CDI ${CDI_VERSION} ready"

# ── Done ──────────────────────────────────────────────────────────────────────
step "Cluster is ready"
echo ""
echo -e "  KubeVirt:  ${KUBEVIRT_VERSION}"
echo -e "  CDI:       ${CDI_VERSION}"
echo -e "  Node:      ${KIND_NODE_IMAGE}"
echo ""
echo -e "  Next steps:"
echo -e "  ${CYAN}make golden-ubuntu${NC}    # ~20 min, once"
echo -e "  ${CYAN}make golden-windows${NC}   # ~45 min, once"
echo -e "  ${CYAN}make build load-kind${NC}  # build + load images"
echo -e "  ${CYAN}make deploy${NC}           # deploy the platform"
echo ""
