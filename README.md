# Ubuntu and Windows desktops on KubeVirt

**An end-to-end proof of concept: build golden Ubuntu 24.04 and Windows 10 images with Packer, run
them as KubeVirt VMs on a single-node kind cluster, and open either desktop in a browser — no VNC or
RDP client needed.**

```bash
make cluster                        # kind + KubeVirt + CDI     (~10 min)
make golden-ubuntu                  # one-time Packer build     (~20 min)
make vm OS=ubuntu NAME=ubuntu1      # boot and print a link     (~1 min)
```

Windows is the same two steps; the installer ISO is downloaded for you:

```bash
make golden-windows                 # fetch ISO + Packer build  (~45 min)
make vm OS=windows NAME=win1
```

Each `make vm` prints a URL. Open it and the desktop is there, already logged in.

**What this is not:** production infrastructure. Credentials are committed on purpose so the lab
reproduces, nothing is authenticated, and there is no TLS. Keep it on a network you control.

---

## Prerequisites

**Hardware virtualization is mandatory.** KubeVirt runs real QEMU/KVM VMs, so the host needs
`/dev/kvm` — on a cloud VM, nested virtualization has to be enabled first. This is the most common
reason a first attempt fails.

```bash
ls -l /dev/kvm     # must exist and be readable
```

Without KVM you can fall back to emulation. Ubuntu becomes sluggish, Windows unusable:

```bash
kubectl -n kubevirt patch kv kubevirt --type merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
```

**Tools:** `docker`, `kind`, `kubectl`, `packer`, `virtctl`, `git`, `go` — checked by `make cluster`.
Windows additionally needs `xorriso`, `p7zip-full` (`7z`), and `curl` to fetch and repack the installer ISO.

**Capacity:** ~8 GB RAM and 60 GB disk for Ubuntu alone. With Windows, ~16 GB RAM and ~120 GB disk —
the 5.5 GB source ISO, the repacked copy and a 64 GiB golden image dominate. VMs themselves are cheap:
each one is a copy-on-write overlay on the golden image, not a copy of it.

---

## The workflow

See the [detailed flow diagrams](docs/workflow.md) for cluster setup, golden-image
builds, Windows provisioning, VM creation, and browser traffic.

### 1. Cluster

`make cluster` runs [scripts/setup-cluster.sh](scripts/setup-cluster.sh): a kind cluster
(`kindest/node:v1.35.0`), then **KubeVirt v1.8.2** and **CDI v1.65.0**, waiting for both to report
Available. Idempotent — re-run it freely. CDI is what turns an installer ISO into a golden PVC;
VMs then overlay that PVC directly, so CDI is not in the path of `make vm` at all.

### 2. Golden image

`make golden-ubuntu` is the slow, once-per-cluster step. Packer boots a throwaway VM *inside the
cluster* from the Ubuntu 24.04 ISO, runs an unattended install driven by
[golden/ubuntu/user-data](golden/ubuntu/user-data), provisions XFCE with autologin and **x11vnc on
:5900 inside the guest**, generalizes the disk, and leaves a CDI `DataSource` named `ubuntu-golden`.

Putting the VNC server *in the guest* rather than proxying `virtctl vnc` from outside is the
decision the rest of the repo rests on: an Ubuntu desktop and a Windows desktop then look identical
to the cluster — both are just a TCP port behind a Service.

