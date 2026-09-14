# Ubuntu and Windows desktops on KubeVirt

**A working, end-to-end proof of concept: build golden Ubuntu 24.04 and Windows 10 images with
Packer, run them as KubeVirt VMs on a single-node kind cluster, and open either desktop in your
browser — no VNC or RDP client installed.**

Three commands for Ubuntu:

```bash
make cluster                        # kind + KubeVirt + CDI          (~10 min)
make golden-ubuntu                  # one-time Packer build          (~20 min)
make vm OS=ubuntu NAME=ubuntu1      # clone, boot, print a link      (~3 min)
```

Then two more for Windows, once you supply an ISO:

```bash
make golden-windows                 # one-time Packer build          (~45 min)
make vm OS=windows NAME=win1
```

Each `make vm` prints a URL. Open it and the desktop is there, already logged in.

---

## Why this exists

KubeVirt's own documentation covers the primitives well: `VirtualMachine`, CDI `DataVolume`,
`virtctl`. What was missing when I built this was the whole path — how to get from an installer ISO
to a *reusable golden image*, and from there to a running desktop you can actually look at, for
Windows as well as Linux. The Windows half in particular is mostly folklore: unattended installs on
KubeVirt fail in several non-obvious ways, and the fixes are buried in issue threads.

So this repository is the missing middle. Everything here runs on one machine, and the parts that
took the longest to get right are documented as such rather than left as bare YAML.

