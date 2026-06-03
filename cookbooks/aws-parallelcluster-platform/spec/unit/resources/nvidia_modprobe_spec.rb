require 'spec_helper'

nvidia_version = "1.2.3"
SOURCE_DIR = 'SOURCE_DIR'.freeze unless defined?(SOURCE_DIR)
cluster_artifacts_s3_url = 'https://aws_region-aws-parallelcluster.s3.aws_region.AWS_DOMAIN'

class ConvergeNvidiaModprobe
  def self.install(chef_run)
    chef_run.converge_dsl('aws-parallelcluster-platform') do
      nvidia_modprobe 'install' do
        action :install
      end
    end
  end
end

describe 'nvidia_modprobe:nvidia_enabled_or_installed?' do
  for_all_oses do |platform, version|
    context "on #{platform}#{version}" do
      cached(:chef_run) do
        runner(platform: platform, version: version, step_into: ['nvidia_modprobe'])
      end
      cached(:resource) do
        ConvergeNvidiaModprobe.install(chef_run)
        chef_run.find_resource('nvidia_modprobe', 'install')
      end

      context "when nvidia not enabled and not installed" do
        before do
          allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(false)
          allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(false)
        end

        it 'is false' do
          expect(resource.nvidia_enabled_or_installed?).to eq(false)
        end
      end

      context "when nvidia not enabled but already installed" do
        before do
          allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(false)
          allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(true)
        end

        it 'is true' do
          expect(resource.nvidia_enabled_or_installed?).to eq(true)
        end
      end

      context "when nvidia is enabled but not yet installed" do
        before do
          allow_any_instance_of(Object).to receive(:nvidia_enabled?).and_return(true)
          allow_any_instance_of(Object).to receive(:nvidia_installed?).and_return(false)
        end

        it 'is true' do
          expect(resource.nvidia_enabled_or_installed?).to eq(true)
        end
      end
    end
  end
end

