#!/bin/bash
# Runs inside: oc debug node/<n> -- chroot /host /bin/bash -c '...'
# Collects OS/kernel/network/storage baseline; writes tarball on the host.
# oc debug merges remote stderr into stdout, so we must NOT stream tar to stdout.
set -uo pipefail

EXPORT_TAR="/var/tmp/ocp-baseline-export.tar.gz"

collect() {
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  "$@" > "$f" 2>&1 || true
}

BASE=$(mktemp -d /var/tmp/ocp-baseline-XXXXXX)
cleanup() { rm -rf "${BASE}"; }
trap cleanup EXIT

rm -f "${EXPORT_TAR}"

KB="${BASE}/kernel_os"
collect "${KB}/os-release.txt"           cat /etc/os-release
collect "${KB}/uname.txt"                uname -a
collect "${KB}/kernel_cmdline.txt"       cat /proc/cmdline
collect "${KB}/lsmod.txt"                lsmod
collect "${KB}/sysctl_all.txt"           sysctl -a
collect "${KB}/lscpu.txt"                lscpu
collect "${KB}/cpu_flags.txt"            bash -c 'grep flags /proc/cpuinfo | head -1'
collect "${KB}/numactl.txt"              numactl --hardware
collect "${KB}/meminfo.txt"              cat /proc/meminfo
collect "${KB}/numa_maps.txt"            cat /proc/self/numa_maps
collect "${KB}/hugepages_2M.txt"         cat /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
collect "${KB}/hugepages_1G.txt"         cat /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages
collect "${KB}/thp.txt"                  cat /sys/kernel/mm/transparent_hugepage/enabled
collect "${KB}/thp_defrag.txt"           cat /sys/kernel/mm/transparent_hugepage/defrag
collect "${KB}/tuned_profile.txt"        tuned-adm active
collect "${KB}/cpufreq.txt"              bash -c 'cpupower frequency-info 2>/dev/null || cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "not available"'
collect "${KB}/irq_affinity.txt"         bash -c 'for d in /proc/irq/*/smp_affinity_list; do echo "$d: $(cat "$d")"; done'
collect "${KB}/limits.txt"               ulimit -a
collect "${KB}/dmidecode.txt"            dmidecode
collect "${KB}/microcode.txt"            bash -c 'grep microcode /proc/cpuinfo | head -5'

NET="${BASE}/network"
collect "${NET}/ip_addr.txt"             ip addr show
collect "${NET}/ip_route_all.txt"        ip route show table all
collect "${NET}/ip_rules.txt"            ip rule show
collect "${NET}/arp.txt"                 ip neigh show
collect "${NET}/ss_listen.txt"           ss -tlnup
collect "${NET}/ovs_vsctl.txt"           ovs-vsctl show
collect "${NET}/ovn_info.txt"            ovn-nbctl show
collect "${NET}/bonding_all.txt"           bash -c 'ls /proc/net/bonding/ 2>/dev/null && for b in /proc/net/bonding/*; do echo "=== $b ==="; cat "$b"; done || echo "No bond interfaces"'
collect "${NET}/vlan_all.txt"            bash -c 'cat /proc/net/vlan/config 2>/dev/null || echo "No VLAN config"'
collect "${NET}/rdma_dev.txt"            rdma dev
collect "${NET}/rdma_link.txt"           rdma link
collect "${NET}/ibv_devinfo.txt"         ibv_devinfo
collect "${NET}/nftables.txt"            nft list ruleset
collect "${NET}/iptables_filter.txt"     iptables-save

IFACES=$(ip -br link show | awk '{print $1}' | grep -Ev '^lo$|^ovs|^veth|^br-|^flannel|^cni|^docker|^tun|^tap|@' | sed 's/@.*//')
for iface in ${IFACES}; do
  IDIR="${NET}/interfaces/${iface}"
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
  cat "/sys/class/net/${iface}/mtu" > "${IDIR}/mtu.txt" 2>/dev/null || true
  if [[ -f "/proc/net/bonding/${iface}" ]]; then
    cp "/proc/net/bonding/${iface}" "${IDIR}/bonding.txt"
  fi
  cat "/proc/net/vlan/${iface}" > "${IDIR}/vlan.txt" 2>/dev/null || true
done

STOR="${BASE}/storage"
collect "${STOR}/lsblk.txt"              lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,ROTA,SCHED,PHY-SEC,LOG-SEC,MODEL,SERIAL,TRAN,HCTL
collect "${STOR}/nvme_list.txt"          nvme list
collect "${STOR}/nvme_subsystems.txt"    nvme list-subsys
collect "${STOR}/disk_scheduler.txt"     bash -c 'for d in /sys/block/*/queue/scheduler; do echo "$d: $(cat "$d")"; done'
collect "${STOR}/nr_requests.txt"        bash -c 'for d in /sys/block/*/queue/nr_requests; do echo "$d: $(cat "$d")"; done'
collect "${STOR}/read_ahead.txt"         bash -c 'for d in /sys/block/*/queue/read_ahead_kb; do echo "$d: $(cat "$d")"; done'
collect "${STOR}/multipathd_ll.txt"      multipathd -ll
collect "${STOR}/multipath_conf.txt"     cat /etc/multipath.conf
collect "${STOR}/iscsiadm_sessions.txt"  iscsiadm -m session
collect "${STOR}/iscsiadm_nodes.txt"     iscsiadm -m node
collect "${STOR}/mounts.txt"             cat /proc/mounts
collect "${STOR}/df.txt"                 df -hT

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

tar -czf "${EXPORT_TAR}" -C "${BASE}" .
cleanup
trap - EXIT
