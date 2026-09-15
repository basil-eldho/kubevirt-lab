SHELL := /bin/bash
.DEFAULT_GOAL := help

# Defaults for the VM targets: make vm / vm-url / vm-delete / console.
OS   ?= ubuntu
NAME ?= lab1

# Golden DataVolume/DataSource/PVC names that VMs overlay.
GOLDEN_UBUNTU    ?= ubuntu-golden
GOLDEN_WINDOWS   ?= windows-golden

# The golden PVC the requested OS overlays. One expansion keeps the OS-to-image
# mapping in a single place; check-os rejects any other OS before this is used.
# The Packer builds name the DataVolume, its PVC and its DataSource alike, so this
# one name serves as both the readiness signal and the ephemeral claimName.
GOLDEN = $(if $(filter windows,$(OS)),$(GOLDEN_WINDOWS),$(GOLDEN_UBUNTU))

# Golden builds and cleanup honour this; deploy/ hardcodes `namespace: default`,
# so check-namespace refuses anything else rather than splitting the setup
# across two namespaces that cannot see each other's DataSources.
NAMESPACE        ?= default

# Windows installer media. Unlike the Ubuntu ISO, which CDI pulls from a stable
# mirror inside the cluster, this one is downloaded on the host: it has to be
# repacked with Autounattend.xml before anything can boot it.
#
# Default is the public Windows 10 22H2 Enterprise Evaluation ISO on Microsoft's
# CDN — the same object Dockur pins. Retail FIDO links expire within a day;
# this one does not. WIN_ISO_SRC is the cache: downloaded when absent, reused
# afterwards. Drop your own ISO there (or pass WIN_ISO_SRC) and no fetch runs.
# Override with WIN_ISO_URL=… ; prefer the env-var form, because a make
# argument would expand '&' and '$' in signed URLs.
DEFAULT_WIN_ISO_URL    := https://software-static.download.prss.microsoft.com/dbazure/988969d5-f34g-4e03-ac9d-1f9786c66750/19045.2006.220908-0225.22h2_release_svc_refresh_CLIENTENTERPRISEEVAL_OEMRET_x64FRE_en-us.iso
DEFAULT_WIN_ISO_SHA256 := ef7312733a9f5d7d51cfa04ac497671995674ca5e1058d5164d6028f0938d668
DEFAULT_WIN_ISO_SIZE   := 5550497792
WIN_ISO_SRC    ?= $(CURDIR)/disk/Win10_22H2_EnterpriseEval_x64.iso
WIN_ISO_OUT    ?= $(CURDIR)/disk/Win10_22H2_unattended.iso
WIN_ISO_URL    ?= $(DEFAULT_WIN_ISO_URL)
# Only pin size/checksum against the default object. A custom URL would fail them.
ifeq ($(WIN_ISO_URL),$(DEFAULT_WIN_ISO_URL))
WIN_ISO_SHA256 ?= $(DEFAULT_WIN_ISO_SHA256)
WIN_ISO_SIZE   ?= $(DEFAULT_WIN_ISO_SIZE)
else
WIN_ISO_SHA256 ?=
WIN_ISO_SIZE   ?=
endif

# Fork of hashicorp/packer-plugin-kubevirt. HTTPS so the clone needs no creds.
PLUGIN_REPO ?= https://github.com/basil-eldho/packer-plugin-kubevirt.git
PLUGIN_REF  ?= feat/configurable-media-files-label
PLUGIN_DIR  ?= $(CURDIR)/packer-plugin-kubevirt
# Must match required_plugins in golden/*/*.pkr.hcl — installing the fork under
# the upstream name is what makes those templates resolve to it.
PLUGIN_SOURCE := github.com/hashicorp/kubevirt

# 7z unpacks the Microsoft UDF tree without sudo and xorriso rebuilds the ISO.
# Checked here rather than in preflight so an Ubuntu-only run is not blocked on
# Windows tools.
CORE_TOOLS := docker kind kubectl packer virtctl git go
WIN_TOOLS  := xorriso curl 7z

# Progress lines. Keep messages free of '%' — these are printf formats.
SAY  := @printf '\033[0;32m▸ %s\033[0m\n'
WARN := @printf '\033[1;33m! %s\033[0m\n'

NODE_IP = $$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

help: ## Show this help
	@printf '\n  \033[1mKubeVirt VM lab\033[0m — Ubuntu and Windows desktops in a browser\n'
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n  \033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "    \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\n  \033[1mFirst run:\033[0m\n'
	@printf '    make cluster && make golden-ubuntu && make vm OS=ubuntu NAME=ubuntu1\n'
	@printf '  \033[1mWindows:\033[0m   make golden-windows && make vm OS=windows NAME=win1\n\n'

##@ Setup

