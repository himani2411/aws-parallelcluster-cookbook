require 'spec_helper'

describe 'aws-parallelcluster-platform::configure_selinux' do
  context 'when security_access_control_mode is permissive (default)' do
    for_all_oses do |platform, version|
      context "on #{platform}#{version}" do
        cached(:chef_run) do
          runner = ChefSpec::Runner.new(platform: platform, version: version) do |node|
            node.override['cluster']['security_access_control_mode'] = 'permissive'
          end
          allow(runner).to receive(:shell_out).and_return(
            double('shell_out', stdout: '/usr/sbin/getenforce', exitstatus: 0, error?: false)
          )
          runner.converge(described_recipe)
        end

        it 'sets SELinux to permissive mode' do
          is_expected.to permissive_selinux_state('SELinux Permissive')
        end

        it 'does not disable SELinux' do
          is_expected.not_to disabled_selinux_state('SELinux Disabled')
        end

        it 'does not run grubby to disable selinux' do
          is_expected.not_to run_execute('disable selinux via grubby')
        end

        it 'does not run grub2 to disable selinux' do
          is_expected.not_to run_execute('disable selinux via grub2')
        end
      end
    end
  end

  context 'when security_access_control_mode is disabled' do
    for_all_oses do |platform, version|
      context "on #{platform}#{version}" do
        cached(:chef_run) do
          runner = ChefSpec::Runner.new(platform: platform, version: version) do |node|
            node.override['cluster']['security_access_control_mode'] = 'disabled'
          end
          allow(runner).to receive(:shell_out).and_return(
            double('shell_out', stdout: '/usr/sbin/getenforce', exitstatus: 0, error?: false)
          )
          runner.converge(described_recipe)
        end

        it 'disables SELinux via config' do
          is_expected.to disabled_selinux_state('SELinux Disabled')
        end

        it 'does not set SELinux to permissive' do
          is_expected.not_to permissive_selinux_state('SELinux Permissive')
        end

        it 'disables SELinux via grubby on RHEL-family' do
          is_expected.to run_execute('disable selinux via grubby')
            .with_command('grubby --update-kernel=ALL --args="selinux=0"')
        end
      end
    end
  end

  context 'when security_access_control_mode is enforcing' do
    for_all_oses do |platform, version|
      context "on #{platform}#{version}" do
        cached(:chef_run) do
          runner = ChefSpec::Runner.new(platform: platform, version: version) do |node|
            node.override['cluster']['security_access_control_mode'] = 'enforcing'
          end
          runner.converge(described_recipe)
        end

        it 'does not disable SELinux' do
          is_expected.not_to disabled_selinux_state('SELinux Disabled')
        end

        it 'does not set SELinux to permissive' do
          is_expected.not_to permissive_selinux_state('SELinux Permissive')
        end

        it 'does not run grubby' do
          is_expected.not_to run_execute('disable selinux via grubby')
        end

        it 'does not run grub2' do
          is_expected.not_to run_execute('disable selinux via grub2')
        end

        it 'logs that enforcing mode is active' do
          is_expected.to write_log('SELinux enforcing mode: leaving OS default configuration')
        end
      end
    end
  end

  context 'when security_access_control_mode is not set (defaults to permissive)' do
    for_all_oses do |platform, version|
      context "on #{platform}#{version}" do
        cached(:chef_run) do
          runner = ChefSpec::Runner.new(platform: platform, version: version)
          # Do not set security_access_control_mode — should default to permissive
          allow(runner).to receive(:shell_out).and_return(
            double('shell_out', stdout: '/usr/sbin/getenforce', exitstatus: 0, error?: false)
          )
          runner.converge(described_recipe)
        end

        it 'sets SELinux to permissive mode by default' do
          is_expected.to permissive_selinux_state('SELinux Permissive')
        end
      end
    end
  end
end
