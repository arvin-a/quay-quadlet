# OCP + SimplyBlock Baseline Configuration Collector

A shell script that captures a point-in-time snapshot of OS/kernel tuning, global OpenShift configuration, and SimplyBlock-related settings across your cluster. The goal is a deterministic before/after record — when performance changes after enabling huge pages, tuning NICs, changing MachineConfig, etc., you know exactly what the known-good baseline looked like.

**Primary deliverable:** `baseline-report.txt` — a single readable file with global OCP settings and per-node sections (kernel, network, storage). Raw files are also kept for precise `diff` comparisons.

---

## Repository files

| File | Purpose |
|---|---|
| `collect-baseline.sh` | Main collector — cluster API, node OS via `oc debug`, Prometheus snapshot, report generation |
| `collect-node-os.sh` | Node-level collector script (runs inside `chroot /host` on each node; invoked automatically) |

---

## Why this exists

Modern storage-attached Kubernetes clusters are sensitive to settings at many layers:

- A kernel parameter (`vm.nr_hugepages`) can double or halve NVMe-oF throughput.
- Transparent Huge Pages set to `madvise` vs `never` changes latency for database workloads.
- An NIC ring buffer that is too small causes packet drops under storage bursts.
- A wrong bond `xmit_hash_policy` means only one physical link carries storage traffic.
- A `KubeletConfig`, `PerformanceProfile`, or `MachineConfig` change silently moves CPU isolation or sysctl boundaries.

Without a baseline, root-cause analysis becomes guesswork. With a baseline, `diff` between two labeled snapshots shows what changed.

---

## What is collected

### 1. Kernel & OS (per node)

| Item | Source |
|---|---|
| Kernel version and boot parameters | `uname -a`, `/proc/cmdline` |
| All kernel tunables | `sysctl -a` |
| Loaded kernel modules | `lsmod` |
| CPU topology, cores, threads, NUMA | `lscpu`, `numactl --hardware` |
| Huge pages — 2M and 1G counts | `/sys/kernel/mm/hugepages/hugepages-*/nr_hugepages` |
| Transparent Huge Pages mode and defrag | `/sys/kernel/mm/transparent_hugepage/` |
| Active `tuned` profile | `tuned-adm active` |
| CPU frequency governor | `cpupower` / `scaling_governor` |
| IRQ affinity per interrupt | `/proc/irq/*/smp_affinity_list` |
| Hardware identity and BIOS version | `dmidecode` |
| Memory layout | `/proc/meminfo` |

### 2. Network (per node)

| Item | Source |
|---|---|
| All interface addresses and MTU | `ip addr show` |
| All routing tables | `ip route show table all` |
| Per-NIC: driver, offloads, ring buffers, coalescing, channels | `ethtool`, `ethtool -i/-k/-g/-c/-l/-a/-S` |
| Bond mode, LACP rate, hash policy, members | `/proc/net/bonding/<bond>` |
| VLAN IDs and associated interfaces | `/proc/net/vlan/config` |
| RDMA / RoCE devices and link state | `rdma dev`, `rdma link`, `ibv_devinfo` |
| OVS bridge configuration | `ovs-vsctl show` |
| Firewall rules | `nft list ruleset`, `iptables-save` |
| Active TCP/UDP sockets | `ss -tlnup` |

### 3. Block Storage — OS side (per node)

| Item | Source |
|---|---|
| All block devices with scheduler, rotation, sector size, model | `lsblk` |
| NVMe device list and subsystem topology | `nvme list`, `nvme list-subsys` |
| I/O scheduler and queue params per device | `/sys/block/*/queue/` |
| Multipath topology and config | `multipathd -ll`, `/etc/multipath.conf` |
| Active iSCSI sessions and nodes | `iscsiadm -m session/node` |
| Mounted filesystems | `/proc/mounts`, `df -hT` |

### 4. Global OpenShift configuration (cluster API)

