SHELL := /bin/bash
.DEFAULT_GOAL := help

# Defaults for the VM targets: make vm / vm-url / vm-delete / console.
OS   ?= ubuntu
NAME ?= lab1

# Golden DataVolume/DataSource names that VMs clone from.
GOLDEN_UBUNTU    ?= ubuntu-golden
GOLDEN_WINDOWS   ?= windows-golden

# The image the requested OS clones from. One expansion keeps the OS-to-image
# mapping in a single place; check-os rejects any other OS before this is used.
DATASOURCE = $(if $(filter windows,$(OS)),$(GOLDEN_WINDOWS),$(GOLDEN_UBUNTU))

# Golden builds and cleanup honour this; deploy/ hardcodes `namespace: default`,
# so check-namespace refuses anything else rather than splitting the setup
# across two namespaces that cannot see each other's DataSources.
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

# xorriso and rsync repack the Windows installer ISO. They are checked in
# preflight-windows rather than preflight, so an Ubuntu-only run that never
# touches either is not blocked on installing them.
CORE_TOOLS := docker kind kubectl packer virtctl git go
WIN_TOOLS  := xorriso rsync

# Progress lines. Keep messages free of '%' — these are printf formats.
SAY  := @printf '\033[0;32m▸ %s\033[0m\n'
WARN := @printf '\033[1;33m! %s\033[0m\n'

NODE_IP = $$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

help: ## Show this help
	@printf '\n  \033[1mKubeVirt VM lab\033[0m — Ubuntu and Windows desktops in a browser\n'
	@awk 'BEGIN {FS = ":.*##"} \
		/^##@/ { printf "\n  \033[1m%s\033[0m\n", substr($$0, 5) } \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "    \033[36m%-22s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf '\n  \033[1mFirst run, in order:\033[0m\n'
	@printf '    make cluster                    # kind + KubeVirt + CDI, ~10 min\n'
	@printf '    make golden-ubuntu              # one-time Packer build, ~20 min\n'
	@printf '    make vm OS=ubuntu NAME=ubuntu1  # prints a browser link\n'
	@printf '\n  \033[1mAdd Windows:\033[0m  make golden-windows && make vm OS=windows NAME=win1\n\n'

##@ Setup

preflight: ## Check that the required tools are installed
	@missing=; for t in $(CORE_TOOLS); do \
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

# Internal guard, invoked by prepare-windows-iso. Not in `make help`.
preflight-windows:
	@missing=; for t in $(WIN_TOOLS); do \
		command -v $$t >/dev/null || missing="$$missing $$t"; done; \
	if [ -n "$$missing" ]; then \
		printf '\033[1;33m! missing:%s\033[0m\n' "$$missing"; \
		printf '  Debian/Ubuntu: sudo apt-get install -y%s\n' "$$missing"; exit 1; fi

# Autounattend.xml goes in both places: sources/ for the windowsPE pass, root
# for setup. One shell so the trap survives every step; a private mktemp -d
# rather than /mnt, which would clobber whatever is already mounted there.
# Needs sudo — mounting the source ISO is the only way to read its contents.
prepare-windows-iso: preflight-windows ## Inject Autounattend.xml into the Windows ISO
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
serve: check-namespace ## Deploy Guacamole and the proxy that publishes it
	kubectl apply -f deploy/guacamole.yaml
	$(WARN) "Waiting for MySQL — the first start runs schema init"
	kubectl wait --for=condition=Ready pod -l app=mysql --timeout=3m
	kubectl wait --for=condition=Ready pod -l app=guacamole --timeout=2m
	kubectl create configmap portal-nginx-conf --from-file=nginx.conf=portal/nginx.conf \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl apply -f deploy/portal.yaml
	kubectl wait --for=condition=Ready pod -l app=student-portal --timeout=2m

# Anything other than ubuntu or windows would otherwise fail later and less
# clearly, on a `deploy/vm-$(OS).yaml` that does not exist.
check-os:
	@case "$(OS)" in ubuntu|windows) ;; *) \
		printf '\033[1;33m! OS must be ubuntu or windows (got "%s")\033[0m\n' '$(OS)'; \
		exit 1;; esac

