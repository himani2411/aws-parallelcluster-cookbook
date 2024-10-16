# frozen_string_literal: true

#
# Copyright:: 2013-2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

# TODO: move the logrotate configuration of the various services to the corresponding recipes/cookbooks.
logrotate_conf_dir = node['cluster']['logrotate_conf_dir']
logrotate_template_dir = 'log_rotation/'

config_files = %w(
  parallelcluster_cloud_init_log_rotation
  parallelcluster_cloud_init_output_log_rotation
  parallelcluster_supervisord_log_rotation
)

if node['cluster']['dcv_enabled'] == "login_node" && dcv_installed?
  config_files += %w(
    parallelcluster_dcv_log_rotation
  )
end

if node['cluster']["directory_service"]["generate_ssh_keys_for_users"] == 'true'
  config_files += %w(
    parallelcluster_pam_ssh_key_generator_log_rotation
  )
end

generate_logrotate_configs(config_files, logrotate_conf_dir, logrotate_template_dir)