# Invoked by `cluster`. Not in `make help`.
preflight:
	@missing=; for t in $(CORE_TOOLS); do \
		command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then printf '\033[1;33m! missing:%s\033[0m\n' "$$missing"; exit 1; fi

cluster: preflight ## kind + KubeVirt + CDI
	./scripts/setup-cluster.sh

##@ Golden images

# Order-only prerequisite: cloned when absent, otherwise left untouched, so
# building from a dirty local checkout keeps working.
$(PLUGIN_DIR):
	$(SAY) "Cloning the Packer plugin fork — $(PLUGIN_REF)"
	git clone --branch $(PLUGIN_REF) --single-branch $(PLUGIN_REPO) $(PLUGIN_DIR)

packer-init-local: | $(PLUGIN_DIR)
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

# Internal guard, invoked by the Windows targets. Not in `make help`.
preflight-windows:
	@missing=; for t in $(WIN_TOOLS); do \
		command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then \
		printf '\033[1;33m! missing:%s\033[0m\n' "$$missing"; \
		printf '  Debian/Ubuntu: sudo apt-get install -y xorriso curl p7zip-full\n'; exit 1; fi

# Download the installer media, cached in disk/. Deliberately no prerequisites:
# once the file exists make treats it as up to date, so a rebuild never re-fetches
# 5.5 GB and an ISO you supplied by hand is used as-is. Delete it to force a refetch.
#
# Resumable, and the partial download is kept under .part so an interrupted or
# 403-ed transfer cannot leave a truncated file that later looks like valid media.
# Signed URLs expire mid-download; -f turns that into a failure instead of an
# error page appended to the ISO, and rerunning with a fresh URL resumes.
$(WIN_ISO_SRC):
	@if [ -z "$(WIN_ISO_URL)" ]; then \
		printf '\033[1;33m! Windows ISO not found at %s\n' "$(WIN_ISO_SRC)"; \
		printf '  Optional — Ubuntu-only needs nothing here. Drop a Windows 10 22H2 x64\n'; \
		printf '  ISO in disk/ (or pass WIN_ISO_SRC=/path/to.iso), or restore the default\n'; \
		printf '  Evaluation Center URL so make can fetch it:\n'; \
		printf '    make golden-windows\033[0m\n'; \
		exit 1; fi
	$(SAY) "Downloading Windows 10 22H2 Enterprise Evaluation — ~5.5 GB, resumable, cached in disk/"
	@set -e; \
	mkdir -p "$(dir $(WIN_ISO_SRC))"; \
	touch "$(WIN_ISO_SRC).part"; \
	curl -fL --retry 3 --retry-delay 5 --continue-at - \
		-o "$(WIN_ISO_SRC).part" "$(WIN_ISO_URL)"; \
	if [ -n "$(WIN_ISO_SIZE)" ]; then \
		got=$$(stat -c%s "$(WIN_ISO_SRC).part"); \
		if [ "$$got" != "$(WIN_ISO_SIZE)" ]; then \
			printf '\033[1;33m! size mismatch: got %s, expected %s\033[0m\n' "$$got" "$(WIN_ISO_SIZE)"; \
			exit 1; \
		fi; \
	fi; \
	if [ -n "$(WIN_ISO_SHA256)" ]; then \
		printf '\033[0;32m▸ %s\033[0m\n' "Verifying sha256"; \
		echo "$(WIN_ISO_SHA256)  $(WIN_ISO_SRC).part" | sha256sum -c -; \
	else \
		printf '\033[1;33m! %s\033[0m\n' "No WIN_ISO_SHA256 given — download not verified"; \
	fi; \
	mv "$(WIN_ISO_SRC).part" "$(WIN_ISO_SRC)"
	$(SAY) "Windows ISO ready: $(WIN_ISO_SRC)"

# Pre-download only. `golden-windows` already does this; keep the target for
# fetching the ISO without starting Packer. Not in `make help`.
fetch-windows-iso: preflight-windows $(WIN_ISO_SRC)

