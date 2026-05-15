# OCP + SimplyBlock Baseline Configuration Collector

A shell script that captures a point-in-time snapshot of every meaningful configuration parameter across your OpenShift cluster and SimplyBlock storage nodes. The goal is to give you a deterministic before/after record so that when cluster performance changes — after enabling huge pages, changing CPU count, upgrading firmware, tuning the scheduler, etc. — you know exactly what changed and what the known-good baseline looked like.

---

## Why this exists

Modern storage-attached Kubernetes clusters are sensitive to a wide range of settings that live at different layers of the stack:

- A kernel parameter (`vm.nr_hugepages`) can double or halve NVMe-oF throughput.
- Transparent Huge Pages set to `madvise` vs `never` changes latency profiles for database workloads.
- An NIC ring buffer that is too small causes packet drops under storage bursts.
- A wrong bond `xmit_hash_policy` means only one physical link carries all storage traffic.
- A `KubeletConfig` or `PerformanceProfile` change silently moves CPU isolation boundaries.

Without a baseline, root-cause analysis becomes guesswork. With a baseline, a single `diff` command shows you what changed between two snapshots.

---

## What is collected

The script collects data in five sections.

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
| Per-NIC: speed, duplex, driver, firmware | `ethtool`, `ethtool -i` |
| Per-NIC: offloads (TSO, LRO, GRO, RSS) | `ethtool -k` |
| Per-NIC: ring buffer sizes | `ethtool -g` |
| Per-NIC: interrupt coalescing | `ethtool -c` |
| Per-NIC: channel count | `ethtool -l` |
| Per-NIC: pause frames | `ethtool -a` |
| Per-NIC: hardware statistics | `ethtool -S` |
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
| I/O scheduler per device | `/sys/block/*/queue/scheduler` |
| Queue depth, read-ahead, max sectors per device | `/sys/block/*/queue/` params |
| Multipath device topology | `multipathd -ll` |
| Multipath configuration file | `/etc/multipath.conf` |
| Active iSCSI sessions and nodes | `iscsiadm -m session/node` |
| Mounted filesystems | `/proc/mounts`, `df -hT` |

### 4. OpenShift Cluster (API level)

| Category | Resources captured |
|---|---|
| Cluster identity | `ClusterVersion`, `Infrastructure`, `DNS`, `APIServer`, `Scheduler` |
| Nodes | `oc get nodes`, `oc describe node` for every node |
| MachineConfig | All `MachineConfig` objects, all `MachineConfigPool` status |
| Performance tuning | `PerformanceProfile`, `KubeletConfig`, `ContainerRuntimeConfig`, NTO `Tuned` + `Profile` |
| Cluster operators | All `ClusterOperator` status, `Subscription`, `CSV`, `InstallPlan` |
| Cluster network | `network/cluster`, `NetworkAttachmentDefinition`, SR-IOV policies and node states, `NetworkPolicy` |
| Storage / CSI | `StorageClass`, `CSIDriver`, `PersistentVolume`, `PersistentVolumeClaim`, `VolumeSnapshot`, `VolumeSnapshotClass` |
| SimplyBlock | Pods, ConfigMaps, DaemonSets, Deployments, Services in SimplyBlock namespaces |
| Scheduler / resources | `PriorityClass`, `LimitRange`, `ResourceQuota`, `oc adm top nodes/pods` |
| etcd | Pod list, member list via `etcdctl` |
| Events and alerts | All cluster events sorted by time, live Prometheus alert list |

### 5. Prometheus Metrics Snapshot

A point-in-time query against the in-cluster Prometheus captures quantitative baselines alongside the configuration baselines:

| Metric group | Queries |
|---|---|
| CPU | Per-node usage rate, allocatable capacity |
| Memory | Available, total, huge page free/total, THP fault rate |
| Network | Per-device rx/tx bytes/s, error rate |
| Disk | Per-device read/write IOPS, bandwidth, I/O await |
| etcd | WAL fsync p99 latency, backend commit p99 latency |
| Containers | Per-pod CPU usage, per-pod memory working set |

Results are saved as JSON files so they can be ingested into any analysis tool.

---

## Requirements

