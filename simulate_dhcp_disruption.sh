#!/bin/bash
# Simulate DHCP disruption on primary interface and test FSx routing impact
# Run as root on a multi-NIC compute node with FSx after bootstrap completes

set -e

LOG=/var/log/fsx_dhcp_disruption_test.log

log() {
    echo "$1" | tee -a $LOG
}

log "============================================================"
log "=== FSx DHCP Disruption Simulation ==="
log "============================================================"
log "Date: $(date)"
log "Hostname: $(hostname)"
log "Instance type: $(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/instance-type 2>/dev/null || echo 'unknown')"
log ""

# --- Gather metadata ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/placement/region)
PRIMARY_MAC=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/mac)
PRIMARY_IFACE=$(ip -o link | grep -i "${PRIMARY_MAC}" | awk '{print substr($2, 1, length($2)-1)}')

FSX_DNS="${1}"
if [ -z "${FSX_DNS}" ]; then
    FSX_FS_ID=$(jq -r '.cluster.fsx_fs_ids' /etc/chef/dna.json | cut -d',' -f1)
    FSX_DNS="${FSX_FS_ID}.fsx.${REGION}.amazonaws.com"
fi
FSX_MOUNT_NAME=$(jq -r '.cluster.fsx_mount_names' /etc/chef/dna.json | cut -d',' -f1)
FSX_IP=$(dig +short ${FSX_DNS} | head -1)

log "============================================================"
log "=== Current System State ==="
log "============================================================"
log ""
log "--- Instance Metadata ---"
log "  Region: ${REGION}"
log "  Primary MAC: ${PRIMARY_MAC}"
log "  Primary interface: ${PRIMARY_IFACE}"
log ""
log "--- FSx Details ---"
log "  FSx FS ID: ${FSX_FS_ID}"
log "  FSx DNS: ${FSX_DNS}"
log "  FSx IP: ${FSX_IP}"
log "  FSx mount name: ${FSX_MOUNT_NAME}"
log ""

log "--- All Network Interfaces ---"
for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^ens|^eth'); do
    IP=$(ip -o addr show dev ${IFACE} 2>/dev/null | grep 'inet ' | awk '{print $4}')
    MAC=$(ip -o link show dev ${IFACE} | grep -oP 'link/ether \K[^ ]+')
    STATE=$(ip -o link show dev ${IFACE} | grep -oP 'state \K\w+')
    MTU=$(ip -o link show dev ${IFACE} | grep -oP 'mtu \K\d+')
    if [ "${IFACE}" = "${PRIMARY_IFACE}" ]; then
        log "  ${IFACE}: IP=${IP} MAC=${MAC} State=${STATE} MTU=${MTU} [PRIMARY]"
    else
        log "  ${IFACE}: IP=${IP} MAC=${MAC} State=${STATE} MTU=${MTU}"
    fi
done
log ""

log "--- Current Routing Table (main) ---"
ip route show | while read -r line; do log "  ${line}"; done
log ""

log "--- Routing Rules ---"
ip rule show | while read -r line; do log "  ${line}"; done
log ""

log "--- Per-Interface Kernel Routes ---"
for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^ens|^eth'); do
    KERNEL_ROUTE=$(ip route show dev ${IFACE} 2>/dev/null | grep 'proto kernel' || echo "NONE (deleted by cleanup hook)")
    log "  ${IFACE}: ${KERNEL_ROUTE}"
done
log ""

log "--- Cleanup Hook ---"
if [ -f /etc/networkd-dispatcher/routable.d/cleanup-routes.sh ]; then
    log "  Status: INSTALLED"
    log "  Contents:"
    cat /etc/networkd-dispatcher/routable.d/cleanup-routes.sh | while read -r line; do log "    ${line}"; done
else
    log "  Status: NOT INSTALLED"
fi
log ""

log "--- Current Route to FSx ---"
ip route get ${FSX_IP} 2>&1 | while read -r line; do log "  ${line}"; done
log ""

log "--- LNet State ---"
if command -v lnetctl &> /dev/null; then
    lnetctl net show 2>&1 | while read -r line; do log "  ${line}"; done
else
    log "  lnetctl not available"
fi
log ""

log "--- Current FSx Mounts ---"
mount | grep lustre | while read -r line; do log "  ${line}"; done || log "  No Lustre mounts found"
log ""

log "============================================================"
log "=== Starting Simulation Tests ==="
log "============================================================"
log ""

# --- Test 1: Baseline ---
log "============================================================"
log "=== Test 1: Baseline Mount (current state) ==="
log "============================================================"
log ""
log "  Route to FSx: $(ip route get ${FSX_IP} 2>&1 | head -1)"
log "  LNet NID: $(lctl list_nids 2>/dev/null || echo 'unknown')"
log ""
log "  Attempting FSx mount..."
mkdir -p /tmp/fsx_test
umount /tmp/fsx_test 2>/dev/null || true
if timeout 30 mount -t lustre -o defaults,_netdev,flock,user_xattr,noatime,noauto,x-systemd.automount "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" /tmp/fsx_test 2>&1; then
    log "  ✓ RESULT: Mount SUCCEEDED"
    umount /tmp/fsx_test
