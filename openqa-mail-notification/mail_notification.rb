#!/usr/bin/ruby

require 'net/https'
require 'net/smtp'
require 'uri'
require 'json'
require 'mail'
require 'yaml'

def get_build_information(config, version, group)
  begin
    uri = URI.parse("#{config['open_qa']}api/v1/jobs?distri=#{config['distribution']}&version=#{version}&groupid=#{group}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE
    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    JSON.parse(response.body)['jobs'].last
  rescue Exception => e
    $stderr.puts "Error while fetching openQA data: #{e.inspect}"
    abort
  end
end

def modules_to_sentence(modules)
  modules.map { |m| "#{m['name']} #{m['result']}" }
end

def build_message(config, build, successful_modules, failed_modules, version, group)
  <<~MESSAGE_END
    See #{config['open_qa']}tests/overview?distri=#{config['distribution']}&version=#{version}&build=#{build}&groupid=#{group}

    #{failed_modules.length + successful_modules.length} modules, #{failed_modules.length} failed, #{successful_modules.length} successful

    Failed:
    #{failed_modules.join("\n")}

    Successful:
    #{successful_modules.join("\n")}
  MESSAGE_END
end

def send_notification(smtp_server, from, to, subject, message)
  begin
    mail = Mail.new do
      from    from
      to      to
      subject subject
      body    message
    end
    settings = { address: smtp_server, port: 25, enable_starttls_auto: false }
    settings[:domain] = ENV["HOSTNAME"] if ENV["HOSTNAME"] && !ENV["HOSTNAME"].empty?
    mail.delivery_method :smtp, settings
    mail.deliver
  rescue Exception => e
    $stderr.puts "#{smtp_server}: #{e.inspect}"
    abort
  end
end

config = YAML::load_file('config.yml')

config['versions'].each_pair do |version, group|
  build = get_build_information(config, version, group)
  last_build = DateTime.parse(build['t_finished'])
  ten_minutes_ago = DateTime.now - (10/1440.0)
  result = last_build >= ten_minutes_ago

  if result && build['state'] == 'done'
    modules = build['modules']
    successful_modules = modules.select { |m| m['result'] == 'passed' }
    failed_modules = modules.select { |m| m['result'] == 'failed' }
    successful_modules = modules_to_sentence(successful_modules)
    failed_modules = modules_to_sentence(failed_modules)

    subject = "Build #{build['result']} in openQA: #{build['name']}"
    message = build_message(config, build['settings']['BUILD'], successful_modules, failed_modules, version, group)
    to = config['to_success']
    to = config['to_failed'] unless failed_modules.empty?
    send_notification(config['smtp_server'], config['from'], to, subject, message)
  end
end
