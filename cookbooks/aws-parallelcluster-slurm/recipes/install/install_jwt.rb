# frozen_string_literal: true

#
# Cookbook:: aws-parallelcluster-slurm
# Recipe:: install_jwt
#
# Copyright:: Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the
# License. A copy of the License is located at
#
# http://aws.amazon.com/apache2.0/
#
# or in the "LICENSE.txt" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES
# OR CONDITIONS OF ANY KIND, express or implied. See the License for the specific language governing permissions and
# limitations under the License.

jwt_version = node['cluster']['jwt']['version']
jwt_url = "#{node['cluster']['jwt']['base_url']}/v#{jwt_version}.tar.gz"
jwt_tarball = "#{node['cluster']['sources_dir']}/libjwt-#{jwt_version}.tar.gz"

remote_file jwt_tarball do
  source jwt_url
  mode '0644'
  retries 3
  retry_delay 5
  checksum node['cluster']['jwt']['sha256']
  action :create_if_missing
end

jwt_dependencies 'Install jwt dependencies'

# libjwt 2.0+ builds with CMake (the autotools build was dropped upstream).
bash 'libjwt' do
  user 'root'
  group 'root'
  cwd Chef::Config[:file_cache_path]
  code <<-LIBJWT
    set -e
    tar xf #{jwt_tarball} --no-same-owner
    cd libjwt-#{jwt_version}
    mkdir build
    cd build
    cmake .. -DCMAKE_INSTALL_PREFIX=/opt/libjwt -DWITH_TESTS=OFF -DWITH_OPENSSL=ON -DWITH_GNUTLS=OFF
    make -j $(grep -c processor /proc/cpuinfo)
    make install
  LIBJWT
end unless redhat_on_docker?
