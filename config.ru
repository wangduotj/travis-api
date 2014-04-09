# Make sure we set that before everything
ENV['RACK_ENV'] ||= ENV['RAILS_ENV'] || ENV['ENV']
ENV['RAILS_ENV']  = ENV['RACK_ENV']

$stdout.sync = true

require 'travis/api/app'
require 'core_ext/module/load_constants'

models = Travis::Model.constants.map(&:to_s)
only   = [/^(ActiveRecord|ActiveModel|Travis|GH|#{models.join('|')})/]
skip   = ['Travis::Memory', 'GH::ResponseWrapper', 'Travis::NewRelic', 'Travis::Helpers::Legacy', 'GH::FaradayAdapter::EMSynchrony']

[Travis::Api, Travis, GH].each do |target|
  target.load_constants! :only => only, :skip => skip, :debug => false
end

# https://help.heroku.com/tickets/92756
class RackTimer
  def initialize(app)
    @app = app
  end

  def call(env)
    start_request = Time.now
    status, headers, body = @app.call(env)
    elapsed = (Time.now - start_request) * 1000
    $stdout.puts("request-id=#{env['HTTP_HEROKU_REQUEST_ID']} measure.rack-request=#{elapsed.round}ms")
    [status, headers, body]
  end
end

if ENV['SKYLIGHT_APPLICATION']
  require 'skylight'
  require 'skylight/probes/net_http'
  require 'logger'
  config = Skylight::Config.load(nil, ENV['RACK_ENV'], ENV)
  config['root'] = File.expand_path('..', __FILE__)
  config['agent.sockfile_path'] = File.expand_path('../tmp', __FILE__)
  config.logger = Logger.new(STDOUT)
  config.validate!

  class DalliProbe
    def install
      %w[get get_multi set add incr decr delete replace append prepend].each do |method_name|
        next unless Dalli::Client.method_defined?(method_name.to_sym)
        Dalli::Client.class_eval <<-EOD
          alias #{method_name}_without_sk #{method_name}
          def #{method_name}(*args, &block)
            Skylight.instrument(category: "api.memcache.#{method_name}", title: "Memcache #{method_name}") do
              #{method_name}_without_sk(*args, &block)
            end
          end
        EOD
      end
    end
  end
  Skylight::Probes.register("Dalli::Client", "dalli", DalliProbe.new)

  class RedisProbe
    def install
      ::Redis::Client.class_eval do
        alias call_without_sk call

        def call(command_parts, &block)
          command   = command_parts[0].upcase

          opts = {
            category: "api.redis.#{command.downcase}",
            title:    "Redis #{command}",
            annotations: {
              command:   command.to_s
            }
          }

          Skylight.instrument(opts) do
            call_without_sk(command_parts, &block)
          end
        end
      end
    end
  end
  Skylight::Probes.register("Redis", "redis", RedisProbe.new)

  Skylight.start!(config)

  use Skylight::Middleware
end

use RackTimer
run Travis::Api::App.new
