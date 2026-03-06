#!/bin/bash
# Simulate DHCP disruption on primary interface and test FSx routing impact
# Run as root on a multi-NIC compute node with FSx

set -e

LOG=/var/log/fsx_dhcp_disruption_test.log

echo "=== FSx DHCP Disruption Simulation ===" | tee -a $LOG
date | tee -a $LOG

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

echo "Primary interface: ${PRIMARY_IFACE}" | tee -a $LOG
echo "FSx DNS: ${FSX_DNS}" | tee -a $LOG
echo "FSx IP: ${FSX_IP}" | tee -a $LOG
echo "FSx mount name: ${FSX_MOUNT_NAME}" | tee -a $LOG

# --- Test 1: Baseline ---
echo "" | tee -a $LOG
echo "=== Test 1: Baseline (current state) ===" | tee -a $LOG
echo "Route to FSx:" | tee -a $LOG
ip route get ${FSX_IP} | tee -a $LOG

echo "LNet state:" | tee -a $LOG
lnetctl net show 2>&1 | tee -a $LOG || echo "LNet not configured" | tee -a $LOG

echo "Attempting FSx mount..." | tee -a $LOG
mkdir -p /tmp/fsx_test
umount /tmp/fsx_test 2>/dev/null || true
if timeout 30 mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" /tmp/fsx_test 2>&1; then
    echo "✓ BASELINE: Mount succeeded" | tee -a $LOG
    umount /tmp/fsx_test
else
    echo "✗ BASELINE: Mount failed" | tee -a $LOG
fi

# --- Test 2: Delete primary interface default route ---
echo "" | tee -a $LOG
echo "=== Test 2: Simulate primary DHCP disruption ===" | tee -a $LOG

# Save current route
SAVED_DEFAULT=$(ip route show default dev ${PRIMARY_IFACE} | head -1)
echo "Deleting primary default route: ${SAVED_DEFAULT}" | tee -a $LOG
ip route del default dev ${PRIMARY_IFACE} proto dhcp 2>&1 | tee -a $LOG || true

echo "Route to FSx after disruption:" | tee -a $LOG
ip route get ${FSX_IP} 2>&1 | tee -a $LOG

echo "Attempting FSx mount..." | tee -a $LOG
if timeout 30 mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" /tmp/fsx_test 2>&1; then
    echo "✓ DHCP DISRUPTION: Mount succeeded (via secondary interface)" | tee -a $LOG
    umount /tmp/fsx_test
else
    echo "✗ DHCP DISRUPTION: Mount FAILED - confirms routing issue!" | tee -a $LOG
fi

# Restore route
echo "Restoring primary default route..." | tee -a $LOG
ip route add ${SAVED_DEFAULT} 2>&1 | tee -a $LOG || true

# --- Test 3: Force traffic through each secondary interface ---
echo "" | tee -a $LOG
echo "=== Test 3: Force FSx traffic through each interface ===" | tee -a $LOG

for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^ens|^eth'); do
    IFACE_IP=$(ip -o addr show dev ${IFACE} | grep 'inet ' | awk '{print $4}' | cut -d'/' -f1)

    echo "" | tee -a $LOG
    echo "--- Testing via ${IFACE} (${IFACE_IP}) ---" | tee -a $LOG

    # Add specific route to FSx via this interface
    ip route add ${FSX_IP}/32 dev ${IFACE} src ${IFACE_IP} 2>&1 | tee -a $LOG || true

    echo "Route to FSx:" | tee -a $LOG
    ip route get ${FSX_IP} 2>&1 | tee -a $LOG

    # Rebind LNet to this interface
    lnetctl lnet configure 2>/dev/null
    lnetctl net del --net tcp 2>/dev/null || true
    lnetctl net add --net tcp --if ${IFACE} 2>&1 | tee -a $LOG
    echo "LNet bound to ${IFACE}:" | tee -a $LOG
    lnetctl net show 2>&1 | tee -a $LOG

    if timeout 30 mount -t lustre -o relatime,flock "${FSX_DNS}@tcp:/${FSX_MOUNT_NAME}" /tmp/fsx_test 2>&1; then
        echo "✓ ${IFACE}: Mount succeeded" | tee -a $LOG
        umount /tmp/fsx_test
    else
        echo "✗ ${IFACE}: Mount FAILED" | tee -a $LOG
    fi

    # Remove specific route
    ip route del ${FSX_IP}/32 dev ${IFACE} 2>&1 | tee -a $LOG || true
done

# --- Restore original state ---
echo "" | tee -a $LOG
echo "=== Restoring original state ===" | tee -a $LOG
lnetctl lnet configure 2>/dev/null
lnetctl net del --net tcp 2>/dev/null || true
lnetctl net add --net tcp --if ${PRIMARY_IFACE} 2>&1 | tee -a $LOG

rmdir /tmp/fsx_test 2>/dev/null || true

echo "" | tee -a $LOG
echo "=== All Tests Complete ===" | tee -a $LOG
echo "Results in: ${LOG}"
