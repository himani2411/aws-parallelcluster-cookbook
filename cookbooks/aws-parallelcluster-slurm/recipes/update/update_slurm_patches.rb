# frozen_string_literal: true

#
# Cookbook:: aws-parallelcluster-slurm
# Recipe:: update_slurm_patches
#
# Copyright:: 2026 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.
#
# Re-applies a custom Slurm patches archive (DevSettings.SlurmPatchesS3Archive)
# to a running head node by rebuilding Slurm in place. Designed to be invoked
# from `aws-parallelcluster-slurm::update_head_node` so that `pcluster update-cluster`
# picks up patch changes without requiring a custom AMI rebuild.
#
# Notes:
#   * The Slurm install dir (node['cluster']['slurm']['install_dir'], typically
#     /opt/slurm) is an NFS-loopback mountpoint on the head node; we cannot
#     remove the mountpoint itself, only its contents.
#   * The compute fleet must be stopped before invoking this recipe -- enforced
#     via the COMPUTE_FLEET_STOP update policy on the schema field in CLI.
#   * <slurm_install_dir>/etc (slurm.conf, gres.conf, slurmdbd.conf, JWT key,
#     plugin configs) is preserved by snapshotting before rebuild and
#     restoring after.
#   * A marker file at <base_dir>/.slurm_patches_archive caches the
#     last-applied archive URL so that idempotent updates skip the rebuild.

require 'json'

return unless node['cluster']['node_type'] == 'HeadNode'

archive_url = node['cluster']['slurm_patches_s3_archive'].to_s

# Skip when no archive is configured. Once a patch has been applied,
# unsetting the field does NOT roll it back -- the patched Slurm tree
# stays in place. To remove patches, replace the AMI or recreate the cluster.
#
# State matrix:
#   archive_url       previously_applied   Action
#   ""                ""                   skip (never patched)
#   ""                "X"                  skip (keep X applied as-is)
#   "X"               ""                   apply X (first patch)
#   "X"               "X"                  skip (idempotent)
#   "Y"               "X"                  apply Y (roll forward to new patch set)
return if archive_url.empty?

slurm_install_dir = node['cluster']['slurm']['install_dir']
slurm_etc_dir = "#{slurm_install_dir}/etc"
applied_marker = "#{node['cluster']['base_dir']}/.slurm_patches_archive"
sentinel_path = "#{node['cluster']['base_dir']}/.slurm_patches_in_progress"

previously_applied = ::File.exist?(applied_marker) ? ::File.read(applied_marker).strip : ''

# Idempotent skip: same archive as last successful apply -> no rebuild.
return if archive_url == previously_applied

backup_dir = "#{slurm_install_dir}.bak.#{Time.now.strftime('%Y%m%d-%H%M%S')}"

# Slurmdbd is only present and managed when the cluster config has a Database
# section under SlurmSettings. Use this flag to gate the service stop/start
# steps and avoid touching a unit that doesn't exist on this head node.
slurmdbd_in_use = !node['cluster']['config'].dig(:Scheduling, :SlurmSettings, :Database).nil?

# Sentinel for UpdateFailureHandler. Written *before* we stop any services so
# the handler can recover from any failure point in this recipe, including:
#   * service stop fails / preflight raises (no backup_dir yet -> handler
#     just restarts services, since /opt/slurm is intact)
#   * snapshot fails (backup_dir unset -> same)
#   * empty/install_slurm/restore/start fail (backup_dir set, full restore)
#
# JSON format keeps native types (booleans, nil) so the handler reads values
# without manual string-casting. We deliberately omit backup_dir from this
# initial write; the handler treats absence of backup_dir as "no destructive
# change yet, just restart daemons."
file sentinel_path do
  content lazy {
    JSON.pretty_generate(
      slurm_install_dir: slurm_install_dir,
      slurmdbd_in_use: slurmdbd_in_use,
      archive_url: archive_url
    )
  }
  owner 'root'
  group 'root'
  mode '0644'
