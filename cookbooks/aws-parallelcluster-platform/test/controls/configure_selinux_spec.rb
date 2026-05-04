# Copyright:: 2023 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, express or implied.
# See the License for the specific language governing permissions and limitations under the License.

# Default mode: permissive — SELinux logs violations but does not block operations.
# This replaces the previous disable_selinux_spec.rb which asserted SELinux must be disabled.

control 'tag:install_selinux_configured' do
  title 'Check if SELinux is in permissive mode (default) after install'

  only_if('SELinux is only relevant on OSes that have getenforce') do
    command('which getenforce').exist?
  end

  # On OSes where SELinux is installed, verify it is in permissive mode (default).
  # Permissive mode logs violations but does not block — recommended for HPC.
  describe selinux do
    it { should be_permissive }
    it { should_not be_enforcing }
    it { should_not be_disabled }
  end unless os_properties.alinux2023? || os_properties.redhat? || os_properties.rocky? || os_properties.centos? # Because it requires reboot of the instance
end

control 'tag:testami_selinux_configured' do
  title 'Check if SELinux is in permissive mode (default) on test AMI'

  only_if('SELinux is only relevant on OSes that have getenforce') do
    command('which getenforce').exist?
  end

  describe selinux do
    it { should be_permissive }
    it { should_not be_enforcing }
    it { should_not be_disabled }
  end
end
