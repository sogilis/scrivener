require "excon"
require "multi_json"
require "thread"
require "uri"

module Scrivener
  class Main
    def initialize
      @api1 = Excon.new("https://api.hipchat.com")
      @api2 = Excon.new("https://api.hipchat.com")
      @auth_token = ENV["AUTH_TOKENS"]
      @last_message_time = nil
      @mutex = Mutex.new
      @room_id = nil
      @user_lookup = {}
    end

    def run
      abort("missing=AUTH_TOKENS") unless ENV["AUTH_TOKENS"]
      abort("missing=ROOMS") unless ENV["ROOMS"]
      cache_rooms
      abort("no_rooms") unless @room_id
      cache_users
      thread {
        http_loop(5) do
          check_messages
        end
      }
      http_loop(300) do
        cache_users
      end
    end

    private

    def cache_rooms
      log "cache_rooms"
      rooms = request {
        @api1.get(
          path: "/v1/rooms/list",
          expects: 200,
          query: { auth_token: @auth_token }
        )
      }
      rooms["rooms"].each do |room|
        if room["name"] == ENV["ROOMS"]
          @room_id = room["room_id"]
          log "room name=#{room["name"]} id=#{@room_id}"
        end
      end
    end

    def cache_users
      log "cache_users"
      users = request {
        @api2.get(
          path: "/v1/users/list",
          expects: 200,
          query: { auth_token: @auth_token }
        )
      }
      user_lookup = {}
      users["users"].each do |user|
        user_lookup[user["name"]] = user["mention_name"]
        log "cached full=#{user["name"]} mention=#{user["mention_name"]}"
      end
      @mutex.synchronize do
        @user_lookup = user_lookup
      end
    end

    def check_messages
      log "check_messages"
      get_messages(@room_id).each do |message|
        time = Time.parse(message["date"])

        # only process messages that we haven't already done
        next if @last_message_time && time <= @last_message_time

        # don't try to process the message if it looks too stale either
        next if time < Time.now - 20

        mentions = []
        @mutex.synchronize {
          @user_lookup.each do |full, mention|
            mentions << mention if message_mentions(message["message"], full)
          end
        }
        if mentions.size > 0
          log "post_mention users=#{mentions.join(",")}"
          message = "#{mentions.map { |u| "@" + u }.join(" ")} ^^^"
          post_message(message)
        end

        # messages are ordered by time ascending
        @last_message_time = time
      end
    end

    def get_messages(room_id)
      request {
        @api1.get(
          path: "/v1/rooms/history",
          expects: 200,
          query: {
            auth_token: @auth_token,
            date: "recent",
            room_id: room_id,
          }
        )
      }["messages"]
    end

    def http_loop(sleep)
      loop do
        begin
          sleep(sleep)
          yield
        rescue Excon::Errors::HTTPStatusError
          log "error status=#{$!.response.status} body=#{$!.response.body}"
        rescue Excon::Errors::Error
          log "error class=#{$!.class} message=#{$!.message}"
          next
        end
      end
    end

    def log(str)
      @mutex.synchronize {
        puts(str)
      }
    end

    def message_mentions(message, full)
      return true if message.index(full)

      short = full.sub(" ", "")
      return true if message.index(short) && !message.index("@" + short)

      return false
    end

    def post_message(message)
      request {
        @api1.post(
          path: "/v1/rooms/message",
          expects: 200,
          query: URI.encode_www_form({
            auth_token: @auth_token,
            room_id: @room_id,
            from: "Scrivener",
            message: message,
            notify: 1,
          }),
        )
      }
    end

    def request
      response = yield
      MultiJson.decode(response.body)
    rescue Excon::Errors::Forbidden
      log "rate_limited"
      raise
    end

    def thread
      Thread.start {
        begin
          yield
        rescue
          log "error class=#{$!.class} message=#{$!.message} backtrace=#{$!.backtrace.inspect}"
        end
      }
    end
  end
end

if __FILE__ == $0
  $stdout.sync = $stderr.sync = true
  Scrivener::Main.new.run
end