end

service 'supervisord' do
  action :stop
end

service 'slurmctld' do
  action :stop
end

service 'slurmdbd' do
  action :stop
  only_if { slurmdbd_in_use }
end

ruby_block "preflight: check no foreign processes hold files in #{slurm_install_dir}" do
  block do
    # Daemons we manage have already been stopped above, so anything still
    # holding a file under the install dir is a foreign holder we shouldn't
    # destroy out from under.
    begin
      lsof = Mixlib::ShellOut.new('lsof', '+D', slurm_install_dir)
      lsof.run_command
    rescue Errno::ENOENT
      Chef::Log.info("lsof not available; skipping foreign-holder check on #{slurm_install_dir}")
      next
    end

    # lsof exits non-zero when nothing is held -- the happy path -- and stdout
    # is empty in that case.
    next if lsof.stdout.strip.empty?

    Chef::Log.error("Processes hold files in #{slurm_install_dir} after Slurm daemons were stopped:")
    Chef::Log.error(lsof.stdout)
    raise "Cannot proceed with Slurm patch rebuild: foreign processes hold files in " \
          "#{slurm_install_dir}. Stop them and re-run pcluster update-cluster."
  end
end

execute "snapshot #{slurm_install_dir} before rebuild" do
  command "cp -a #{slurm_install_dir} #{backup_dir}"
end

# Update the sentinel with backup_dir now that the snapshot exists. From this
# point on, any handler invocation will perform a full restore from the
# backup, not just a service restart.
file sentinel_path do
  content lazy {
    JSON.pretty_generate(
      slurm_install_dir: slurm_install_dir,
      slurmdbd_in_use: slurmdbd_in_use,
      archive_url: archive_url,
      backup_dir: backup_dir
    )
  }
  owner 'root'
  group 'root'
  mode '0644'
end

execute "empty #{slurm_install_dir} contents (mountpoint preserved)" do
  # mindepth 1 leaves the mountpoint itself intact; -delete depth-first removes
  # everything underneath so install_slurm can do a clean rebuild.
  command "find #{slurm_install_dir} -mindepth 1 -delete"
end

# Reuse the install path. install_slurm.rb already:
#   * downloads + extracts node['cluster']['slurm_patches_s3_archive']
#     into <sources_dir>/slurm_patches/
#   * applies every *.diff in that directory in lexicographic order
#   * runs ./configure && make install
#
# NOTE: We deliberately do NOT clean <sources_dir>/slurm_patches/ between
# runs. Patches from previous archives remain on disk and will be applied
# alongside the new archive's contents. CX is responsible for choosing
# patch filenames such that:
#   * Files in a new archive overwrite files in old archives (same filename),
#   * Or the cumulative set is the intended set when archives are layered.
# Switching archives without considering filename overlap can lead to
# silent application of stale patches.
include_recipe 'aws-parallelcluster-slurm::install_slurm'

execute "restore #{slurm_etc_dir} from snapshot" do
  # Trailing /. so contents merge into the etc dir instead of nesting.
  command "cp -Rp #{backup_dir}/etc/. #{slurm_etc_dir}/"
end

# Persist the applied archive only after the rebuild + restore succeeded.
# If anything above fails, the marker stays at the previous value and the
# next run will retry the apply.
file applied_marker do
  content archive_url
  owner 'root'
  group 'root'
  mode '0644'
end

service 'slurmctld' do
  action :start
end

service 'supervisord' do
  action :start
end

service 'slurmdbd' do
  action :start
  only_if { slurmdbd_in_use }
end

# Recipe completed successfully. Drop the sentinel so the handler is a no-op
# on any subsequent failure unrelated to the patch rebuild.
file sentinel_path do
  action :delete
end

log 'slurm_patches_rebuild_complete' do
  message "Slurm rebuilt from archive '#{archive_url}'. Previous tree preserved at #{backup_dir}."
  level :info
end
