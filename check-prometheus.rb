#!/usr/bin/env ruby

require 'sensu-plugin/check/cli'
require 'json'
require 'net/http'
require 'net/https'
require 'socket'

class Prometheus < Sensu::Plugin::Check::CLI
  option :host,
         short: '-h HOST',
         long: '--host HOST',
         description: 'Prometheus host to connect to, include port',
         required: true

  option :query,
         description: 'The prometheus query.',
         short: '-q QUERY',
         long: '--query QUERY',
         required: true

  option :greater_than,
         description: 'Change whether value is greater than or less than check',
         short: '-g',
         long: '--greater_than',
         default: false

  option :check_last,
         description: 'Check that the last value in Prometheus is greater/less than VALUE',
         short: '-l VALUE',
         long: '--last VALUE',
         default: nil

  option :concat_output,
         description: 'Include warning messages in output even if overall status is critical',
         short: '-c',
         long: '--concat_output',
         default: false,
         boolean: true

  option :short_output,
         description: 'Report only the highest status per series in output',
         short: '-s',
         long: '--short_output',
         default: false,
         boolean: true

  option :http_user,
         description: 'Basic HTTP authentication user',
         short: '-U USER',
         long: '--http-user USER',
         default: nil

  option :http_password,
         description: 'Basic HTTP authentication password',
         short: '-P PASSWORD',
         long: '--http-password USER',
         default: nil

  def initialize
    super
    @prometheus_cache = {}
  end

  def prometheus_cache(query = nil)
    # #YELLOW
    if @prometheus_cache.key?(query)
      prometheus_value = @prometheus_cache[query]
      prometheus_value if prometheus_value.size > 0
    end
  end

  # Create a prometheus url from params
  #
  #
  def prometheus_url(query = nil)
    url = "#{config[:host]}/api/v1/query"
    url = 'http://' + url unless url[0..3] == 'http'
    # #YELLOW
    url = url + "?query=#{query}" if query # rubocop:disable Style/SelfAssignment
    URI.parse(url)
  end

  def get_levels(config_param)
    values = config_param.split(',')
    i = 0
    levels = {}
    %w(warning error fatal).each do |type|
      levels[type] = values[i] if values[i]
      i += 1
    end
    levels
  end

  def get_prometheus_values(query)
    cache_value = prometheus_cache query
    return cache_value if cache_value

    url = prometheus_url(query)
    req = Net::HTTP::Get.new(url)

    # If the basic http authentication credentials have been provided, then use them
    if !config[:http_user].nil? && !config[:http_password].nil?
      req.basic_auth(config[:http_user], config[:http_password])
    end

    nethttp = Net::HTTP.new(url.host, url.port)
    if url.scheme == 'https'
      nethttp.use_ssl = true
    end
    resp = nethttp.start { |http| http.request(req) }

    data = JSON.parse(resp.body)
    @prometheus_cache[query] = []
    return unless data['status'] == 'success' # TODO
    if data['data']['result'].size > 0
      data['data']['result'].each do |d|
        labels = d['metric'].map do |key, val|
          next '' if key == '__name__'
          key + '="' + val + '"'
        end.reject(&:empty?).join(',')
        labels = '{' + labels + '}' if labels.size > 0
        target = d['metric']['__name__'] + labels
        @prometheus_cache[query] << { target: target, datapoints: [[d['value'][1].to_f, (d['value'][0] * 1000).to_i]] }
      end
      prometheus_cache query
    end
  end

  def last_prometheus_metric(query, count = 1)
    last_values = {}
    values = get_prometheus_values query
    if values
      values.each do |val|
        last = get_last_metric(val[:datapoints], count)
        last_values[val[:target]] = last
      end
    end
    last_values
  end

  def get_last_metric(values, count = 1)
    if values
      ret = []
      values_size = values.size
      count = values_size if count > values_size
      while count > 0
        values_size -= 1
        break if values[values_size].nil?
        count -= 1 if values[values_size][0]
        ret.push(values[values_size]) if values[values_size][0]
      end
      ret
    end
  end

  def greater_less
    return 'greater' if config[:greater_than]
    return 'less' unless config[:greater_than]
  end

  def check_last(query, max_values)
    last_targets = last_prometheus_metric query
    return [[], [], []] unless last_targets
    warnings = []
    criticals = []
    fatal = []
    # #YELLOW
    last_targets.each do |target_name, last|
      last_value = last.first[0]
      unless last_value.nil?
        # #YELLOW
        %w(fatal error warning).each do |type|
          next unless max_values.key?(type)
          max_value = max_values[type]
          var1 = config[:greater_than] ? last_value : max_value.to_f
          var2 = config[:greater_than] ? max_value.to_f : last_value
          if var1 > var2
            text = "The metric #{target_name} is #{last_value} that is #{greater_less} than max allowed #{max_value}"
            case type
            when 'warning'
              warnings << text
            when 'error'
              criticals << text
            when 'fatal'
              fatal << text
            else
              raise "Unknown type #{type}"
            end
            break if config[:short_output]
          end
        end
      end
    end
    [warnings, criticals, fatal]
  end

  def run
    queries = [config[:query]]
    critical_errors = []
    warnings = []
    fatals = []
    # #YELLOW
    queries.each do |query|
      if config[:check_last]
        max_values = get_levels config[:check_last]
        lt_warnings, lt_critical, lt_fatal = check_last(query, max_values)
        warnings += lt_warnings
        critical_errors += lt_critical
        fatals += lt_fatal
      end
    end
    fatals_string = fatals.size > 0 ? fatals.join("\n") : ''
    criticals_string = critical_errors.size > 0 ? critical_errors.join("\n") : ''
    warnings_string = warnings.size > 0 ? warnings.join("\n") : ''

    if config[:concat_output]
      fatals_string = fatals_string + "\n" + criticals_string if critical_errors.size > 0
      fatals_string = fatals_string + "\nPrometheus WARNING: " + warnings_string if warnings.size > 0
      criticals_string = criticals_string + "\nPrometheus WARNING: " + warnings_string if warnings.size > 0
      critical fatals_string if fatals.size > 0
      critical criticals_string if critical_errors.size > 0
      warning warnings_string if warnings.size > 0 # rubocop:disable Style/IdenticalConditionalBranches
    else
      critical fatals_string if fatals.size > 0
      critical criticals_string if critical_errors.size > 0
      warning warnings_string if warnings.size > 0 # rubocop:disable Style/IdenticalConditionalBranches
    end
    ok
  end
end