**What it is not:** production infrastructure. Credentials are committed on purpose so the lab
reproduces, nothing is authenticated, and there is no TLS. Keep it on an isolated network. See
[Security and known gaps](#security-and-known-gaps).

---

## Prerequisites

**Hardware virtualization is mandatory.** KubeVirt runs real QEMU/KVM VMs, so the host needs
`/dev/kvm`. This is the single most common reason a KubeVirt POC fails on the first attempt — on a
cloud VM you must explicitly enable nested virtualization before any of this works.

```bash
ls -l /dev/kvm            # must exist and be readable
kvm-ok                    # Debian/Ubuntu: cpu-checker package
```

If you have no KVM, you can fall back to software emulation. Ubuntu becomes sluggish and Windows
becomes unusable, but the pipeline runs:

```bash
kubectl -n kubevirt patch kv kubevirt --type merge \
  -p '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'
```

**Tools:** `docker`, `kind`, `kubectl`, `packer`, `virtctl`, `git`, `go`. Run `make preflight` to
check. Adding Windows also needs `xorriso` and `rsync` (`make preflight-windows`) and `sudo`, to
mount and repack the installer ISO.

**Capacity:** roughly **8 GB RAM and 60 GB disk** for Ubuntu alone — the VM requests 2 GB and the
Guacamole stack plus the KubeVirt and CDI control planes want a few more. Add Windows and it is
**16 GB RAM and ~200 GB disk**: the VM requests 4 GB, and between the source ISO, the repacked ISO,
the 64 GiB golden image and each clone, storage adds up fast.

**A Windows 10 ISO**, if you want the Windows VM. It is not redistributable and is not in this
repository — download a Windows 10 22H2 x64 image from Microsoft and drop it in `disk/`, which is
gitignored. See [Golden images](#golden-images).

---

## Walkthrough

### 1. The cluster

```bash
make cluster
```

`scripts/setup-cluster.sh` creates a kind cluster, then installs **KubeVirt v1.8.2** and **CDI
v1.65.0** and waits for both to report Available. Idempotent — re-run it freely. CDI is the piece
that turns an ISO or a disk image into a PVC, and later clones the golden PVC per VM.

### 2. A golden image

```bash
make golden-ubuntu
```

This is the slow, once-per-cluster step, and the most interesting one. Packer boots a throwaway VM
*inside the cluster* from the Ubuntu 24.04 ISO, runs an unattended install driven by
`golden/ubuntu/user-data`, then provisions the desktop with
`golden/ubuntu/scripts/setup-desktop.sh` — XFCE, autologin, and **x11vnc listening on :5900 inside
the guest**. Finally it generalizes the disk and leaves behind a CDI `DataSource` named
`ubuntu-golden`.

Putting the VNC server *in the guest* rather than proxying `virtctl vnc` from outside is the design
decision the rest of the repo rests on: it makes an Ubuntu desktop and a Windows desktop look
identical from the cluster's point of view. Both are just a TCP port behind a Service.

### 3. A VM

```bash
make vm OS=ubuntu NAME=ubuntu1
```

In order, this:

1. checks that the `ubuntu-golden` DataSource exists, so a missing image fails in a second;
2. deploys Guacamole, guacd, MySQL and the nginx proxy if they are not already up (`make serve`);
3. renders `deploy/vm-ubuntu.yaml` with the name and DataSource, and applies it — CDI
   copy-on-write clones the golden PVC, which is why this takes minutes and not the 20 that a fresh
   install would;
4. waits for the VM to report Ready, which for both OS types means the QEMU guest agent has checked
   in;
5. runs `scripts/vm-connect.sh`, which creates a ClusterIP Service pointing at the guest's VNC or
   RDP port, waits until something actually answers on it, registers the connection in Guacamole,
   and prints an auto-login URL.

Run it again with a different `NAME` for a second VM. `make status` lists what you have.

### 4. Windows

```bash
make golden-windows
make vm OS=windows NAME=win1
```

Same shape, different guest: RDP on :3389 instead of VNC on :5900, a sysprep answer file instead of
cloud-init, and a longer build. `make vm` handles the difference.

---

## How the browser access works

Both OS types reach the browser through **Apache Guacamole**, over one code path. The only per-OS
difference is a protocol and a port number.

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

The link `vm-connect.sh` prints carries a Guacamole token for a **throwaway account scoped to that
one VM**, recreated on every run. That matters: handing out the `guacadmin` token instead would let
anyone holding the link enumerate every other connection and read its hostname and password back in
plaintext.

An earlier revision of this repo put a Go control plane in front of all this — a controller keeping
a warm pool of pre-booted VMs and an HTTP API that handed them out, so a click produced a desktop in
under two seconds. It worked, but it is a distraction from the KubeVirt mechanics this repo is meant
to show. It is preserved on the
[`warm-pool`](https://github.com/basil-eldho/kubevirt-lab/tree/warm-pool) branch.

---

## Commands

`make help` lists everything. The ones you will use:

| Command | What it does |
|---|---|
| `make cluster` | kind + KubeVirt + CDI |
| `make golden-ubuntu` / `make golden-windows` | Build a golden image (one-time, slow) |
| `make vm OS=ubuntu NAME=ubuntu1` | Create a VM and print a browser link |
| `make vm-url NAME=ubuntu1 OS=ubuntu` | Fresh link — tokens expire after 60 idle minutes |
| `make status` | Which VMs and golden images exist |
| `make urls` | The Guacamole URL and admin login |
| `make console NAME=ubuntu1` | Serial console into the guest, for debugging |
| `make vm-delete NAME=ubuntu1` | Delete one VM, its disk and its Service |
| `make clean` | Delete all VMs and Guacamole; keep the golden images |
| `make clean-all` | Also delete the golden images and every PVC |
| `make clean-cluster` | Delete the kind cluster outright |

---

## Golden images

Ubuntu builds unattended from the public 24.04 ISO with no manual steps.

Windows needs media you supply. Place a Windows 10 22H2 x64 ISO at
`disk/Win10_22H2_EnglishInternational_x64v1.iso`, then `make golden-windows` runs
`prepare-windows-iso` for you: it mounts the ISO, injects `Autounattend.xml`, and repacks it with a
no-prompt EFI boot image.

Getting a **fully unattended Windows install onto KubeVirt** took a long series of failed
approaches — oemdrv disks, cloud-init, floppy attachment — before ISO injection worked. If you are
fighting the same problem, the working combination is:

- `Autounattend.xml` in **both** the ISO root and `sources/` — the root copy for setup, the
  `sources/` copy for the windowsPE pass;
- an `efisys.bin` no-prompt EFI boot image, so the build does not stall on "press any key to boot";
- a Packer `boot_command` of `["<enter>"]`;
- `virtio-win` drivers installed during the build, and the QEMU guest agent, or KubeVirt never sees
  the guest come up;
- a sysprep answer file mounted on every clone (`deploy/windows-pool-unattend.yaml`). The golden
  image is sysprepped with `/oobe`, so without it a clone stops at the region-select wizard.

### Packer plugin fork

Upstream `hashicorp/packer-plugin-kubevirt` is missing a few things this pipeline needs, so the
golden targets use a [fork](https://github.com/basil-eldho/packer-plugin-kubevirt) and clone it on
demand — no manual step. `make packer-init-local` builds and installs it.

It installs under the name `github.com/hashicorp/kubevirt`, which is what the `required_plugins`
blocks in `golden/*/*.pkr.hcl` resolve against. That name is deliberate, not a mistake. The fork
carries three changes:

| Change | Why |
|---|---|
| `media_files_label` config field | Ubuntu cloud-init looks for a `cidata`-labelled disk, not the builder's hardcoded `OEMDRV` |
| UEFI firmware on the build VM | The VMs here boot UEFI; if the install VM does not match, Ubuntu installs a BIOS bootloader that never boots |
| Pre-existing resource cleanup | A failed run leaves an orphaned DataVolume/DataSource that blocks the next run until deleted by hand |

If `packer-plugin-kubevirt/` already exists it is left untouched — nothing pulls or resets it — so
building from a dirty working tree is supported. Point it elsewhere with `PLUGIN_REPO`,
`PLUGIN_REF`, or `PLUGIN_DIR`.

---

## Repository layout

| Path | What it is |
|---|---|
| [golden/](golden/) | Packer templates and provisioning scripts for the Ubuntu and Windows images |
| [deploy/](deploy/) | The VM templates, the Guacamole stack, the nginx proxy, the sysprep ConfigMap |
| [scripts/](scripts/) | Cluster bootstrap, and `vm-connect.sh` which publishes a desktop and prints a link |
| [Makefile](Makefile) | Every command above |

---

## Troubleshooting

**The link opens on a black screen.** The desktop is not rendering yet, or x11vnc attached before
anything logged in. `make console NAME=ubuntu1` in and check `loginctl list-sessions`; re-running
`make vm-url` reissues the connection with a fresh hostname and password.

**The URL's host is unreachable.** `make urls` prints the kind node's internal IP, which is directly
routable on Linux but **not** from the host on Docker Desktop for macOS or Windows. Port-forward
instead, then open `http://localhost:8080/guacamole/` and paste the `#/client/...?token=...`
fragment from the printed link onto it:

```bash
kubectl port-forward svc/student-portal 8080:80
```

**A VM sits in `WaitingForVolumeBinding` or never becomes Ready.** The clone is still running, or
there is no disk space left. Check `kubectl get dv` and the CDI importer pod's logs.

**Windows boots to a setup wizard.** The sysprep ConfigMap is missing. `make vm OS=windows` applies
it; a hand-applied `deploy/vm-windows.yaml` does not.

**A Packer build failed and the next one refuses to start.** An orphaned DataVolume or DataSource is
in the way. `make clean-all` clears everything including the golden images, or delete the named
DataVolume by hand to keep them.

**Everything is slow.** Check `/dev/kvm` and that you are not running under `useEmulation`.

---

## Security and known gaps

This is a proof of concept, and every item here is a known open gap rather than an undiscovered bug.
Do not put it on a network you do not control.

- **Credentials are committed deliberately** so the lab reproduces: `student` / `Lab@2024!` on
  Windows, `Lab@2024` for Ubuntu's VNC (capped at 8 characters, because standard VNC auth derives a
  DES key from the first 8 bytes and silently ignores the rest), `guacadmin` / `guacadmin` for the
  Guacamole admin UI, and `guacamole_pass` / `rootpass` for MySQL. They are not secrets and are not
  used anywhere real. Replace them with Kubernetes Secrets before any deployment you care about.
- **No TLS.** The proxy serves plain HTTP and the Guacamole token travels in the URL.
- **No NetworkPolicy**, and the desktop Services are reachable from anything else in the cluster.
- **Shared desktop credentials with autologin**, so there is no OS-level isolation between whoever
  holds two links.
- **Guacamole state outlives its VM.** `make vm-delete` removes the VM, disk and Service, but leaves
  the connection and its scoped user in the Guacamole database; `make clean` drops the whole MySQL
  PVC.
- **Single replica of everything**, no resource limits, containers run as root, and no automated
  tests.

---

## Contributing

Issues and pull requests are welcome.

## License

[Apache License 2.0](LICENSE). The Packer plugin fork is a separate repository under its own
upstream license (MPL-2.0).
