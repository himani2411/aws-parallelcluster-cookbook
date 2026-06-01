# frozen_string_literal: true

#
# Copyright:: 2025 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

require 'chef/handler'
require 'json'
require_relative 'command_runner'

module ErrorHandlers
  # Chef exception handler for cluster update failures.
  #
  # This handler is triggered when either the update or update-compute-fleet recipe fails.
  # It performs recovery actions to restore the cluster to a consistent state:
  # 1. Logs information about the update failure including which resources succeeded before failure.
  # 2. Cleans up DNA files shared with compute nodes, if cleanup_dna_files=true.
  # 3. Starts clustermgtd, if start_clustermgtd=true.
  # 4. Restores Slurm from a pre-rebuild snapshot, if restore_slurm_patches=true and a
  #    sentinel file from update_slurm_patches.rb is present (indicating the destructive
  #    section was entered but did not complete).
  #
  # Only runs on HeadNode - compute and login nodes skip this handler.
  class UpdateFailureHandler < Chef::Handler
    def initialize(config = {})
      @cleanup_dna_files = config.fetch(:cleanup_dna_files, false)
      @start_clustermgtd = config.fetch(:start_clustermgtd, false)
      @restore_slurm_patches = config.fetch(:restore_slurm_patches, false)
      super()
    end

    def report
      Chef::Log.info("#{log_prefix} Started with parameters @cleanup_dna_files=#{@cleanup_dna_files}, @start_clustermgtd=#{@start_clustermgtd}, @restore_slurm_patches=#{@restore_slurm_patches}")

      unless node_type == 'HeadNode' && scheduler == 'slurm'
        Chef::Log.info("#{log_prefix} Node type is #{node_type} and scheduler is #{scheduler}, recovery from update failure only executes on the HeadNode with slurm scheduler")
        return
      end

      begin
        write_error_report
        run_recovery
        Chef::Log.info("#{log_prefix} Completed successfully")
      rescue => e
        Chef::Log.error("#{log_prefix} Failed with error: #{e.message}")
        Chef::Log.error("#{log_prefix} Backtrace: #{e.backtrace.join("\n")}")
      end
    end

    def write_error_report
      Chef::Log.info("#{log_prefix} Update failed on #{node_type} due to: #{run_status.exception}")
      Chef::Log.info("#{log_prefix} Resources that have been successfully executed before the failure:")
      run_status.updated_resources.each do |resource|
        Chef::Log.info("#{log_prefix}   - #{resource}")
      end
    end

    def run_recovery
      Chef::Log.info("#{log_prefix} Running recovery commands")
      # Slurm rollback runs first: services need to be in a coherent state
      # before clustermgtd starts polling them again.
      restore_slurm_patches if @restore_slurm_patches
      start_clustermgtd if @start_clustermgtd
      cleanup_dna_files if @cleanup_dna_files
    end

    def cleanup_dna_files
      marker = "#{cluster_attributes['shared_dir']}/update_failed_marker"
      begin
        if ::File.exist?(marker)
          # Marker exists from previous update failure — this is a rollback failure, keep DNA files
          Chef::Log.info("#{log_prefix} Rollback failure detected (marker found at #{marker}), keeping DNA files")
          ::File.delete(marker)
        else
          # No marker — this is an update failure, clean up DNA files and write marker
          Chef::Log.info("#{log_prefix} Update failure detected (no marker at #{marker}), cleaning up DNA files")
          command = "#{cookbook_virtualenv_path}/bin/python #{cluster_attributes['scripts_dir']}/share_compute_fleet_dna.py --region #{cluster_attributes['region']} --cleanup"
          command_runner.run_with_retries(command, description: "cleanup DNA files")
          ::File.write(marker, '')
        end
      rescue => e
        # If marker I/O fails, fall back to deleting DNA files
        Chef::Log.warn("#{log_prefix} Error during marker check (#{e.message}), falling back to cleaning up DNA files")
        command = "#{cookbook_virtualenv_path}/bin/python #{cluster_attributes['scripts_dir']}/share_compute_fleet_dna.py --region #{cluster_attributes['region']} --cleanup"
        command_runner.run_with_retries(command, description: "cleanup DNA files")
      end
    end

    def start_clustermgtd
      run_service_action(:start, 'clustermgtd', controller: :supervisorctl)
    end

    # Restore Slurm from a pre-rebuild snapshot if update_slurm_patches.rb dropped
    # the sentinel file. The recipe writes the sentinel BEFORE stopping daemons,
    # then updates it with backup_dir AFTER snapshot succeeds. This lets us
    # distinguish three states:
    #   * No sentinel -> the patch flow never started; do nothing.
    #   * Sentinel without backup_dir -> stops/preflight/snapshot failed; the
    #     install dir is intact, we just need to restart daemons.
    #   * Sentinel with backup_dir -> destructive section ran; full restore
    #     from backup, then restart daemons.
    def restore_slurm_patches
      unless ::File.exist?(slurm_patches_sentinel_path)
        Chef::Log.info("#{log_prefix} No Slurm patches sentinel at #{slurm_patches_sentinel_path}, nothing to restore")
        return
      end

      if slurm_install_dir.nil?
        Chef::Log.error("#{log_prefix} Sentinel #{slurm_patches_sentinel_path} is malformed (missing slurm_install_dir); cannot restore automatically. Manual recovery required.")
        return
      end

      if backup_dir.nil? || backup_dir.empty?
        # Recipe failed before snapshot completed. Install dir is untouched;
        # we just need to bring daemons back up.
        Chef::Log.warn("#{log_prefix} Slurm patch flow interrupted before snapshot; restarting daemons against unchanged #{slurm_install_dir}")
        return unless start_slurm_daemons(slurmdbd_in_use?)
        ::File.delete(slurm_patches_sentinel_path)
        Chef::Log.info("#{log_prefix} Slurm daemons restarted; sentinel cleared")
        return
      end

      unless ::File.directory?(backup_dir)
        Chef::Log.error("#{log_prefix} Sentinel references backup #{backup_dir} but the directory is missing; cannot restore automatically. Manual recovery required.")
        return
      end

      Chef::Log.warn("#{log_prefix} Slurm rebuild interrupted; restoring #{slurm_install_dir} from #{backup_dir}")

      # Stop daemons that may have been left running half-installed. Errors are
      # tolerated here -- daemons may already be stopped from the failed run.
      stop_slurm_daemons(slurmdbd_in_use?)

      # Empty whatever's in the install dir -- could be a partial rebuild.
      unless command_runner.run_with_retries(
        "find #{slurm_install_dir} -mindepth 1 -delete",
        description: "empty #{slurm_install_dir} contents"
      )
        Chef::Log.error("#{log_prefix} Failed to empty #{slurm_install_dir}. Backup is preserved at #{backup_dir}. Restore the snapshot manually with: cp -a #{backup_dir}/. #{slurm_install_dir}/")
        return
      end

      # Restore the snapshot.
      unless command_runner.run_with_retries(
        "cp -a #{backup_dir}/. #{slurm_install_dir}/",
        description: "restore #{slurm_install_dir} from #{backup_dir}"
      )
        Chef::Log.error("#{log_prefix} Failed to restore #{slurm_install_dir} from #{backup_dir}. The install dir may be empty or partial. Manual recovery required: cp -a #{backup_dir}/. #{slurm_install_dir}/")
        return
      end

      # Bring services back up against the restored tree.
      return unless start_slurm_daemons(slurmdbd_in_use?)

      # Only delete the sentinel after every step above succeeded. If we
      # bailed early via `return`, the sentinel stays and the next chef run
      # can attempt the restore again.
      ::File.delete(slurm_patches_sentinel_path)
      Chef::Log.info("#{log_prefix} Slurm restore from #{backup_dir} completed; sentinel cleared")
    end

    def stop_slurm_daemons(slurmdbd_in_use)
      run_service_action(:stop, 'slurmctld', 'supervisord')
      return unless slurmdbd_in_use
      run_service_action(:stop, 'slurmdbd')
    end

    def start_slurm_daemons(slurmdbd_in_use)
      ok = run_service_action(:start, 'slurmctld', 'supervisord')
      return false unless ok

      return true unless slurmdbd_in_use
      run_service_action(:start, 'slurmdbd')
    end

    # Run a service control action via systemctl (default) or supervisorctl.
    # Returns whatever command_runner.run_with_retries returns (truthy on
    # success, false on failure after retries).
    #
    # Example: run_service_action(:start, 'slurmctld', 'supervisord')
    #          run_service_action(:start, 'clustermgtd', controller: :supervisorctl)
    def run_service_action(action, *services, controller: :systemctl)
      raise ArgumentError, 'at least one service is required' if services.empty?

      command = case controller
                when :systemctl
                  "systemctl #{action} #{services.join(' ')}"
                when :supervisorctl
                  "#{cookbook_virtualenv_path}/bin/supervisorctl #{action} #{services.join(' ')}"
                else
                  raise ArgumentError, "unsupported controller: #{controller}"
                end

      command_runner.run_with_retries(command, description: "#{action} #{services.join(' ')}")
    end

    # Parse the sentinel file produced by update_slurm_patches.rb. JSON keeps
    # native types (booleans for slurmdbd_in_use, nil for absent fields) so
    # callers can read values without manual string-casting.
    def parse_sentinel(path)
      JSON.parse(::File.read(path))
    rescue => e
      Chef::Log.warn("#{log_prefix} Could not parse sentinel #{path}: #{e.message}")
      {}
    end

    def cluster_attributes
      run_status.node['cluster']
    end

    def node_type
      cluster_attributes['node_type']
    end

    def scheduler
      cluster_attributes['scheduler']
    end

    def cookbook_virtualenv_path
      "#{cluster_attributes['system_pyenv_root']}/versions/#{cluster_attributes['python-version']}/envs/cookbook_virtualenv"
    end

    def slurm_patches_sentinel_path
      "#{cluster_attributes['base_dir']}/.slurm_patches_in_progress"
    end

    # Memoized parse of the sentinel produced by update_slurm_patches.rb.
    # Returns {} when the sentinel is missing or unreadable so callers can
    # safely chain key lookups without nil checks on the hash itself.
    def slurm_patches_metadata
      return @slurm_patches_metadata if defined?(@slurm_patches_metadata)
      @slurm_patches_metadata = ::File.exist?(slurm_patches_sentinel_path) ? parse_sentinel(slurm_patches_sentinel_path) : {}
    end

    def slurm_install_dir
      slurm_patches_metadata['slurm_install_dir']
    end

    def slurmdbd_in_use?
      slurm_patches_metadata['slurmdbd_in_use'] == true
    end

    def backup_dir
      slurm_patches_metadata['backup_dir']
    end

    def resource_succeeded?(resource_name)
      %i(updated up_to_date).include?(resource_status(resource_name))
    end

    def resource_status(resource_name)
      # Use action_collection directly (inherited from Chef::Handler)
      action_records = action_collection.filtered_collection
      record = action_records.find { |r| r.new_resource.resource_name == :execute && r.new_resource.name == resource_name }
      record ? record.status : :not_executed
    end

    def command_runner
      @command_runner ||= CommandRunner.new(log_prefix: log_prefix)
    end

    def log_prefix
      @log_prefix ||= "#{self.class.name}:"
    end
  end
end
