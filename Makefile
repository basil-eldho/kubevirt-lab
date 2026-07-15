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
	@printf '\n  \033[1mFirst run, in order:\033[0m\n'
	@printf '    make cluster          # kind + KubeVirt + CDI\n'
	@printf '    make golden-ubuntu    # one-time, ~20 min\n'
	@printf '    make deploy && make urls\n'
	@printf '\n  \033[1mAdd Windows later:\033[0m  make golden-windows && make deploy MIN_POOL_WINDOWS=1\n\n'

##@ Setup

preflight: ## Check that required tools are installed
	@missing=; for t in docker kind kubectl packer virtctl xorriso git go rsync lsof; do \
		command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then printf '\033[1;33m! missing:%s\033[0m\n' "$$missing"; exit 1; fi
	$(SAY) "All required tools present"

cluster: preflight ## Create the kind cluster with KubeVirt + CDI
	./scripts/setup-cluster.sh

##@ Golden images (Packer, one-time)

# Order-only prerequisite: cloned when absent, otherwise left untouched, so
# building from a dirty local checkout keeps working.
$(PLUGIN_DIR):
	$(SAY) "Cloning the Packer plugin fork — $(PLUGIN_REF)"
	git clone --branch $(PLUGIN_REF) --single-branch $(PLUGIN_REPO) $(PLUGIN_DIR)

packer-init-local: | $(PLUGIN_DIR) ## Build and install the Packer plugin fork
	$(MAKE) -C $(PLUGIN_DIR) build
	packer plugins install --path $(PLUGIN_DIR)/packer-plugin-kubevirt "$(PLUGIN_SOURCE)"

golden-ubuntu: packer-init-local ## Build the Ubuntu golden image (~20 min)
	kubectl apply -f golden/ubuntu/iso-dv.yaml
	kubectl wait --for=condition=Ready dv/ubuntu-2404-iso --timeout=20m
	$(SAY) "Packer build: installs OS, XFCE, x11vnc, then generalizes"
	cd golden/ubuntu && KUBECONFIG=~/.kube/config packer build \
		-var "namespace=$(NAMESPACE)" \
		-var "name=$(GOLDEN_UBUNTU)" \
		ubuntu.pkr.hcl
	$(SAY) "Ubuntu golden image ready — DataSource $(GOLDEN_UBUNTU)"

# Autounattend.xml goes in both places: sources/ for the windowsPE pass, root
# for setup. One shell so the trap survives every step; a private mktemp -d
# rather than /mnt, which would clobber whatever is already mounted there.
prepare-windows-iso: ## Inject Autounattend.xml into the Windows ISO
	@if [ ! -f "$(WIN_ISO_SRC)" ]; then \
		printf '\033[1;33m! Windows ISO not found at %s\n' "$(WIN_ISO_SRC)"; \
		printf '  Optional — Ubuntu-only needs nothing here. Drop a Windows 10 22H2\n'; \
		printf '  x64 ISO in disk/, or pass WIN_ISO_SRC=/path/to.iso\033[0m\n'; \
		exit 1; fi
	@set -e; \
	mnt=$$(mktemp -d); ext=$$(mktemp -d); \
	trap 'sudo umount "$$mnt" 2>/dev/null || true; rmdir "$$mnt" 2>/dev/null || true; rm -rf "$$ext"' EXIT; \
	printf '\033[0;32m▸ %s\033[0m\n' "Repacking Windows ISO with Autounattend.xml"; \
	sudo mount -o loop,ro "$(WIN_ISO_SRC)" "$$mnt"; \
	rsync -a "$$mnt"/ "$$ext"/; \
	sudo umount "$$mnt"; \
	chmod -R u+w "$$ext"; \
	cp golden/windows/autounattend.xml "$$ext"/Autounattend.xml; \
	cp golden/windows/autounattend.xml "$$ext"/sources/Autounattend.xml; \
	xorriso -as mkisofs \
		-iso-level 3 -full-iso9660-filenames \
		-rock -joliet -joliet-long \
		-disable-deep-relocation -untranslated-filenames \
		-b boot/etfsboot.com -no-emul-boot -boot-load-size 8 -boot-info-table \
		-eltorito-alt-boot -eltorito-platform efi \
		-b efi/microsoft/boot/efisys.bin -no-emul-boot \
		-V "CCCOMA_X64FRE_EN-GB_DV9" \
		-o "$(WIN_ISO_OUT)" \
		"$$ext"
	$(SAY) "Unattended ISO ready: $(WIN_ISO_OUT)"

