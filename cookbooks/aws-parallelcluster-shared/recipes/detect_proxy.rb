# frozen_string_literal: true

#
# Cookbook:: aws-parallelcluster
# Recipe:: detect_proxy
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

# This recipe auto-detects a forward proxy server in the VPC for isolated network environments.
#
# Background:
#   When build-image runs in a private subnet with no internet access, a proxy instance
#   is deployed in the public subnet (e.g., tinyproxy on port 8888) to allowlist external
#   traffic such as OS package repos and AWS CLI downloads. The build instance's route table
#   sends all 0.0.0.0/0 traffic through this proxy instance.
#
# What this recipe does:
#   1. Gets the build instance's private IP to determine the VPC subnet prefix (e.g., "10.0")
#   2. Scans the .0 subnet (public subnet) for any host listening on port 8888 (tinyproxy)
#      - Example: build instance is 10.0.1.78, scans 10.0.0.1 through 10.0.0.254
#   3. If a proxy is found, sets HTTP/HTTPS proxy environment variables for the Chef run:
#      - http_proxy, https_proxy, HTTP_PROXY, HTTPS_PROXY → http://<proxy_ip>:8888
#      - no_proxy, NO_PROXY → excludes S3 endpoints so S3 traffic goes through VPC endpoints
#   4. If no proxy is found, does nothing — normal builds are unaffected
#
# Why explicit proxy instead of transparent:
#   The proxy instance uses tinyproxy + redsocks for transparent HTTP proxying, which works
#   for apt-get (port 80). However, transparent HTTPS proxying via redsocks is unreliable
#   (SSL_ERROR_SYSCALL during TLS handshake). Setting explicit proxy env vars makes all
#   HTTPS traffic use tinyproxy's CONNECT tunnel directly, which works correctly.
#
# The no_proxy list ensures S3 traffic bypasses the proxy and uses the S3 VPC Gateway
# Endpoint instead, since S3 downloads (cookbook, dependencies) are already accessible
# through the VPC endpoint without needing external internet access.

ruby_block 'detect and configure proxy' do
  block do
    require 'socket'
    require 'timeout'

    # Step 1: Get the instance's private IP to derive the VPC prefix
    # e.g., "10.0.1.78" → prefix "10.0"
    local_ip = node['ipaddress']
    next unless local_ip

    prefix = local_ip.split('.')[0..1].join('.')
    proxy_ip = nil

    # Step 2: Scan the .0 subnet (public subnet where proxy lives) for port 8888
    # The proxy instance runs tinyproxy on port 8888. We try each IP with a 1-second
    # TCP connect timeout. Most IPs will fail instantly (connection refused), so this
    # scan typically completes in a few seconds.
    (1..254).each do |i|
      candidate = "#{prefix}.0.#{i}"
      begin
        Timeout.timeout(1) do
          TCPSocket.new(candidate, 8888).close
          proxy_ip = candidate
        end
      rescue StandardError
        # Connection refused or timeout — not a proxy, try next IP
        next
      end
      break if proxy_ip
    end

    if proxy_ip
      proxy_url = "http://#{proxy_ip}:8888"
      region = node['cluster']['region']

      # Step 3: Build the no_proxy list
      # S3 endpoints are excluded so cookbook/dependency downloads from S3 go through
      # the S3 VPC Gateway Endpoint directly, not through the proxy.
      # Both regional (s3.{region}.amazonaws.com) and global (s3.amazonaws.com) endpoints
      # are included because some resources use the global endpoint (e.g., cloudformation-examples
      # bucket uses https://s3.amazonaws.com/cloudformation-examples/...).
      # Note: only the regional S3 endpoint is in no_proxy because the S3 VPC Gateway Endpoint
      # handles regional endpoints correctly. The global s3.amazonaws.com endpoint does NOT work
      # through the VPC Gateway Endpoint (SSL errors), so it is intentionally left out of no_proxy
      # and instead goes through the proxy which has internet access. The proxy allowlist in
      # proxy_stack.yaml must include s3.amazonaws.com for this to work.
      # IMDS (169.254.169.254) and ECS task metadata (169.254.170.2) are also excluded.
      no_proxy = "localhost,127.0.0.1,169.254.169.254,169.254.170.2,.s3.#{region}.amazonaws.com,s3.#{region}.amazonaws.com"

      Chef::Log.info("Proxy detected at #{proxy_url}, configuring environment variables")

      # Step 4: Set proxy env vars for the current Chef run
      # All subsequent Chef resources (remote_file, bash, execute, etc.) will inherit
      # these environment variables, so downloads like awscli, EFA installer, etc.
      # will automatically use the explicit proxy instead of trying direct connections.
      ENV['http_proxy'] = proxy_url
      ENV['https_proxy'] = proxy_url
      ENV['HTTP_PROXY'] = proxy_url
      ENV['HTTPS_PROXY'] = proxy_url
      ENV['no_proxy'] = no_proxy
      ENV['NO_PROXY'] = no_proxy
    else
      Chef::Log.info("No proxy detected on port 8888 in #{prefix}.0.0/24 subnet")
    end
  end
end
