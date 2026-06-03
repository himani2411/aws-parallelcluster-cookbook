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

unified_mode true
default_action :install

# nvidia-modprobe is a small setuid binary that the NVIDIA kernel modules
# rely on for runtime module loading. The driver .run installer drops the
# binary into /usr/bin/, but does not register a corresponding entry in
# the system package database (dpkg/rpm). Starting with driver branch
# 580.159, nvidia-imex (and other sidecar packages) declare a hard
# dependency on `nvidia-modprobe = <driver_version>`, so installing the
# matching .deb/.rpm is required for those package installs to succeed
# even though the binary itself is already on disk.
#
# Installing the same binary that the .run installer already laid down
# is intentional: the cost is one rpm/deb worth of metadata, and in
# return we get a correctly registered package that satisfies dependency
# resolution for future package operations.

action :install do
  return unless nvidia_enabled_or_installed?
  return if on_docker?

  action_install_modprobe

  # Save Modprobe version in node attributes for InSpec tests.
  node.default['cluster']['nvidia']['modprobe']['version'] = nvidia_modprobe_full_version
  node.default['cluster']['nvidia']['modprobe']['package'] = nvidia_modprobe_package
  node_attributes 'dump node attributes'
end

def nvidia_modprobe_package
  'nvidia-modprobe'
end

# Mirrors the version derivation used by nvidia-imex / fabric_manager so
# all three packages move in lockstep with the driver bump.
def nvidia_modprobe_full_version
  "#{node['cluster']['nvidia']['driver_version']}-1"
end

def nvidia_enabled_or_installed?
  nvidia_enabled? || nvidia_installed?
end
