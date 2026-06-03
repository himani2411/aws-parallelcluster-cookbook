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

action :install_modprobe do
  remote_file "#{node['cluster']['sources_dir']}/#{nvidia_modprobe_package}-#{nvidia_modprobe_full_version}.rpm" do
    source "#{nvidia_modprobe_url}"
    mode '0644'
    retries 3
    retry_delay 5
    action :create_if_missing
  end

  package 'yum-plugin-versionlock'
  bash "Install nvidia-modprobe" do
    user 'root'
    cwd node['cluster']['sources_dir']
    code <<-NVIDIA_MODPROBE
    set -e
    yum install -y #{nvidia_modprobe_package}-#{nvidia_modprobe_full_version}.rpm
    yum versionlock #{nvidia_modprobe_package}
    NVIDIA_MODPROBE
    retries 3
    retry_delay 5
  end
end

def arch_suffix
  arm_instance? ? 'aarch64' : 'x86_64'
end

def nvidia_modprobe_url
  base_url = node['cluster']['nvidia']['modprobe']['base_url']
  nvidia_package_url(base_url, platform,
    "#{nvidia_modprobe_package}-#{nvidia_modprobe_full_version}#{nvidia_rpm_distro_tag(base_url)}.#{arch_suffix}.rpm")
end
