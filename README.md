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

