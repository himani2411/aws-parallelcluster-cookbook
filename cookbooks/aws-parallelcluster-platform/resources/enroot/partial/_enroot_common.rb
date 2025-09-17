# frozen_string_literal: true
#
# Copyright:: 2024 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

action :setup do
  return if on_docker? || enroot_installed || !enroot_enabled?

  action_install_package

  enroot_examples_dir = "#{node['cluster']['examples_dir']}/enroot"

  directory enroot_examples_dir

  template "#{enroot_examples_dir}/enroot.conf" do
    source 'enroot/enroot.conf.erb'
    owner 'root'
    group 'root'
    mode '0644'
  end
end

def package_version
  node['cluster']['enroot']['version']
end

def enroot_installed
  ::File.exist?('/usr/bin/enroot')
end

def enroot_enabled?
  ['true', 'yes', true].include?(node['cluster']['enroot']['enabled'])
end