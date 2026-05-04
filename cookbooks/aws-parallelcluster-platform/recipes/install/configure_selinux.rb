# frozen_string_literal: true
#
# Copyright:: 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
# See the License for the specific language governing permissions and limitations under the License.

# Configure SELinux based on the cluster's security_access_control_mode setting.
# Default is 'permissive' — logs violations but does not block operations.
# See: https://docs.aws.amazon.com/linux/al2023/ug/disable-option-selinux.html#change-to-permissive

selinux_mode = node['cluster']['security_access_control_mode'] || 'permissive'

case selinux_mode
when 'disabled'
  # Disable SELinux via config file (works on older kernels like RHEL 8 / 4.18)
  selinux_state "SELinux Disabled" do
    action :disabled
    only_if 'which getenforce'
  end

  # Disable SELinux via kernel cmdline using grubby (required for kernels >= 6.4
  # where runtime disable is deprecated). Also covers RHEL 9 (5.14) which
  # backported the deprecation.
  execute 'disable selinux via grubby' do
    command 'grubby --update-kernel=ALL --args="selinux=0"'
    only_if 'which grubby'
  end

  # Ubuntu/Debian: disable via kernel cmdline using GRUB2
  execute 'disable selinux via grub2' do
    command %q(sed -i 's/^\(GRUB_CMDLINE_LINUX=".*\)"$/\1 selinux=0"/g' /etc/default/grub && update-grub)
    only_if { ::File.exist?('/etc/default/grub') }
    not_if 'which grubby'
    not_if 'grep -q selinux=0 /etc/default/grub'
  end

when 'permissive'
  # Set SELinux to permissive mode — logs violations but does not block.
  # This is the recommended approach for AL2023 and RHEL-based distros.
  # Benefits:
  #   - Zero functional impact on HPC operations
  #   - Maintains file labels for easier transition to enforcing if needed
  #   - Logs policy violations for audit/compliance visibility
  #   - Resolves AL2023 cloud-init cc_selinux crash (KeyError on 'current_mode')
  #   - No grubby/kernel cmdline changes needed
  selinux_state "SELinux Permissive" do
    action :permissive
    only_if 'which getenforce'
  end

when 'enforcing'
  # Leave OS default — do not modify SELinux configuration.
  # Customers choosing enforcing must manage their own SELinux policies
  # for PCluster paths (/opt/slurm, /opt/parallelcluster, NFS mounts, etc.)
  # as per the shared-responsibility model.
  log 'SELinux enforcing mode: leaving OS default configuration' do
    level :info
  end

else
  raise "Invalid security_access_control_mode '#{selinux_mode}'. Valid values: disabled, permissive, enforcing"
end
