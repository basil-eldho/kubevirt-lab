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

