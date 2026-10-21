require "http/server"
require "http/server/handler"

module Saci
  # HTTP middleware (the ActionDispatch / Rack-middleware equivalent).
  #
  # A middleware is a normal Crystal `HTTP::Handler`: it can inspect/modify the
  # request and response and must either finish the response itself or call
  # `call_next(context)` to continue down the chain. The terminal handler is
  # always the router (`Saci::Handler`).
  #
  # ```
  # Saci.configure do |config|
  #   config.middleware.use MyAuthHandler.new(secret: ENV["SECRET"])
  #   config.middleware.use TimingHandler, header: "X-Timing"
  #   config.middleware.insert_before Saci::Middleware::Static, RequestId.new
  #   config.middleware.swap Saci::Middleware::Compression, MyCompressor.new
  #   config.middleware.delete Saci::Middleware::HostAuthorization
  # end
  # ```
  #
  # `use Class, **options` is compiled into `Class.new(**options)`, so every
  # option is a normal Crystal named argument. Crystal cannot splat a runtime
  # `Hash` into keyword arguments; `use Class, options_hash` instead calls
  # `Class.new(options_hash)` and works with a matching
  # `initialize(options : Hash(K, V))`. The contract is: pass an `HTTP::Handler`
  # instance, or a class with an `initialize(**options)` /
  # `initialize(options : Hash(K, V))` matching the call site.
  module Middleware
    # Built-in middleware that can be disabled at runtime include this module.
    # `Saci::Middleware::Stack#build(terminal, skip_disabled: true)` omits
    # disabled entries without removing them from the stack, so they remain
    # valid targets for `insert_before` / `insert_after` / `swap`.
    module Conditional
      abstract def enabled? : Bool
    end

    # Insert/remove/reorder HTTP handlers before the terminal router.
    #
    # The stack stores instances, never classes, so middleware can keep state.
    # Entries are linked into a single `HTTP::Handler` chain by `#build`.
    class Stack
      getter entries : Array(HTTP::Handler)

      def initialize(entries : Array(HTTP::Handler) = [] of HTTP::Handler)
        @entries = entries.dup
      end

      # Appends an already-instantiated handler.
      def use(handler : HTTP::Handler) : self
        @entries << handler
        self
      end

      # Appends `klass.new(**options)` (compile-time keyword expansion).
      def use(klass : T.class, **options) forall T
        @entries << klass.new(**options).as(HTTP::Handler)
        self
      end

      # Appends `klass.new(options)` for middleware whose constructor takes a
      # runtime options hash. The hash keeps its concrete type, so this works
      # whenever the constructor accepts that exact hash type.
      def use(klass : T.class, options : Hash(K, V)) : self forall T, K, V
        @entries << klass.new(options).as(HTTP::Handler)
        self
      end

      # Inserts an instance immediately before the first handler of *target*'s
      # class (subclasses match too).
      def insert_before(target : T.class, handler : HTTP::Handler) forall T
        @entries.insert(index_of!(target), handler)
        self
      end

      # Inserts `handler` immediately before a specific instance.
      def insert_before(target : HTTP::Handler, handler : HTTP::Handler) : self
        @entries.insert(index_of_instance!(target), handler)
        self
      end

      def insert_before(target : T.class, klass : U.class, **options) forall T, U
        insert_before(target, klass.new(**options).as(HTTP::Handler))
      end

      def insert_before(target : T.class, klass : U.class, options : Hash(K, V)) : self forall T, U, K, V
        insert_before(target, klass.new(options).as(HTTP::Handler))
      end

      # Inserts a handler immediately after the target.
      def insert_after(target : T.class, handler : HTTP::Handler) forall T
        @entries.insert(index_of!(target) + 1, handler)
        self
      end

      def insert_after(target : HTTP::Handler, handler : HTTP::Handler) : self
        @entries.insert(index_of_instance!(target) + 1, handler)
        self
      end

      def insert_after(target : T.class, klass : U.class, **options) forall T, U
        insert_after(target, klass.new(**options).as(HTTP::Handler))
      end

      def insert_after(target : T.class, klass : U.class, options : Hash(K, V)) : self forall T, U, K, V
        insert_after(target, klass.new(options).as(HTTP::Handler))
      end

      # Replaces the first handler of *target*'s class with *handler*.
      def swap(target : T.class, handler : HTTP::Handler) forall T
        @entries[index_of!(target)] = handler
        self
      end

      def swap(target : HTTP::Handler, handler : HTTP::Handler) : self
        @entries[index_of_instance!(target)] = handler
        self
      end

      def swap(target : T.class, klass : U.class, **options) forall T, U
        swap(target, klass.new(**options).as(HTTP::Handler))
      end

      def swap(target : T.class, klass : U.class, options : Hash(K, V)) : self forall T, U, K, V
        swap(target, klass.new(options).as(HTTP::Handler))
      end

      # Removes the first handler of *target*'s class. Returns it, or `nil`
      # when no such handler is present.
      def delete(target : T.class) : HTTP::Handler? forall T
        if index = @entries.index { |entry| entry.is_a?(T) }
          @entries.delete_at(index)
        end
      end

      def delete(target : HTTP::Handler) : HTTP::Handler?
        if index = @entries.index { |entry| entry.same?(target) }
          @entries.delete_at(index)
        end
      end

      # Returns a copy of the handlers, optionally omitting disabled built-ins.
      # Filtering (instead of deleting) keeps insert targets available even
      # when a feature is currently off.
      def handlers(*, skip_disabled : Bool = false) : Array(HTTP::Handler)
        @entries.select do |handler|
          !(skip_disabled && handler.is_a?(Conditional) && !handler.enabled?)
        end
      end

      # Links every enabled handler plus *terminal* and returns the first one.
      # Existing `next` links are overwritten, so a stack can be rebuilt (for
      # example after a reload) without leaking references to old handlers.
      def build(terminal : HTTP::Handler, *, skip_disabled : Bool = false) : HTTP::Handler
        chain = handlers(skip_disabled: skip_disabled) + [terminal.as(HTTP::Handler)]
        chain.each_with_index do |handler, index|
          handler.next = index + 1 < chain.size ? chain[index + 1] : nil
        end
        chain.first
      end

      def clear : self
        @entries.clear
        self
      end

      def size : Int32
        @entries.size
      end

      def empty? : Bool
        @entries.empty?
      end

      def each(& : HTTP::Handler ->) : Nil
        @entries.each { |handler| yield handler }
      end

      def to_a : Array(HTTP::Handler)
        @entries.dup
      end

      private def index_of!(target : T.class) : Int32 forall T
        @entries.index { |entry| entry.is_a?(T) } ||
          raise ArgumentError.new("middleware #{T} is not in the stack")
      end

      private def index_of_instance!(target : HTTP::Handler) : Int32
        @entries.index { |entry| entry.same?(target) } ||
          raise ArgumentError.new("middleware instance is not in the stack")
      end
    end

    # Appends *value* to the response's `Vary` header without duplicating it.
    def self.vary(response : HTTP::Server::Response, value : String) : Nil
      existing = response.headers["Vary"]?
      values = existing ? existing.split(',').map(&.strip).reject(&.empty?) : [] of String
      unless values.any? { |entry| entry.downcase == value.downcase }
        values << value
      end
      response.headers["Vary"] = values.join(", ")
    end

    # True for requests that originate on the local machine (used to keep the
    # detailed development error page local unless explicitly enabled).
    def self.local_request?(request : HTTP::Request) : Bool
      host = request.headers["Host"]?
      return true unless host
      if host.starts_with?("[") && (close = host.index(']'))
        host = host[1...close]
      else
        host = host.split(':').first
      end
      {"localhost", "127.0.0.1", "::1", "0.0.0.0"}.includes?(host.downcase)
    end

    # Small response helper shared by middleware. Sets the status, content type
    # and body; callers do not need to remember the `Content-Length` dance.
    def self.respond_text(response : HTTP::Server::Response, status : Int32, body : String,
                          content_type : String = "text/plain; charset=utf-8") : Nil
      response.status_code = status
      response.content_type = content_type
      response.headers["Content-Length"] = body.bytesize.to_s
      response.print(body)
    end

    # True when the request's `Accept` header prefers HTML (or does not
    # express a preference). Used by the default error pages.
    def self.wants_html?(request : HTTP::Request) : Bool
      accept = request.headers["Accept"]?
      return true unless accept
      accept = accept.downcase
      return false if accept.includes?("application/json")
      accept.includes?("text/html") || accept.includes?("*/*") || accept.strip.empty?
    end
  end
end

require "./middleware/net"
require "./middleware/cors"
require "./middleware/host_authorization"
require "./middleware/remote_ip"
require "./middleware/static"
require "./middleware/compression"
require "./middleware/health_check"
require "./middleware/request_body_limit"
require "./middleware/ssl"
require "./middleware/show_exceptions"
