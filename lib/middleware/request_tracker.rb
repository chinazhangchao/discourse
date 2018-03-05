# frozen_string_literal: true

require_dependency 'middleware/anonymous_cache'

class Middleware::RequestTracker

  @@detailed_request_loggers = nil

  # register callbacks for detailed request loggers called on every request
  # example:
  #
  # Middleware::RequestTracker.detailed_request_logger(->|env, data| do
  #   # do stuff with env and data
  # end
  def self.register_detailed_request_logger(callback)

    unless @patched_instrumentation
      require_dependency "method_profiler"
      MethodProfiler.patch(PG::Connection, [
        :exec, :async_exec, :exec_prepared, :send_query_prepared, :query
      ], :sql)

      MethodProfiler.patch(Redis::Client, [
        :call, :call_pipeline
      ], :redis)
      @patched_instrumentation = true
    end

    (@@detailed_request_loggers ||= []) << callback
  end

  def self.unregister_detailed_request_logger(callback)
    @@detailed_request_loggers.delete callback

    if @@detailed_request_loggers.length == 0
      @detailed_request_loggers = nil
    end

  end

  def initialize(app, settings = {})
    @app = app
  end

  def self.log_request_on_site(data, host)
    RailsMultisite::ConnectionManagement.with_hostname(host) do
      log_request(data)
    end
  end

  def self.log_request(data)
    status = data[:status]
    track_view = data[:track_view]

    if track_view
      if data[:is_crawler]
        ApplicationRequest.increment!(:page_view_crawler)
      elsif data[:has_auth_cookie]
        ApplicationRequest.increment!(:page_view_logged_in)
        ApplicationRequest.increment!(:page_view_logged_in_mobile) if data[:is_mobile]
      else
        ApplicationRequest.increment!(:page_view_anon)
        ApplicationRequest.increment!(:page_view_anon_mobile) if data[:is_mobile]
      end
    end

    ApplicationRequest.increment!(:http_total)

    if status >= 500
      ApplicationRequest.increment!(:http_5xx)
    elsif data[:is_background]
      ApplicationRequest.increment!(:http_background)
    elsif status >= 400
      ApplicationRequest.increment!(:http_4xx)
    elsif status >= 300
      ApplicationRequest.increment!(:http_3xx)
    elsif status >= 200 && status < 300
      ApplicationRequest.increment!(:http_2xx)
    end

  end

  def self.get_data(env, result, timing)
    status, headers = result
    status = status.to_i

    helper = Middleware::AnonymousCache::Helper.new(env)
    request = Rack::Request.new(env)

    env_track_view = env["HTTP_DISCOURSE_TRACK_VIEW"]
    track_view = status == 200
    track_view &&= env_track_view != "0" && env_track_view != "false"
    track_view &&= env_track_view || (request.get? && !request.xhr? && headers["Content-Type"] =~ /text\/html/)
    track_view = !!track_view

    {
      status: status,
      is_crawler: helper.is_crawler?,
      has_auth_cookie: helper.has_auth_cookie?,
      is_background: request.path =~ /^\/message-bus\// || request.path == /\/topics\/timings/,
      is_mobile: helper.is_mobile?,
      track_view: track_view,
      timing: timing
    }

  end

  def log_request_info(env, result, info)

    # we got to skip this on error ... its just logging
    data = self.class.get_data(env, result, info) rescue nil
    host = RailsMultisite::ConnectionManagement.host(env)

    if data
      if result && (headers = result[1])
        headers["X-Discourse-TrackView"] = "1" if data[:track_view]
      end

      if @@detailed_request_loggers
        @@detailed_request_loggers.each { |logger| logger.call(env, data) }
      end

      log_later(data, host)
    end

  end

  def call(env)
    result = nil

    if rate_limit(env)
      result = [429, {}, ["Slow down, too Many Requests from this IP Address"]]
      return result
    end

    env["discourse.request_tracker"] = self
    MethodProfiler.start if @@detailed_request_loggers
    result = @app.call(env)
    info = MethodProfiler.stop if @@detailed_request_loggers
    result
  ensure
    log_request_info(env, result, info) unless env["discourse.request_tracker.skip"]
  end

  PRIVATE_IP = /^(127\.)|(192\.168\.)|(10\.)|(172\.1[6-9]\.)|(172\.2[0-9]\.)|(172\.3[0-1]\.)|(::1$)|([fF][cCdD])/

  def is_private_ip?(ip)
    ip = IPAddr.new(ip) rescue nil
    !!(ip && ip.to_s.match?(PRIVATE_IP))
  end

  def rate_limit(env)

    if (
      GlobalSetting.max_requests_per_ip_mode == "block" ||
      GlobalSetting.max_requests_per_ip_mode == "warn" ||
      GlobalSetting.max_requests_per_ip_mode == "warn+block"
    )

      ip = Rack::Request.new(env).ip

      if !GlobalSetting.max_requests_rate_limit_on_private
        return false if is_private_ip?(ip)
      end

      limiter10 = RateLimiter.new(
        nil,
        "global_ip_limit_10_#{ip}",
        GlobalSetting.max_requests_per_ip_per_10_seconds,
        10,
        global: true
      )

      limiter60 = RateLimiter.new(
        nil,
        "global_ip_limit_60_#{ip}",
        GlobalSetting.max_requests_per_ip_per_10_seconds,
        10,
        global: true
      )

      type = 10
      begin
        limiter10.performed!
        type = 60
        limiter60.performed!
      rescue RateLimiter::LimitExceeded
        if (
          GlobalSetting.max_requests_per_ip_mode == "warn" ||
          GlobalSetting.max_requests_per_ip_mode == "warn+block"
        )
          Rails.logger.warn("Global IP rate limit exceeded for #{ip}: #{type} second rate limit, uri: #{env["REQUEST_URI"]}")
          !(GlobalSetting.max_requests_per_ip_mode == "warn")
        else
          true
        end
      end
    end
  end

  def log_later(data, host)
    Scheduler::Defer.later("Track view", _db = nil) do
      self.class.log_request_on_site(data, host)
    end
  end

end