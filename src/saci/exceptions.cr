require "html"

module Saci
  # Exceptions raised by the dispatcher that map to HTTP statuses.
  class ParameterMissing < Exception
  end

  class RoutingError < Exception
  end

  class ActionNotFound < Exception
  end

  # Default exceptions app and the global error-reporter hook.
  #
  # Rails calls `config.exceptions_app` with a Rack env for unhandled
  # exceptions; Crystal's server hands middleware the request/response pair, so
  # Saci's app signature is:
  #
  # ```
  # Saci::Exceptions::App = Proc(HTTP::Server::Context, Int32, Exception?, Nil)
  # #                                                   status   exception
  # ```
  #
  # The default app renders HTML (`public/<status>.html` when the app has
  # one, else a built-in page) or text for 400/404/422/500. It is used
  # in production for responses that would otherwise be the framework's JSON
  # error body; in development the router's detailed page wins for local
  # requests. Assign a custom callable with:
  #
  # ```
  # Saci.configure do |config|
  #   config.exceptions_app = ->(context : HTTP::Server::Context, status : Int32, ex : Exception?) {
  #     context.response.status_code = status
  #     context.response.content_type = "text/plain"
  #     context.response.print("error #{status}")
  #   }
  # end
  # ```
  module Exceptions
    alias App = Proc(HTTP::Server::Context, Int32, Exception?, Nil)

    TITLES = {
      400 => "Bad Request",
      404 => "Not Found",
      422 => "Unprocessable Entity",
      500 => "Internal Server Error",
    }

    # The built-in production error page app. HTML is selected for browsers
    # (`Accept: text/html` or `*/*`); JSON/API clients get `text/plain`.
    def self.default_app : App
      App.new do |context, status, _exception|
        render_default(context, status)
      end
    end

    def self.render_default(context : HTTP::Server::Context, status : Int32) : Nil
      status = 500 unless TITLES.has_key?(status)
      response = context.response
      response.status_code = status
      response.headers.delete("Content-Encoding")
      response.headers.delete("Content-Length")
      response.headers.delete("ETag")
      response.headers.delete("Last-Modified")
      # The page replaces whatever the action rendered; the action's CSP
      # would block the error page's own inline styles.
      response.headers.delete("Content-Security-Policy")

      title = TITLES[status]
      if Middleware.wants_html?(context.request)
        response.content_type = "text/html; charset=utf-8"
        response.print(html_for(status, context.request))
      else
        response.content_type = "text/plain; charset=utf-8"
        response.print("#{status} #{title}\n")
      end
    end

    # The app's `public/<status>.html` (the generated error pages, under
    # `config.public_file_server.root`) when it exists, else the built-in
    # page.
    def self.html_for(status : Int32, request : HTTP::Request) : String
      if page = public_page(status)
        return page
      end
      html_page(status, TITLES[status]? || TITLES[500], request)
    end

    def self.public_page(status : Int32) : String?
      path = File.join(Saci.config.public_file_server.root, "#{status}.html")
      File.file?(path) ? File.read(path) : nil
    rescue File::Error
      nil
    end

    private def self.html_page(status : Int32, title : String, request : HTTP::Request) : String
      path = HTML.escape(request.path || "/")
      <<-HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>#{status} #{HTML.escape(title)}</title>
          <style>
            body { font-family: system-ui, -apple-system, sans-serif; margin: 4rem auto; max-width: 42rem; color: #222; }
            h1 { font-size: 2rem; margin-bottom: .25rem; }
            p { color: #555; }
            code { background: #f3f3f3; padding: .15rem .35rem; border-radius: 3px; }
          </style>
        </head>
        <body>
          <h1>#{status} #{HTML.escape(title)}</h1>
          <p>Saci could not complete <code>#{HTML.escape(request.method)} #{path}</code>.</p>
          <p>The server has been notified and will look into it.</p>
        </body>
        </html>
        HTML
    end
  end

  # Optional global error reporter (`Rails.error` / Sentry hook equivalent).
  # The router calls this for unhandled server errors. Reporting failures are
  # swallowed so a broken reporter cannot break the response.
  @@error_reporter : Proc(Exception, Nil)? = nil
  @@error_reporter_mutex = Mutex.new

  def self.error_reporter : Proc(Exception, Nil)?
    @@error_reporter_mutex.synchronize { @@error_reporter }
  end

  def self.error_reporter=(reporter : Nil) : Nil
    @@error_reporter_mutex.synchronize { @@error_reporter = nil }
  end

  # Accepts callbacks whose last expression is not necessarily `Nil` (for
  # example `errors << ex`), wrapping them to keep the internal type simple.
  def self.error_reporter=(reporter : Proc(Exception, T)) : Nil forall T
    wrapped = Proc(Exception, Nil).new do |exception|
      reporter.call(exception)
      nil
    end
    @@error_reporter_mutex.synchronize { @@error_reporter = wrapped }
  end

  def self.report_error(exception : Exception) : Nil
    reporter = error_reporter
    return unless reporter
    reporter.call(exception)
  rescue
    # Error reporting must never mask the original failure.
  end
end