# A real file target rather than a phony one, so a second `make golden-windows` —
# after a failed Packer build, say — does not unpack 6 GB again for nothing.
# Rebuilt only when the source ISO or the answer file is newer.
#
# Microsoft's ISO is UDF with a stub ISO9660 tree (often just README.TXT). A loop
# mount works because the kernel picks UDF, but that needs root. 7z reads UDF as
# a regular file, so the repack does not need sudo.
#
# Autounattend.xml goes in both places: sources/ for the windowsPE pass, root for
# setup. xorriso writes to .tmp and the result is moved into place, so an
# interrupted run cannot leave a truncated ISO that looks newer than its source
# and gets skipped.
$(WIN_ISO_OUT): $(WIN_ISO_SRC) golden/windows/autounattend.xml
	@set -e; \
	ext=$$(mktemp -d); \
	trap 'rm -rf "$$ext"; rm -f "$(WIN_ISO_OUT).tmp"' EXIT; \
	printf '\033[0;32m▸ %s\033[0m\n' "Repacking Windows ISO with Autounattend.xml"; \
	vol=$$(xorriso -indev "$(WIN_ISO_SRC)" -toc 2>&1 | sed -n "s/^Volume id    : '//p" | tr -d "'"); \
	vol=$${vol:-CCCOMA_X64FRE_EN-US_DV9}; \
	7z x -y -bd -o"$$ext" "$(WIN_ISO_SRC)" >/dev/null; \
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
		-V "$$vol" \
		-o "$(WIN_ISO_OUT).tmp" \
		"$$ext"; \
	mv "$(WIN_ISO_OUT).tmp" "$(WIN_ISO_OUT)"
	$(SAY) "Unattended ISO ready: $(WIN_ISO_OUT)"

prepare-windows-iso: preflight-windows $(WIN_ISO_OUT)

golden-windows: packer-init-local prepare-windows-iso ## Build the Windows golden image (~45 min)
	kubectl delete dv windows-iso --ignore-not-found
	kubectl patch pvc windows-iso -n $(NAMESPACE) -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null || true
	kubectl delete pvc windows-iso --ignore-not-found
	kubectl apply -f golden/windows/iso-dv.yaml
	kubectl wait --for=jsonpath='{.status.phase}'=UploadReady dv/windows-iso --timeout=5m
	$(SAY) "Uploading the Windows ISO — takes a few minutes"
	@# Kill the forward by its own PID and let a failed upload fail the target.
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

##@ Run VMs

# Internal guards for the targets below. Kept out of `make help`: nobody runs
# them directly, and they would crowd out the commands that matter.
check-namespace:
	@if [ "$(NAMESPACE)" != "default" ]; then \
		printf '\033[1;33m! NAMESPACE=%s unsupported: deploy/ hardcodes `namespace: default`,\n' '$(NAMESPACE)'; \
		printf '  so the manifests and the golden images would land in different places.\033[0m\n'; \
		exit 1; fi

# Guacamole plus the nginx proxy in front of it. A prerequisite of `vm`, because
# the desktop link is useless until both are up and forgetting this step yields a
# connection error that explains nothing.
#
# Deliberately no `rollout restart`: this runs on every `make vm`, and bouncing
# the proxy would drop the tunnel of any desktop already open in a browser. Edit
# portal/nginx.conf and you have to restart the Deployment yourself.
serve: check-namespace
	kubectl apply -f deploy/guacamole.yaml
	$(WARN) "Waiting for MySQL — the first start runs schema init"
	kubectl wait --for=condition=Ready pod -l app=mysql --timeout=3m
	kubectl wait --for=condition=Ready pod -l app=guacamole --timeout=2m
	kubectl create configmap portal-nginx-conf --from-file=nginx.conf=portal/nginx.conf \
		--dry-run=client -o yaml | kubectl apply -f -
	# Drop the pre-rename Service so NodePort 30000 is free for guac-proxy.
	kubectl delete deployment,svc student-portal --ignore-not-found
	kubectl apply -f deploy/guac-proxy.yaml
	kubectl wait --for=condition=Ready pod -l app=guac-proxy --timeout=2m

# Anything other than ubuntu or windows would otherwise fail later and less
# clearly, on a `deploy/vm-$(OS).yaml` that does not exist.
check-os:
	@case "$(OS)" in ubuntu|windows) ;; *) \
		printf '\033[1;33m! OS must be ubuntu or windows (got "%s")\033[0m\n' '$(OS)'; \
		exit 1;; esac

# Checked before `serve` runs, so a missing image fails in a second rather than
# after a three-minute wait on MySQL. The PVC is what the ephemeral volume mounts,
# so that — not the DataSource — is what has to exist.
check-golden: check-os
	@kubectl get pvc $(GOLDEN) -n $(NAMESPACE) >/dev/null 2>&1 || { \
		printf '\033[1;33m! golden image "%s" missing — run: make golden-$(OS)\033[0m\n' '$(GOLDEN)'; \
		exit 1; }

# The wait is on the VM, not the VMI: the VMI does not exist the instant the VM is
# applied, and `kubectl wait` errors out on an object that is not there yet.
# Readiness means the guest agent has checked in; vm-connect.sh then waits for the
# desktop itself to answer. Comments stay out of the recipe so make does not echo
# them into the middle of the output.
vm: check-golden serve ## Spin up a VM and print a browser link (OS=ubuntu|windows NAME=lab1)
	@if [ "$(OS)" = windows ]; then kubectl apply -f deploy/windows-pool-unattend.yaml; fi
	sed -e 's/__NAME__/$(NAME)/g' -e 's/__GOLDEN__/$(GOLDEN)/g' deploy/vm-$(OS).yaml | kubectl apply -f -
	$(SAY) "Booting — the disk is an overlay on the golden image, so there is nothing to copy"
	kubectl wait --for=condition=Ready vm/$(NAME) -n $(NAMESPACE) --timeout=15m
	$(SAY) "Waiting for the desktop to come up"
	@./scripts/vm-connect.sh $(NAME) $(OS)

