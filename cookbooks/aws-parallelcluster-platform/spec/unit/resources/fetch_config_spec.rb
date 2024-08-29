require 'spec_helper'

describe 'fetch_config:run' do
  context "when running a HeadNode from kitchen" do
    cached(:cluster_shared_dir) { '/cluster_shared_dir' }
    cached(:cluster_shared_dir_login_nodes) { '/shared_dir_login_nodes' }
    cached(:cluster_config_path) { 'cluster_config_path' }
    cached(:previous_cluster_config_path) { 'previous_cluster_config_path' }
    cached(:cluster_config_version) { 'cluster_config_version' }
    cached(:instance_types_data_path) { 'instance_types_data_path' }
    cached(:previous_instance_types_data_path) { 'previous_instance_types_data_path' }
    cached(:chef_run) do
      runner = ChefSpec::Runner.new(
        platform: 'ubuntu', step_into: %w(fetch_config)
      ) do |node|
        node.override['kitchen'] = true
        node.override['cluster']['shared_dir'] = cluster_shared_dir
        node.override['cluster']['shared_dir_login_nodes'] = cluster_shared_dir_login_nodes
        node.override['cluster']['cluster_config_path'] = cluster_config_path
        node.override['cluster']['previous_cluster_config_path'] = previous_cluster_config_path
        node.override['cluster']['cluster_config_version'] = cluster_config_version
        node.override['cluster']['instance_types_data_path'] = instance_types_data_path
        node.override['cluster']['previous_instance_types_data_path'] = previous_instance_types_data_path
        node.override['cluster']['node_type'] = 'HeadNode'
      end
      runner.converge_dsl do
        fetch_config 'run' do
          action :run
        end
      end
    end

    it "copies data from kitchen data dir" do
      is_expected.to create_remote_file("copy fake cluster config")
        .with(path: cluster_config_path)
        .with(source: "file://#{kitchen_cluster_config_path}")

      is_expected.to create_remote_file("copy fake instance type data")
        .with(path: instance_types_data_path)
        .with(source: "file://#{kitchen_instance_types_data_path}")
    end

    it "writes the cluster config version file for compute nodes" do
      is_expected.to create_file("/cluster_shared_dir/cluster-config-version").with(
        content: cluster_config_version,
        mode: '0644',
        owner: 'root',
        group: 'root'
      )
    end

    it "writes the cluster config version file for login nodes" do
      is_expected.to create_file("/shared_dir_login_nodes/cluster-config-version").with(
        content: cluster_config_version,
        mode: '0644',
        owner: 'root',
        group: 'root'
      )
    end

    it "does not wait for cluster config version file" do
      is_expected.not_to run_execute("Wait cluster config files to be updated by the head node")
    end
  end

  %w(ComputeFleet LoginNode).each do |node_type|
    context "when running a #{node_type} from kitchen on create" do
      cached(:cluster_config_path) { 'cluster_config_path' }
      cached(:login_cluster_config_path) { 'login_cluster_config_path' }
      cached(:previous_cluster_config_path) { 'previous_cluster_config_path' }
      cached(:instance_types_data_path) { 'instance_types_data_path' }
      cached(:previous_instance_types_data_path) { 'previous_instance_types_data_path' }
      cached(:chef_run) do
        runner = ChefSpec::Runner.new(
          platform: 'ubuntu', step_into: %w(fetch_config)
        ) do |node|
          node.override['kitchen'] = true
          node.override['cluster']['cluster_config_path'] = cluster_config_path
          node.override['cluster']['login_cluster_config_path'] = login_cluster_config_path
          node.override['cluster']['node_type'] = node_type
        end
        allow(File).to receive(:exist?).with(cluster_config_path).and_return(true)
        allow(File).to receive(:exist?).with(login_cluster_config_path).and_return(true)
        runner.converge_dsl do
          fetch_config 'run' do
            action :run
            update false
          end
        end
      end

      it "does not wait for cluster config version file" do
        is_expected.not_to run_execute("Wait cluster config files to be updated by the head node")
      end

      it "reads config from shared folder" do
        is_expected.to run_ruby_block("load cluster configuration")
      end
    end
  end

  %w(ComputeFleet LoginNode).each do |node_type|
    context "when running a #{node_type} from kitchen on update" do
      cached(:cluster_shared_dir) { '/cluster_shared_dir' }
      cached(:cluster_shared_dir_login_nodes) { '/shared_dir_login_nodes' }
      cached(:cluster_config_path) { 'cluster_config_path' }
      cached(:login_cluster_config_path) { 'login_cluster_config_path' }
      cached(:previous_cluster_config_path) { 'previous_cluster_config_path' }
      cached(:cluster_config_version) { 'cluster_config_version' }
      cached(:cluster_shared_storages_mapping_path) { '/cluster_shared_storages_mapping_path' }
      cached(:cluster_previous_shared_storages_mapping_path) { '/cluster_previous_shared_storages_mapping_path' }
      cached(:instance_types_data_path) { 'instance_types_data_path' }
      cached(:previous_instance_types_data_path) { 'previous_instance_types_data_path' }
      cached(:chef_run) do
        runner = ChefSpec::Runner.new(
          platform: 'ubuntu', step_into: %w(fetch_config)
        ) do |node|
          node.override['kitchen'] = true
          node.override['cluster']['shared_dir'] = cluster_shared_dir
          node.override['cluster']['cluster_config_path'] = cluster_config_path
          node.override['cluster']['cluster_config_version'] = cluster_config_version
          node.override['cluster']['shared_storages_mapping_path'] = cluster_shared_storages_mapping_path
          node.override['cluster']['previous_shared_storages_mapping_path'] = cluster_previous_shared_storages_mapping_path
          node.override['cluster']['login_cluster_config_path'] = login_cluster_config_path
          node.override['cluster']['shared_dir_login_nodes'] = cluster_shared_dir_login_nodes
          node.override['cluster']['node_type'] = node_type
        end
        allow(File).to receive(:exist?).with(cluster_config_path).and_return(true)
        allow(FileUtils).to receive(:cp_r).with(
          cluster_shared_storages_mapping_path, cluster_previous_shared_storages_mapping_path, remove_destination: true
        ).and_return(true)
        runner.converge_dsl do
          fetch_config 'run' do
            action :run
            update true
          end
        end
      end

      it "waits for cluster config version file" do
        config_version_file = case node_type
                              when "ComputeFleet"
                                "/cluster_shared_dir/cluster-config-version"
                              when "LoginNode"
                                "/shared_dir_login_nodes/cluster-config-version"
                              else
                                raise "Unsupported node_type #{node_type}"
                              end
        is_expected.to run_bash("Wait cluster config files to be updated by the head node").with(
          code: "[[ \"$(cat #{config_version_file})\" == \"cluster_config_version\" ]] || exit 1",
          retries: 30,
          retry_delay: 15,
          timeout: 5
        )
      end

      it "reads config from shared folder" do
        is_expected.to run_ruby_block("load cluster configuration")
      end
    end
  end
