#!/usr/bin/env bash
# =============================================================================
# OCP + SimplyBlock Baseline Configuration Collector
# =============================================================================
# Usage:
#   ./collect-baseline.sh                    # full collection
#   ./collect-baseline.sh --node-only        # only node-level OS collection
#   ./collect-baseline.sh --cluster-only     # only OCP API-level collection
#   ./collect-baseline.sh --label "post-hugepages-enable"  # tag the snapshot
#
# Requirements (cluster mode): oc CLI, logged-in session with cluster-admin
# Requirements (node mode):    run directly on the RHCOS/RHEL node as root
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_OS_SCRIPT="${SCRIPT_DIR}/collect-node-os.sh"

# ---------------------------------------------------------------------------
# CLI args
# ---------------------------------------------------------------------------
MODE="full"           # full | node-only | cluster-only
LABEL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-only)    MODE="node-only";    shift ;;
    --cluster-only) MODE="cluster-only"; shift ;;
    --label)        LABEL="$2";          shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LABEL_SUFFIX=${LABEL:+_${LABEL// /_}}
OUTDIR="baseline_${TIMESTAMP}${LABEL_SUFFIX}"
mkdir -p "${OUTDIR}"

LOG="${OUTDIR}/collector.log"
exec > >(tee -a "${LOG}") 2>&1

echo "============================================================"
echo " OCP + SimplyBlock Baseline Collector"
echo " Timestamp : ${TIMESTAMP}"
echo " Label     : ${LABEL:-<none>}"
echo " Mode      : ${MODE}"
echo " Output    : ${OUTDIR}/"
echo "============================================================"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
run() {
  # run CMD, save stdout to FILE; never abort on non-zero
  local desc="$1"; local file="$2"; shift 2
  echo "[collect] ${desc}"
  mkdir -p "$(dirname "${file}")"
  "$@" > "${file}" 2>&1 || echo "  WARNING: command exited $? — partial output saved"
}

oc_get() {
  # oc get with -o yaml, resilient to missing resources
  local resource="$1"; local file="$2"; shift 2
  local extra=("$@")
  echo "[oc] ${resource}"
  mkdir -p "$(dirname "${file}")"
  oc get "${resource}" "${extra[@]}" -o yaml > "${file}" 2>&1 \
    || echo "  WARNING: oc get ${resource} exited $? — resource may not exist"
}

# ---------------------------------------------------------------------------
# ── SECTION 1: NODE-LEVEL (OS / KERNEL / NETWORK / STORAGE) ─────────────
# Designed to run directly on the node (as root) OR via oc debug node/<n>
# ---------------------------------------------------------------------------
collect_node() {
  local NB="${OUTDIR}/node_${HOSTNAME:-localhost}"
  echo ""
  echo "=== Node-level collection on $(hostname) ==="

  # ── 1.1 OS & Kernel ──────────────────────────────────────────────────────
  local KB="${NB}/kernel_os"

  run "OS release"           "${KB}/os-release.txt"           cat /etc/os-release
  run "Kernel version"       "${KB}/uname.txt"                uname -a
  run "Kernel cmdline"       "${KB}/kernel_cmdline.txt"       cat /proc/cmdline
  run "Loaded modules"       "${KB}/lsmod.txt"                lsmod
  run "sysctl full dump"     "${KB}/sysctl_all.txt"           sysctl -a
  run "CPU info"             "${KB}/lscpu.txt"                lscpu
  run "CPU flags"            "${KB}/cpu_flags.txt"            grep flags /proc/cpuinfo | head -1
  run "NUMA topology"        "${KB}/numactl.txt"              numactl --hardware
  run "Memory info"          "${KB}/meminfo.txt"              cat /proc/meminfo
  run "NUMA maps summary"    "${KB}/numa_maps.txt"            cat /proc/self/numa_maps 2>/dev/null || true

  # Huge pages
  run "Hugepages (2M)"       "${KB}/hugepages_2M.txt"         cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages 2>/dev/null || echo "not found"
  run "Hugepages (1G)"       "${KB}/hugepages_1G.txt"         cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages 2>/dev/null || echo "not found"
  run "THP setting"          "${KB}/thp.txt"                  cat /sys/kernel/mm/transparent_hugepage/enabled
  run "THP defrag"           "${KB}/thp_defrag.txt"           cat /sys/kernel/mm/transparent_hugepage/defrag

  # Scheduler & CPU power
  run "tuned active profile" "${KB}/tuned_profile.txt"        tuned-adm active 2>/dev/null || echo "tuned not available"
  run "CPU frequency info"   "${KB}/cpufreq.txt"              cpupower frequency-info 2>/dev/null || cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "not available"
  run "IRQ affinity"         "${KB}/irq_affinity.txt"         bash -c 'for d in /proc/irq/*/smp_affinity_list; do echo "$d: $(cat $d)"; done'
  run "Process limits"       "${KB}/limits.txt"               ulimit -a

  # BIOS / hardware
  run "DMI hardware info"    "${KB}/dmidecode.txt"            dmidecode 2>/dev/null || echo "dmidecode not available"
  run "CPU microcode"        "${KB}/microcode.txt"            grep microcode /proc/cpuinfo | head -5

  # ── 1.2 Network ──────────────────────────────────────────────────────────
  local NET="${NB}/network"

  run "IP addresses"         "${NET}/ip_addr.txt"             ip addr show
  run "IP routes all tables" "${NET}/ip_route_all.txt"        ip route show table all
  run "IP rules"             "${NET}/ip_rules.txt"            ip rule show
  run "ARP table"            "${NET}/arp.txt"                 ip neigh show
  run "Listening sockets"    "${NET}/ss_listen.txt"           ss -tlnup
  run "OVS bridges"          "${NET}/ovs_vsctl.txt"           ovs-vsctl show 2>/dev/null || echo "OVS not present"
  run "OVN southbound info"  "${NET}/ovn_info.txt"            ovn-nbctl show 2>/dev/null || echo "OVN not accessible"

  # Per-interface ethtool + bonding
  local IFACES
  IFACES=$(ip -br link show | awk '{print $1}' | grep -Ev '^lo$|^ovs|^veth|^br-|^flannel|^cni|^docker|^tun|^tap|@' | sed 's/@.*//')

  for iface in ${IFACES}; do
    local IDIR="${NET}/interfaces/${iface}"
    mkdir -p "${IDIR}"
    ethtool          "${iface}" > "${IDIR}/ethtool.txt"           2>&1 || true
    ethtool -i       "${iface}" > "${IDIR}/ethtool_driver.txt"    2>&1 || true
    ethtool -k       "${iface}" > "${IDIR}/ethtool_offloads.txt"  2>&1 || true
    ethtool -g       "${iface}" > "${IDIR}/ethtool_ring.txt"      2>&1 || true
    ethtool -l       "${iface}" > "${IDIR}/ethtool_channels.txt"  2>&1 || true
    ethtool -a       "${iface}" > "${IDIR}/ethtool_pause.txt"     2>&1 || true
    ethtool -c       "${iface}" > "${IDIR}/ethtool_coalesce.txt"  2>&1 || true
    ethtool -S       "${iface}" > "${IDIR}/ethtool_stats.txt"     2>&1 || true
    ip link show     "${iface}" > "${IDIR}/ip_link.txt"           2>&1 || true
    # MTU
    cat "/sys/class/net/${iface}/mtu" > "${IDIR}/mtu.txt" 2>/dev/null || true
    # bonding details
    if [[ -f "/proc/net/bonding/${iface}" ]]; then
      cp "/proc/net/bonding/${iface}" "${IDIR}/bonding.txt"
    fi
    # VLAN info
    cat "/proc/net/vlan/${iface}" > "${IDIR}/vlan.txt" 2>/dev/null || true
  done

  # Aggregate bonding and VLAN summary
  run "All bonding devices"  "${NET}/bonding_all.txt"          bash -c 'ls /proc/net/bonding/ 2>/dev/null && for b in /proc/net/bonding/*; do echo "=== $b ==="; cat "$b"; done || echo "No bond interfaces"'
  run "All VLAN devices"     "${NET}/vlan_all.txt"             bash -c 'cat /proc/net/vlan/config 2>/dev/null || echo "No VLAN config"'
  run "RDMA devices"         "${NET}/rdma_dev.txt"             rdma dev 2>/dev/null || echo "RDMA not present"
  run "RDMA link state"      "${NET}/rdma_link.txt"            rdma link 2>/dev/null || true
  run "IB device info"       "${NET}/ibv_devinfo.txt"          ibv_devinfo 2>/dev/null || echo "IB not present"
  run "nftables rules"       "${NET}/nftables.txt"             nft list ruleset 2>/dev/null || echo "nft not available"
  run "iptables filter"      "${NET}/iptables_filter.txt"      iptables-save 2>/dev/null || echo "iptables not available"

  # ── 1.3 Block Storage (OS side) ──────────────────────────────────────────
  local STOR="${NB}/storage"

  run "Block devices"        "${STOR}/lsblk.txt"              lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,ROTA,SCHED,PHY-SEC,LOG-SEC,MODEL,SERIAL,TRAN,HCTL
  run "NVMe list"            "${STOR}/nvme_list.txt"          nvme list 2>/dev/null || echo "nvme-cli not present"
  run "NVMe subsystems"      "${STOR}/nvme_subsystems.txt"    nvme list-subsys 2>/dev/null || true
  run "Disk scheduler (all)" "${STOR}/disk_scheduler.txt"     bash -c 'for d in /sys/block/*/queue/scheduler; do echo "$d: $(cat $d)"; done'
  run "nr_requests (all)"    "${STOR}/nr_requests.txt"        bash -c 'for d in /sys/block/*/queue/nr_requests; do echo "$d: $(cat $d)"; done'
  run "read_ahead_kb (all)"  "${STOR}/read_ahead.txt"         bash -c 'for d in /sys/block/*/queue/read_ahead_kb; do echo "$d: $(cat $d)"; done'
  run "Multipath topology"   "${STOR}/multipathd_ll.txt"      multipathd -ll 2>/dev/null || echo "multipath not present"
  run "multipath.conf"       "${STOR}/multipath_conf.txt"     cat /etc/multipath.conf 2>/dev/null || echo "no multipath.conf"
  run "iSCSI sessions"       "${STOR}/iscsiadm_sessions.txt"  iscsiadm -m session 2>/dev/null || echo "iscsiadm not present"
  run "iSCSI nodes"          "${STOR}/iscsiadm_nodes.txt"     iscsiadm -m node 2>/dev/null || true
  run "Mounted filesystems"  "${STOR}/mounts.txt"             cat /proc/mounts
  run "Disk usage"           "${STOR}/df.txt"                 df -hT

  # Per-block-device queue settings
  for dev in /sys/block/*/; do
    devname=$(basename "${dev}")
    ddir="${STOR}/queue/${devname}"
    mkdir -p "${ddir}"
    for param in scheduler nr_requests read_ahead_kb max_sectors_kb \
                 rotational write_cache nomerges rq_affinity \
                 physical_block_size logical_block_size; do
      val=$(cat "${dev}queue/${param}" 2>/dev/null || echo "N/A")
      echo "${param}=${val}" >> "${ddir}/queue_params.txt"
    done
  done

  echo "[node] Node-level collection complete → ${NB}/"
}

# ---------------------------------------------------------------------------
# ── SECTION 2: CLUSTER-LEVEL (OCP API) ──────────────────────────────────
# Requires: oc CLI + cluster-admin login
# ---------------------------------------------------------------------------
collect_cluster() {
  echo ""
  echo "=== Cluster-level collection ==="

  # Verify oc is available
  if ! command -v oc &>/dev/null; then
    echo "ERROR: 'oc' not found. Skipping cluster collection."
    return 1
  fi
  if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into OpenShift. Run 'oc login ...' first."
    return 1
  fi

  local OCP="${OUTDIR}/cluster"

  # ── 2.1 Cluster Identity ─────────────────────────────────────────────────
  local ID="${OCP}/identity"
  run  "oc version"           "${ID}/oc_version.txt"          oc version
  oc_get "clusterversion"     "${ID}/clusterversion.yaml"
  oc_get "infrastructure/cluster" "${ID}/infrastructure.yaml"
  oc_get "proxy/cluster"      "${ID}/proxy.yaml"
  oc_get "dns/cluster"        "${ID}/dns.yaml"
  oc_get "apiservers"         "${ID}/apiservers.yaml"
  oc_get "schedulers/cluster" "${ID}/scheduler.yaml"

  # ── 2.2 Nodes ────────────────────────────────────────────────────────────
  local NODES="${OCP}/nodes"
  run  "Node list (wide)"     "${NODES}/nodes_wide.txt"       oc get nodes -o wide
  oc_get "nodes"              "${NODES}/nodes.yaml"
  # Per-node describe
  while IFS= read -r node; do
    run "describe node ${node}" \
        "${NODES}/describe_${node}.txt" \
        oc describe node "${node}"
  done < <(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')

  # ── 2.3 MachineConfig & MCPool ───────────────────────────────────────────
  local MC="${OCP}/machineconfig"
  oc_get "mcp"                "${MC}/mcp.yaml"
  oc_get "mc"                 "${MC}/mc_all.yaml"
  run  "MCP status"           "${MC}/mcp_status.txt"          oc get mcp
  run  "MC list"              "${MC}/mc_list.txt"             oc get mc

  # ── 2.4 Performance & Tuning ─────────────────────────────────────────────
  local PERF="${OCP}/performance"
  oc_get "performanceprofile" "${PERF}/performanceprofile.yaml" -A
  oc_get "tuned"              "${PERF}/tuned.yaml"            -A
  oc_get "profile.tuned"      "${PERF}/tuned_profile.yaml"   -A
  oc_get "kubeletconfig"      "${PERF}/kubeletconfig.yaml"
  oc_get "containerruntimeconfig" "${PERF}/containerruntimeconfig.yaml"

  # ── 2.5 Cluster Operators ────────────────────────────────────────────────
  local CO="${OCP}/operators"
  run  "Cluster operators"    "${CO}/clusteroperators.txt"    oc get co
  oc_get "clusteroperators"   "${CO}/clusteroperators.yaml"
  oc_get "subscriptions"      "${CO}/subscriptions.yaml"      -A
  oc_get "clusterserviceversion" "${CO}/csv.yaml"             -A
  oc_get "installplan"        "${CO}/installplan.yaml"        -A

  # ── 2.6 Cluster Network ──────────────────────────────────────────────────
  local CNET="${OCP}/network"
  oc_get "network/cluster"    "${CNET}/network_cluster.yaml"
  oc_get "networks"           "${CNET}/networks.yaml"         -A
  oc_get "network-attachment-definition" "${CNET}/nad.yaml"  -A
  oc_get "sriovnetwork"       "${CNET}/sriovnetwork.yaml"     -A
  oc_get "sriovnetworknodestate" "${CNET}/sriovnodestates.yaml" -A
  oc_get "sriovnetworknodepolicy" "${CNET}/sriovpolicies.yaml"  -A
  oc_get "hostsubnets"        "${CNET}/hostsubnets.yaml"       2>/dev/null || true
  oc_get "clusternetwork"     "${CNET}/clusternetwork.yaml"
  run  "Network policies (all ns)" "${CNET}/networkpolicies.txt" oc get networkpolicy -A

  # ── 2.7 Storage / CSI ────────────────────────────────────────────────────
  local KSTOR="${OCP}/storage"
  oc_get "storageclasses"             "${KSTOR}/storageclasses.yaml"
  oc_get "volumesnapshotclass"        "${KSTOR}/volumesnapshotclass.yaml"   -A
  oc_get "csidriver"                  "${KSTOR}/csidrivers.yaml"
  oc_get "csistoragecapacity"         "${KSTOR}/csistoragecapacity.yaml"    -A
  oc_get "pv"                         "${KSTOR}/pv.yaml"
  oc_get "pvc"                        "${KSTOR}/pvc.yaml"                   -A
  oc_get "volumesnapshot"             "${KSTOR}/volumesnapshots.yaml"       -A
  oc_get "volumesnapshotcontent"      "${KSTOR}/volumesnapshotcontent.yaml"
  run  "StorageClass list"            "${KSTOR}/sc_list.txt"   oc get sc
  run  "PV list"                      "${KSTOR}/pv_list.txt"   oc get pv
  run  "PVC list (all ns)"            "${KSTOR}/pvc_list.txt"  oc get pvc -A

  # SimplyBlock CSI pods and config
  local SB="${OCP}/simplyblock"
  run  "SimplyBlock pods"     "${SB}/sb_pods.txt"             oc get pods -A -o wide | grep -iE 'simplyblock|spdk|nvmeof|csi-sb' || echo "No SimplyBlock pods found (grep)"
  for ns in $(oc get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\n"}{end}' \
              | sort -u | xargs -I{} sh -c 'oc get pods -n {} -o name 2>/dev/null | grep -iE "simplyblock|spdk|csi-sb" | head -1 | grep -q . && echo {}' 2>/dev/null || true); do
    oc_get "pods"             "${SB}/pods_${ns}.yaml"         -n "${ns}"
    oc_get "configmap"        "${SB}/configmaps_${ns}.yaml"   -n "${ns}"
    oc_get "daemonset"        "${SB}/daemonsets_${ns}.yaml"   -n "${ns}"
    oc_get "statefulset"      "${SB}/statefulsets_${ns}.yaml" -n "${ns}"
    oc_get "deployment"       "${SB}/deployments_${ns}.yaml"  -n "${ns}"
    oc_get "service"          "${SB}/services_${ns}.yaml"     -n "${ns}"
    oc_get "secret"           "${SB}/secrets_names_${ns}.txt" -n "${ns}" --show-managed-fields=false || true
  done

  # ── 2.8 Scheduler / Resource Management ──────────────────────────────────
  local SCHED="${OCP}/scheduler"
  oc_get "priorityclass"      "${SCHED}/priorityclass.yaml"
  oc_get "limitrange"         "${SCHED}/limitrange.yaml"      -A
  oc_get "resourcequota"      "${SCHED}/resourcequota.yaml"   -A
  run  "Top nodes"            "${SCHED}/top_nodes.txt"        oc adm top nodes  2>/dev/null || true
  run  "Top pods (all ns)"    "${SCHED}/top_pods.txt"         oc adm top pods -A 2>/dev/null || true

  # ── 2.9 etcd health ──────────────────────────────────────────────────────
  local ETCD="${OCP}/etcd"
  run  "etcd pods"            "${ETCD}/etcd_pods.txt"         oc get pods -n openshift-etcd
  oc_get "pods"               "${ETCD}/etcd_pods.yaml"        -n openshift-etcd
  # etcd member list via exec into etcd pod
  ETCD_POD=$(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${ETCD_POD}" ]]; then
    run "etcd member list" "${ETCD}/member_list.txt" \
        oc exec -n openshift-etcd "${ETCD_POD}" -- \
        etcdctl member list --write-out=table \
        --endpoints=https://localhost:2379 \
        --cacert=/etc/kubernetes/static-pod-resources/etcd-certs/configmaps/etcd-serving-ca/ca-bundle.crt \
        --cert=/etc/kubernetes/static-pod-resources/etcd-certs/secrets/etcd-all-certs/etcd-serving-$(hostname).crt \
        --key=/etc/kubernetes/static-pod-resources/etcd-certs/secrets/etcd-all-certs/etcd-serving-$(hostname).key \
        2>/dev/null || echo "etcd exec failed — skipping"
  fi

  # ── 2.10 Alerts & Events ─────────────────────────────────────────────────
  local EVT="${OCP}/events"
  run  "Cluster events (all)" "${EVT}/events_all.txt"         oc get events -A --sort-by='.lastTimestamp'
  run  "Alerts (Prometheus)"  "${EVT}/alerts.txt"             \
       bash -c 'TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring 2>/dev/null || true); \
                ROUTE=$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath="{.spec.host}" 2>/dev/null || true); \
                [[ -n "$ROUTE" ]] && curl -sk -H "Authorization: Bearer $TOKEN" \
                "https://$ROUTE/api/v1/alerts" | python3 -m json.tool 2>/dev/null \
                || echo "Prometheus route not accessible"'

  echo "[cluster] Cluster-level collection complete → ${OCP}/"
}

# ---------------------------------------------------------------------------
# ── SECTION 3: NODE COLLECTION via oc debug (runs remotely per node) ──────
# Writes tarball on the node at /var/tmp/ocp-baseline-export.tar.gz, then
# fetches it with a separate oc debug (oc merges remote stderr into stdout).
# ---------------------------------------------------------------------------
collect_nodes_via_oc_debug() {
  echo ""
  echo "=== Collecting OS-level data from all nodes via 'oc debug' ==="

  if ! command -v oc &>/dev/null || ! oc whoami &>/dev/null; then
    echo "SKIP: oc not available or not logged in."
    return
  fi

  if [[ ! -f "${NODE_OS_SCRIPT}" ]]; then
    echo "ERROR: missing ${NODE_OS_SCRIPT}"
    return 1
  fi

  local NODE_SCRIPT_B64 HOST_EXPORT="/var/tmp/ocp-baseline-export.tar.gz"
  NODE_SCRIPT_B64=$(base64 -w0 < "${NODE_OS_SCRIPT}")

  local node NOUT TMP_TAR file_count tar_bytes oc_rc

  while IFS= read -r node; do
    [[ -z "${node}" ]] && continue
    echo "  → collecting node: ${node}"
    NOUT="${OUTDIR}/cluster/nodes_os/${node}"
    mkdir -p "${NOUT}"
    TMP_TAR=$(mktemp --suffix=.tar.gz /tmp/baseline-node-XXXXXX)

    # Phase 1: run collector on the node (logs only — no stdout capture)
    set +e
    oc debug "node/${node}" --quiet -- \
      chroot /host /bin/bash -c "echo ${NODE_SCRIPT_B64} | base64 -d | /bin/bash" \
      >/dev/null 2>"${NOUT}/collect.log"
    oc_rc=$?

    if [[ ${oc_rc} -ne 0 ]]; then
      echo "  WARNING: ${node}: collector failed (exit ${oc_rc}, see ${NOUT}/collect.log)"
      rm -f "${TMP_TAR}"
      set -e
      continue
    fi

    # Phase 2: copy tarball off the node (cat only — clean binary stdout)
    oc debug "node/${node}" --quiet -- \
      chroot /host cat "${HOST_EXPORT}" > "${TMP_TAR}" 2>>"${NOUT}/collect.log"
    oc_rc=$?

    # Phase 3: cleanup on node
    oc debug "node/${node}" --quiet -- \
      chroot /host rm -f "${HOST_EXPORT}" >/dev/null 2>&1 || true
    set -e

    tar_bytes=$(wc -c < "${TMP_TAR}" | tr -d ' ')

    if [[ ${oc_rc} -ne 0 ]]; then
      echo "  WARNING: ${node}: failed to fetch tarball (exit ${oc_rc}, see ${NOUT}/collect.log)"
      rm -f "${TMP_TAR}"
      continue
    fi

    if [[ "${tar_bytes}" -eq 0 ]]; then
      echo "  WARNING: ${node}: tarball missing or empty on host"
      sed 's/^/    /' "${NOUT}/collect.log" >&2 || true
      rm -f "${TMP_TAR}"
      continue
    fi

    if tar -tzf "${TMP_TAR}" &>/dev/null; then
      tar -xzf "${TMP_TAR}" -C "${NOUT}"
      file_count=$(find "${NOUT}" -type f ! -name 'collect.log' | wc -l)
      echo "  ✓ ${node}: ${file_count} files (${tar_bytes} bytes) → ${NOUT}/"
    else
      echo "  WARNING: ${node}: ${tar_bytes} bytes fetched but not a valid tar.gz"
      cp "${TMP_TAR}" "${NOUT}/raw_output.bin"
      file "${NOUT}/raw_output.bin" >&2 || true
    fi
    rm -f "${TMP_TAR}"

  done < <(oc get nodes -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n')

  echo "[oc debug] Node OS collection complete."
}

# ---------------------------------------------------------------------------
# ── SECTION 4: Prometheus Metrics Snapshot ──────────────────────────────
# ---------------------------------------------------------------------------
collect_prometheus_snapshot() {
  echo ""
  echo "=== Prometheus metric snapshot ==="

  if ! command -v oc &>/dev/null || ! oc whoami &>/dev/null; then
    echo "SKIP: oc not available."
    return
  fi

  local PROM="${OUTDIR}/prometheus"
  mkdir -p "${PROM}"

  local TOKEN ROUTE
  TOKEN=$(oc create token prometheus-k8s -n openshift-monitoring 2>/dev/null || true)
  ROUTE=$(oc get route -n openshift-monitoring prometheus-k8s -o jsonpath='{.spec.host}' 2>/dev/null || true)

  if [[ -z "${ROUTE}" || -z "${TOKEN}" ]]; then
    echo "  Prometheus route or token not available — skipping metrics snapshot"
    return
  fi

  BASE="https://${ROUTE}/api/v1"

  query_prom() {
    local name="$1"; local q="$2"
    curl -sk -H "Authorization: Bearer ${TOKEN}" \
         --data-urlencode "query=${q}" \
         "${BASE}/query" | python3 -m json.tool > "${PROM}/${name}.json" 2>/dev/null || true
  }

  echo "  Querying Prometheus for baseline metrics..."

  # CPU
  query_prom "node_cpu_usage"        'sum by (node) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))'
  query_prom "node_cpu_capacity"     'kube_node_status_capacity{resource="cpu"}'
  # Memory
  query_prom "node_memory_available" 'node_memory_MemAvailable_bytes'
  query_prom "node_memory_total"     'node_memory_MemTotal_bytes'
  query_prom "node_hugepages_total"  'node_memory_HugePages_Total'
  query_prom "node_hugepages_free"   'node_memory_HugePages_Free'
  query_prom "node_thp_fault"        'rate(node_vmstat_thp_fault_alloc[5m])'
  # Network
  query_prom "node_net_rx_bytes"     'sum by (instance,device) (rate(node_network_receive_bytes_total[5m]))'
  query_prom "node_net_tx_bytes"     'sum by (instance,device) (rate(node_network_transmit_bytes_total[5m]))'
  query_prom "node_net_errors"       'sum by (instance,device) (rate(node_network_receive_errs_total[5m]) + rate(node_network_transmit_errs_total[5m]))'
  # Disk
  query_prom "node_disk_read_iops"   'sum by (instance,device) (rate(node_disk_reads_completed_total[5m]))'
  query_prom "node_disk_write_iops"  'sum by (instance,device) (rate(node_disk_writes_completed_total[5m]))'
  query_prom "node_disk_read_bw"     'sum by (instance,device) (rate(node_disk_read_bytes_total[5m]))'
  query_prom "node_disk_write_bw"    'sum by (instance,device) (rate(node_disk_written_bytes_total[5m]))'
  query_prom "node_disk_await"       'sum by (instance,device) (rate(node_disk_io_time_seconds_total[5m]))'
  # etcd
  query_prom "etcd_disk_wal_fsync"   'histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))'
  query_prom "etcd_disk_backend"     'histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m]))'
  # Pods/containers
  query_prom "container_cpu_usage"   'sum by (namespace,pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))'
  query_prom "container_mem_usage"   'sum by (namespace,pod) (container_memory_working_set_bytes{container!=""})'

  echo "  Prometheus snapshot saved to ${PROM}/"
}

# ---------------------------------------------------------------------------
# ── SECTION 5: Consolidated readable report (single file) ───────────────
# ---------------------------------------------------------------------------
report_banner() {
  printf '%s\n' "$1"
  printf '%*s\n' "${#1}" '' | tr ' ' '='
}

report_file() {
  local title="$1" file="$2"
  echo ""
  echo "--- ${title} ---"
  if [[ -f "${file}" ]]; then
    cat "${file}"
  else
    echo "(not collected)"
  fi
}

report_dir_files() {
  local section="$1" dir="$2"
  local f relpath
  [[ -d "${dir}" ]] || return 0
  echo ""
  report_banner "${section}"
  while IFS= read -r f; do
    relpath="${f#"${dir}/"}"
    report_file "${relpath}" "${f}"
  done < <(find "${dir}" -type f | sort)
}

write_consolidated_report() {
  local REPORT="${OUTDIR}/baseline-report.txt"
  echo ""
  echo "=== Writing consolidated report → ${REPORT} ==="

  {
    report_banner "OCP + SimplyBlock Baseline Report"
    echo "Timestamp : ${TIMESTAMP}"
    echo "Label     : ${LABEL:-<none>}"
    echo "Mode      : ${MODE}"
    echo "Host      : $(hostname)"
    echo "OCP client: $(oc version --client 2>/dev/null | head -1 || echo 'N/A')"

    # ── Global OCP settings ────────────────────────────────────────────────
    report_banner "GLOBAL OCP SETTINGS"

    report_file "Cluster version" "${OUTDIR}/cluster/identity/oc_version.txt"
    report_file "Cluster network" "${OUTDIR}/cluster/network/network_cluster.yaml"
    report_file "PerformanceProfile" "${OUTDIR}/cluster/performance/performanceprofile.yaml"
    report_file "KubeletConfig" "${OUTDIR}/cluster/performance/kubeletconfig.yaml"
    report_file "ContainerRuntimeConfig" "${OUTDIR}/cluster/performance/containerruntimeconfig.yaml"
    report_file "Tuned (cluster)" "${OUTDIR}/cluster/performance/tuned.yaml"
    report_file "Tuned profiles (per node)" "${OUTDIR}/cluster/performance/tuned_profile.yaml"
    report_file "MachineConfig pools" "${OUTDIR}/cluster/machineconfig/mcp_status.txt"
    report_file "MachineConfig list" "${OUTDIR}/cluster/machineconfig/mc_list.txt"
    report_file "Scheduler config" "${OUTDIR}/cluster/identity/scheduler.yaml"
    report_file "API server config" "${OUTDIR}/cluster/identity/apiservers.yaml"

    # ── Per-node OS / kernel / network / storage ───────────────────────────
    local node_dir node_name nodes_found=0

    # Nodes collected via oc debug
    if [[ -d "${OUTDIR}/cluster/nodes_os" ]]; then
      while IFS= read -r node_dir; do
        [[ -z "${node_dir}" ]] && continue
        node_name=$(basename "${node_dir}")
        # skip nodes with no kernel_os data
        [[ -d "${node_dir}/kernel_os" ]] || continue
        nodes_found=$((nodes_found + 1))

        echo ""
        report_banner "NODE: ${node_name}"

        # Quick tuning summary at top of each node section
        echo ""
        echo "--- Tuning summary ---"
        echo -n "Kernel: " ; cat "${node_dir}/kernel_os/uname.txt" 2>/dev/null | head -1 || echo "N/A"
        echo -n "TuneD profile: " ; cat "${node_dir}/kernel_os/tuned_profile.txt" 2>/dev/null || echo "N/A"
        echo -n "THP: " ; cat "${node_dir}/kernel_os/thp.txt" 2>/dev/null || echo "N/A"
        echo -n "THP defrag: " ; cat "${node_dir}/kernel_os/thp_defrag.txt" 2>/dev/null || echo "N/A"
        echo -n "Hugepages 2M: " ; cat "${node_dir}/kernel_os/hugepages_2M.txt" 2>/dev/null || echo "N/A"
        echo -n "Hugepages 1G: " ; cat "${node_dir}/kernel_os/hugepages_1G.txt" 2>/dev/null || echo "N/A"
        echo -n "CPU governor: " ; grep -m1 'governor\|performance\|powersave' "${node_dir}/kernel_os/cpufreq.txt" 2>/dev/null || cat "${node_dir}/kernel_os/cpufreq.txt" 2>/dev/null | head -1 || echo "N/A"

        report_dir_files "Kernel & OS — ${node_name}" "${node_dir}/kernel_os"
        report_dir_files "Network — ${node_name}" "${node_dir}/network"
        report_dir_files "Storage — ${node_name}" "${node_dir}/storage"

      done < <(find "${OUTDIR}/cluster/nodes_os" -mindepth 1 -maxdepth 1 -type d | sort)
    fi

    # Local node collection (--node-only or root on node)
    for node_dir in "${OUTDIR}"/node_*; do
      [[ -d "${node_dir}" ]] || continue
      node_name="${node_dir#"${OUTDIR}"/node_}"
      nodes_found=$((nodes_found + 1))

      echo ""
      report_banner "NODE: ${node_name} (local collection)"

      echo ""
      echo "--- Tuning summary ---"
      echo -n "Kernel: " ; cat "${node_dir}/kernel_os/uname.txt" 2>/dev/null | head -1 || echo "N/A"
      echo -n "TuneD profile: " ; cat "${node_dir}/kernel_os/tuned_profile.txt" 2>/dev/null || echo "N/A"
      echo -n "THP: " ; cat "${node_dir}/kernel_os/thp.txt" 2>/dev/null || echo "N/A"
      echo -n "Hugepages 2M: " ; cat "${node_dir}/kernel_os/hugepages_2M.txt" 2>/dev/null || echo "N/A"

      report_dir_files "Kernel & OS — ${node_name}" "${node_dir}/kernel_os"
      report_dir_files "Network — ${node_name}" "${node_dir}/network"
      report_dir_files "Storage — ${node_name}" "${node_dir}/storage"
    done

    if [[ ${nodes_found} -eq 0 ]]; then
      echo ""
      echo "(No node OS data collected — run full mode with oc login, or --node-only as root)"
    fi

    echo ""
    report_banner "END OF REPORT"

  } > "${REPORT}"

  echo "  Report written: ${REPORT} ($(wc -c < "${REPORT}" | tr -d ' ') bytes)"
}

# ---------------------------------------------------------------------------
# ── SECTION 6: Manifest / metadata ──────────────────────────────────────
# ---------------------------------------------------------------------------
write_manifest() {
  local MF="${OUTDIR}/MANIFEST.txt"
  {
    echo "Baseline Collection Manifest"
    echo "============================"
    echo "Timestamp   : ${TIMESTAMP}"
    echo "Label       : ${LABEL:-<none>}"
    echo "Mode        : ${MODE}"
    echo "Collected on: $(hostname)"
    echo "OCP version : $(oc version --client 2>/dev/null | head -1 || echo 'N/A')"
    echo ""
    echo "Files collected:"
    find "${OUTDIR}" -type f | sort
  } > "${MF}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${MODE}" in
  node-only)
    collect_node
    ;;
  cluster-only)
    collect_cluster
    collect_prometheus_snapshot
    ;;
  full)
    # If running as root on a node, do local OS collection
    if [[ $(id -u) -eq 0 ]]; then
      collect_node
    else
      echo "NOTE: Not root — skipping local node collection. Use --node-only as root, or we'll collect via oc debug."
    fi
    collect_cluster
    collect_nodes_via_oc_debug
    collect_prometheus_snapshot
    ;;
esac

write_consolidated_report
write_manifest

# ---------------------------------------------------------------------------
# Package output
# ---------------------------------------------------------------------------
TARBALL="${OUTDIR}.tar.gz"
tar -czf "${TARBALL}" "${OUTDIR}/"
echo ""
echo "============================================================"
echo " Collection complete!"
echo " Directory : ${OUTDIR}/"
echo " Report    : ${OUTDIR}/baseline-report.txt"
echo " Archive   : ${TARBALL}"
echo "============================================================"
