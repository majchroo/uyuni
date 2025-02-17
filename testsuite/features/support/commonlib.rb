# Copyright (c) 2013-2023 SUSE LLC.
# Licensed under the terms of the MIT license.

require 'tempfile'
require 'yaml'
require 'nokogiri'
require 'timeout'

# return current URL
def current_url
  driver.current_url
end

# generate temporary file on the controller
def generate_temp_file(name, content)
  Tempfile.open(name) do |file|
    file.write(content)
    return file.path
  end
end

# If we for example
#  - start a reposync in reposync/srv_sync_channels.feature
#  - then kill it in reposync/srv_wait_for_reposync.feature
#  - then restart it later on in init_clients/sle_minion.feature
# then the channel will be in an inconsistent state.
#
# This function computes a list of reposyncs to avoid killing, because they might be involved in bootstrapping.
#
# This is a safety net only, the best thing to do is to not start the reposync at all.
def compute_channels_to_leave_running
  # keep the repos needed for the auto-installation tests
  do_not_kill = CHANNEL_TO_SYNCH_BY_OS_VERSION['default']
  [get_target('sle_minion'), get_target('build_host'), get_target('ssh_minion'), get_target('rhlike_minion')].each do |node|
    next unless node
    os_version = node.os_version
    os_family = node.os_family
    next unless ['sles', 'rocky'].include?(os_family)
    os_version = os_version.split('.')[0] if os_family == 'rocky'
    log 'Can\'t build list of reposyncs to leave running' unless %w[15-SP3 15-SP4 8].include? os_version
    do_not_kill += CHANNEL_TO_SYNCH_BY_OS_VERSION[os_version]
  end
  do_not_kill.uniq
end

def count_table_items
  # count table items using the table counter component
  items_label_xpath = '//span[contains(text(), \'Items \')]'
  raise unless (items_label = find(:xpath, items_label_xpath).text)
  items_label.split('of ')[1].strip
end

def product
  _product_raw, code = get_target('server').run('rpm -q patterns-uyuni_server', check_errors: false)
  return 'Uyuni' if code.zero?
  _product_raw, code = get_target('server').run('rpm -q patterns-suma_server', check_errors: false)
  return 'SUSE Manager' if code.zero?
  raise 'Could not determine product'
end

def product_version
  product_raw, code = get_target('server').run('rpm -q patterns-uyuni_server', check_errors: false)
  m = product_raw.match(/patterns-uyuni_server-(.*)-.*/)
  return m[1] if code.zero? && !m.nil?
  product_raw, code = get_target('server').run('rpm -q patterns-suma_server', check_errors: false)
  m = product_raw.match(/patterns-suma_server-(.*)-.*/)
  return m[1] if code.zero? && !m.nil?
  raise 'Could not determine product version'
end

def use_salt_bundle
  # Use venv-salt-minion in Uyuni, or SUMA Head, 4.2 and 4.3
  product == 'Uyuni' || %w[head 4.3 4.2].include?(product_version)
end

# create salt pillar file in the default pillar_roots location
def inject_salt_pillar_file(source, file)
  dest = '/srv/pillar/' + file
  return_code = file_inject(get_target('server'), source, dest)
  raise 'File injection failed' unless return_code.zero?
  # make file readable by salt
  get_target('server').run("chgrp salt #{dest}")
  return_code
end

# WARN: It's working for /24 mask, but couldn't not work properly with others
def get_reverse_net(net)
  a = net.split('.')
  a[2] + '.' + a[1] + '.' + a[0] + '.in-addr.arpa'
end

# Repeatedly executes a block raising an exception in case it is not finished within timeout seconds
# or retries attempts, whichever comes first.
# Exception will optionally contain the specified message and the result from the last block execution, if any, in case
# report_result is set to true
#
# Implementation works around https://bugs.ruby-lang.org/issues/15886
def repeat_until_timeout(timeout: DEFAULT_TIMEOUT, retries: nil, message: nil, report_result: false)
  last_result = nil
  Timeout.timeout(timeout) do
    # HACK: Timeout.timeout might not raise Timeout::Error depending on the yielded code block
    # Pitfalls with this method have been long known according to the following articles:
    # https://rnubel.svbtle.com/ruby-timeouts
    # https://vaneyckt.io/posts/the_disaster_that_is_rubys_timeout_method
    # At the time of writing some of the problems described have been addressed.
    # However, at least https://bugs.ruby-lang.org/issues/15886 remains reproducible and code below
    # works around it by adding an additional check between loops
    start = Time.new
    attempts = 0
    while (Time.new - start <= timeout) && (retries.nil? || attempts < retries)
      last_result = yield
      attempts += 1
    end

    detail = format_detail(message, last_result, report_result)
    raise "Giving up after #{attempts} attempts#{detail}" if attempts == retries
    raise "Timeout after #{timeout} seconds (repeat_until_timeout)#{detail}"
  end
