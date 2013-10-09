require "excon"
require "multi_json"
require "oj"
require "thread"
require "uri"
require 'xmpp4r'
require 'xmpp4r/muc/helper/simplemucclient'

# XMPP4R is tightly coupled to REXML which has terrible UTF-8 support; monkey
# patch this to avoid crazy warnings in 1.9+
require_relative "patch"

module Scrivener
  class Main
    def initialize
      @auth_token = ENV["AUTH_TOKEN"]
      @ignore_users = ENV["IGNORE_USERS"] ? ENV["IGNORE_USERS"].split(",") : []
      @rooms = ENV["ROOMS"] ? ENV["ROOMS"].split(",") : []
      @user_lookup = {}
      Jabber.warnings = true
    end

    def run
      abort("missing=AUTH_TOKEN") unless ENV["AUTH_TOKEN"]
      abort("missing=XMPP_ID") unless ENV["XMPP_ID"]
      abort("missing=XMPP_PASSWORD") unless ENV["XMPP_PASSWORD"]

      @api = Excon.new("https://api.hipchat.com")

      cache_users
      init_xmpp

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
      @user_lookup = user_lookup
    end

    def get_rooms
      rooms = request {
        @api.get(
          path: "/v1/rooms/list",
          expects: 200,
          query: { auth_token: @auth_token }
        )
      }
      rooms["rooms"].
        select { |r| !r["is_archived"] && !r["is_private"] }.
        map { |r| [r["name"], r["xmpp_jid"]] }
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
      @xmpp_client.connect
      @xmpp_client.auth(ENV["XMPP_PASSWORD"])
      @xmpp_client.send(Jabber::Presence.new.set_type(:available))

      get_rooms.each do |name, xmpp_jid|
        # if the ROOMS option has been specified, restrict joins to those rooms
        # only
        next if !@rooms.empty? && !@rooms.include?(name)

        log "join_room name=#{name} xmpp_jid=#{xmpp_jid}"
        xmpp_muc = Jabber::MUC::SimpleMUCClient.new(@xmpp_client)
        xmpp_muc.on_message do |time, nick, text|
          handle_message(xmpp_muc, nick, text)
        end
        xmpp_muc.join("#{xmpp_jid}/#{ENV["NICK"]}")
      end
    end

    def log(str)
      puts("app=scrivener " + str)
    end

    def message_mentions(message, full)
      # make sure there's a colon to the right of the name so that we don't
      # unintentionally catch off-hand mentions
      return true if message =~ /#{full}.*:/

      short = full.gsub(" ", "")
      return true if message =~ /#{short}.*:/ && !message.index("@" + short)

      # also try without dots, like 'Ricardo Chimal Jr."
      short = short.gsub(".", "")
      return true if message =~ /#{short}.*:/ && !message.index("@" + short)

      return false
    end

    def handle_message(xmpp_muc, nick, message)
      # don't process if from an ignored user
      return if @ignore_users.include?(nick)

      # don't process if not from a "known" user, we want to disclude announce
      # bots etc.
      return unless @user_lookup.include?(nick)

      mentions = []
      @user_lookup.reject { |k,v| k == nick }.each do |full, mention|
        mentions << mention if message_mentions(message, full)
      end
      if mentions.size > 0
        log "post_mention room=#{xmpp_muc.room} users=#{mentions.join(",")}"
        response = "#{mentions.map { |u| "@" + u }.join(" ")} ^^^"
        xmpp_muc.say(response)
      end
    end

    def request
      tries = 0
      begin
        tries += 1
        response = yield
        MultiJson.decode(response.body)
      rescue Excon::Errors::Forbidden
        log "rate_limited"
        raise
      rescue Excon::Errors::Error
        log "api_error class=#{$!.class} message=#{$!.message}"
        # reset the connection because we probably lost it
        @api.reset
        retry if tries < 2
        raise
      end
    end
  end
end

if __FILE__ == $0
  $stdout.sync = $stderr.sync = true
  Scrivener::Main.new.run
end
