# frozen_string_literal: true

# Copyright:: 2026 Amazon.com, Inc. and its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

require 'spec_helper'

describe 'aws-parallelcluster-slurm::update_slurm_patches' do
  slurm_install_dir = '/MOCK_SLURM_INSTALL_DIR'
  base_dir = '/MOCK_BASE_DIR'
  marker_path = "#{base_dir}/.slurm_patches_archive"
  archive_url = 'MOCK_ARCHIVE_URL'
  alt_archive_url = 'MOCK_OLD_ARCHIVE_URL'
  time_now = Time.parse('2026-05-28T11:22:33.000+00:00')
  expected_backup_dir = "#{slurm_install_dir}.bak.20260528-112233"
  preflight_resource_name = "preflight: check no foreign processes hold files in #{slurm_install_dir}"
  snapshot_resource_name = "snapshot #{slurm_install_dir} before rebuild"
  empty_resource_name = "empty #{slurm_install_dir} contents (mountpoint preserved)"
  restore_resource_name = "restore #{slurm_install_dir}/etc from snapshot"

  # Single setup helper to keep node-attribute boilerplate out of every context.
  def configure_node(node, node_type:, archive: '', database: nil)
    slurm_settings = database ? { Database: database } : {}
    node.override['cluster']['node_type'] = node_type
    node.override['cluster']['slurm_patches_s3_archive'] = archive
    node.override['cluster']['slurm']['install_dir'] = '/MOCK_SLURM_INSTALL_DIR'
    node.override['cluster']['base_dir'] = '/MOCK_BASE_DIR'
    # `node['cluster']['config']` is normally populated by the
    # `load_cluster_config` ruby_block during the update flow. The recipe's
    # `slurmdbd_in_use` lambda reads it at converge time -- chefspec's
    # converge runs ruby_blocks for us, but we don't include the loader
    # here, so override the attribute directly to mimic the post-load state.
    node.override['cluster']['config'] = { Scheduling: { SlurmSettings: slurm_settings } }
  end

  before do
    allow(Time).to receive(:now).and_return(time_now)
    # Don't actually descend into install_slurm during unit tests; just record
    # that it would have been included so a single example can verify.
    # NOTE: cached(:chef_run) means only the first example to invoke chef_run
    # populates @included_recipes -- subsequent examples reuse the cached
    # run but get a fresh empty array. So at most one assertion per cached
    # context can use this spy. See entrypoints/spec/.../update_spec.rb for
    # the same pattern.
    @included_recipes = []
    allow_any_instance_of(Chef::Recipe).to receive(:include_recipe).and_call_original
    allow_any_instance_of(Chef::Recipe)
      .to receive(:include_recipe).with('aws-parallelcluster-slurm::install_slurm') do |_, name|
        @included_recipes << name
      end
    # Pass-through stubs for ::File so fauxhai (and anything else in the chef
    # internals) can keep reading platform JSON. Individual contexts override
    # behavior for the marker path only.
    allow(::File).to receive(:exist?).and_call_original
    allow(::File).to receive(:read).and_call_original
  end

  for_all_oses do |platform, version|
    context "on #{platform}#{version}" do
      context 'when node_type is not HeadNode' do
        cached(:chef_run) do
          runner = runner(platform: platform, version: version) do |node|
            configure_node(node, node_type: 'ComputeFleet', archive: archive_url)
          end
          runner.converge(described_recipe)
        end

        it 'is a no-op on non-HeadNode' do
          is_expected.not_to run_ruby_block(preflight_resource_name)
          is_expected.not_to stop_service('slurmctld')
          is_expected.not_to include_recipe('aws-parallelcluster-slurm::install_slurm')
        end
      end

      context 'when archive URL is empty and never been patched' do
        cached(:chef_run) do
          allow(::File).to receive(:exist?).with(marker_path).and_return(false)

          runner = runner(platform: platform, version: version) do |node|
            configure_node(node, node_type: 'HeadNode', archive: '')
          end
          runner.converge(described_recipe)
        end

        it 'is a complete no-op when no archive is configured' do
          is_expected.not_to run_ruby_block(preflight_resource_name)
          is_expected.not_to stop_service('slurmctld')
          is_expected.not_to include_recipe('aws-parallelcluster-slurm::install_slurm')
          is_expected.not_to create_file(marker_path)
        end
      end

      context 'when archive URL is unset but a previous patch was applied' do
        cached(:chef_run) do
          allow(::File).to receive(:exist?).with(marker_path).and_return(true)
          allow(::File).to receive(:read).with(marker_path).and_return("#{archive_url}\n")

          runner = runner(platform: platform, version: version) do |node|
            configure_node(node, node_type: 'HeadNode', archive: '')
          end
          runner.converge(described_recipe)
        end

        it 'leaves the previously applied patch in place (no rollback)' do
          # Empty field never triggers a rebuild, even if a patch is on disk.
          # Operator must replace the AMI or recreate the cluster to roll back.
          is_expected.not_to run_ruby_block(preflight_resource_name)
          is_expected.not_to stop_service('slurmctld')
          is_expected.not_to run_execute(snapshot_resource_name)
          is_expected.not_to include_recipe('aws-parallelcluster-slurm::install_slurm')
          is_expected.not_to create_file(marker_path)
        end
      end

      context 'when archive URL matches the marker' do
        cached(:chef_run) do
          allow(::File).to receive(:exist?).with(marker_path).and_return(true)
          allow(::File).to receive(:read).with(marker_path).and_return("#{archive_url}\n")

          runner = runner(platform: platform, version: version) do |node|
            configure_node(node, node_type: 'HeadNode', archive: archive_url)
          end
          runner.converge(described_recipe)
        end

        it 'is idempotent — skips rebuild when archive is unchanged' do
          is_expected.not_to stop_service('slurmctld')
          is_expected.not_to run_execute(snapshot_resource_name)
          is_expected.not_to include_recipe('aws-parallelcluster-slurm::install_slurm')
        end
      end

      context 'when archive URL differs from the marker (apply path, no slurmdbd)' do
        cached(:chef_run) do
          allow(::File).to receive(:exist?).with(marker_path).and_return(true)
          allow(::File).to receive(:read).with(marker_path).and_return("#{alt_archive_url}\n")

          runner = runner(platform: platform, version: version) do |node|
            configure_node(node, node_type: 'HeadNode', archive: archive_url)
          end
          runner.converge(described_recipe)
        end

        it 'reuses install_slurm to rebuild and apply patches from archive' do
          # Must be the first example in this context to fire -- cached(:chef_run)
          # means subsequent examples reuse the cached run but reset
          # @included_recipes. See `before` block.
          chef_run
          expect(@included_recipes).to include('aws-parallelcluster-slurm::install_slurm')
        end

        it 'runs the preflight check' do
          is_expected.to run_ruby_block(preflight_resource_name)
        end

        it 'stops supervisord and slurmctld via Chef service resources' do
          is_expected.to stop_service('supervisord')
          is_expected.to stop_service('slurmctld')
        end

        it 'does not stop slurmdbd when accounting is not configured' do
          # Both service 'slurmdbd' resources (stop + start) carry the only_if
          # guard, so when accounting is off neither gets applied. Verify
          # neither stop_service nor start_service ran for slurmdbd.
          is_expected.not_to stop_service('slurmdbd')
          is_expected.not_to start_service('slurmdbd')
        end

        it 'snapshots the slurm install dir under a timestamped backup' do
          is_expected.to run_execute(snapshot_resource_name)
            .with(command: "cp -a #{slurm_install_dir} #{expected_backup_dir}")
        end

        it 'empties the mountpoint contents (find -mindepth 1 -delete)' do
          is_expected.to run_execute(empty_resource_name)
            .with(command: "find #{slurm_install_dir} -mindepth 1 -delete")
        end

        it 'restores etc from the snapshot using trailing /. for merge' do
          is_expected.to run_execute(restore_resource_name)
            .with(command: "cp -Rp #{expected_backup_dir}/etc/. #{slurm_install_dir}/etc/")
        end

        it 'updates the marker file with the new archive URL' do
          is_expected.to create_file(marker_path)
            .with(
              content: archive_url,
              owner: 'root',
              group: 'root',
              mode: '0644'
            )
        end

        it 'starts slurmctld and supervisord via Chef service resources' do
          is_expected.to start_service('slurmctld')
          is_expected.to start_service('supervisord')
        end

        it 'writes a sentinel before the destructive section so the failure handler can roll back' do
          is_expected.to create_file("#{base_dir}/.slurm_patches_in_progress").with(
            owner: 'root',
            group: 'root',
            mode: '0644'
          )
        end

        it 'deletes the sentinel after the rebuild completes successfully' do
          is_expected.to delete_file("#{base_dir}/.slurm_patches_in_progress")
        end
      end

      context 'when archive URL differs and slurmdbd is in use' do
        cached(:chef_run) do
          allow(::File).to receive(:exist?).with(marker_path).and_return(false)

          runner = runner(platform: platform, version: version) do |node|
            configure_node(
              node,
              node_type: 'HeadNode',
              archive: archive_url,
              database: { Uri: 'MOCK_DB_URI', UserName: 'MOCK_DB_USER' }
            )
          end
          runner.converge(described_recipe)
        end

        it 'stops slurmdbd alongside slurmctld and supervisord' do
          is_expected.to stop_service('slurmctld')
          is_expected.to stop_service('supervisord')
          is_expected.to stop_service('slurmdbd')
        end

        it 'starts slurmdbd back up after the rebuild' do
          is_expected.to start_service('slurmctld')
          is_expected.to start_service('supervisord')
          is_expected.to start_service('slurmdbd')
        end
      end
    end
  end
end
