# frozen_string_literal: true
#
# Test recipe to diagnose FSx routing issues between init and config phases
#

return if on_docker?

# Only run on compute nodes with FSx configured
return unless node['cluster']['fsx_fs_id_array']&.any?

log 'Starting FSx routing diagnostic test' do
  level :info
end

bash 'test_fsx_routing_after_init' do
  user 'root'
  code <<-BASH
    set -e
    
    echo "=== FSx Routing Test (Post-Init Phase) ===" | tee -a /var/log/fsx_routing_test.log
    date | tee -a /var/log/fsx_routing_test.log
    
    # Get FSx DNS from node attributes
    FSX_DNS="#{node['cluster']['fsx_dns_name_array']&.first}"
    
    if [ -z "${FSX_DNS}" ]; then
      echo "No FSx DNS found, skipping test" | tee -a /var/log/fsx_routing_test.log
      exit 0
    fi
    
    echo "FSx DNS: ${FSX_DNS}" | tee -a /var/log/fsx_routing_test.log
    
    # Resolve FSx IP
    FSX_IP=$(dig +short ${FSX_DNS} | head -1)
    echo "FSx IP: ${FSX_IP}" | tee -a /var/log/fsx_routing_test.log
    
    # Check route to FSx
    echo "" | tee -a /var/log/fsx_routing_test.log
    echo "Current route to FSx:" | tee -a /var/log/fsx_routing_test.log
    ip route get ${FSX_IP} | tee -a /var/log/fsx_routing_test.log
    
    # Check all interface routes
    echo "" | tee -a /var/log/fsx_routing_test.log
    echo "All interface routes:" | tee -a /var/log/fsx_routing_test.log
    ip route show | tee -a /var/log/fsx_routing_test.log
    
    # Check for cleanup hook
    echo "" | tee -a /var/log/fsx_routing_test.log
    if [ -f /etc/networkd-dispatcher/routable.d/cleanup-routes.sh ]; then
      echo "Cleanup hook is installed" | tee -a /var/log/fsx_routing_test.log
    else
      echo "Cleanup hook NOT found" | tee -a /var/log/fsx_routing_test.log
    fi
    
    # Check if FSx IP is in any secondary interface subnet
    echo "" | tee -a /var/log/fsx_routing_test.log
    echo "Checking if FSx is in secondary interface subnets:" | tee -a /var/log/fsx_routing_test.log
    
    for IFACE in $(ip -o link show | awk -F': ' '{print $2}' | grep -E '^ens|^eth'); do
      CIDR=$(ip -o addr show dev ${IFACE} | grep 'inet ' | awk '{print $4}')
      if [ -n "${CIDR}" ]; then
        # Check if FSx IP is in this subnet
        NETWORK=$(echo ${CIDR} | cut -d'/' -f1 | cut -d'.' -f1-3)
        FSX_NETWORK=$(echo ${FSX_IP} | cut -d'.' -f1-3)
        
        if [ "${NETWORK}" = "${FSX_NETWORK}" ]; then
          echo "⚠️  WARNING: Interface ${IFACE} (${CIDR}) is in same /24 as FSx (${FSX_IP})" | tee -a /var/log/fsx_routing_test.log
          echo "⚠️  Cleanup hook may delete route needed for FSx!" | tee -a /var/log/fsx_routing_test.log
          
          # Check if automatic route exists
          if ip route show dev ${IFACE} | grep -q "$(echo ${CIDR} | cut -d'/' -f1,2)"; then
            echo "✓ Automatic route still exists on ${IFACE}" | tee -a /var/log/fsx_routing_test.log
          else
            echo "✗ Automatic route MISSING on ${IFACE} - cleanup hook may have run!" | tee -a /var/log/fsx_routing_test.log
          fi
        fi
      fi
    done
    
    echo "" | tee -a /var/log/fsx_routing_test.log
    echo "=== Test Complete ===" | tee -a /var/log/fsx_routing_test.log
  BASH
end
