---
name: Prometheus monitoring of the Windows fleet
description: Architecture and state of Prometheus monitoring for MAST Windows machines
type: project
---

Up to ~20 Windows unit machines (e.g. mastw) and the Windows spec machine will eventually all run `windows_exporter` to expose metrics. The Prometheus server on the control machine (localhost / 127.0.0.1) scrapes them (pull model).

**Current state (as of 2026-04-19):** Only `mastw` has `windows_exporter` installed and running.

**windows_exporter on a unit:**
- Binary: `C:\Program Files\windows_exporter\windows_exporter.exe`
- Config: `C:\Program Files\windows_exporter\config.yaml`
- Enabled collectors: `cpu, memory, net, logical_disk, os, service, process, system, time`
- Listens on port 9182

**Prometheus server (control machine = localhost):**
- Config: `/etc/prometheus/prometheus.yml`
- Service: `prometheus.service` (enabled, running since 2026-02-25)
- Scrape interval: 15s
- Jobs: `prometheus` (localhost:9090), `linux-servers` (localhost:9100), `windows-servers` (mastw:9182)

**To onboard a new Windows machine:**
1. Install `windows_exporter` with the same config as mastw
2. Add `hostname:9182` to the `windows-servers` targets list in `/etc/prometheus/prometheus.yml`

**Why:** a Grafana dashboard on the control machine shows scraped metrics per machine. Machine list & SSH access: [[reference_fleet_topology]].