rescue Timeout::Error
  raise "Timeout after #{timeout} seconds (Timeout.timeout)#{format_detail(message, last_result, report_result)}"
end

def check_text_and_catch_request_timeout_popup?(text1, text2: nil, timeout: Capybara.default_max_wait_time)
  start_time = Time.now
  repeat_until_timeout(message: "'#{text1}' still not visible", timeout: DEFAULT_TIMEOUT) do
    while Time.now - start_time <= timeout
      return true if has_text?(text1, wait: 4)
      return true if !text2.nil? && has_text?(text2, wait: 4)
      next unless has_text?('Request has timed out', wait: 0)
      log 'Request timeout found, performing reload'
      click_button('reload the page')
      start_time = Time.now
      raise "Request timeout message still present after #{Capybara.default_max_wait_time} seconds." unless has_no_text?('Request has timed out')
    end
    return false
  end
end

def format_detail(message, last_result, report_result)
  formatted_message = "#{': ' unless message.nil?}#{message}"
  formatted_result = "#{', last result was: ' unless last_result.nil?}#{last_result}" if report_result
  "#{formatted_message}#{formatted_result}"
end

def click_button_and_wait(locator = nil, **options)
  click_button(locator, options)
  begin
    raise 'Timeout: Waiting AJAX transition (click link)' unless has_no_css?('.senna-loading', wait: 20)
  rescue StandardError, Capybara::ExpectationNotMet => e
    STDOUT.puts e.message # Skip errors related to .senna-loading element
  end
end

def click_link_and_wait(locator = nil, **options)
  click_link(locator, options)
  begin
    raise 'Timeout: Waiting AJAX transition (click link)' unless has_no_css?('.senna-loading', wait: 20)
  rescue StandardError, Capybara::ExpectationNotMet => e
    STDOUT.puts e.message # Skip errors related to .senna-loading element
  end
end

def click_link_or_button_and_wait(locator = nil, **options)
  click_link_or_button(locator, options)
  begin
    raise 'Timeout: Waiting AJAX transition (click link)' unless has_no_css?('.senna-loading', wait: 20)
  rescue StandardError, Capybara::ExpectationNotMet => e
    STDOUT.puts e.message # Skip errors related to .senna-loading element
  end
end

# Capybara Node Element extension to override click method, clicking and then waiting for ajax transition
module CapybaraNodeElementExtension
  def click
    super
    begin
      raise 'Timeout: Waiting AJAX transition (click link)' unless has_no_css?('.senna-loading', wait: 20)
    rescue StandardError, Capybara::ExpectationNotMet => e
      STDOUT.puts e.message # Skip errors related to .senna-loading element
    end
  end
end

def find_and_wait_click(*args, **options, &optional_filter_block)
  element = find(*args, options, &optional_filter_block)
  element.extend(CapybaraNodeElementExtension)
end

def suse_host?(name)
  (name.include? 'sle') || (name.include? 'opensuse') || (name.include? 'ssh')
end

def slemicro_host?(name)
  (name.include? 'slemicro') || (name.include? 'micro')
end

def rh_host?(name)
  (name.include? 'rhlike') || (name.include? 'alma') || (name.include? 'centos') || (name.include? 'liberty') || (name.include? 'oracle') || (name.include? 'rocky')
end

def deb_host?(name)
  (name.include? 'deblike') || (name.include? 'debian') || (name.include? 'ubuntu')
end

def repository_exist?(repo)
  repo_list = $api_test.channel.software.list_user_repos
  repo_list.include? repo
end

def generate_repository_name(repo_url)
  repo_name = repo_url.strip
  repo_name.sub!(%r{http:\/\/download.suse.de\/ibs\/SUSE:\/Maintenance:\/}, '')
  repo_name.sub!(%r{http:\/\/download.suse.de\/download\/ibs\/SUSE:\/Maintenance:\/}, '')
  repo_name.sub!(%r{http:\/\/download.suse.de\/download\/ibs\/SUSE:\/}, '')
  repo_name.sub!(%r{http:\/\/.*compute.internal\/SUSE:\/}, '')
  repo_name.sub!(%r{http:\/\/.*compute.internal\/SUSE:\/Maintenance:\/}, '')
  repo_name.gsub!('/', '_')
  repo_name.gsub!(':', '_')
  repo_name[0...64] # HACK: Due to the 64 characters size limit of a repository label