end


describe 'fetch_config:share_common_dna' do
  context "when running on HeadNode from kitchen" do
    cached(:file_path) { '/tmp/common-dna.json' }
    cached(:chef_run) do
      runner = ChefSpec::Runner.new(
        platform: 'ubuntu', step_into: %w(fetch_config)
      ) do |node|
        node.override['kitchen'] = true
        node.override['cluster']['node_type'] = 'HeadNode'
        node.override['cluster']['cluster_s3_bucket'] = 'BUCKET'
        node.override['cluster']['region'] = 'REGION'
        node.override['cluster']['common_dna_s3_key'] = 'COMMON_S3_DNA_PREFIX'
        node.override['cluster']['system_pyenv_root'] = 'pyenv'
        node.override['cluster']['python-version'] = 'pyversion'
      end
      runner.converge_dsl do
        fetch_config 'share_common_dna' do
          action :share_common_dna
        end
      end
    end

    it "executes command to update HeadNode Private IP in common-dna.json file" do
      allow_any_instance_of(Object).to receive(:get_primary_ip).and_return('IP')
      is_expected.to run_execute("Update HeadNode Ip").with(command:"sed -i 's/HEAD_NODE_PRIVATE_IP/#{get_primary_ip}/g' /tmp/common-dna.json")
    end

    it "uploads common-dna.json in S3" do
      is_expected.to run_execute("upload_common_dna_to_s3").with(command: "pyenv/versions/pyversion/envs/cookbook_virtualenv/bin/aws s3api put-object" \
                         " --bucket BUCKET" \
                         " --key COMMON_S3_DNA_PREFIX" \
                         " --region REGION" \
                         " --body /tmp/common-dna.json")
    end
  end
end