# Checked before `serve` runs, so a missing image fails in a second rather than
# after a three-minute wait on MySQL.
check-golden: check-os
	@kubectl get datasource $(DATASOURCE) -n $(NAMESPACE) >/dev/null 2>&1 || { \
		printf '\033[1;33m! DataSource "%s" missing — run: make golden-$(OS)\033[0m\n' '$(DATASOURCE)'; \
		exit 1; }

vm: check-golden serve ## Spin up a VM and print a browser link (OS=ubuntu|windows NAME=lab1)
	@if [ "$(OS)" = windows ]; then kubectl apply -f deploy/windows-pool-unattend.yaml; fi
	sed -e 's/__NAME__/$(NAME)/g' -e 's/__DATASOURCE__/$(DATASOURCE)/g' deploy/vm-$(OS).yaml | kubectl apply -f -
	$(SAY) "Cloning the golden disk — a few minutes"
	# Wait on the VM, not the VMI: the VMI does not exist until the clone
	# finishes, and kubectl wait errors on a missing object. vm-connect.sh then
	# waits for the desktop itself to answer.
	kubectl wait --for=condition=Ready vm/$(NAME) -n $(NAMESPACE) --timeout=15m
	$(SAY) "Waiting for the desktop to come up"
	@./scripts/vm-connect.sh $(NAME) $(OS)

vm-url: ## Reprint a VM's browser link with a fresh token (NAME=lab1 OS=ubuntu)
	@./scripts/vm-connect.sh $(NAME) $(OS)

vm-delete: ## Delete one VM, its disk and its Service (NAME=lab1)
	kubectl delete vm $(NAME) -n $(NAMESPACE) --ignore-not-found
	kubectl delete dv $(NAME)-disk -n $(NAMESPACE) --ignore-not-found
	kubectl delete svc desktop-$(NAME) -n $(NAMESPACE) --ignore-not-found
	$(WARN) "Guacamole connection '$(NAME)' and user 'lab-vm-$(NAME)' left in place — remove them in the admin UI"

##@ Operate

status: ## List the VMs this repo created and their state
	@printf '\n\033[1mVMs\033[0m\n'
	@kubectl get vm -l app=lab-vm -n $(NAMESPACE) \
		-o custom-columns='NAME:.metadata.name,OS:.metadata.labels.lab-vm-os,STATE:.status.printableStatus' \
		2>/dev/null || echo "  none"
	@printf '\n\033[1mGolden images\033[0m\n'
	@kubectl get datasource -n $(NAMESPACE) \
		-o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status' \
		2>/dev/null || echo "  none"
	@printf '\n'

urls: ## Print the Guacamole URL
	@ip=$(NODE_IP); \
	printf '\n  Guacamole       http://%s:30000/guacamole/\n'   "$$ip"; \
	printf '  Admin login     guacadmin / guacadmin\n'; \
	printf '  Desktop link    make vm-url NAME=lab1 OS=ubuntu\n\n'

console: ## Open a serial console on a VM, to debug a black screen (NAME=lab1)
	virtctl console $(NAME) -n $(NAMESPACE)

##@ Cleanup

clean: ## Delete every VM, plus Guacamole and the proxy; keep golden images
	@kubectl get vm -l app=lab-vm -n $(NAMESPACE) -o name 2>/dev/null | xargs -r kubectl delete -n $(NAMESPACE)
	@kubectl get svc -l app=lab-vm -n $(NAMESPACE) -o name 2>/dev/null | xargs -r kubectl delete -n $(NAMESPACE)
	kubectl delete deployment student-portal --ignore-not-found
	kubectl delete svc student-portal --ignore-not-found
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
        prepare-windows-iso golden-windows check-namespace check-os check-golden \
        serve vm vm-url vm-delete status urls console clean clean-all clean-cluster