else
    log "  ✗ RESULT: Mount FAILED"
fi
log ""

# --- Test 2: Delete primary interface default route ---
log "============================================================"
log "=== Test 2: Simulate Primary DHCP Disruption ==="
log "============================================================"
log ""
log "  Scenario: Primary interface (${PRIMARY_IFACE}) loses its DHCP default route."
log "  Expected: Traffic to FSx reroutes via secondary interface."
log "  Risk: LNet NID mismatch with source IP → FSx MGS rejects mount."
log ""

SAVED_DEFAULT=$(ip route show default dev ${PRIMARY_IFACE} proto dhcp)
log "  Before - default routes:"
ip route show default | while read -r line; do log "    ${line}"; done
log ""

log "  Action: Deleting primary DHCP default route..."
log "    ip route del default dev ${PRIMARY_IFACE} proto dhcp"
ip route del default dev ${PRIMARY_IFACE} proto dhcp 2>&1 || true
log ""

log "  After - default routes:"
ip route show default | while read -r line; do log "    ${line}"; done
log ""

log "  Route to FSx after disruption:"
ip route get ${FSX_IP} 2>&1 | while read -r line; do log "    ${line}"; done
log ""

log "  Attempting FSx mount..."
if timeout 30 mount -t lustre -o defaults,_netdev,flock,user_xattr,noatime,noauto,x-systemd.automount "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" /tmp/fsx_test 2>&1; then
    log "  ✓ RESULT: Mount SUCCEEDED (FSx reachable via secondary interface)"
    umount /tmp/fsx_test
else
    log "  ✗ RESULT: Mount FAILED — confirms routing fragility!"
fi
log ""

log "  Restoring primary default route..."
echo "${SAVED_DEFAULT}" | while read -r route; do
    [ -n "${route}" ] && ip route add ${route} 2>&1 || true
done
log "  Restored. Current default routes:"
ip route show default | while read -r line; do log "    ${line}"; done
log ""

# --- Test 3: Force traffic through each interface ---
log "============================================================"
log "=== Test 3: Mount FSx via Each Interface ==="
log "============================================================"
log ""
log "  Scenario: Force FSx traffic through each interface with LNet rebound."
log "  Purpose: Identify which interface/LNet combinations work or fail."
log ""

for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^ens|^eth'); do
    IFACE_IP=$(ip -o addr show dev ${IFACE} | grep 'inet ' | awk '{print $4}' | cut -d'/' -f1)

    log "  ----------------------------------------------------------"
    log "  Interface: ${IFACE} (${IFACE_IP})"
    if [ "${IFACE}" = "${PRIMARY_IFACE}" ]; then
        log "  Role: PRIMARY"
    else
        log "  Role: SECONDARY"
    fi
    log ""

    # Add specific route to FSx via this interface
    log "    Adding host route: ip route add ${FSX_IP}/32 dev ${IFACE} src ${IFACE_IP}"
    ip route add ${FSX_IP}/32 dev ${IFACE} src ${IFACE_IP} 2>&1 || true

    log "    Route to FSx: $(ip route get ${FSX_IP} 2>&1 | head -1)"

    # Rebind LNet
    lnetctl lnet configure 2>/dev/null
    lnetctl net del --net tcp 2>/dev/null || true
    lnetctl net add --net tcp --if ${IFACE} 2>&1 || true
    LNET_NID=$(lctl list_nids 2>/dev/null || echo 'unknown')
    log "    LNet NID: ${LNET_NID}"

    log "    Attempting FSx mount..."
    if timeout 30 mount -t lustre -o defaults,_netdev,flock,user_xattr,noatime,noauto,x-systemd.automount "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" /tmp/fsx_test 2>&1; then
        log "    ✓ RESULT: Mount SUCCEEDED via ${IFACE}"
        umount /tmp/fsx_test
    else
        log "    ✗ RESULT: Mount FAILED via ${IFACE}"
    fi

    # Remove specific route
    ip route del ${FSX_IP}/32 dev ${IFACE} 2>&1 || true
    log ""
done

# --- Restore original state ---
log "============================================================"
log "=== Restoring Original State ==="
log "============================================================"
log ""
lnetctl lnet configure 2>/dev/null
lnetctl net del --net tcp 2>/dev/null || true
lnetctl net add --net tcp --if ${PRIMARY_IFACE} 2>&1 || true
log "  LNet rebound to ${PRIMARY_IFACE}"
log "  LNet NID: $(lctl list_nids 2>/dev/null || echo 'unknown')"
log ""

rmdir /tmp/fsx_test 2>/dev/null || true

log "============================================================"
log "=== All Tests Complete ==="
log "============================================================"
log "Results saved to: ${LOG}"
