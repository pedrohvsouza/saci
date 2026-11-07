require "./base"

module Saci
  module Mailbox
    # Raised when no route matches an inbound email.
    class NoRouteError < Error
    end

    # Raised by `Saci::Mailbox.mount` when a route is malformed.
    class ConfigurationError < Error
    end

    # Rails ActionMailbox-style routing DSL. Routes are checked in
    # registration order; the first match wins.
    #
    # ```
    # Saci::Mailbox.router = Saci::Mailbox::Router.new.draw do |r|
    #   r.route SpamMailbox, subject: /viagra/i
    #   r.route SupportMailbox, to: "support@example.com"
    #   r.route ->(inbound : Saci::Mailbox::InboundEmail) {
    #     inbound.mail.attachments.any?
    #   }, mailbox: FilesMailbox
    #   r.route all: :backup
    # end
    # ```
    #
    # Conditions:
    # * `to:` / `from:` accept a String (exact address, case-insensitive),
    #   a Regex, or an Array of Strings.
    # * `subject:` accepts a String or Regex.
    # * `all: true` (or `all: :mailbox_name`) matches every message.
    # * A block/Proc matcher receives the `InboundEmail` and returns Bool.
    #
    # Mailbox names can be classes, symbols or strings; symbols/strings are
    # resolved through the compile-time registry populated by
    # `Mailbox::Base.inherited` (`:support` -> `SupportMailbox`).
    class Router
      class Route
        getter mailbox : Base.class
        getter matcher : Proc(InboundEmail, Bool)
        getter description : String

        def initialize(@mailbox : Base.class, @matcher : Proc(InboundEmail, Bool), @description : String)
        end

        def matches?(inbound : InboundEmail) : Bool
          @matcher.call(inbound)
        end
      end

      getter routes : Array(Route)

      def initialize
        @routes = [] of Route
      end

      def draw(&block : self ->) : self
        yield self
        self
      end

      def empty? : Bool
        @routes.empty?
      end

      def clear : Nil
        @routes.clear
      end

      # Matches every inbound email (unless further conditions are added).
      def route(mailbox : Base.class, *, all : Bool = false,
                to : String | Regex | Array(String) | Nil = nil,
                from : String | Regex | Array(String) | Nil = nil,
                subject : String | Regex | Nil = nil) : Nil
        add_route(mailbox, build_matcher(all, to, from, subject))
      end

      # Adds a custom matcher block. Conditions may be combined with the
      # block (`all:` is implied when no conditions are given).
      def route(mailbox : Base.class, *, all : Bool = false,
                to : String | Regex | Array(String) | Nil = nil,
                from : String | Regex | Array(String) | Nil = nil,
                subject : String | Regex | Nil = nil,
                &block : InboundEmail -> Bool) : Nil
        combined = combine_matchers(build_matcher(all, to, from, subject), block)
        add_route(mailbox, combined)
      end

      # Rails-style keyword route:
      #
      # ```
      # router.route to: "support@example.com", mailbox: :support
      # router.route all: :backup
      # ```
      def route(*, all : Bool | Symbol | String = false,
                to : String | Regex | Array(String) | Nil = nil,
                from : String | Regex | Array(String) | Nil = nil,
                subject : String | Regex | Nil = nil,
                mailbox : Base.class | String | Symbol | Nil = nil) : Nil
        if all.is_a?(Symbol) || all.is_a?(String)
          raise ConfigurationError.new("route all: #{all.inspect} cannot be combined with mailbox:") unless mailbox.nil?
          mailbox = all
          match_all = true
        else
          match_all = all == true
        end

        if mailbox.nil?
          # Convenience: `route to: "support@example.com"` infers
          # `SupportMailbox` from the address local part.
          if to.is_a?(String) && (local = to.split("@").first?) && !local.empty?
            begin
              mailbox = Saci::Mailbox.resolve_mailbox(local)
            rescue UnknownMailboxError
              raise ConfigurationError.new(
                "route to: #{to.inspect} has no mailbox: and no mailbox named #{local.inspect} is registered"
              )
            end
          else
            raise ConfigurationError.new("route requires a mailbox (pass a class, `mailbox:`, or `all: :name`)")
          end
        end

        add_route(Saci::Mailbox.resolve_mailbox(mailbox), build_matcher(match_all, to, from, subject))
      end

      # Proc-first form:
      #
      # ```
      # router.route ->(inbound : Saci::Mailbox::InboundEmail) {
      #   inbound.mail.subject.includes?("urgent")
      # }, mailbox: UrgentMailbox
      # ```
      def route(matcher : Proc(InboundEmail, Bool), *, mailbox : Base.class | String | Symbol) : Nil
        add_route(Saci::Mailbox.resolve_mailbox(mailbox), matcher)
      end

      def route(matcher : Proc(InboundEmail, Bool), mailbox : Base.class | String | Symbol) : Nil
        add_route(Saci::Mailbox.resolve_mailbox(mailbox), matcher)
      end

      def route_for(inbound : InboundEmail) : Route?
        @routes.find { |route| route.matches?(inbound) }
      end

      def matching?(inbound : InboundEmail) : Bool
        !route_for(inbound).nil?
      end

      def mailbox_class_for(inbound : InboundEmail) : Base.class | Nil
        route_for(inbound).try(&.mailbox)
      end

      # Returns an instantiated mailbox for the first matching route.
      # Raises `NoRouteError` with the inbound headers when nothing matched.
      def mailbox_for(inbound : InboundEmail) : Base
        if route = route_for(inbound)
          route.mailbox.new(inbound)
        else
          raise NoRouteError.new(no_route_message(inbound))
        end
      end

      def mailbox_for(mail : Message) : Base
        mailbox_for(InboundEmail.build_from_message(mail))
      end

      private def add_route(mailbox : Base.class, matcher : Proc(InboundEmail, Bool)) : Nil
        @routes << Route.new(mailbox, matcher, mailbox.name)
      end

      private def combine_matchers(base : Proc(InboundEmail, Bool), extra : Proc(InboundEmail, Bool)) : Proc(InboundEmail, Bool)
        Proc(InboundEmail, Bool).new do |inbound|
          base.call(inbound) && extra.call(inbound)
        end
      end

      private def build_matcher(all : Bool,
                                to : String | Regex | Array(String) | Nil,
                                from : String | Regex | Array(String) | Nil,
                                subject : String | Regex | Nil) : Proc(InboundEmail, Bool)
        Proc(InboundEmail, Bool).new do |inbound|
          mail = inbound.mail_message
          if all
            true
          else
            # Conditions combine with AND; a route with no conditions is an
            # intentional catch-all (same behavior as `route MyMailbox`).
            matched = true
            matched = false unless to.nil? || address_matches?(to, mail.to)
            matched = false unless from.nil? || address_matches?(from, [mail.from])
            matched = false unless subject.nil? || subject_matches?(subject, mail.subject)
            matched
          end
        end
      end

      private def address_matches?(condition : String | Regex | Array(String), addresses : Array(String)) : Bool
        case condition
        when String
          addresses.any? { |address| address.downcase == condition.downcase }
        when Regex
          addresses.any? { |address| condition.matches?(address) }
        when Array(String)
          condition.any? { |candidate| addresses.any? { |address| address.downcase == candidate.downcase } }
        else
          false
        end
      end

      private def subject_matches?(condition : String | Regex, subject : String) : Bool
        case condition
        when String then subject.downcase == condition.downcase
        when Regex  then condition.matches?(subject)
        else             false
        end
      end

      private def no_route_message(inbound : InboundEmail) : String
        mail = inbound.mail_message
        from = mail.from.empty? ? "(none)" : mail.from
        to = mail.to.empty? ? "(none)" : mail.to.join(", ")
        message_id = mail.message_id.empty? ? "(none)" : mail.message_id
        "No mailbox matched inbound email #{message_id} (from: #{from}, to: #{to}, subject: #{mail.subject.inspect}). " \
        "Register one with Saci::Mailbox::Router#route, e.g. " \
        "`router.route SupportMailbox, to: \"support@example.com\"` or `router.route all: :backup`."
      end
    end
  end
end