| Category | Resources captured |
|---|---|
| Cluster identity | `ClusterVersion`, `Infrastructure`, `DNS`, `APIServer`, `Scheduler` |
| MachineConfig | All `MachineConfig` objects, `MachineConfigPool` status |
| Performance tuning | `PerformanceProfile`, `KubeletConfig`, `ContainerRuntimeConfig`, NTO `Tuned` + `Profile` |
| Cluster network | `network/cluster`, SR-IOV, `NetworkPolicy`, etc. |
| Storage / CSI | `StorageClass`, `CSIDriver`, PV/PVC, volume snapshots |
| SimplyBlock | Pods, ConfigMaps, DaemonSets, Deployments, Services in SimplyBlock namespaces |
| Nodes (API) | `oc get/describe nodes` |
| Cluster operators, events, alerts | For operational context |
| etcd | Pod list, member list via `etcdctl` |
| Scheduler / resources | `PriorityClass`, `LimitRange`, `ResourceQuota`, `oc adm top` |

### 5. Prometheus metrics snapshot

Point-in-time queries for CPU, memory, huge pages, network, disk I/O, etcd latency, and container usage — saved as JSON under `prometheus/`.

---

## Requirements

| Requirement | Needed for |
|---|---|
| `bash` >= 4.x | Script execution |
| `oc` CLI | Cluster-level and remote node collection |
| Active `oc login` session with `cluster-admin` | All OCP API calls and `oc debug node` |
| `base64` | Passing node collector script into debug pods |
| `ethtool`, `nvme-cli`, `numactl` | Node-level collection (present on RHCOS) |
| `python3`, `curl` | Prometheus API queries |

For `--node-only`, run as **root** directly on a node; `oc` is not required.

---

## Usage

```bash
# Full collection — workstation with active oc session
./collect-baseline.sh

# Tag snapshots (strongly recommended for before/after comparison)
./collect-baseline.sh --label "pre-hugepages-enable"
./collect-baseline.sh --label "post-hugepages-enable"

# OCP API + global settings only (no node OS access)
./collect-baseline.sh --cluster-only

# OS-level settings only — run as root on a single node
sudo ./collect-baseline.sh --node-only
```

After a full run, open the consolidated report:

```bash
less baseline_*_<label>/baseline-report.txt
```

---

## Output layout

Every run creates a timestamped directory, a compressed archive, and a **single consolidated report**:

```
baseline_20260526_183401_os-kernel-baseline-v2/
├── baseline-report.txt                   # ★ main readable output (start here)
├── MANIFEST.txt                          # inventory of every file collected
├── collector.log                         # full run log with warnings
├── collect-node-os.sh                    # (source copy lives in repo root)
├── cluster/
│   ├── identity/                         # cluster version, API server, scheduler
│   ├── machineconfig/                    # MachineConfig + MCP status
│   ├── performance/                      # PerformanceProfile, KubeletConfig, TuneD
│   ├── network/                          # cluster network (MTU, CNI, etc.)
│   ├── nodes/                            # oc get/describe nodes
│   ├── nodes_os/<node-name>/             # ★ per-node OS data (via oc debug)
│   │   ├── collect.log                   # debug/collection log for this node
│   │   ├── kernel_os/                    # sysctl, hugepages, THP, tuned, cmdline…
│   │   ├── network/
│   │   │   └── interfaces/<iface>/       # ethtool, MTU, bonding per NIC
│   │   └── storage/
│   │       └── queue/<device>/           # scheduler, queue depth per disk
│   ├── storage/                          # StorageClasses, PV/PVC, CSI
│   ├── simplyblock/
│   ├── operators/
│   ├── scheduler/
│   ├── etcd/
│   ├── events/
│   └── ...
├── node_<hostname>/                      # present when run as root (--node-only)
│   ├── kernel_os/
│   ├── network/
│   └── storage/
└── prometheus/
    ├── node_cpu_usage.json
    └── ...

baseline_20260526_183401_os-kernel-baseline-v2.tar.gz
```

### `baseline-report.txt` structure

```
OCP + SimplyBlock Baseline Report
  timestamp, label, mode

GLOBAL OCP SETTINGS
  cluster network, PerformanceProfile, KubeletConfig, TuneD,
  MachineConfig pools, scheduler, API server

NODE: control1.infra1.k8s.example.com
  tuning summary (THP, hugepages, TuneD, governor…)
  Kernel & OS — full file contents
  Network — full file contents
  Storage — full file contents

NODE: worker1…
  …

END OF REPORT
```

Use **`baseline-report.txt`** for reviews and management. Use the raw files under `cluster/nodes_os/` for precise diffs.

---

## How node OS collection works

When not running as root locally, the script collects from every node via `oc debug`:

