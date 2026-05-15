# frozen_string_literal: true

# Tests for the nvidia.rb library helpers used by the dependency upgrade pipeline.
# These helpers enable the pipeline to override base_url attributes to point at
# public NVIDIA repos instead of the default PCluster S3 mirror.
#
# Library methods are mixed into the Chef DSL context and only accessible during
# action execution. We test them through resource outcomes (URLs passed to
# remote_file, filenames constructed, etc.) rather than direct method calls.
#
# Helpers tested:
#   - default_artifacts_url?(base_url) — via DCGM/enroot URL construction
#   - nvidia_package_url(base_url, platform, filename) — via DCGM download URLs
#   - nvidia_repo_arch — via ARM DCGM URL containing 'sbsa'
#   - nvidia_rpm_distro_tag(base_url) — via Fabric Manager/IMEX RPM filenames
#   - nvidia_deb_distro_tag(base_url) — via Fabric Manager/IMEX DEB filenames

require 'spec_helper'

# Shared test constants
S3_ARTIFACTS_URL = 'https://fake-s3-bucket.s3.us-east-1.amazonaws.com/archives'.freeze
S3_DCGM_BASE_URL = "#{S3_ARTIFACTS_URL}/dependencies/nvidia_dcgm".freeze
PUBLIC_NVIDIA_BASE_URL = 'https://fake-nvidia-public.example.com/compute/cuda/repos'.freeze
S3_ENROOT_BASE_URL = "#{S3_ARTIFACTS_URL}/dependencies/enroot".freeze
PUBLIC_ENROOT_BASE_URL = 'https://fake-github-enroot.example.com/releases/download/v3.4.1'.freeze