`make golden-windows` has the same shape, plus media handling (see [Windows](#windows)).

### 3. VM

`make vm OS=ubuntu NAME=ubuntu1`, in order:

1. checks the `ubuntu-golden` PVC exists, so a missing image fails in a second;
2. deploys Guacamole, guacd, MySQL and the nginx proxy if they are not already up;
3. renders [deploy/vm-ubuntu.yaml](deploy/vm-ubuntu.yaml) and applies it — the VM's root disk is an
   `ephemeral` volume, so KubeVirt mounts the golden PVC read-only and lays a copy-on-write overlay
   over it. Nothing is copied, and boot is the only thing left to wait for;
4. waits for the VM to be Ready, meaning the QEMU guest agent has checked in;
5. runs [scripts/vm-connect.sh](scripts/vm-connect.sh), which creates a ClusterIP Service for the
   guest's VNC or RDP port, waits until it answers, registers the connection in Guacamole, and
   prints an auto-login URL.

Re-run with a different `NAME` for another VM. `make status` lists what exists.

### Browser access

Both OS types reach the browser over one code path; the only per-OS difference is a protocol and a
port.

```
Your browser
      │
      ▼
nginx proxy  (NodePort :30000)  ── same origin, so the ?token= auto-login works
      │                            and the WebSocket tunnel gets its upgrade headers
      ▼
Apache Guacamole ──► guacd ──┬── vnc :5900 ──►  Ubuntu VM   (x11vnc + XFCE, autologin)
                             └── rdp :3389 ──►  Windows VM  (native RDP)
                                    │
                              per-VM ClusterIP Service, selector kubevirt.io/vm=<name>
```

The printed link carries a token for a **throwaway account scoped to that one VM**, recreated on
every run — the `guacadmin` token would instead let anyone holding the link enumerate every other
connection and read its password back in plaintext.

---

## Commands

`make help` lists everything. The ones you will use:

| Command | What it does |
|---|---|
| `make cluster` | kind + KubeVirt + CDI |
| `make golden-ubuntu` / `make golden-windows` | Build a golden image (one-time, slow) |
| `make vm OS=ubuntu NAME=ubuntu1` | Create a VM and print a browser link |
| `make vm-url NAME=ubuntu1 OS=ubuntu` | Fresh link — tokens expire after 60 idle minutes |
| `make status` | VMs, golden images, and the Guacamole URL |
| `make console NAME=ubuntu1` | Serial console into the guest, for debugging |
| `make vm-delete NAME=ubuntu1` | Delete one VM and its Service |
| `make clean` | Delete all VMs and Guacamole; keep the golden images |
| `make clean-all` | Also delete golden images, ISOs and every PVC |
| `make clean-cluster` | Delete the kind cluster outright |

---

## Windows

`make golden-windows` downloads the public **Windows 10 22H2 Enterprise Evaluation** ISO (~5.5 GB,
resumable, size- and SHA256-verified), caches it in `disk/`, injects `Autounattend.xml` and repacks
it. To use your own media instead, drop it at `disk/Win10_22H2_EnterpriseEval_x64.iso` or pass
`WIN_ISO_SRC=/path/to.iso`; a different URL goes in `WIN_ISO_URL` (as an env var — make would expand
`&` and `$` in a signed URL). Custom media unsets the checksum pins, and
[golden/windows/autounattend.xml](golden/windows/autounattend.xml) targets the Evaluation WIM, so a
retail ISO needs its image name and product key adjusted.

A **fully unattended Windows install on KubeVirt** took a long series of failed approaches — oemdrv
disks, cloud-init, floppy attachment — before ISO injection worked. The combination that does work:

- `Autounattend.xml` in **both** the ISO root and `sources/` — root for setup, `sources/` for the
  windowsPE pass;
- an `efisys.bin` no-prompt EFI boot image, so the build does not stall on "press any key to boot";
- a Packer `boot_command` of `["<enter>"]`;
- `virtio-win` drivers and the QEMU guest agent installed during the build, or KubeVirt never sees
  the guest come up;
- a sysprep answer file mounted on every VM
  ([deploy/windows-pool-unattend.yaml](deploy/windows-pool-unattend.yaml)). The golden image is
  sysprepped with `/oobe`, so without it the VM stops at the region-select wizard. Because every
  start overlays the pristine image, this runs on every boot, not just the first.

---

## Packer plugin fork

Upstream `hashicorp/packer-plugin-kubevirt` lacks a few things this pipeline needs, so the golden
targets clone a [fork](https://github.com/basil-eldho/packer-plugin-kubevirt) on demand and install
it under the *upstream* name `github.com/hashicorp/kubevirt` — deliberate, since that is what the
`required_plugins` blocks in `golden/*/*.pkr.hcl` resolve against.

| Change | Why |
|---|---|
| `media_files_label` config field | Ubuntu cloud-init looks for a `cidata`-labelled disk, not the builder's hardcoded `OEMDRV` |
| UEFI firmware on the build VM | These VMs boot UEFI; a BIOS build VM produces a bootloader that never boots |
| Pre-existing resource cleanup | A failed run leaves an orphaned DataVolume/DataSource that blocks the next run |

An existing `packer-plugin-kubevirt/` checkout is left untouched, so building from a dirty tree
works. Override with `PLUGIN_REPO`, `PLUGIN_REF` or `PLUGIN_DIR`.

---

## Repository layout

| Path | What it is |
|---|---|
| [golden/](golden/) | Packer templates and provisioning scripts for the Ubuntu and Windows images |
| [deploy/](deploy/) | VM templates, the Guacamole stack, the nginx proxy, the sysprep ConfigMap |
| [scripts/](scripts/) | Cluster bootstrap, and `vm-connect.sh` which publishes a desktop and prints a link |
| [Makefile](Makefile) | Every command above |

An earlier revision put a Go control plane in front of all this — a controller keeping a warm pool of
pre-booted VMs behind an HTTP API, so a click produced a desktop in under two seconds. It worked, but
it distracts from the KubeVirt mechanics this repo exists to show; it is preserved on the
[`warm-pool`](https://github.com/basil-eldho/kubevirt-lab/tree/warm-pool) branch.

---

## Troubleshooting

**Black screen.** The desktop is not rendering yet, or x11vnc attached before anything logged in.
`make console NAME=ubuntu1` and check `loginctl list-sessions`; `make vm-url` reissues the connection.

**The URL's host is unreachable.** `make status` prints the kind node's internal IP, routable on
Linux but **not** from the host on Docker Desktop. Port-forward instead, then paste the
`#/client/...?token=...` fragment onto `http://localhost:8080/guacamole/`:

```bash
kubectl port-forward svc/guac-proxy 8080:80
```

**A VM never goes Ready.** Check `kubectl get vmi` and the virt-launcher pod. If VMIs sit at
`phase=Scheduled` and never define a libvirt domain, virt-handler has wedged:
`kubectl rollout restart ds/virt-handler -n kubevirt`.

**Windows boots to a setup wizard.** The sysprep ConfigMap is missing — `make vm OS=windows` applies
it; a hand-applied `deploy/vm-windows.yaml` does not.

**Windows reboots into OOBE over and over.** Every VM start overlays the pristine sysprepped image,
so a guest *shutdown* — as opposed to a reboot — makes `runStrategy: Always` build a fresh VMI with a
fresh overlay, and OOBE runs again. Guest-internal reboots are safe; a full shutdown is not. If the
unattend sequence ends in a shutdown, switch that VM to `runStrategy: Manual`.

**A golden image rebuild hangs.** Running VMs mount the golden PVC read-only, so `make golden-*`
cannot replace it underneath them. `make clean` first.

**A Packer build failed and the next refuses to start.** An orphaned DataVolume or DataSource is in
the way: `make clean-all`, or delete the named DataVolume to keep the golden images.

**Everything is slow.** Check `/dev/kvm` and that you are not running under `useEmulation`.

---

## Notes and feedback

I built this while learning KubeVirt, CDI and Packer, so parts of it are almost certainly done in a
clumsier way than they need to be — there may well be better patterns for the golden-image flow, the
per-VM Services, or the Guacamole wiring than the ones here. If you spot something wrong, fragile, or
just unnecessary, please open an issue or a pull request. That kind of feedback is genuinely useful
to me, and thanks in advance.

---

## License

[Apache License 2.0](LICENSE). The Packer plugin fork is a separate repository under its own
upstream license (MPL-2.0).
