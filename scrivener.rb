require "excon"
require "multi_json"
require "oj"
require "thread"
require "uri"
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'

module Scrivener
  class Main
    def initialize
      @auth_token = ENV["AUTH_TOKEN"]
      @ignore_users = ENV["IGNORE_USERS"] ? ENV["IGNORE_USERS"].split(",") : []
      @mutex = Mutex.new
      @user_lookup = {}
    end

    def run
      abort("missing=AUTH_TOKEN") unless ENV["AUTH_TOKEN"]
      abort("missing=XMPP_ID") unless ENV["XMPP_ID"]
      abort("missing=XMPP_PASSWORD") unless ENV["XMPP_PASSWORD"]

      @api = Excon.new("https://api.hipchat.com")
      init_xmpp
      cache_users

      http_loop(300) do
        cache_users
      end
    end

    private

    def cache_users
      log "cache_users"
      users = request {
        @api.get(
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

    def init_xmpp
      log "init_xmpp"
      @xmpp_client = Jabber::Client.new(ENV["XMPP_ID"])
      @xmpp_muc = Jabber::MUC::SimpleMUCClient.new(@xmpp_client)

      @xmpp_client.connect
      @xmpp_client.auth(ENV["XMPP_PASSWORD"])
      @xmpp_client.send(Jabber::Presence.new.set_type(:available))

      @xmpp_muc.on_message do |time, nick, text|
        process_message(nick, text)
      end

      log "join room=#{ENV["ROOMS"] + '/' + ENV["NICK"]}"
      @xmpp_muc.join(ENV["ROOMS"] + '/' + ENV["NICK"])
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

    def process_message(nick, message)
p message
      # don't process if from an ignored user
      return if @ignore_users.include?(nick)

      mentions = []
      @mutex.synchronize {
        @user_lookup.each do |full, mention|
          mentions << mention if message_mentions(message, full)
        end
      }
      if mentions.size > 0
        log "post_mention users=#{mentions.join(",")}"
        response = "#{mentions.map { |u| "@" + u }.join(" ")} ^^^"
      # @xmpp_muc.send Jabber::Message.new(@xmpp_muc.room, response)
      end
    end

    def request
      # only allow one thread access to the connection object at any given time
      response = @mutex.synchronize {
        yield
      }
      MultiJson.decode(response.body)
    rescue Excon::Errors::Forbidden
      log "rate_limited"
      raise
    end
  end
end

if __FILE__ == $0
  $stdout.sync = $stderr.sync = true
  Scrivener::Main.new.run
end
