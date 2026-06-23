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

# Install amazon-efs-utils from the official EFS apt repository (the same repo
# set up by https://amazon-efs-utils.aws.com/efs-utils-installer.sh) instead of
# building from source. v3+ builds need a Rust toolchain newer than the OS ships;
# the pre-built package side-steps that entirely.

def efs_domain
  "https://amazon-efs-utils.aws.com"
end

action :install_utils do
  package_version = _efs_utils_version

  # Do not install efs-utils if a same or newer version is already installed.
  return if already_installed?("amazon-efs-utils", package_version)

  apt_repository "efs-utils" do
    uri "#{efs_domain}/repo/deb/ubuntu"
    distribution node['platform_version']
    components ['main']
    key "#{efs_domain}/efs-utils.gpg"
    retries 3
    retry_delay 5
  end

  apt_update

  # --force-confold/-confdef keep our customized /etc/amazon/efs/efs-utils.conf
  # on upgrade; without them dpkg prompts interactively and aborts on EOF.
  package "amazon-efs-utils" do
    version "#{package_version}-1"
    options '-o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef"'
    retries 3
    retry_delay 5
  end

  action_increase_poll_interval
end
