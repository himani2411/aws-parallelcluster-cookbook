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


# -------------------------------------------------------------------
# nvidia_enabled? — tested via nvidia_install recipe guard
# The recipe returns early if nvidia_enabled? is false
# -------------------------------------------------------------------
describe 'nvidia_enabled? via nvidia_driver resource' do
  [
    ['yes', true],
    [true, true],
    ['true', true],
    ['no', false],
    [false, false],
    ['false', false],
    ['any_other_value', false],
  ].each do |input, should_install|
    context "when node['cluster']['nvidia']['enabled'] is #{input.inspect}" do
      cached(:chef_run) do
        allow(::File).to receive(:exist?).and_call_original
        allow(::File).to receive(:exist?).with('/usr/bin/nvidia-smi').and_return(false)
        stub_command("lsinitramfs /boot/initrd.img-$(uname -r) | grep nouveau").and_return(false)
        ChefSpec::SoloRunner.new(step_into: ['nvidia_driver']) do |node|
          node.override['cluster']['nvidia']['enabled'] = input
        end.converge('aws-parallelcluster-platform::nvidia_install')
      end

      if should_install
        it 'runs nvidia driver install bash' do
          is_expected.to run_bash('nvidia.run advanced')
        end
      else
        it 'does not run nvidia driver install bash' do
          is_expected.not_to run_bash('nvidia.run advanced')
        end
      end
    end
  end
end