1. **Collect on node** — `collect-node-os.sh` is base64-encoded and executed inside `chroot /host`. It writes a tarball to `/var/tmp/ocp-baseline-export.tar.gz` on the node filesystem.
2. **Fetch tarball** — a separate `oc debug` runs `cat` on that file (clean binary stdout).
3. **Extract locally** — tarball is unpacked into `cluster/nodes_os/<node>/{kernel_os,network,storage}/`.
4. **Cleanup** — temp tarball removed from the node.

This two-step fetch is required because `oc debug` merges remote stderr into stdout, which corrupts tarball streams if logs and tar data share the same pipe.

If node collection fails for a specific node, check:

```bash
cat baseline_*/cluster/nodes_os/<node>/collect.log
```

---

## Recommended workflow

**1. Capture baseline before any change**

```bash
./collect-baseline.sh --label "before-hugepages-enable"
```

**2. Make the change** (huge pages, NIC tuning, MachineConfig, SimplyBlock update, etc.)

**3. Capture post-change snapshot**

```bash
./collect-baseline.sh --label "after-hugepages-enable"
```

**4. Review the consolidated reports**

```bash
less baseline_*before-hugepages-enable/baseline-report.txt
less baseline_*after-hugepages-enable/baseline-report.txt
```

**5. Diff raw files for exact changes**

```bash
# See which files differ
diff -rq \
  baseline_*before-hugepages-enable/ \
  baseline_*after-hugepages-enable/

# Diff sysctl across nodes
diff \
  baseline_*before*/cluster/nodes_os/worker1*/kernel_os/sysctl_all.txt \
  baseline_*after*/cluster/nodes_os/worker1*/kernel_os/sysctl_all.txt

# Diff global TuneD / MachineConfig
diff \
  baseline_*before*/cluster/performance/tuned_profile.yaml \
  baseline_*after*/cluster/performance/tuned_profile.yaml
```

**6. Store in git** (optional)

```bash
git add baseline_*.tar.gz
git commit -m "baseline: post-hugepages-enable $(date +%Y-%m-%d)"
```

---

## What to look for when performance changes

| Symptom | Key files / report sections |
|---|---|
| Latency increased after node change | `kernel_os/sysctl_all.txt`, `thp.txt`, `hugepages_*.txt`, `cpufreq.txt` |
| Throughput dropped | `network/interfaces/*/ethtool_ring.txt`, `ethtool_offloads.txt`, `bonding.txt`, `storage/disk_scheduler.txt` |
| Intermittent storage errors | `ethtool_stats.txt`, `multipathd_ll.txt`, `iscsiadm_sessions.txt` |
| Global OCP tuning drift | `cluster/performance/`, `cluster/machineconfig/`, report **GLOBAL OCP SETTINGS** section |
| Pod evictions or OOM | `prometheus/node_memory_*.json`, `cluster/scheduler/resourcequota.yaml` |
| etcd slow | `prometheus/etcd_*.json`, `cluster/etcd/member_list.txt` |
| Network packet drops | `prometheus/node_net_errors.json`, `ethtool_stats.txt`, `nftables.txt` |
| CPU steal / noisy-neighbor | `prometheus/node_cpu_usage.json`, `lscpu.txt`, `numactl.txt` |

---

## Troubleshooting

| Problem | What to check |
|---|---|
| `nodes_os/` empty or missing `kernel_os/` | `collect.log` per node; verify `oc whoami` and cluster-admin |
| Node section missing from report | Node OS collection did not succeed — re-run with `--label` after fixing `oc` access |
| Collection slow | Normal — each node runs three `oc debug` sessions (collect, fetch, cleanup) |
| `--node-only` on workstation | Must run as **root on the node itself**, not from a laptop |

---

## Salvaging a corrupted tarball (legacy runs)

Older runs that streamed tar directly over `oc debug` may have a `raw_output.bin` with log text prepended to the gzip data. If the tarball starts with `[node] collecting…` text, extract from the gzip magic offset:

```bash
RAW=baseline_*/cluster/nodes_os/<node>/raw_output.bin
OFFSET=$(grep -abo $'\x1f\x8b' "$RAW" | head -1 | cut -d: -f1)
tail -c +$((OFFSET+1)) "$RAW" | tar -xzf - -C baseline_*/cluster/nodes_os/<node>/
```

Current versions write the tarball to the node filesystem first and do not require this workaround.