golden-windows: packer-init-local prepare-windows-iso ## Build the Windows golden image (~45 min)
	kubectl delete dv windows-iso --ignore-not-found
	kubectl patch pvc windows-iso -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	kubectl delete pvc windows-iso --ignore-not-found
	kubectl apply -f golden/windows/iso-dv.yaml
	kubectl wait --for=jsonpath='{.status.phase}'=UploadReady dv/windows-iso --timeout=5m
	$(SAY) "Uploading the Windows ISO — takes a few minutes"
	# Kill the forward by its own PID and let a failed upload fail the target.
	@set -e; \
	kubectl port-forward -n cdi svc/cdi-uploadproxy 18443:443 & \
	pf=$$!; \
	trap 'kill $$pf 2>/dev/null || true' EXIT; \
	sleep 3; \
	virtctl image-upload dv windows-iso \
		--size=8Gi \
		--image-path="$(WIN_ISO_OUT)" \
		--uploadproxy-url=https://localhost:18443 \
		--force-bind --insecure
	kubectl wait --for=condition=Ready dv/windows-iso --timeout=10m
	$(SAY) "Packer build: autounattend install, then WinRM provisioners"
	cd golden/windows && KUBECONFIG=~/.kube/config PACKER_LOG=1 packer build \
		-var "namespace=$(NAMESPACE)" \
		-var "name=$(GOLDEN_WINDOWS)" \
		windows.pkr.hcl
	$(SAY) "Windows golden image ready — DataSource $(GOLDEN_WINDOWS)"

##@ Deploy

# Listed in the order `deploy` runs them: guards first (they fail in seconds),
# then the image build, then the cluster objects.
check-namespace: ## Refuse a NAMESPACE the deploy manifests cannot honour
	@if [ "$(NAMESPACE)" != "default" ]; then \
		printf '\033[1;33m! NAMESPACE=%s unsupported: deploy/ hardcodes `namespace: default`,\n' '$(NAMESPACE)'; \
		printf '  so the platform and the golden images would land in different places.\033[0m\n'; \
		exit 1; fi

# Without the DataSource the controller still creates VMs; their clone just
# never resolves and the pool sits at zero with nothing obvious in the logs.
# Only enabled pools are checked, so Ubuntu-only needs no Windows image.
check-golden: ## Verify the golden DataSources the enabled pools need
	@rc=0; \
	ready() { kubectl get datasource "$$1" -n $(NAMESPACE) \
		-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -qx True; }; \
	if [ "$(MIN_POOL_UBUNTU)" -gt 0 ] 2>/dev/null && ! ready $(GOLDEN_UBUNTU); then \
		printf '\033[1;33m! Ubuntu pool is %s but DataSource "%s" is missing or not ready\n  Run: make golden-ubuntu\033[0m\n' \
			'$(MIN_POOL_UBUNTU)' '$(GOLDEN_UBUNTU)'; rc=1; \
	fi; \
	if [ "$(MIN_POOL_WINDOWS)" -gt 0 ] 2>/dev/null && ! ready $(GOLDEN_WINDOWS); then \
		printf '\033[1;33m! Windows pool is %s but DataSource "%s" is missing or not ready\n  Run: make golden-windows\033[0m\n' \
			'$(MIN_POOL_WINDOWS)' '$(GOLDEN_WINDOWS)'; rc=1; \
	fi; \
	exit $$rc

build: ## Build the controller and API images
	docker build --target controller -t pool-controller:v1 pool-go/
	docker build --target api -t pool-api:v1 pool-go/

load-kind: build ## Build, then load images into the kind node
	kind load docker-image pool-controller:v1
	kind load docker-image pool-api:v1
	$(SAY) "Images loaded into kind"

setup-rbac: ## Apply the controller ServiceAccount and RBAC
	kubectl apply -f deploy/rbac.yaml

deploy-guacamole: ## Deploy the Guacamole stack (MySQL, guacd, Guacamole)
	kubectl apply -f deploy/guacamole.yaml
	$(WARN) "Waiting for MySQL — the first start runs schema init"
	kubectl wait --for=condition=Ready pod -l app=mysql --timeout=3m
	kubectl wait --for=condition=Ready pod -l app=guacamole --timeout=2m

# load-kind is a prerequisite because the manifests use imagePullPolicy: Never —
# the images must be on the node already or the pods hit ErrImageNeverPull.
deploy: check-namespace check-golden load-kind setup-rbac deploy-guacamole ## Deploy the controller, API, and portal
	kubectl apply -f deploy/redis.yaml
	kubectl wait --for=condition=Ready pod -l app=redis --timeout=60s
	kubectl apply -f deploy/windows-pool-unattend.yaml
	kubectl apply -f deploy/controller.yaml
	# Set unconditionally: comparing against controller.yaml's defaults first
	# would rot silently the moment either default is edited.
	kubectl set env deployment/pool-controller \
		MIN_POOL_UBUNTU=$(MIN_POOL_UBUNTU) MIN_POOL_WINDOWS=$(MIN_POOL_WINDOWS) \
		DATASOURCE_UBUNTU=$(GOLDEN_UBUNTU) DATASOURCE_WINDOWS=$(GOLDEN_WINDOWS)
	kubectl apply -f deploy/api.yaml
	kubectl create configmap portal-html --from-file=index.html=portal/index.html \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl create configmap portal-nginx-conf --from-file=nginx.conf=portal/nginx.conf \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f deploy/portal.yaml
	$(SAY) "Deployed (ubuntu=$(MIN_POOL_UBUNTU), windows=$(MIN_POOL_WINDOWS)). Warm in 3-8 min: make status"