# -------------------------------------------------------------------
# nvidia_rpm_distro_tag — tested via IMEX RPM filename construction
# S3 filenames have no distro tag; public repo filenames include it
# -------------------------------------------------------------------
describe 'nvidia_rpm_distro_tag via IMEX install' do
  cached(:s3_base_url) { "https://fake-s3-bucket.s3.us-east-1.amazonaws.com/archives/dependencies/nvidia_imex" }
  cached(:public_base_url) { 'https://fake-nvidia-public.example.com/compute/cuda/repos' }

  {
    ['amazon', '2023'] => '.amzn2023',
    ['redhat', '8'] => '.el8',
    ['redhat', '9'] => '.el9',
    ['rocky', '8'] => '.el8',
    ['rocky', '9'] => '.el9',
  }.each do |(platform, version), expected_tag|
    context "on #{platform}#{version} with public base_url" do
      cached(:chef_run) do
        stubs_for_resource('nvidia_imex') do |res|
          allow(res).to receive(:nvidia_enabled_or_installed?).and_return(true)
          allow(res).to receive(:imex_installed?).and_return(false)
        end
        allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
        runner = runner(platform: platform, version: version, step_into: ['nvidia_imex']) do |node|
          node.override['cluster']['artifacts_s3_url'] = 'https://fake-s3-bucket.s3.us-east-1.amazonaws.com/archives'
          node.override['cluster']['nvidia']['imex']['base_url'] = public_base_url
          node.override['cluster']['nvidia']['driver_version'] = '580.105.08'
        end
        runner.converge_dsl('aws-parallelcluster-platform') do
          nvidia_imex 'install' do
            action :install
          end
        end
      end

      it "includes '#{expected_tag}' distro tag in the RPM filename" do
        remote_file = chef_run.find_resource('remote_file', /nvidia-imex.*\.rpm/)
        expect(remote_file.source.first).to match(/#{Regexp.escape(expected_tag)}/)
      end
    end

    context "on #{platform}#{version} with default S3 base_url" do
      cached(:chef_run) do
        stubs_for_resource('nvidia_imex') do |res|
          allow(res).to receive(:nvidia_enabled_or_installed?).and_return(true)
          allow(res).to receive(:imex_installed?).and_return(false)
        end
        allow_any_instance_of(Object).to receive(:arm_instance?).and_return(false)
        runner = runner(platform: platform, version: version, step_into: ['nvidia_imex']) do |node|
          node.override['cluster']['artifacts_s3_url'] = 'https://fake-s3-bucket.s3.us-east-1.amazonaws.com/archives'
          node.override['cluster']['nvidia']['imex']['base_url'] = s3_base_url
          node.override['cluster']['nvidia']['driver_version'] = '580.105.08'
        end
        runner.converge_dsl('aws-parallelcluster-platform') do
          nvidia_imex 'install' do
            action :install
          end
        end
      end

      it "does not include distro tag in the RPM filename" do
        remote_file = chef_run.find_resource('remote_file', /nvidia-imex.*\.rpm/)
        expect(remote_file.source.first).not_to match(/\.el\d|\.amzn/)
      end
    end
  end
end

# -------------------------------------------------------------------
# get_pci_device_count — tested via fabric_manager configure action
# enable_fabric_manager? uses get_gpu_count, get_nvswitch_count, etc.
# -------------------------------------------------------------------
describe 'get_pci_device_count via enable_fabric_manager?' do
  cached(:fabric_manager_service) { 'nvidia-fabricmanager' }

  context 'when multiple GPUs (>1) and NVSwitches (>1) detected' do
    cached(:chef_run) do
      stubs_for_provider('fabric_manager') do |res|
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0302').and_return(8)  # 8 GPUs
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0680').and_return(6)  # 6 NVSwitches
        allow(res).to receive(:get_pci_device_count).with('15b3', '', '0207').and_return(0)  # 0 Mellanox
        allow(res).to receive(:get_pci_device_count).with('10de', '2941').and_return(0)      # not GB200
      end
      runner = runner(platform: 'redhat', version: '8', step_into: ['fabric_manager'])
      runner.converge_dsl('aws-parallelcluster-platform') do
        fabric_manager 'configure' do
          action :configure
        end
      end
    end

    it 'enables and starts fabric manager service' do
      is_expected.to start_service(fabric_manager_service)
        .with_action(%i(start enable))
    end
  end

  context 'when multiple GPUs but only Mellanox bridges (no NVSwitches)' do
    cached(:chef_run) do
      stubs_for_provider('fabric_manager') do |res|
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0302').and_return(8)  # 8 GPUs
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0680').and_return(0)  # 0 NVSwitches
        allow(res).to receive(:get_pci_device_count).with('15b3', '', '0207').and_return(4)  # 4 Mellanox CX-7
        allow(res).to receive(:get_pci_device_count).with('10de', '2941').and_return(0)      # not GB200
      end
      runner = runner(platform: 'redhat', version: '8', step_into: ['fabric_manager'])
      runner.converge_dsl('aws-parallelcluster-platform') do
        fabric_manager 'configure' do
          action :configure
        end
      end
    end

    it 'enables fabric manager (Mellanox bridges trigger it)' do
      is_expected.to start_service(fabric_manager_service)
        .with_action(%i(start enable))
    end
  end

  context 'when single GPU (no multi-GPU topology)' do
    cached(:chef_run) do
      stubs_for_provider('fabric_manager') do |res|
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0302').and_return(1)  # 1 GPU
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0680').and_return(0)
        allow(res).to receive(:get_pci_device_count).with('15b3', '', '0207').and_return(0)
        allow(res).to receive(:get_pci_device_count).with('10de', '2941').and_return(0)
      end
      runner = runner(platform: 'redhat', version: '8', step_into: ['fabric_manager'])
      runner.converge_dsl('aws-parallelcluster-platform') do
        fabric_manager 'configure' do
          action :configure
        end
      end
    end

    it 'does not start fabric manager service' do
      is_expected.not_to start_service(fabric_manager_service)
    end
  end

  context 'when zero GPUs' do
    cached(:chef_run) do
      stubs_for_provider('fabric_manager') do |res|
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0302').and_return(0)  # 0 GPUs
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0680').and_return(0)
        allow(res).to receive(:get_pci_device_count).with('15b3', '', '0207').and_return(0)
        allow(res).to receive(:get_pci_device_count).with('10de', '2941').and_return(0)
      end
      runner = runner(platform: 'redhat', version: '8', step_into: ['fabric_manager'])
      runner.converge_dsl('aws-parallelcluster-platform') do
        fabric_manager 'configure' do
          action :configure
        end
      end
    end

    it 'does not start fabric manager service' do
      is_expected.not_to start_service(fabric_manager_service)
    end
  end

  context 'when GB200 node (multiple GPUs + NVSwitches but GB200 device detected)' do
    cached(:chef_run) do
      stubs_for_provider('fabric_manager') do |res|
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0302').and_return(8)
        allow(res).to receive(:get_pci_device_count).with('10de', '', '0680').and_return(6)
        allow(res).to receive(:get_pci_device_count).with('15b3', '', '0207').and_return(0)
        allow(res).to receive(:get_pci_device_count).with('10de', '2941').and_return(4)      # GB200 detected
      end
      runner = runner(platform: 'redhat', version: '8', step_into: ['fabric_manager'])
      runner.converge_dsl('aws-parallelcluster-platform') do
        fabric_manager 'configure' do
          action :configure
        end
      end
    end

    it 'does not start fabric manager (GB200 does not need it)' do
      is_expected.not_to start_service(fabric_manager_service)
    end
  end
end