end

def extract_logs_from_node(node)
  os_family = node.os_family
  node.run('zypper --non-interactive install tar') if os_family =~ /^opensuse/
  node.run('journalctl > /var/log/messages', check_errors: false) # Some clients might not support systemd
  node.run("tar cfvJP /tmp/#{node.full_hostname}-logs.tar.xz /var/log/ || [[ $? -eq 1 ]]")
  `mkdir logs` unless Dir.exist?('logs')
  code = file_extract(node, "/tmp/#{node.full_hostname}-logs.tar.xz", "logs/#{node.full_hostname}-logs.tar.xz")
  raise 'Download log archive failed' unless code.zero?
end

def reportdb_server_query(query)
  "echo \"#{query}\" | spacewalk-sql --reportdb --select-mode -"
end

def get_variable_from_conf_file(host, file_path, variable_name)
  node = get_target(host)
  variable_value, return_code = node.run("sed -n 's/^#{variable_name} = \\(.*\\)/\\1/p' < #{file_path}")
  raise "Reading #{variable_name} from file on #{host} #{file_path} failed" unless return_code.zero?
  variable_value.strip!
end

def get_uptime_from_host(host)
  node = get_target(host)
  uptime, _return_code = node.run('cat /proc/uptime') # run code on node only once, to get uptime
  seconds = Float(uptime.split[0]) # return only the uptime in seconds, as a float
  minutes = (seconds / 60.0) # 60 seconds; the .0 forces a float division
  hours = (minutes / 60.0) # 60 minutes
  days = (hours / 24.0) # 24 hours
  { seconds: seconds, minutes: minutes, hours: hours, days: days }
end

