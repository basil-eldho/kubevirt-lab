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

