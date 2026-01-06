# frozen_string_literal: true

module Rack
  class MiniProfiler
    class ClientSettings

      COOKIE_NAME = "__profilin"

      BACKTRACE_DEFAULT = nil
      BACKTRACE_FULL    = 1
      BACKTRACE_NONE    = 2

      attr_accessor :disable_profiling
      attr_accessor :backtrace_level

      def initialize(env, store, start)
        @request = ::Rack::Request.new(env)
        log_it_cs("CS_INIT")
        @cookie = @request.cookies[COOKIE_NAME]
        @store = store
        @start = start
        @backtrace_level = nil
        @orig_disable_profiling = @disable_profiling = nil

        @allowed_tokens, @orig_auth_tokens = nil

        if @cookie
          found = false
          @cookie.split(",").map { |pair| pair.split("=") }.each do |k, v|
            found = true
            @orig_disable_profiling = @disable_profiling = (v == 't') if k == "dp"
            log_it_cs("CS_INIT_DISABLE_PROFILING_TRUE") if @disable_profiling
            @backtrace_level = v.to_i if k == "bt"
            @orig_auth_tokens = v.to_s.split("|") if k == "a"
            log_it_cs("CS_INIT_ORIG_AUTH_TOKENS_SET", orig_auth_tokens: @orig_auth_tokens) if k == "a"
          end
          log_it_cs("CS_INIT_NO_MEANINGFUL_COOKIE") unless found
        else
          log_it_cs("CS_INIT_NO_COOKIE")
        end

        if !@backtrace_level.nil? && (@backtrace_level == 0 || @backtrace_level > BACKTRACE_NONE)
          @backtrace_level = nil
        end

        @orig_backtrace_level = @backtrace_level
      end

      def handle_cookie(result, preserve_cookie: false)
        status, headers, _body = result

        if (MiniProfiler.config.authorization_mode == :allow_authorized && !MiniProfiler.request_authorized?)
          # this is non-obvious, don't kill the profiling cookie on errors or short requests
          # this ensures that stuff that never reaches the rails stack does not kill profiling
          if !preserve_cookie && status.to_i >= 200 && status.to_i < 300 && ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @start) > 0.1)
            log_it_cs("HANDLE_COOKIE_DISCARD_2XX_SLOW")
            discard_cookie!(headers)
          end
        else
          log_it_cs("HANDLE_COOKIE_WRITE")
          write!(headers)
        end

        result
      end

      def write!(headers)
        tokens_changed = false

        if MiniProfiler.request_authorized? && MiniProfiler.config.authorization_mode == :allow_authorized
          log_it_cs("WRITE_COOKIE_AUTHORIZED_REQUEST_TRUE")
          @allowed_tokens ||= @store.allowed_tokens
          tokens_changed = !@orig_auth_tokens || ((@allowed_tokens - @orig_auth_tokens).length > 0)
        else
          log_it_cs("WRITE_COOKIE_AUTHORIZED_REQUEST_FALSE")
        end

        if  @orig_disable_profiling != @disable_profiling ||
            @orig_backtrace_level != @backtrace_level ||
            @cookie.nil? ||
            tokens_changed

          if @cookie.nil?
            log_it_cs("WRITE_COOKIE_NO_COOKIE_SET", allowed_tokens: @allowed_tokens)
          elsif tokens_changed
            log_it_cs("WRITE_COOKIE_TOKENS_CHANGED_TRUE", allowed_tokens: @allowed_tokens, orig_auth_tokens: @orig_auth_tokens, tokens_diff: @allowed_tokens - @orig_auth_tokens)
          end

          settings = { "p" => "t" }
          settings["dp"] = "t"                  if @disable_profiling
          settings["bt"] = @backtrace_level     if @backtrace_level
          settings["a"] = @allowed_tokens.join("|") if @allowed_tokens && MiniProfiler.request_authorized?
          settings_string = settings.map { |k, v| "#{k}=#{v}" }.join(",")
          cookie = { value: settings_string, path: MiniProfiler.config.cookie_path, httponly: true }
          cookie[:secure] = true if @request.ssl?
          cookie[:same_site] = 'Lax'
          Rack::Utils.set_cookie_header!(headers, COOKIE_NAME, cookie)
        end
      end

      def discard_cookie!(headers)
        if @cookie
          Rack::Utils.delete_cookie_header!(headers, COOKIE_NAME, path: MiniProfiler.config.cookie_path)
        end
      end

      def log_it_cs(msg, data = {})
        msg = msg.to_s.ljust(40)[0,40]
        data_s = data.present? ? " data: #{data.to_json}" : ""
        body_s = ""
        if @request.path == "/mini-profiler-resources/results" && @request.post?
          id = @request.POST["id"]
          body_s = " id=#{id}"
        end
        Rails.logger.error "==== MINI_PROFILER [#{@request.ip}]: #{msg}: path: #{@request.path}#{body_s}#{data_s}"
      end

      def has_valid_cookie?
        valid_cookie = !@cookie.nil?

        if valid_cookie
          log_it_cs("HAS_VALID_COOKIE_FIRST_CHECK_TRUE")
        else
          log_it_cs("HAS_VALID_COOKIE_FIRST_CHECK_FALSE")
        end

        if (MiniProfiler.config.authorization_mode == :allow_authorized) && valid_cookie
          begin
            @allowed_tokens ||= @store.allowed_tokens
          rescue => e
            if MiniProfiler.config.storage_failure != nil
              MiniProfiler.config.storage_failure.call(e)
            end
            log_it_cs("HAS_VALID_COOKIE_SECOND_CHECK_EXCEPTION", exception: e)
          end

          valid_cookie = @allowed_tokens &&
            (Array === @orig_auth_tokens) &&
            ((@allowed_tokens & @orig_auth_tokens).length > 0)

          if valid_cookie
            log_it_cs("HAS_VALID_COOKIE_SECOND_CHECK_TRUE", allowed_tokens: @allowed_tokens, orig_auth_tokens: @orig_auth_tokens)
          else
            log_it_cs("HAS_VALID_COOKIE_SECOND_CHECK_FALSE", allowed_tokens: @allowed_tokens, orig_auth_tokens: @orig_auth_tokens)
          end
        end

        valid_cookie
      end

      def disable_profiling?
        @disable_profiling
      end

      def backtrace_full?
        @backtrace_level == BACKTRACE_FULL
      end

      def backtrace_default?
        @backtrace_level == BACKTRACE_DEFAULT
      end

      def backtrace_none?
        @backtrace_level == BACKTRACE_NONE
      end
    end
  end
end
