module Saci
  # Controller authentication helpers (devise-lite conventions every app
  # hand-rolls). `Controller` is reopened here so `controller.cr` itself
  # stays untouched (same pattern as `SecureHeaders`' `skip_csp`/`csp`).
  #
  # ```
  # class ApplicationController < Saci::Controller
  #   before_action :require_login
  #
  #   memoize_current_user User
  #
  #   private def find_current_user(id : Int64) : User?
  #     User.find?(id)
  #   end
  # end
  #
  # class SessionsController < ApplicationController
  #   allow_unauthenticated_access only: [:new, :create]
  #   before_action :require_no_login, only: [:new]
  #
  #   def create
  #     if user = User.find_by?(email: params["email"]?)
  #       login(user)
  #       redirect_to session.string(:redirect_to) || "/"
  #     else
  #       render plain: "nope", status: :unauthorized
  #     end
  #   end
  # end
  # ```
  #
  # Framework-agnostic about the User class: `login` duck-types `id` (plus
  # `session_token` when the record has one), and the lookup side resolves
  # through `find_current_user` / `find_user` / `load_user` overrides, so
  # any class — `Saci::Record` models, plain classes — works.
  #
  # A note on types (why `memoize_current_user` exists): Crystal resolves
  # every instance variable to one concrete type per program. A
  # framework-level `@current_user` slot cannot name an app's `User`
  # class, so the memoized slot is generated *in your controller* by
  # `memoize_current_user`, where the type is spellable. The base
  # `current_user` (correct, resolves on every call) stays available for
  # controllers that skip the macro.
  module Auth
    # Authentication configuration (`login_path`, key names, ...).
    # Everything stored here is framework-spellable (strings/symbols).
    class Config
      # Where `require_login` sends anonymous visitors.
      property login_path : String = "/login"
      # Where `require_no_login` sends already-logged-in visitors.
      property already_logged_in_path : String = "/"
      # Session key holding the logged-in record's id.
      property session_key : Symbol = :user_id
      # Session key holding the pre-login GET target (`require_login`).
      property redirect_key : Symbol = :redirect_to
      # Session key holding the record's rolling `session_token`.
      property token_key : Symbol = :session_token

      # The globally configured finder lambda (`Saci::Auth.user_finder`).
      def user_finder
        Saci::Auth.user_finder
      end

      # Assigning a finder lambda through `configure` is not supported:
      # Crystal cannot store `Proc(Int64, YourUser?)` in framework state
      # (abstract types are rejected in proc signatures and unions alike),
      # so there is no framework-spellable slot for an app-typed callback.
      # Override `find_current_user(id)` in your `ApplicationController`
      # (e.g. `User.find?(id)`) or reopen `Saci::Auth.user_finder`
      # instead — this raises loudly so a silently-ignored finder can
      # never masquerade as a working one.
      def user_finder=(finder : T) forall T
        raise "Saci::Auth: cannot assign user_finder (#{finder.class}): " \
              "override `find_current_user(id)` in ApplicationController " \
              "(e.g. `User.find?(id)`) or reopen `Saci::Auth.user_finder` instead"
      end
    end

    @@config = Config.new
    @@mutex = Mutex.new

    def self.configure(& : Config ->) : Nil
      @@mutex.synchronize { yield @@config }
    end

    # Restores every `Config` default (spec isolation).
    def self.reset! : Nil
      @@mutex.synchronize { @@config = Config.new }
    end

    def self.login_path : String
      @@mutex.synchronize { @@config.login_path }
    end

    def self.already_logged_in_path : String
      @@mutex.synchronize { @@config.already_logged_in_path }
    end

    def self.session_key : Symbol
      @@mutex.synchronize { @@config.session_key }
    end

    def self.redirect_key : Symbol
      @@mutex.synchronize { @@config.redirect_key }
    end

    def self.token_key : Symbol
      @@mutex.synchronize { @@config.token_key }
    end

    # Default finder lambda: resolves nobody. Apps override it by
    # reopening the module (or, preferably, by overriding
    # `find_current_user` per controller, which isolates concurrent
    # apps/specs sharing one binary):
    #
    # ```
    # module Saci::Auth
    #   def self.user_finder
    #     ->(id : Int64) { User.find?(id) }
    #   end
    # end
    # ```
    def self.user_finder
      ->(id : Int64) { nil }
    end
  end

  class Controller
    # Logs `user` in, fixation-safe: the session is reset first, then the
    # record's id is stored under `Saci::Auth.session_key`. When the
    # record responds to `session_token`, its rolling token is stored too
    # (`current_user` rejects the session once the record rotates it).
    # Duck-typed: any object with `id` works.
    def login(user) : Nil
      reset_session
      case raw = user.id
      when Int
        session[Saci::Auth.session_key] = raw.to_i64
      when String
        session[Saci::Auth.session_key] = raw
      else
        session[Saci::Auth.session_key] = raw.to_s
      end
      if user.responds_to?(:session_token)
        session[Saci::Auth.token_key] = user.session_token.to_s
      end
    end

    # Logs out: full session reset.
    def logout : Nil
      reset_session
    end

    # The logged-in record, `nil` when absent (no session id, unknown id,
    # or rotated `session_token`). Resolves on every call; add
    # `memoize_current_user User` to your controller for a memoized,
    # self-validating override (one finder hit per request).
    def current_user
      resolve_current_user
    end

    def logged_in? : Bool
      !current_user.nil?
    end

    # Finder seam (override in `ApplicationController`, e.g.
    # `User.find?(id)`). The first non-nil result across the three hooks
    # wins; all three default to consulting `Saci::Auth.user_finder`, so
    # overriding any one of them — or reopening `user_finder` — is enough.
    def find_current_user(id : Int64)
      Saci::Auth.user_finder.call(id)
    end

    # Fallback finder hooks (same contract as `find_current_user`).
    def find_user(id : Int64)
      Saci::Auth.user_finder.call(id)
    end

    # Fallback finder hooks (same contract as `find_current_user`).
    def load_user(id : Int64)
      Saci::Auth.user_finder.call(id)
    end

    # Generates a memoized, self-validating `current_user` override typed
    # for `klass`, plus its private slot. A cached record is returned only
    # while its id *and* rolling token still match the session, so
    # `login`/`logout`/rotation naturally invalidate it — no sweepers:
    #
    # ```
    # class ApplicationController < Saci::Controller
    #   memoize_current_user User
    #
    #   private def find_current_user(id : Int64) : User?
    #     User.find?(id)
    #   end
    # end
    # ```
    macro memoize_current_user(klass)
      @__saci_current_user : {{klass}}? = nil

      def current_user : {{klass}}?
        if memo = @__saci_current_user
          if memo.id.to_s == session.string(Saci::Auth.session_key)
            if memo.responds_to?(:session_token)
              return memo if session.string(Saci::Auth.token_key) == memo.session_token.to_s
            else
              return memo
            end
          end
        end
        @__saci_current_user = resolve_current_user.as({{klass}}?)
      end
    end

    # Before-action guard: anonymous visitors are redirected to
    # `Saci::Auth.login_path`. For GET requests the original target is
    # remembered in `session[redirect_key]` so the login action can send
    # the user back (`redirect_to session.string(:redirect_to) || "/"`).
    private def require_login : Nil
      return if logged_in?
      if request.method == "GET"
        session[Saci::Auth.redirect_key] = request.resource
      end
      redirect_to Saci::Auth.login_path
    end

    # Before-action guard for login/signup pages: visitors that are
    # already logged in bounce to `already_logged_in_path`.
    private def require_no_login : Nil
      redirect_to Saci::Auth.already_logged_in_path if logged_in?
    end

    # Opens actions to anonymous visitors by skipping an inherited
    # `require_login` filter (thin wrapper over `skip_before_action`):
    #
    # ```
    # class SessionsController < ApplicationController
    #   allow_unauthenticated_access only: [:new, :create]
    # end
    #
    # class HealthController < ApplicationController
    #   allow_unauthenticated_access # whole controller is public
    # end
    # ```
    macro allow_unauthenticated_access(only = nil, except = nil)
      skip_before_action :require_login, only: {{only}}, except: {{except}}
    end

    private def resolve_current_user
      id = session.int(Saci::Auth.session_key)
      return nil if id.nil?
      found = find_current_user(id) || find_user(id) || load_user(id)
      return nil if found.nil?
      if found.responds_to?(:session_token)
        stored = session.string(Saci::Auth.token_key)
        return nil if stored.nil? || stored != found.session_token.to_s
      end
      found
    end
  end
end
