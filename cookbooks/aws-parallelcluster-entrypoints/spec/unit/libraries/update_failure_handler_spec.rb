# frozen_string_literal: true

# Copyright:: 2025 Amazon.com, Inc. and its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

require_relative '../../spec_helper'
require_relative '../../../libraries/update_failure_handler'
require 'json'

describe ErrorHandlers::UpdateFailureHandler do
  let(:handler) { described_class.new(cleanup_dna_files: true, start_clustermgtd: true) }
  let(:exception) { StandardError.new('Test error') }
  let(:resource1) { double('resource1', to_s: 'file[/tmp/test]') }
  let(:updated_resources) { [resource1] }
  let(:action_collection) { double('action_collection') }
  let(:pyenv_root) { '/opt/parallelcluster/pyenv' }
  let(:python_version) { '3.9.0' }
  let(:scripts_dir) { '/opt/parallelcluster/scripts' }
  let(:region) { 'us-east-1' }
  let(:virtualenv_path) { "#{pyenv_root}/versions/#{python_version}/envs/cookbook_virtualenv" }
  let(:shared_dir) { '/opt/parallelcluster/shared' }
  let(:base_dir) { '/opt/parallelcluster' }
  let(:slurm_install_dir) { '/opt/slurm' }
  let(:backup_dir) { '/opt/slurm.bak.20260528-112233' }
  let(:archive_url) { 's3://example-bucket/slurm-patches.tar.gz' }
  let(:sentinel_path) { "#{base_dir}/.slurm_patches_in_progress" }
  let(:node) do
    {
      'cluster' => {
        'node_type' => node_type,
        'scheduler' => scheduler,
        'system_pyenv_root' => pyenv_root,
        'python-version' => python_version,
        'scripts_dir' => scripts_dir,
        'region' => region,
        'shared_dir' => shared_dir,
        'base_dir' => base_dir,
      },
    }
  end
  let(:node_type) { 'HeadNode' }
  let(:scheduler) { 'slurm' }
  let(:run_status) { double('run_status', exception: exception, updated_resources: updated_resources, node: node) }
  let(:command_runner) { instance_double(ErrorHandlers::CommandRunner) }

  before do
    allow(handler).to receive(:run_status).and_return(run_status)
    allow(handler).to receive(:action_collection).and_return(action_collection)
    allow(action_collection).to receive(:filtered_collection).and_return([])
    allow(handler).to receive(:command_runner).and_return(command_runner)
    allow(command_runner).to receive(:run_with_retries).and_return(true)
  end

  describe '#node_type' do
    it 'returns the node type from cluster attributes' do
      expect(handler.node_type).to eq('HeadNode')
    end
  end

  describe '#scheduler' do
    it 'returns the scheduler from cluster attributes' do
      expect(handler.scheduler).to eq('slurm')
    end
  end

  describe '#cookbook_virtualenv_path' do
    it 'constructs the correct virtualenv path' do
      expect(handler.cookbook_virtualenv_path).to eq(virtualenv_path)
    end
  end

  describe '#report' do
    context 'when node type is HeadNode and scheduler is slurm' do
      it 'writes error report and runs recovery commands' do
        expect(handler).to receive(:write_error_report)
        expect(handler).to receive(:run_recovery)
        handler.report
      end

      it 'catches and logs exceptions during recovery' do
        allow(handler).to receive(:write_error_report).and_raise(StandardError.new('Recovery failed'))
        expect(Chef::Log).to receive(:error).with(/Failed with error: Recovery failed/)
        expect(Chef::Log).to receive(:error).with(/Backtrace:/)
        handler.report
      end
    end

    context 'when node type is not HeadNode' do
      let(:node_type) { 'ComputeFleet' }

      it 'skips recovery and returns early' do
        expect(handler).not_to receive(:write_error_report)
        expect(handler).not_to receive(:run_recovery)
        allow(Chef::Log).to receive(:info)
        expect(Chef::Log).to receive(:info).with(/Node type is ComputeFleet and scheduler is slurm, recovery from update failure only executes on the HeadNode with slurm scheduler/)
        handler.report
      end
    end
  end

  describe '#write_error_report' do
    it 'logs the exception and updated resources' do
      expect(Chef::Log).to receive(:info).with(/Update failed on HeadNode due to: Test error/)
      expect(Chef::Log).to receive(:info).with(/Resources that have been successfully executed/)
      expect(Chef::Log).to receive(:info).with(%r{file\[/tmp/test\]})
      handler.write_error_report
    end
  end

  describe '#run_recovery' do
    {
      cleanup_dna_files: :cleanup_dna_files,
      start_clustermgtd: :start_clustermgtd,
      restore_slurm_patches: :restore_slurm_patches,
    }.each do |flag, method|
      [true, false].each do |enabled|
        context "when #{flag} is #{enabled}" do
          let(:handler) { described_class.new(flag => enabled) }

          before do
            allow(handler).to receive(:run_status).and_return(run_status)
            allow(handler).to receive(:action_collection).and_return(action_collection)
            allow(handler).to receive(:command_runner).and_return(command_runner)
            allow(Chef::Log).to receive(:info)
          end

          it "#{enabled ? 'calls' : 'does not call'} #{method}" do
            if enabled
              expect(handler).to receive(method)
            else
              expect(handler).not_to receive(method)
            end
            handler.run_recovery
          end
        end
      end
    end
  end

  describe '#cleanup_dna_files' do
    let(:marker) { "#{shared_dir}/update_failed_marker" }

    context 'when marker does not exist (update failure)' do
      before do
        allow(::File).to receive(:exist?).with(marker).and_return(false)
        allow(::File).to receive(:write)
      end

      it 'runs the cleanup command' do
        expected_command = "#{virtualenv_path}/bin/python #{scripts_dir}/share_compute_fleet_dna.py --region #{region} --cleanup"
        expect(command_runner).to receive(:run_with_retries).with(expected_command, description: "cleanup DNA files")
        handler.cleanup_dna_files
      end

      it 'writes the marker file' do
        expect(::File).to receive(:write).with(marker, '')
        handler.cleanup_dna_files
      end

      it 'logs update failure detected with marker path' do
        expect(Chef::Log).to receive(:info).with(/Update failure detected.*#{Regexp.escape(marker)}/)
        handler.cleanup_dna_files
      end
    end

    context 'when marker exists (rollback failure)' do
      before do
        allow(::File).to receive(:exist?).with(marker).and_return(true)
        allow(::File).to receive(:delete)
      end

      it 'does not run the cleanup command' do
        expect(command_runner).not_to receive(:run_with_retries)
        handler.cleanup_dna_files
      end

      it 'deletes the marker file' do
        expect(::File).to receive(:delete).with(marker)
        handler.cleanup_dna_files
      end

      it 'logs rollback failure detected with marker path' do
        expect(Chef::Log).to receive(:info).with(/Rollback failure detected.*#{Regexp.escape(marker)}/)
        handler.cleanup_dna_files
      end
    end

    context 'when marker check raises an error' do
      before do
        allow(::File).to receive(:exist?).with(marker).and_raise(Errno::EIO.new("I/O error"))
      end

      it 'falls back to cleaning up DNA files' do
        expected_command = "#{virtualenv_path}/bin/python #{scripts_dir}/share_compute_fleet_dna.py --region #{region} --cleanup"
        expect(command_runner).to receive(:run_with_retries).with(expected_command, description: "cleanup DNA files")
        handler.cleanup_dna_files
      end

      it 'logs a warning' do
        expect(Chef::Log).to receive(:warn).with(/Error during marker check/)
        handler.cleanup_dna_files
      end
    end
  end

  describe '#start_clustermgtd' do
    it 'runs the supervisorctl command' do
      expected_command = "#{virtualenv_path}/bin/supervisorctl start clustermgtd"
      expect(command_runner).to receive(:run_with_retries).with(expected_command, description: "start clustermgtd")
      handler.start_clustermgtd
    end
  end

  describe '#run_service_action' do
    it 'invokes systemctl by default with all named services' do
      expect(command_runner).to receive(:run_with_retries)
        .with('systemctl start slurmctld supervisord', description: 'start slurmctld supervisord')
      handler.run_service_action(:start, 'slurmctld', 'supervisord')
    end

    it 'invokes supervisorctl when controller: :supervisorctl is given' do
      expect(command_runner).to receive(:run_with_retries)
        .with("#{virtualenv_path}/bin/supervisorctl start clustermgtd", description: 'start clustermgtd')
      handler.run_service_action(:start, 'clustermgtd', controller: :supervisorctl)
    end

    it 'raises when no services are passed' do
      expect { handler.run_service_action(:start) }.to raise_error(ArgumentError, /at least one service/)
    end

    it 'raises on an unknown controller' do
      expect { handler.run_service_action(:start, 'slurmctld', controller: :foo) }
        .to raise_error(ArgumentError, /unsupported controller/)
    end
  end

  describe '#restore_slurm_patches' do
    let(:sentinel_content) do
      JSON.generate(
        backup_dir: backup_dir,
        slurm_install_dir: slurm_install_dir,
        slurmdbd_in_use: false,
        archive_url: archive_url
      )
    end

    context 'when sentinel does not exist (no destructive section was entered)' do
      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(false)
      end

      it 'is a no-op without touching daemons or the install dir' do
        expect(command_runner).not_to receive(:run_with_retries)
        expect(::File).not_to receive(:delete)
        expect(Chef::Log).to receive(:info).with(/No Slurm patches sentinel.*nothing to restore/)
        handler.restore_slurm_patches
      end
    end

    context 'when sentinel is present and backup_dir exists (happy-path restore)' do
      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:directory?).with(backup_dir).and_return(true)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
        allow(::File).to receive(:delete)
        allow(Chef::Log).to receive(:warn)
        allow(Chef::Log).to receive(:info)
      end

      it 'stops slurm daemons before manipulating the install dir' do
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl stop slurmctld supervisord', hash_including(description: anything)).ordered
        expect(command_runner).to receive(:run_with_retries)
          .with("find #{slurm_install_dir} -mindepth 1 -delete", hash_including(description: anything)).ordered
        expect(command_runner).to receive(:run_with_retries)
          .with("cp -a #{backup_dir}/. #{slurm_install_dir}/", hash_including(description: anything)).ordered
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl start slurmctld supervisord', hash_including(description: anything)).ordered
        handler.restore_slurm_patches
      end

      it 'deletes the sentinel after successful restore' do
        expect(::File).to receive(:delete).with(sentinel_path)
        handler.restore_slurm_patches
      end
    end

    context 'when sentinel signals slurmdbd_in_use=true' do
      let(:sentinel_content) do
        JSON.generate(
          backup_dir: backup_dir,
          slurm_install_dir: slurm_install_dir,
          slurmdbd_in_use: true,
          archive_url: archive_url
        )
      end

      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:directory?).with(backup_dir).and_return(true)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
        allow(::File).to receive(:delete)
        allow(Chef::Log).to receive(:warn)
        allow(Chef::Log).to receive(:info)
      end

      it 'also stops and starts slurmdbd' do
        # Other run_with_retries calls (stop/start slurmctld+supervisord, find, cp)
        # fall through to the global `before` block's default-true stub.
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl stop slurmdbd', anything)
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl start slurmdbd', anything)
        handler.restore_slurm_patches
      end
    end

    context 'when sentinel exists but backup_dir is missing' do
      let(:sentinel_content) do
        JSON.generate(
          backup_dir: '/opt/slurm.bak.gone',
          slurm_install_dir: slurm_install_dir,
          slurmdbd_in_use: false
        )
      end

      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:directory?).with('/opt/slurm.bak.gone').and_return(false)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
      end

      it 'logs and refuses to restore (manual recovery required)' do
        expect(command_runner).not_to receive(:run_with_retries)
        expect(::File).not_to receive(:delete)
        expect(Chef::Log).to receive(:error).with(/Sentinel references backup .* directory is missing.*Manual recovery required/)
        handler.restore_slurm_patches
      end
    end

    context 'when sentinel exists without backup_dir (recipe failed before snapshot)' do
      let(:sentinel_content) do
        # Initial sentinel write -- recipe stops services / preflight raises /
        # snapshot fails before the second write that would add backup_dir.
        JSON.generate(
          slurm_install_dir: slurm_install_dir,
          slurmdbd_in_use: false,
          archive_url: archive_url
        )
      end

      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
        allow(::File).to receive(:delete)
        allow(Chef::Log).to receive(:warn)
        allow(Chef::Log).to receive(:info)
      end

      it 'just restarts daemons (install dir untouched, no restore needed)' do
        # Should NOT call find or cp; should call systemctl start.
        expect(command_runner).not_to receive(:run_with_retries).with(/find /, anything)
        expect(command_runner).not_to receive(:run_with_retries).with(/cp -a /, anything)
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl start slurmctld supervisord', hash_including(description: anything))
          .and_return(true)
        handler.restore_slurm_patches
      end

      it 'deletes the sentinel after successful restart' do
        allow(command_runner).to receive(:run_with_retries).and_return(true)
        expect(::File).to receive(:delete).with(sentinel_path)
        handler.restore_slurm_patches
      end

      it 'leaves the sentinel in place if daemon restart fails' do
        allow(command_runner).to receive(:run_with_retries).and_return(false)
        expect(::File).not_to receive(:delete)
        handler.restore_slurm_patches
      end
    end

    context 'when sentinel exists without backup_dir AND slurmdbd_in_use' do
      let(:sentinel_content) do
        JSON.generate(
          slurm_install_dir: slurm_install_dir,
          slurmdbd_in_use: true,
          archive_url: archive_url
        )
      end

      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
        allow(::File).to receive(:delete)
        allow(Chef::Log).to receive(:warn)
        allow(Chef::Log).to receive(:info)
      end

      it 'starts slurmctld+supervisord and slurmdbd' do
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl start slurmctld supervisord', anything).and_return(true)
        expect(command_runner).to receive(:run_with_retries)
          .with('systemctl start slurmdbd', anything).and_return(true)
        handler.restore_slurm_patches
      end
    end

    context 'when the find -delete step fails' do
      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:directory?).with(backup_dir).and_return(true)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
        # Stops succeed via the global stub; only the find call returns false.
        allow(command_runner).to receive(:run_with_retries)
          .with(/find /, anything).and_return(false)
      end

      it 'logs the manual-recovery instructions and leaves the sentinel in place' do
        expect(::File).not_to receive(:delete)
        expect(Chef::Log).to receive(:error).with(/Failed to empty.*Backup is preserved at #{Regexp.escape(backup_dir)}/)
        handler.restore_slurm_patches
      end
    end

    context 'when the cp restore step fails' do
      before do
        allow(::File).to receive(:exist?).with(sentinel_path).and_return(true)
        allow(::File).to receive(:directory?).with(backup_dir).and_return(true)
        allow(::File).to receive(:read).with(sentinel_path).and_return(sentinel_content)
        allow(command_runner).to receive(:run_with_retries)
          .with(/cp -a /, anything).and_return(false)
      end

      it 'logs and leaves the sentinel in place for retry' do
        expect(::File).not_to receive(:delete)
        expect(Chef::Log).to receive(:error).with(/Failed to restore.*Manual recovery required/)
        handler.restore_slurm_patches
      end
    end
  end

  describe '#command_runner' do
    before do
      allow(handler).to receive(:command_runner).and_call_original
    end

    it 'returns a CommandRunner instance' do
      expect(handler.command_runner).to be_a(ErrorHandlers::CommandRunner)
    end

    it 'memoizes the command runner' do
      expect(handler.command_runner).to be(handler.command_runner)
    end
  end

  describe '#resource_succeeded?' do
    let(:resource_name) { 'test resource' }
    let(:test_resource) { double('test_resource', resource_name: :execute, name: resource_name) }

    context 'when resource was updated' do
      let(:action_record) { double('action_record', new_resource: test_resource, status: :updated) }

      before { allow(action_collection).to receive(:filtered_collection).and_return([action_record]) }

      it 'returns true' do
        expect(handler.resource_succeeded?(resource_name)).to be true
      end
    end

    context 'when resource was up_to_date' do
      let(:action_record) { double('action_record', new_resource: test_resource, status: :up_to_date) }

      before { allow(action_collection).to receive(:filtered_collection).and_return([action_record]) }

      it 'returns true' do
        expect(handler.resource_succeeded?(resource_name)).to be true
      end
    end

    context 'when resource was not executed' do
      before { allow(action_collection).to receive(:filtered_collection).and_return([]) }

      it 'returns false' do
        expect(handler.resource_succeeded?(resource_name)).to be false
      end
    end

    context 'when resource failed' do
      let(:action_record) { double('action_record', new_resource: test_resource, status: :failed) }

      before { allow(action_collection).to receive(:filtered_collection).and_return([action_record]) }

      it 'returns false' do
        expect(handler.resource_succeeded?(resource_name)).to be false
      end
    end
  end

  describe '#resource_status' do
    let(:resource_name) { 'test resource' }
    let(:test_resource) { double('test_resource', resource_name: :execute, name: resource_name) }

    context 'when resource was not executed' do
      before { allow(action_collection).to receive(:filtered_collection).and_return([]) }

      it 'returns :not_executed' do
        expect(handler.resource_status(resource_name)).to eq(:not_executed)
      end
    end

    context 'when resource was executed' do
      let(:action_record) { double('action_record', new_resource: test_resource, status: :updated) }

      before { allow(action_collection).to receive(:filtered_collection).and_return([action_record]) }

      it 'returns the resource status' do
        expect(handler.resource_status(resource_name)).to eq(:updated)
      end
    end
  end
end