| Requirement | Needed for |
|---|---|
| `bash` >= 4.x | Script execution |
| `oc` CLI | Cluster-level and remote node collection |
| Active `oc login` session with `cluster-admin` | All OCP API calls |
| `ethtool`, `nvme-cli`, `numactl` | Node-level collection (usually present on RHCOS) |
| `python3` | Pretty-printing Prometheus JSON output |
| `curl` | Prometheus API queries |

If you are collecting only from a single node as root (`--node-only`), the `oc` CLI is not required.

---

## Usage

```bash
# Full collection — run from a workstation with an active oc session
./collect-baseline.sh

# Tag the snapshot with a meaningful label (strongly recommended)
./collect-baseline.sh --label "pre-hugepages-enable"
./collect-baseline.sh --label "post-hugepages-enable"

# Collect only OCP API objects (no node access needed)
./collect-baseline.sh --cluster-only

# Collect only OS-level settings — run as root directly on a node
sudo ./collect-baseline.sh --node-only
```

---

## Output layout

Every run creates a timestamped directory and a compressed archive:

```
baseline_20260515_133000_pre-hugepages-enable/
├── MANIFEST.txt                          # list of every file collected + metadata
├── collector.log                         # full run log with warnings
├── node_<hostname>/                      # present when run as root on a node
│   ├── kernel_os/
│   ├── network/
│   │   └── interfaces/<iface>/
│   └── storage/
│       └── queue/<device>/
├── cluster/
│   ├── identity/
│   ├── nodes/
│   ├── machineconfig/
│   ├── performance/
│   ├── operators/
│   ├── network/
│   ├── storage/
│   ├── simplyblock/
│   ├── scheduler/
│   ├── etcd/
│   ├── events/
│   └── nodes_os/<node-name>/            # OS data collected via oc debug node
└── prometheus/
    ├── node_cpu_usage.json
    ├── node_memory_available.json
    ├── node_disk_read_iops.json
    └── ...

baseline_20260515_133000_pre-hugepages-enable.tar.gz
```

---

## Recommended workflow

**1. Capture the baseline before any change**

```bash
./collect-baseline.sh --label "before-<change-description>"
```

**2. Make the change** (enable huge pages, update SimplyBlock, tune NIC, etc.)

**3. Capture the post-change snapshot**

```bash
./collect-baseline.sh --label "after-<change-description>"
```

**4. Compare**

```bash
# See which files differ at all
diff -rq \
  baseline_*before-hugepages-enable/ \
  baseline_*after-hugepages-enable/

# Diff a specific config across both snapshots
diff \
  baseline_*before*/node_*/kernel_os/sysctl_all.txt \
  baseline_*after*/node_*/kernel_os/sysctl_all.txt

# Diff cluster storage classes
diff \
  baseline_*before*/cluster/storage/storageclasses.yaml \
  baseline_*after*/cluster/storage/storageclasses.yaml
```

**5. Store in git** — commit each archive or the expanded directory so you have a permanent, diffable history:

```bash
git add baseline_*.tar.gz
git commit -m "baseline: post-hugepages-enable $(date +%Y-%m-%d)"
```

---

## What to look for when performance changes

| Symptom | Key files to diff |
|---|---|
| Latency increased after node change | `sysctl_all.txt`, `thp.txt`, `hugepages_*.txt`, `cpufreq.txt` |
| Throughput dropped | `ethtool_ring_*.txt`, `ethtool_offloads_*.txt`, `bonding.txt`, `disk_scheduler.txt` |
| Intermittent storage errors | `ethtool_stats_*.txt`, `multipathd_ll.txt`, `iscsiadm_sessions.txt` |
| Pod evictions or OOM | `prometheus/node_memory_*.json`, `cluster/scheduler/resourcequota.yaml` |
| etcd slow | `prometheus/etcd_*.json`, `cluster/etcd/member_list.txt` |
| Network packet drops | `prometheus/node_net_errors.json`, `ethtool_stats_*.txt`, `nftables.txt` |
| CPU steal / noisy-neighbor | `prometheus/node_cpu_usage.json`, `lscpu.txt`, `numactl.txt` |
