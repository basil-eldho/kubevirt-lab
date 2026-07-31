# KubeVirt Lab Platform

**A Kubernetes-native warm-pool VM lab platform.** Students click one button and get a
browser-accessible Ubuntu or Windows desktop in under two seconds — because the disk clone, OS boot,
and desktop render all happened before they arrived.

> **Status: working reference architecture, not a production service.**
> The full student flow runs end-to-end on a single-node kind cluster with both pools warm. It has
> **not** been hardened for production, and it should not be exposed beyond an isolated lab network
> as-is. The open gaps are listed under [Security and known gaps](#security-and-known-gaps) below.
> Read that before deploying this anywhere real.

---

## Why warm pools

Provisioning a VM on demand means the student waits for a disk clone (tens of seconds), an OS boot
(tens of seconds more), and a desktop render. For Windows that is minutes. In a classroom, minutes
times thirty students is a lost lesson.

This platform pre-pays all of it. A controller keeps N VMs of each OS type booted, logged in, and
idle at `pool=warm`. Provisioning is then just a label flip from `warm` to `assigned` plus a URL
handoff, so the student-visible latency is a label patch and an HTTP redirect.

The trade-off is honest and worth stating: you are burning cluster RAM on idle VMs to buy latency.
The pool depth is the dial between the two.

---

## Architecture at a glance

Both OS types are brokered through **Apache Guacamole**, over one code path. Each VM runs its own
remote-desktop listener inside the guest — x11vnc on Ubuntu, RDP on Windows — reached through a
per-VM ClusterIP Service. The only per-OS difference is the protocol and the port.

```
Student browser
      │
      ▼
Student portal  (nginx, NodePort :30000)
      │
      ├── POST /provision ──►  Provisioning API  (Go + chi, NodePort :30001)
      │                              │  claims a pool=warm VM (optimistic-locked label patch)
      │                              │  creates the Guacamole connection
      │                              │  stores the session in Redis
      │                              ▼
      │                        returns an access URL
      │
      └── iframe ──► Apache Guacamole ──► guacd ──┬── vnc :5900 ──► Ubuntu VM  (x11vnc + XFCE)
                     (same-origin /guacamole/)    │
                                                  └── rdp :3389 ──► Windows VM (native RDP)

Pool controller  (Go + controller-runtime, event-driven)
      watches VirtualMachine / VirtualMachineInstance
      promotes pool=creating → pool=warm on AgentConnected
      creates one ClusterIP desktop Service per VM
      refills the pool whenever depth < MinSize
```

Golden images are built once with Packer via a [local fork](#packer-plugin-fork) of
`hashicorp/packer-plugin-kubevirt`, then cloned per-VM by CDI from a `DataSource`.

**Why one path.** An earlier revision served Ubuntu through a per-VM sidecar pod running
`virtctl vnc --proxy-only` behind noVNC and websockify, on a NodePort from a 30080–30200 range. That
meant two access mechanisms, a per-VM Deployment, a NodePort allocator, and a watchdog loop to
restart `virtctl` (it exits one minute after the last client disconnects). Moving the VNC server into
the guest deleted all four, and closed the unauthenticated-NodePort exposure along with them.

---

## Prerequisites

- `docker`, `kind`, `kubectl`, `packer`, `virtctl`
- A machine with enough headroom for the pools: roughly **16 GB RAM** for the default 2 Ubuntu
  (2 GB each) + 1 Windows (4 GB) pool plus the platform components, and **~200 GB disk** for golden
  images and per-VM clones.
- A Windows 10 ISO, if you want the Windows pool. It is **not** included in this repository and is
  not redistributable — download it from Microsoft and drop it in `disk/` (see
  [Golden images](#golden-images)).

## Quickstart

Ubuntu only — three commands, and the middle one is the slow part:

```bash
make cluster          # kind + KubeVirt v1.8.2 + CDI v1.65.0 (idempotent)
make golden-ubuntu    # one-time Packer build, ~20 min
make deploy           # builds and loads images, then deploys everything

make urls             # portal URL
make status           # pool depth and active sessions
```

`make deploy` pulls in image build/load and the Guacamole stack as prerequisites, so there is no
separate step to forget. The manifests use `imagePullPolicy: Never`, which is why the images have to
reach the kind node before the pods start.

**Adding Windows** is opt-in, because it needs its own ~45 minute golden build and a Windows ISO you
supply. `MIN_POOL_WINDOWS` defaults to `0` so that a fresh Ubuntu-only install does not sit trying to
clone a `windows-golden` DataSource that was never built:

```bash
make golden-windows                    # includes prepare-windows-iso
make deploy MIN_POOL_WINDOWS=1
```

`make help` lists every target. Pool depth is tunable at deploy time:

```bash
make deploy MIN_POOL_UBUNTU=4 MIN_POOL_WINDOWS=2
```

### Cleanup

```bash
make clean                   # remove pool VMs, controllers, and Guacamole; keep golden images
make clean-all               # the above, plus the golden images and their DataSources
make clean-golden-windows    # force-clean a stuck Packer build (run after Ctrl+C)
```

---

## Repository layout

| Path | What it is |
|---|---|
| [pool-go/](pool-go/) | The Go control plane: `cmd/api` (chi HTTP API) and `cmd/controller` (controller-runtime reconciler), with `internal/` packages for config, pool manifests, session storage, and the Guacamole client |
| [deploy/](deploy/) | Kubernetes manifests — controller, API, portal, Redis, Guacamole stack, RBAC |
| [golden/](golden/) | Packer templates and provisioning scripts for the Ubuntu and Windows golden images |
| [portal/](portal/) | Static student portal (nginx + a single `index.html`), which also reverse-proxies `/guacamole/` same-origin so the `?token=` auto-login works |
| [scripts/](scripts/) | Cluster bootstrap script |

---

## Golden images

Ubuntu builds unattended from the public 24.04 ISO with no manual steps.

Windows needs media you supply yourself. Place a Windows 10 22H2 x64 ISO at
`disk/Win10_22H2_EnglishInternational_x64v1.iso`, then run `make prepare-windows-iso`, which injects
`Autounattend.xml` into both the ISO root and `sources/` and switches the image to a no-prompt EFI
boot. The `disk/` directory is gitignored; installation media never belongs in version control.

Getting a fully unattended Windows install onto KubeVirt took a long series of failed approaches —
oemdrv disks, cloud-init, floppy attachment — before ISO injection worked. If you are fighting the
same problem: the working combination is `Autounattend.xml` in **both** the ISO root and `sources/`,
an `efisys.bin` no-prompt EFI boot image, and a Packer `boot_command` of `["<enter>"]`.

### Packer plugin fork

The upstream `hashicorp/packer-plugin-kubevirt` builder is missing a few things this pipeline needs
(notably a configurable `media_files_label`, which Ubuntu's cloud-init requires to be `cidata` rather
than `OEMDRV`, and UEFI firmware on the build VM). The fork lives in its own repository rather than
being vendored here, and the golden-image targets clone it on demand — no manual step:

```bash
make packer-init-local    # clones the fork if absent, builds it, installs the plugin
```

Both `make golden-ubuntu` and `make golden-windows` depend on this target, so a fresh clone of this
repository needs nothing extra. If `packer-plugin-kubevirt/` already exists it is left untouched —
nothing pulls or resets it — so building from a dirty working tree is supported. Point it elsewhere
with `PLUGIN_REPO`, `PLUGIN_REF`, or `PLUGIN_DIR`.

The plugin installs under the name `github.com/hashicorp/kubevirt`, which is what the
`required_plugins` blocks in `golden/*/*.pkr.hcl` resolve against — that name is deliberate, not a
mistake. The fork carries three changes that this pipeline depends on:

| Change | Why |
|---|---|
| `media_files_label` config field | Ubuntu cloud-init looks for a `cidata`-labelled disk, not the builder's hardcoded `OEMDRV` |
| UEFI firmware on the build VM | Pool VMs boot UEFI; if the install VM does not match, Ubuntu installs a BIOS bootloader that never boots |
| Pre-existing resource cleanup | A failed run leaves an orphaned DataVolume/DataSource behind, which blocks the next run until deleted by hand |

---

## Security and known gaps

This is a proof of concept. Do not deploy it anywhere that is not an isolated lab network. Every
item below is a known, open gap rather than an undiscovered bug.

**Security**

- The provisioning API is **unauthenticated**, and `DELETE /session/{id}` and `/status` are not
  scoped to the requesting student, so `/status` leaking session IDs makes deletion trivially
  reachable by anyone who can hit the API.
- No NetworkPolicy and no TLS — the portal serves plain HTTP, and the Guacamole auth token travels
  in the URL.
- Credentials in this repository (`Lab@2024!`, `Lab@2024`, `guacamole_pass`, `rootpass`, `ubuntu`)
  are **throwaway lab values committed deliberately so the lab reproduces**. They are not secrets
  and are not used anywhere real. Replace them with Kubernetes Secrets before any deployment you
  care about.
- Desktops share one credential per OS and auto-login, so there is no OS-level isolation between
  students.

**Correctness and reliability**

- There is **no session reaper**. A student who closes the browser tab strands a VM until it is
  cleaned up out-of-band, and the controller spawns a replacement — so capacity leaks every class.
- Claiming a VM is **not atomic**: if building the access URL fails after the label patch, nothing
  rolls it back, and a failed session write is logged rather than returned.
- Redis has no persistence, so a Redis restart strands every active session.
- Single replica of everything, no resource requests or limits, and probes that report healthy
  while dependencies are down.
- Mutable `:v1` image tags with `imagePullPolicy: Never` — kind-only, with no registry or rollback
  path — and containers run as root.
- No automated tests.

**Closed by the Guacamole unification:** Ubuntu desktops are no longer exposed on an
unauthenticated NodePort. Both OS types now sit behind Guacamole on a ClusterIP, and the VNC server
requires a password.

---

## Contributing

Issues and pull requests are welcome. Before opening a PR:

```bash
gofmt -l pool-go          # must print nothing
cd pool-go && go build ./... && go vet ./...
```

## License

[Apache License 2.0](LICENSE).

The Packer plugin fork is a separate repository under its own upstream license (MPL-2.0).
