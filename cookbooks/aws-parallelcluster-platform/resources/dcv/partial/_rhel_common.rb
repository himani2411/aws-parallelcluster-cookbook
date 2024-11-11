# frozen_string_literal: true

#
# Copyright:: 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
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

def dcv_sha256sum
  if arm_instance?
    case el_string
    when "el7"
      # ALINUX2
      'e44f3c06e1830ccc52d25995227bbbb2060bc81a9623420ade8ef69317784fdd'
    when "el8"
      # RHEL and Rocky8
      '2192d084fd7d1bfeaa183b5d6d97ba0aaf6854491bcbd3bee3f8095f025449a3'
    when "el9"
      # RHEL and Rocky9
      'fc56494748a717e05694d9cba653436901921ca46b6d33789bea9eaf544a74e6'
    else
      ''
    end
  else
    case el_string
    when "el7"
      # ALINUX2
      'dd63c2aad943e2c106ac4e519c308bba4786eb1e4c11674bedad9111c65c6230'
    when "el8"
      # RHEL and Rocky8
      'dc459ee21224cb75ff155d9332e27bc2fac80f311df290bda7c8c023f43925bd'
    when "el9"
      # RHEL and Rocky9
      '673ac2bb4c10b4d5a7140066a968117212e597cf47b0a570ad19cad772d67c64'
    else
      ''
    end
  end
end

def el_string
  if platform?('amazon')
    "el7"
  else
    "el#{node['platform_version'].to_i}"
  end
end

def dcv_package
  "nice-dcv-#{node['cluster']['dcv']['version']}-#{el_string}-#{dcv_url_arch}"
end

def dcv_server
  "nice-dcv-server-#{node['cluster']['dcv']['server']['version']}.#{el_string}.#{dcv_url_arch}.rpm"
end

def xdcv
  "nice-xdcv-#{node['cluster']['dcv']['xdcv']['version']}.#{el_string}.#{dcv_url_arch}.rpm"
end

def dcv_web_viewer
  "nice-dcv-web-viewer-#{node['cluster']['dcv']['web_viewer']['version']}.#{el_string}.#{dcv_url_arch}.rpm"
end

def dcv_gl
  "nice-dcv-gl-#{node['cluster']['dcv']['gl']['version']}.#{el_string}.#{dcv_url_arch}.rpm"
end

action_class do
  def pre_install
    # Install the desktop environment and the desktop manager packages
    execute 'Install gnome desktop' do
      command 'yum -y install @gnome'
      retries 3
      retry_delay 5
    end
    # Install X Window System (required when using GPU acceleration)
    package "xorg-x11-server-Xorg" do
      retries 3
      retry_delay 5
    end

    # libvirtd service creates virtual bridge interfaces.
    # It's provided by libvirt-daemon, installed as requirement for gnome-boxes, included in @gnome.
    # Open MPI does not ignore other local-only devices other than loopback:
    # if virtual bridge interface is up, Open MPI assumes that that network is usable for MPI communications.
    # This is incorrect and it led to MPI applications hanging when they tried to send or receive MPI messages
    # see https://www.open-mpi.org/faq/?category=tcp#tcp-selection for details
    service 'libvirtd' do
      action %i(disable stop)
    end
  end

  def post_install
    # stop firewall
    service "firewalld" do
      action %i(disable stop)
    end

    include_recipe 'aws-parallelcluster-platform::disable_selinux'
  end

  def install_dcv_gl
    package = "#{node['cluster']['sources_dir']}/#{dcv_package}/#{dcv_gl}"
    package package do
      action :install
      source package
    end
  end
end