describe 'nvidia_modprobe:install' do
  for_all_oses do |platform, version|
    context "on #{platform}#{version}" do
      context 'when nvidia not enabled' do
        cached(:chef_run) do
          stubs_for_resource('nvidia_modprobe') do |res|
            allow(res).to receive(:nvidia_enabled_or_installed?).and_return(false)
          end
          runner = runner(platform: platform, version: version, step_into: ['nvidia_modprobe'])
          ConvergeNvidiaModprobe.install(runner)
        end
        cached(:node) { chef_run.node }

        it 'does not install nvidia-modprobe' do
          is_expected.not_to install_package('nvidia-modprobe')
        end
      end

      %w(aarch64 x86_64).each do |arm_or_x86|
        context "when nvidia is enabled on #{arm_or_x86}" do
          cached(:nvidia_modprobe_version) { "1.2.3-1" }
          cached(:nvidia_modprobe_package) { "nvidia-modprobe" }
          cached(:nvidia_modprobe_name) do
            if %w(redhat rocky).include?(platform) || (platform == 'amazon' && version == '2023')
              "#{nvidia_modprobe_package}-#{nvidia_modprobe_version}"
            else
              "#{nvidia_modprobe_package}_#{nvidia_modprobe_version}"
            end
          end
          cached(:url_arch) do
            if %w(redhat rocky amazon).include?(platform)
              arm_or_x86
            else
              arm_or_x86 == 'x86_64' ? 'amd64' : 'arm64'
            end
          end
          cached(:url_suffix) do
            if %w(redhat rocky).include?(platform)
              "rhel#{version}/#{nvidia_modprobe_name}.#{url_arch}"
            elsif platform == 'amazon' && version == '2023'
              "amzn2023/#{nvidia_modprobe_name}.#{url_arch}"
            else
              "#{platform}#{version.delete('.')}/#{nvidia_modprobe_name}_#{url_arch}"
            end
          end

          cached(:chef_run) do
            stubs_for_resource('nvidia_modprobe') do |res|
              allow(res).to receive(:nvidia_enabled_or_installed?).and_return(true)
            end
            runner(platform: platform, version: version, step_into: ['nvidia_modprobe'])
          end
          cached(:node) { chef_run.node }

          before do
            chef_run.node.override['cluster']['artifacts_s3_url'] = cluster_artifacts_s3_url
            chef_run.node.override['cluster']['region'] = 'aws_region'
            chef_run.node.override['cluster']['sources_dir'] = SOURCE_DIR
            chef_run.node.automatic['kernel']['machine'] = arm_or_x86
            chef_run.node.override['cluster']['nvidia']['driver_version'] = nvidia_version
            ConvergeNvidiaModprobe.install(chef_run)
          end

          it 'installs nvidia-modprobe' do
            if platform == 'ubuntu'
              is_expected.to create_if_missing_remote_file("#{SOURCE_DIR}/#{nvidia_modprobe_package}-#{nvidia_modprobe_version}.deb").with(
                source: "#{cluster_artifacts_s3_url}/dependencies/nvidia_modprobe/#{url_suffix}.deb",
                mode: '0644',
                retries: 3,
                retry_delay: 5
              )
              is_expected.to run_bash('Install nvidia-modprobe')
                .with(user: 'root')
                .with_retries(3)
                .with_retry_delay(5)
                .with_code(/    set -e\n    dpkg -i #{nvidia_modprobe_package}-#{nvidia_modprobe_version}.deb && apt-mark hold #{nvidia_modprobe_package}/)
            else
              is_expected.to create_if_missing_remote_file("#{SOURCE_DIR}/#{nvidia_modprobe_package}-#{nvidia_modprobe_version}.rpm").with(
                source: "#{cluster_artifacts_s3_url}/dependencies/nvidia_modprobe/#{url_suffix}.rpm",
                mode: '0644',
                retries: 3,
                retry_delay: 5
              )
              is_expected.to install_package('yum-plugin-versionlock')
              is_expected.to run_bash("Install nvidia-modprobe")
                .with(user: 'root')
                .with_retries(3)
                .with_retry_delay(5)
                .with_code(/yum install -y #{nvidia_modprobe_name}.rpm/)
            end
          end

          it 'sets nvidia-modprobe version' do
            expect(node.default['cluster']['nvidia']['modprobe']['version']).to eq(nvidia_modprobe_version)
            expect(node.default['cluster']['nvidia']['modprobe']['package']).to eq(nvidia_modprobe_package)
            is_expected.to write_node_attributes('dump node attributes')
          end
        end
      end
    end
  end
end

# Tests for the NVIDIA library helper nvidia_package_url as exercised
# through nvidia_modprobe URL construction.
#
# Default S3 path:  {base_url}/{platform}/{filename}
# Public repo path: {base_url}/{platform}/{arch}/{filename}
describe 'nvidia_modprobe_url construction' do
  s3_modprobe_base_url = "#{cluster_artifacts_s3_url}/dependencies/nvidia_modprobe"
  public_modprobe_base_url = 'https://fake-public.example.DOMAIN/compute/cuda/repos'

  platform_dirs = {
    'amazon2023' => 'amzn2023',
    'ubuntu22.04' => 'ubuntu2204',
    'ubuntu24.04' => 'ubuntu2404',
    'redhat8' => 'rhel8',
    'redhat9' => 'rhel9',
    'rocky8' => 'rhel8',
    'rocky9' => 'rhel9',
  }.freeze

  for_all_oses do |platform, version|
    debian = (platform == 'ubuntu')
    ext = debian ? 'deb' : 'rpm'
    package_join = debian ? '_' : '-'
    arch_join = debian ? '_' : '.'
    expected_platform = platform_dirs["#{platform}#{version}"]

    [false, true].each do |arm|
      arch_suffix = if debian
                      arm ? 'arm64' : 'amd64'
                    else
                      arm ? 'aarch64' : 'x86_64'
                    end
      package_filename = "nvidia-modprobe#{package_join}#{nvidia_version}-1#{arch_join}#{arch_suffix}.#{ext}"

      [
        ['default S3 base_url',
         s3_modprobe_base_url,
         "#{s3_modprobe_base_url}/#{expected_platform}/#{package_filename}"],
        ['overridden public base_url',
         public_modprobe_base_url,
         "#{public_modprobe_base_url}/#{expected_platform}/#{arm ? 'sbsa' : 'x86_64'}/#{package_filename}"],
      ].each do |scenario, base_url, expected_source|
        context "on #{platform}#{version} #{arm ? 'ARM' : 'x86_64'} with #{scenario}" do
          cached(:chef_run) do
            stubs_for_resource('nvidia_modprobe') do |res|
              allow(res).to receive(:nvidia_enabled_or_installed?).and_return(true)
            end
            allow_any_instance_of(Object).to receive(:arm_instance?).and_return(arm)
            runner = runner(platform: platform, version: version, step_into: ['nvidia_modprobe']) do |node|
              node.override['cluster']['artifacts_s3_url'] = cluster_artifacts_s3_url
              node.override['cluster']['nvidia']['modprobe']['base_url'] = base_url
              node.override['cluster']['nvidia']['driver_version'] = nvidia_version
            end
            runner.converge_dsl('aws-parallelcluster-platform') do
              nvidia_modprobe 'install' do
                action :install
              end
            end
          end

          it 'builds the expected URL' do
            remote_file = chef_run.find_resource('remote_file', /nvidia-modprobe.*\.#{ext}/)
            expect(remote_file.source.first).to eq(expected_source)
          end
        end
      end
    end
  end
end
