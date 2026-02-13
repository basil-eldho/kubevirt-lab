SHELL := /bin/bash
.DEFAULT_GOAL := help

# Warm VMs per OS. Windows is opt-in — it needs the ~45 min golden build first,
# and pooling it without one leaves VMs cloning a DataSource that does not exist.
MIN_POOL_UBUNTU  ?= 1
MIN_POOL_WINDOWS ?= 1

# Defaults for the standalone VM targets: make vm / vm-url / vm-delete.
OS   ?= ubuntu
NAME ?= lab1

# Golden DataVolume/DataSource names that pool VMs clone from.
GOLDEN_UBUNTU    ?= ubuntu-golden
GOLDEN_WINDOWS   ?= windows-golden

# Golden builds and cleanup honour this; deploy/ hardcodes `namespace: default`,
# so check-namespace refuses anything else rather than splitting the platform.
NAMESPACE        ?= default

WIN_ISO_SRC ?= $(CURDIR)/disk/Win10_22H2_EnglishInternational_x64v1.iso
WIN_ISO_OUT ?= $(CURDIR)/disk/Win10_22H2_unattended.iso

# Fork of hashicorp/packer-plugin-kubevirt. HTTPS so the clone needs no creds.
PLUGIN_REPO ?= https://github.com/basil-eldho/packer-plugin-kubevirt.git
PLUGIN_REF  ?= feat/configurable-media-files-label
PLUGIN_DIR  ?= $(CURDIR)/packer-plugin-kubevirt
# Must match required_plugins in golden/*/*.pkr.hcl — installing the fork under
# the upstream name is what makes those templates resolve to it.
PLUGIN_SOURCE := github.com/hashicorp/kubevirt

# Progress lines. Keep messages free of '%' — these are printf formats.
SAY  := @printf '\033[0;32m▸ %s\033[0m\n'
WARN := @printf '\033[1;33m! %s\033[0m\n'

NODE_IP = $$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

help: ## Show this help
	@printf '\n  \033[1mKubeVirt Lab Platform\033[0m — warm-pool Ubuntu + Windows desktops\n'
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n  \033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "    \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

##@ Setup

preflight: ## Check that required tools are installed
	@missing=; for t in docker kind kubectl packer virtctl xorriso git go rsync lsof; do \
		command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then printf '\033[1;33m! missing:%s\033[0m\n' "$$missing"; exit 1; fi
	$(SAY) "All required tools present"

cluster: preflight ## Create the kind cluster with KubeVirt + CDI
	./scripts/setup-cluster.sh
