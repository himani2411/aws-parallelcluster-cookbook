# Use the name matching the resource type
control 'tag:install_efs_utils_installed' do
  title 'Verify that efs_utils is installed'

  only_if { !os_properties.redhat_on_docker? }

  # efs-utils is installed as a pre-built package from the EFS repo, pinned to
  # the requested version.
  describe package('amazon-efs-utils') do
    it { should be_installed }
    its('version') { should include node['cluster']['efs']['version'] }
  end

  # mount.efs reports the installed efs-utils version, e.g.
  # "/usr/sbin/mount.efs Version: 3.1.3".
  describe command('mount.efs --version') do
    its('exit_status') { should eq 0 }
    its('stdout') { should include node['cluster']['efs']['version'] }
  end

  describe file("/etc/amazon/efs/efs-utils.conf") do
    its('content') do
      should match('poll_interval_sec = 10')
    end
  end
end

control 'efs_mounted' do
  title 'Verify that an existing efs filesystem can be mounted'

  only_if { !os_properties.on_docker? }
  describe mount('/shared_dir') do
    it { should be_mounted }
    its('device') { should eq 'fs-03ad31942a4205839.efs.us-west-2.amazonaws.com:/' }
    its('type') { should eq 'nfs4' }
    its('options') { should include '_netdev' }
  end
end

control 'efs_unmounted' do
  title 'Verify that an existing efs filesystem can be unmounted'

  only_if { !os_properties.on_docker? }

  describe mount('/shared_dir') do
    it { should_not be_mounted }
  end
end