def escape_regex(text)
  text.gsub(%r{([$.*\[/^])}) { |match| "\\#{match}" }
end

def get_system_id(node)
  $api_test.system.search_by_name(node.full_hostname).first['id']
end

def check_shutdown(host, time_out)
  cmd = "ping -c1 #{host}"
  repeat_until_timeout(timeout: time_out, message: 'machine didn\'t reboot') do
    _out = `#{cmd}`
    if $CHILD_STATUS.exitstatus.nonzero?
      STDOUT.puts "machine: #{host} went down"
      break
    else
      sleep 1
    end
  end
end

def check_restart(host, node, time_out)
  cmd = "ping -c1 #{host}"
  repeat_until_timeout(timeout: time_out, message: 'machine didn\'t come up') do
    _out = `#{cmd}`
    if $CHILD_STATUS.exitstatus.zero?
      STDOUT.puts "machine: #{host} network is up"
      break
    else
      sleep 1
    end
  end
  repeat_until_timeout(timeout: time_out, message: 'machine didn\'t come up') do
    _out, code = node.run('ls', check_errors: false, timeout: 10)
    if code.zero?
      STDOUT.puts "machine: #{host} ssh is up"
      break
    else
      sleep 1
    end
  end
end

# Extract the OS version and OS family
# We get these data decoding the values in '/etc/os-release'
def get_os_version(node)
  os_family_raw, code = node.run('grep "^ID=" /etc/os-release', check_errors: false)
  return nil, nil unless code.zero?

  os_family = os_family_raw.strip.split('=')[1]
  return nil, nil if os_family.nil?

  os_family.delete! '"'
  os_version_raw, code = node.run('grep "^VERSION_ID=" /etc/os-release', check_errors: false)
  return nil, nil unless code.zero?

  os_version = os_version_raw.strip.split('=')[1]
  return nil, nil if os_version.nil?

  os_version.delete! '"'
  # on SLES, we need to replace the dot with '-SP'
  os_version.gsub!(/\./, '-SP') if os_family =~ /^sles/
  STDOUT.puts "Node: #{node.hostname}, OS Version: #{os_version}, Family: #{os_family}"
  [os_version, os_family]
end

def get_gpg_keys(node, target = get_target('server'))
  os_version, os_family = get_os_version(node)
  if os_family =~ /^sles/
    # HACK: SLE 15 uses SLE 12 GPG key
    os_version = 12 if os_version =~ /^15/
    # SLE12 GPG keys don't contain service pack strings
    os_version = os_version.split('-')[0] if os_version =~ /^12/
    gpg_keys, _code = target.run("cd /srv/www/htdocs/pub/ && ls -1 sle#{os_version}*", check_errors: false)
  elsif os_family =~ /^centos/
    gpg_keys, _code = target.run("cd /srv/www/htdocs/pub/ && ls -1 #{os_family}#{os_version}* res*", check_errors: false)
  else
    gpg_keys, _code = target.run("cd /srv/www/htdocs/pub/ && ls -1 #{os_family}*", check_errors: false)
  end
  gpg_keys.lines.map(&:strip)
end

# Retrieve the value defined in the current feature scope context
def get_context(key)
  return unless $context.key?($feature_scope)

  $context[$feature_scope][key]
end

# Define or replace a key-value in the current feature scope context
def add_context(key, value)
  $context[$feature_scope] = {} unless $context.key?($feature_scope)
  $context[$feature_scope].merge!({ key => value })
end

# This function gets the system name, as displayed in systems list
# * for the usual clients, it is the full hostname, e.g. suma-41-min-sle15.tf.local
# * for the PXE booted clients, it is derived from the branch name, the hardware type,
#   and a fingerprint, e.g. example.Intel-Genuine-None-d6df84cca6f478cdafe824e35bbb6e3b
def get_system_name(host)
  case host
  # The PXE boot minion and the terminals are not directly accessible on the network,
  # therefore they are not represented by a twopence node
  when 'pxeboot_minion'
    output, _code = get_target('server').run('salt-key')
    system_name =
      output.split.find do |word|
        word =~ /example.Intel-Genuine-None-/ || word =~ /example.pxeboot-/ || word =~ /example.Intel/ || word =~ /pxeboot-/
      end
    system_name = 'pxeboot.example.org' if system_name.nil?
  when 'sle12sp5_terminal'
    output, _code = get_target('server').run('salt-key')
    system_name =
      output.split.find do |word|
        word =~ /example.sle12sp5terminal-/
      end
    system_name = 'sle12sp5terminal.example.org' if system_name.nil?
  when 'sle15sp4_terminal'
    output, _code = get_target('server').run('salt-key')
    system_name =
      output.split.find do |word|
        word =~ /example.sle15sp4terminal-/
      end
    system_name = 'sle15sp4terminal.example.org' if system_name.nil?
  when 'containerized_proxy'
    system_name = get_target('proxy').full_hostname.sub('pxy', 'pod-pxy')
  else
    node = get_target(host)
    system_name = node.full_hostname
  end
  system_name
end

# Get MAC address of system
def get_mac_address(host)
  if host == 'pxeboot_minion'
    mac = ENV['PXEBOOT_MAC']
  else
    node = get_target(host)
    output, _code = node.run('ip link show dev eth1')
    mac = output.split("\n")[1].split[1]
  end
  mac
end

# This function returns the net prefix, caching it
def net_prefix
  $net_prefix = $private_net.sub(%r{\.0+/24$}, '.') if $net_prefix.nil? && !$private_net.nil?
  $net_prefix
end

# This function tests whether a file exists on a node
def file_exists?(node, file)
  node.file_exists(file)
end

# This function tests whether a folder exists on a node
def folder_exists?(node, file)
  node.folder_exists(file)
end

# This function deletes a file from a node
def file_delete(node, file)
  node.file_delete(file)
end

# This function deletes a file from a node
def folder_delete(node, folder)
  node.folder_delete(folder)
end

# This function extracts a file from a node
def file_extract(node, remote_file, local_file)
  node.extract(remote_file, local_file, 'root', false)
end

# This function injects a file into a node
def file_inject(node, local_file, remote_file)
  node.inject(local_file, remote_file, 'root', false)
end

# This function updates the server certificate on the controller node
def update_ca(node)
  server_ip = get_target('server').public_ip
  server_name = get_target('server').full_hostname

  case node
  when 'proxy'
    command = "wget http://#{server_ip}/pub/RHN-ORG-TRUSTED-SSL-CERT -O /etc/pki/trust/anchors/RHN-ORG-TRUSTED-SSL-CERT; " \
      'update-ca-certificates;'
    get_target('proxy').run('rm /etc/pki/trust/anchors/RHN-ORG-TRUSTED-SSL-CERT', verbose: true)
    get_target('proxy').run(command, verbose: true)
  else
    # controller
    puts `rm /etc/pki/trust/anchors/*;
    wget http://#{server_ip}/pub/RHN-ORG-TRUSTED-SSL-CERT -O /etc/pki/trust/anchors/#{server_name}.cert &&
    update-ca-certificates &&
    certutil -d sql:/root/.pki/nssdb -A -t TC -n "susemanager" -i  /etc/pki/trust/anchors/#{server_name}.cert`
  end
end
