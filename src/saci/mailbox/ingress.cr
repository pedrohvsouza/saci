require "base64"
require "../controller"
require "../application"
require "./inbound_email"
require "./router"

# Mailbox ingress needs the raw request body, but `Saci::Params.build` drains
# `request.body` before controller actions run. We attach the buffered source
# to the request (rather than a global cache keyed by object id) so it is
# released with the request itself.
class HTTP::Request
  @saci_mailbox_raw_body : String?

  def saci_mailbox_raw_body : String?
    @saci_mailbox_raw_body
  end

  def saci_mailbox_raw_body=(value : String?) : String?
    @saci_mailbox_raw_body = value
  end
end

module Saci
  module Mailbox
    # HTTP ingress for inbound email.
    #
    # ```
    # router = Saci::Router.new.draw do |r|
    #   ...
    # end
    # Saci::Mailbox.mount(router) # POST /rails/action_mailbox/:provider/inbound_emails
    # ```
    #
    # Requests are authenticated with `SACI_MAILBOX_INGRESS_PASSWORD` (or
    # `Saci::Mailbox.ingress_password=`). Send either:
    # * `Authorization: Bearer <password>`
    # * HTTP Basic auth (the password is checked; username is ignored)
    # * `X-Saci-Mailbox-Token: <password>`
    #
    # When no password is configured, ingress is open — set one in any
    # deployed environment.
    module Ingress
      extend self

      DEFAULT_PATH = "/rails/action_mailbox/:provider/inbound_emails"

      # Keys providers commonly use for the raw MIME source in JSON or
      # form/multipart bodies.
      SOURCE_KEYS = ["email", "raw_email", "raw-email", "message", "raw", "body-mime", "RawEmail", "Content"]

      @@paths = [] of Regex
      @@mutex = Mutex.new

      def register_path(pattern : String) : Nil
        regex, _names = Saci::Router.compile(pattern)
        @@mutex.synchronize do
          @@paths << regex unless @@paths.any? { |existing| existing.source == regex.source }
        end
      end

      def mounted? : Bool
        @@mutex.synchronize { !@@paths.empty? }
      end

      def clear! : Nil
        @@mutex.synchronize { @@paths.clear }
      end

      def ingress_path?(path : String) : Bool
        regexes = @@mutex.synchronize { @@paths.dup }
        regexes.any? { |regex| regex.matches?(path) }
      end

      # Buffers the raw body for mounted ingress paths and makes it
      # replayable for `Params`. Installed once in the handler chain by
      # `Saci::Application.handlers`.
      class BodyBuffer
        include HTTP::Handler

        def call(context : HTTP::Server::Context) : Nil
          path = context.request.path || "/"
          if Ingress.ingress_path?(path)
            Ingress.capture_body(context.request)
          end
          call_next(context)
        end
      end

      # Reads at most `max_ingress_size + 1` bytes (enough to reject
      # oversized mails without unbounded allocation), stores the source on
      # the request and rewinds the body for the normal params pipeline.
      def capture_body(request : HTTP::Request) : Nil
        return if request.saci_mailbox_raw_body
        input = request.body
        return unless input
        limit = Saci::Mailbox.max_ingress_size
        remaining = limit + 1
        buffer = IO::Memory.new
        slice = Bytes.new(16 * 1024)
        while remaining > 0
          wanted = Math.min(remaining.to_i64, slice.size.to_i64).to_i32
          read = input.read(slice[0, wanted])
          break if read <= 0
          buffer.write(slice[0, read])
          remaining -= read
        end
        raw = buffer.to_s
        # JSON/form/multipart providers carry the source in a field (email,
        # RawEmail, body-mime, ...); only treat the body itself as the email
        # for raw MIME/text payloads.
        content_type = request.headers["Content-Type"]? || ""
        structured = content_type.includes?("application/json") ||
                     content_type.includes?("application/x-www-form-urlencoded") ||
                     content_type.includes?("multipart/form-data")
        request.saci_mailbox_raw_body = raw unless structured
        # Keep the regular params pipeline working (form/JSON providers).
        request.body = IO::Memory.new(raw)
      rescue
        # A broken body stream should surface as a normal 422 from the
        # controller, not crash the server handler chain.
        request.saci_mailbox_raw_body = nil
      end

      # True when the request carries valid ingress credentials (or no
      # password is configured).
      def authorized?(request : HTTP::Request) : Bool
        password = Saci::Mailbox.ingress_password
        return true if password.nil? || password.empty?

        header = request.headers["Authorization"]? || ""
        scheme = header.downcase
        if scheme.starts_with?("bearer ")
          secure_compare(header[7..].strip, password)
        elsif scheme.starts_with?("basic ")
          begin
            decoded = Base64.decode_string(header[6..].strip)
            supplied = decoded.partition(':')[2]
            secure_compare(supplied, password)
          rescue
            false
          end
        elsif token = request.headers["X-Saci-Mailbox-Token"]?
          secure_compare(token, password)
        elsif token = request.headers["X-Action-Mailbox-Token"]?
          secure_compare(token, password)
        else
          false
        end
      end

      # Extracts the raw email from (in order): the buffered body, the
      # still-unread request body (direct controller tests), provider JSON
      # or form fields, and uploaded multipart fields.
      def raw_email(request : HTTP::Request, params : Saci::Params) : String?
        if buffered = request.saci_mailbox_raw_body
          return buffered
        end
        if body = request.body
          raw = body.gets_to_end
          return raw unless raw.strip.empty?
        end
        SOURCE_KEYS.each do |key|
          if value = params[key]?
            return value unless value.strip.empty?
          end
          if file = params.file(key)
            return file.body unless file.body.strip.empty?
          end
        end
        nil
      end

      private def secure_compare(left : String, right : String) : Bool
        return false unless left.bytesize == right.bytesize
        result = 0
        left.bytes.each_with_index do |byte, index|
          result |= byte ^ right.bytes[index]
        end
        result == 0
      end
    end

    # `POST /rails/action_mailbox/:provider/inbound_emails`-style endpoint.
    #
    # Accepts a raw MIME body (`message/rfc822`, `text/plain`, ...) or a
    # provider JSON/form payload with one of the keys in
    # `Ingress::SOURCE_KEYS` (`email`, `RawEmail`, `body-mime`, ...).
    # Success is `204 No Content`; parse/routing/size failures are `422`
    # with a JSON error. Bad credentials return `401`.
    class IngressController < Saci::Controller
      def create
        unless Ingress.authorized?(request)
          render json: {error: "Unauthorized mailbox ingress"}, status: :unauthorized
          return
        end

        raw = Ingress.raw_email(request, params)
        if raw.nil? || raw.strip.empty?
          render json: {error: "No email source found (send raw MIME or an `email`/`RawEmail`/`body-mime` field)"}, status: :unprocessable_entity
          return
        end

        if raw.bytesize > Saci::Mailbox.max_ingress_size
          render json: {error: "Email source exceeds #{Saci::Mailbox.max_ingress_size} bytes"}, status: :unprocessable_entity
          return
        end

        begin
          inbound = InboundEmail.receive(raw)
          Saci::Mailbox.process!(inbound)
          head :no_content
        rescue ex : Message::ParseError
          render json: {error: "Invalid email: #{ex.message}"}, status: :unprocessable_entity
        rescue ex : NoRouteError
          render json: {error: ex.message}, status: :unprocessable_entity
        rescue ex : Exception
          render json: {error: ex.message || ex.class.name}, status: :unprocessable_entity
        end
      end
    end

    # Mounts the ingress controller on a router. Defaults to the Rails-style
    # `POST /rails/action_mailbox/:provider/inbound_emails`.
    #
    # ```
    # router = Saci::Router.new.draw { |r| r.root HomeController, :index }
    # Saci::Mailbox.mount(router)
    # # or a custom path:
    # Saci::Mailbox.mount(router, path: "/inbound/email")
    # ```
    def self.mount(router : Saci::Router, path : String = Ingress::DEFAULT_PATH) : Saci::Router
      raise ConfigurationError.new("mailbox ingress path must not be empty") if path.strip.empty?
      Ingress.register_path(path)
      # The buffer must sit in front of the router for both `listen` and
      # `TestSession`, including sessions built with a private Configuration.
      Saci::Application.add_pre_router_handler(Ingress::BodyBuffer.new)
      router.post(path, IngressController, :create)
      router
    end
  end
end
