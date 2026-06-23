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

# Install amazon-efs-utils from the official EFS yum repository (the same repo
# set up by https://amazon-efs-utils.aws.com/efs-utils-installer.sh) instead of
# building from source. v3+ builds need a Rust toolchain newer than the OS ships;
# the pre-built package side-steps that entirely.

def efs_repo_base_url
  # RHEL/Rocky are el-binary-compatible, so both use the redhat/<major>.* path.
  "#{efs_domain}/repo/rpm/redhat/#{node['platform_version'].to_i}.*"
end

def efs_domain
  "https://amazon-efs-utils.aws.com"
end

action :install_utils do
  package_name = "amazon-efs-utils-#{_efs_utils_version}"

  # Do not install efs-utils if a same or newer version is already installed.
  return if already_installed?("amazon-efs-utils", _efs_utils_version)

  yum_repository "efs-utils" do
    description "efs-utils repository"
    baseurl efs_repo_base_url
    gpgkey "#{efs_domain}/efs-utils-armored.gpg"
    gpgcheck true
    repo_gpgcheck true
    enabled true
    retries 3
    retry_delay 5
  end

  package package_name do
    retries 3
    retry_delay 5
  end

  action_increase_poll_interval
end