vm-url: ## Reprint a VM's browser link with a fresh token (NAME=lab1 OS=ubuntu)
	@./scripts/vm-connect.sh $(NAME) $(OS)

# No disk to delete: the overlay lives in the virt-launcher pod and goes with it.
vm-delete: ## Delete one VM and its Service (NAME=lab1)
	kubectl delete vm $(NAME) -n $(NAMESPACE) --ignore-not-found
	kubectl delete svc desktop-$(NAME) -n $(NAMESPACE) --ignore-not-found
	$(WARN) "Guacamole connection '$(NAME)' and user 'lab-vm-$(NAME)' left in place — remove them in the admin UI"

##@ Operate

status: ## List VMs, golden images, and the Guacamole URL
	@printf '\n\033[1mVMs\033[0m\n'
	@kubectl get vm -l app=lab-vm -n $(NAMESPACE) \
		-o custom-columns='NAME:.metadata.name,OS:.metadata.labels.lab-vm-os,STATE:.status.printableStatus' \
		2>/dev/null || echo "  none"
	@printf '\n\033[1mGolden images\033[0m\n'
	@kubectl get datasource -n $(NAMESPACE) \
		-o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
		2>/dev/null || echo "  none"
	@ip=$(NODE_IP); \
	printf '\n  Guacamole    http://%s:30000/guacamole/\n' "$$ip"; \
	printf '  Desktop link make vm-url NAME=%s OS=%s\n\n' '$(NAME)' '$(OS)'

console: ## Serial console into a VM (NAME=lab1)
	virtctl console $(NAME) -n $(NAMESPACE)

##@ Cleanup

clean: ## Delete every VM, plus Guacamole and the proxy; keep golden images
	@kubectl get vm -l app=lab-vm -n $(NAMESPACE) -o name 2>/dev/null | xargs -r kubectl delete -n $(NAMESPACE)
	@kubectl get svc -l app=lab-vm -n $(NAMESPACE) -o name 2>/dev/null | xargs -r kubectl delete -n $(NAMESPACE)
	kubectl delete deployment guac-proxy student-portal --ignore-not-found
	kubectl delete svc guac-proxy student-portal --ignore-not-found
	kubectl delete configmap portal-nginx-conf windows-pool-unattend --ignore-not-found
	kubectl delete -f deploy/guacamole.yaml --ignore-not-found
	kubectl delete pvc mysql-data --ignore-not-found
	$(SAY) "VMs and browser access removed — golden images kept"

# Everything in $(NAMESPACE): golden images, installer ISOs, and whatever a
# Packer build left behind.
#
# The virt-launcher pods go FIRST and by force. A build VM whose guest never
# booted ignores ACPI shutdown, so its pod hangs in Terminating; while it lives,
# virt-controller keeps re-adding the VMI finalizers and every delete below
# blocks. Strip the finalizers only once the pods are gone, or they come back.
clean-all: clean ## Also delete golden images, ISOs, and every leftover VM/DV/PVC
	@kubectl get pod -n $(NAMESPACE) -l kubevirt.io=virt-launcher -o name 2>/dev/null \
		| xargs -r kubectl delete -n $(NAMESPACE) --force --grace-period=0 --wait=false
	@for v in $$(kubectl get vmi -n $(NAMESPACE) -o name 2>/dev/null); do \
		kubectl patch $$v -n $(NAMESPACE) --type=merge \
			-p '{"metadata":{"finalizers":null}}' 2>/dev/null || true; \
	done
	@kubectl get vm,vmi -n $(NAMESPACE) -o name 2>/dev/null \
		| xargs -r kubectl delete -n $(NAMESPACE) --force --grace-period=0 --ignore-not-found
	kubectl delete datasource --all -n $(NAMESPACE) --ignore-not-found
	kubectl delete dv --all -n $(NAMESPACE) --ignore-not-found
	kubectl delete pvc --all -n $(NAMESPACE) --ignore-not-found
	$(SAY) "Golden images, ISOs, and all VM artifacts removed"

clean-cluster: ## Delete the kind cluster outright (full reset)
	kind delete cluster
	$(SAY) "Cluster deleted — start again with: make cluster"

.PHONY: help preflight cluster packer-init-local golden-ubuntu preflight-windows \
        fetch-windows-iso prepare-windows-iso golden-windows check-namespace check-os check-golden \
        serve vm vm-url vm-delete status console clean clean-all clean-cluster
