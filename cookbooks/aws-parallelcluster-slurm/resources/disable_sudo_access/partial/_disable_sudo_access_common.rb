# frozen_string_literal: true
#
# Copyright:: 2013-2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

unified_mode true
default_action :setup

property :disable_sudo_access, String

action :setup do
  return unless node['cluster']['node_type'] == 'HeadNode'
  node['cluster']['disable_sudo_access_for_default_user'] == 'true' ? action_disable : action_enable
end

action :enable do
  return if on_docker?

  # Enable sudo access for default user
  template '/etc/sudoers.d/99-parallelcluster-revoke-sudo-access' do
    only_if { ::File.exist? "/etc/sudoers.d/99-parallelcluster-revoke-sudo-access" }
    source 'disable_sudo_access/99-parallelcluster-revoke-sudo.erb'
    owner 'root'
    group 'root'
    mode '0600'
    action :delete
  end
  
end

action :disable do
  return if on_docker?
  
  bash "Disable Sudo Access for #{node['cluster']['cluster_user']}" do
    user 'root'
    group 'root'
    code <<-SUDO_DISABLE
      set -e
      sed -n -i "/"#{node['cluster']['cluster_user']}" ALL=(ALL) NOPASSWD:ALL/d" /etc/sudoers
    SUDO_DISABLE
  end

  # Disable sudo access for default user
  template '/etc/sudoers.d/99-parallelcluster-revoke-sudo-access' do
    source 'disable_sudo_access/99-parallelcluster-revoke-sudo.erb'
    owner 'root'
    group 'root'
    mode '0600'
    action :create
  end

end
