# frozen_string_literal: true
#
# Test recipe to diagnose FSx routing issues between init and config phases
#

return if on_docker?

fsx_fs_ids = node['cluster']['fsx_fs_ids']
return if fsx_fs_ids.nil? || fsx_fs_ids.empty?

log "Running FSx routing diagnostic test for #{fsx_fs_ids}" do
  level :info
end

bash 'test_fsx_routing_after_init' do
  user 'root'
  live_stream true
  code <<-BASH
    set -e
    LOG=/var/log/fsx_routing_test.log

    echo "=== FSx Routing Test (Start of Config Phase) ===" | tee -a $LOG
    date | tee -a $LOG

    TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
    REGION=$(curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" http://169.254.169.254/latest/meta-data/placement/region)

    FSX_FS_ID="#{fsx_fs_ids.split(',').first}"
    FSX_DNS="${FSX_FS_ID}.fsx.${REGION}.amazonaws.com"
    echo "FSx FS ID: ${FSX_FS_ID}" | tee -a $LOG
    echo "FSx DNS: ${FSX_DNS}" | tee -a $LOG

    FSX_IP=$(dig +short ${FSX_DNS} | head -1)
    echo "FSx IP: ${FSX_IP}" | tee -a $LOG

    echo "" | tee -a $LOG
    echo "Route to FSx:" | tee -a $LOG
    ip route get ${FSX_IP} 2>&1 | tee -a $LOG

    echo "" | tee -a $LOG
    echo "All routes:" | tee -a $LOG
    ip route show | tee -a $LOG

    echo "" | tee -a $LOG
    echo "Routing rules:" | tee -a $LOG
    ip rule show | tee -a $LOG

    echo "" | tee -a $LOG
    echo "Cleanup hook installed: $([ -f /etc/networkd-dispatcher/routable.d/cleanup-routes.sh ] && echo YES || echo NO)" | tee -a $LOG

    if [ -f /etc/networkd-dispatcher/routable.d/cleanup-routes.sh ]; then
      echo "Hook contents:" | tee -a $LOG
      cat /etc/networkd-dispatcher/routable.d/cleanup-routes.sh | tee -a $LOG
    fi

    echo "" | tee -a $LOG
    echo "Interface details:" | tee -a $LOG
    for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^ens|^eth'); do
      IP=$(ip -o addr show dev ${IFACE} 2>/dev/null | grep 'inet ' | awk '{print $4}')
      KERNEL_ROUTE=$(ip route show dev ${IFACE} 2>/dev/null | grep 'proto kernel' || echo "NONE")
      echo "  ${IFACE}: IP=${IP} KernelRoute=${KERNEL_ROUTE}" | tee -a $LOG
    done

    echo "" | tee -a $LOG
    echo "=== Test Complete ===" | tee -a $LOG
  BASH
end