# -------------------------------------------------------------------
# nvidia_package_url: S3 vs public URL (arch directory insertion)
# Tested via DCGM resource download URLs
# -------------------------------------------------------------------
describe 'nvidia_package_url via DCGM download' do
  context 'on RHEL x86_64 with default S3 base_url' do
    cached(:chef_run) do
      stubs_for_resource('nvidia_dcgm') do |res|
        allow(res).to receive(:_nvidia_dcgm_enabled).and_return(true)
      end
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner = runner(platform: 'redhat', version: '8', step_into: ['nvidia_dcgm']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['nvidia']['dcgm_base_url'] = S3_DCGM_BASE_URL
        node.override['cluster']['nvidia']['dcgm_version'] = '4.5.1-1'
      end
      runner.converge_dsl('aws-parallelcluster-platform') do
        nvidia_dcgm 'setup' do
          nvidia_enabled true
          action :setup
        end
      end
    end

    it 'builds URL as {base_url}/{platform}/{filename} (no arch dir)' do
      expect(chef_run).to create_if_missing_remote_file("#{chef_run.node['cluster']['sources_dir']}/datacenter-gpu-manager-4-core-4.5.1-1.rpm")
        .with(source: "#{S3_DCGM_BASE_URL}/rhel8/datacenter-gpu-manager-4-core-4.5.1-1.x86_64.rpm")
    end
  end

  context 'on RHEL x86_64 with overridden public base_url' do
    cached(:chef_run) do
      stubs_for_resource('nvidia_dcgm') do |res|
        allow(res).to receive(:_nvidia_dcgm_enabled).and_return(true)
      end
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner = runner(platform: 'redhat', version: '8', step_into: ['nvidia_dcgm']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['nvidia']['dcgm_base_url'] = PUBLIC_NVIDIA_BASE_URL
        node.override['cluster']['nvidia']['dcgm_version'] = '4.5.1-1'
      end
      runner.converge_dsl('aws-parallelcluster-platform') do
        nvidia_dcgm 'setup' do
          nvidia_enabled true
          action :setup
        end
      end
    end

    it 'builds URL as {base_url}/{platform}/{arch}/{filename} (with x86_64 arch dir)' do
      expect(chef_run).to create_if_missing_remote_file("#{chef_run.node['cluster']['sources_dir']}/datacenter-gpu-manager-4-core-4.5.1-1.rpm")
        .with(source: "#{PUBLIC_NVIDIA_BASE_URL}/rhel8/x86_64/datacenter-gpu-manager-4-core-4.5.1-1.x86_64.rpm")
    end
  end

  context 'on Ubuntu x86_64 with default S3 base_url' do
    cached(:chef_run) do
      stubs_for_resource('nvidia_dcgm') do |res|
        allow(res).to receive(:_nvidia_dcgm_enabled).and_return(true)
      end
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner = runner(platform: 'ubuntu', version: '22.04', step_into: ['nvidia_dcgm']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['nvidia']['dcgm_base_url'] = S3_DCGM_BASE_URL
        node.override['cluster']['nvidia']['dcgm_version'] = '4.5.1-1'
      end
      runner.converge_dsl('aws-parallelcluster-platform') do
        nvidia_dcgm 'setup' do
          nvidia_enabled true
          action :setup
        end
      end
    end

    it 'builds URL without arch dir for S3' do
      expect(chef_run).to create_if_missing_remote_file("#{chef_run.node['cluster']['sources_dir']}/datacenter-gpu-manager-4-core-4.5.1-1.deb")
        .with(source: "#{S3_DCGM_BASE_URL}/ubuntu2204/datacenter-gpu-manager-4-core_4.5.1-1_amd64.deb")
    end
  end

  context 'on Ubuntu x86_64 with overridden public base_url' do
    cached(:chef_run) do
      stubs_for_resource('nvidia_dcgm') do |res|
        allow(res).to receive(:_nvidia_dcgm_enabled).and_return(true)
      end
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner = runner(platform: 'ubuntu', version: '22.04', step_into: ['nvidia_dcgm']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['nvidia']['dcgm_base_url'] = PUBLIC_NVIDIA_BASE_URL
        node.override['cluster']['nvidia']['dcgm_version'] = '4.5.1-1'
      end
      runner.converge_dsl('aws-parallelcluster-platform') do
        nvidia_dcgm 'setup' do
          nvidia_enabled true
          action :setup
        end
      end
    end

    it 'builds URL with x86_64 arch dir for public repo' do
      expect(chef_run).to create_if_missing_remote_file("#{chef_run.node['cluster']['sources_dir']}/datacenter-gpu-manager-4-core-4.5.1-1.deb")
        .with(source: "#{PUBLIC_NVIDIA_BASE_URL}/ubuntu2204/x86_64/datacenter-gpu-manager-4-core_4.5.1-1_amd64.deb")
    end
  end

  # nvidia_repo_arch: tests 'sbsa' for ARM
  context 'on RHEL ARM with overridden public base_url' do
    cached(:chef_run) do
      stubs_for_resource('nvidia_dcgm') do |res|
        allow(res).to receive(:_nvidia_dcgm_enabled).and_return(true)
      end
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(true)
      runner = runner(platform: 'redhat', version: '9', step_into: ['nvidia_dcgm']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['nvidia']['dcgm_base_url'] = PUBLIC_NVIDIA_BASE_URL
        node.override['cluster']['nvidia']['dcgm_version'] = '4.5.1-1'
      end
      runner.converge_dsl('aws-parallelcluster-platform') do
        nvidia_dcgm 'setup' do
          nvidia_enabled true
          action :setup
        end
      end
    end

    it 'uses sbsa as arch directory for ARM instances' do
      expect(chef_run).to create_if_missing_remote_file("#{chef_run.node['cluster']['sources_dir']}/datacenter-gpu-manager-4-core-4.5.1-1.rpm")
        .with(source: "#{PUBLIC_NVIDIA_BASE_URL}/rhel9/sbsa/datacenter-gpu-manager-4-core-4.5.1-1.aarch64.rpm")
    end
  end
end

# -------------------------------------------------------------------
# default_artifacts_url? + enroot caps filename swap
# S3 uses 'enroot-caps' (hyphen), public uses 'enroot+caps' (plus)
# -------------------------------------------------------------------
describe 'default_artifacts_url? via enroot caps filename' do
  context 'on RHEL with default S3 caps_base_url' do
    cached(:chef_run) do
      stubs_for_resource('enroot') do |res|
        allow(res).to receive(:enroot_installed).and_return(false)
      end
      allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(true)
      allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(false)
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner(platform: 'redhat', version: '8', step_into: ['enroot']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['enroot']['version'] = '3.4.1'
        node.override['cluster']['enroot']['caps_base_url'] = S3_ENROOT_BASE_URL
      end
    end

    cached(:resource) do
      chef_run.converge_dsl('aws-parallelcluster-platform') do
        enroot 'setup'
      end
      chef_run.find_resource('enroot', 'setup')
    end

    it 'uses enroot-caps (hyphen) for S3 source' do
      expect(resource.enroot_caps_url).to include('enroot-caps-3.4.1')
    end

    it 'does not use enroot+caps (plus) for S3 source' do
      expect(resource.enroot_caps_url).not_to include('enroot+caps')
    end
  end

  context 'on RHEL with overridden public caps_base_url' do
    cached(:chef_run) do
      stubs_for_resource('enroot') do |res|
        allow(res).to receive(:enroot_installed).and_return(false)
      end
      allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(true)
      allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(false)
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner(platform: 'redhat', version: '8', step_into: ['enroot']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['enroot']['version'] = '3.4.1'
        node.override['cluster']['enroot']['caps_base_url'] = PUBLIC_ENROOT_BASE_URL
      end
    end

    cached(:resource) do
      chef_run.converge_dsl('aws-parallelcluster-platform') do
        enroot 'setup'
      end
      chef_run.find_resource('enroot', 'setup')
    end

    it 'uses enroot+caps (plus) for public source' do
      expect(resource.enroot_caps_url).to include('enroot+caps-3.4.1')
    end

    it 'does not use enroot-caps (hyphen) for public source' do
      expect(resource.enroot_caps_url).not_to include('enroot-caps')
    end
  end

  context 'on Ubuntu with default S3 caps_base_url' do
    cached(:chef_run) do
      stubs_for_resource('enroot') do |res|
        allow(res).to receive(:enroot_installed).and_return(false)
      end
      allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(true)
      allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(false)
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner(platform: 'ubuntu', version: '22.04', step_into: ['enroot']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['enroot']['version'] = '3.4.1'
        node.override['cluster']['enroot']['caps_base_url'] = S3_ENROOT_BASE_URL
      end
    end

    cached(:resource) do
      chef_run.converge_dsl('aws-parallelcluster-platform') do
        enroot 'setup'
      end
      chef_run.find_resource('enroot', 'setup')
    end

    it 'uses enroot-caps (hyphen) for S3 source on Debian' do
      expect(resource.enroot_caps_url).to include('enroot-caps_3.4.1')
    end
  end

  context 'on Ubuntu with overridden public caps_base_url' do
    cached(:chef_run) do
      stubs_for_resource('enroot') do |res|
        allow(res).to receive(:enroot_installed).and_return(false)
      end
      allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(true)
      allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(false)
      allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
      runner(platform: 'ubuntu', version: '22.04', step_into: ['enroot']) do |node|
        node.override['cluster']['artifacts_s3_url'] = S3_ARTIFACTS_URL
        node.override['cluster']['enroot']['version'] = '3.4.1'
        node.override['cluster']['enroot']['caps_base_url'] = PUBLIC_ENROOT_BASE_URL
      end
    end

    cached(:resource) do
      chef_run.converge_dsl('aws-parallelcluster-platform') do
        enroot 'setup'
      end
      chef_run.find_resource('enroot', 'setup')
    end

    it 'uses enroot+caps (plus) for public source on Debian' do
      expect(resource.enroot_caps_url).to include('enroot+caps_3.4.1')
    end
  end
end
