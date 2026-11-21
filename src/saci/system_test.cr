require "base64"
require "file_utils"
require "http/client"
require "http/web_socket"
require "json"
require "socket"

module Saci
  # Browser-driven system tests: boots the real router over HTTP and
  # drives a headless Chrome/Chromium through the DevTools protocol, with
  # a Capybara-flavored DSL.
  #
  # ```
  # Saci::SystemTest.serve(router) do |page|
  #   page.visit "/login"
  #   page.fill_in "Email", with: "ada@example.com"
  #   page.fill_in "Password", with: "secret123"
  #   page.click_on "Sign in"
  #   page.assert_text "Welcome"
  #   page.assert_selector "h1"
  # end
  # ```
  #
  # Chrome comes from `CHROME_BIN` or the usual `google-chrome` /
  # `chromium` commands. `SystemTest.available?` tells specs whether to
  # run or mark the example pending. Each test launches one browser; use
  # `Saci::SystemTest.serve` so it is closed even when an assertion fails.
  #
  # The implementation uses `Runtime.evaluate` for most DOM queries and
  # the DevTools DOM domain only to set file inputs. Native JS dialogs
  # (`alert`, `confirm`, `prompt`) are accepted automatically so they do
  # not block `click_on`; call `dismiss_dialog` before the action to
  # dismiss the next one.
  class SystemTest
    class Error < Exception
    end

    DEFAULT_TIMEOUT = 5.seconds

    @scope : String? = nil
    @closed : Bool = false
    @id : Int32 = 0
    @messages : Channel(JSON::Any)
    @next_dialog_accept : Bool = true
    @stderr : IO::Memory
    @profile : String
    @port : Int32
    @process : Process
    @socket : HTTP::WebSocket

    getter base_url : String
    getter timeout : Time::Span
    # Message of the most recent native JS dialog, if any.
    getter last_dialog_message : String?

    # `CHROME_BIN`, then the usual Chrome/Chromium executables.
    def self.browser : String?
      if path = ENV["CHROME_BIN"]?
        return path unless path.empty?
      end
      %w(google-chrome google-chrome-stable chromium chromium-browser chrome).each do |name|
        if path = Process.find_executable(name)
          return path
        end
      end
      mac = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
      File::Info.executable?(mac) ? mac : nil
    end

    def self.available? : Bool
      !browser.nil?
    end

    # Boots *router* on an ephemeral port and yields a browser session.
    def self.serve(router : Router, host : String = "127.0.0.1", port : Int32 = 0,
                   config : Configuration = Saci.config, headless : Bool = true,
                   timeout : Time::Span = DEFAULT_TIMEOUT, & : SystemTest ->) : Nil
      session = TestSession.new(router, host, port, config)
      page = new("http://#{session.host}:#{session.port}", headless: headless, timeout: timeout)
      begin
        yield page
      ensure
        page.close
        session.close
      end
    end

    def initialize(@base_url : String, headless : Bool = true, timeout : Time::Span = DEFAULT_TIMEOUT,
                   browser : String? = nil, window_size : String = "1280,900")
      @timeout = timeout
      @id = 0
      @messages = Channel(JSON::Any).new(256)
      @stderr = IO::Memory.new
      executable = browser || self.class.browser || raise Error.new("Chrome/Chromium not found. Set CHROME_BIN.")
      @profile = File.join(Dir.tempdir, "saci-chrome-#{Process.pid}-#{Random::Secure.hex(4)}")
      Dir.mkdir_p(@profile)
      @port = free_port
      args = [
        "--headless=new",
        "--no-sandbox",
        "--disable-gpu",
        "--disable-dev-shm-usage",
        "--hide-scrollbars",
        "--mute-audio",
        "--no-first-run",
        "--no-default-browser-check",
        "--disable-background-networking",
        "--disable-extensions",
        "--window-size=#{window_size}",
        "--remote-debugging-port=#{@port}",
        "--user-data-dir=#{@profile}",
        "about:blank",
      ]
      @process = Process.new(executable, args: args, output: Process::Redirect::Close, error: Process::Redirect::Pipe)
      spawn { drain_stderr }
      @socket = HTTP::WebSocket.new(URI.parse(wait_for_page_ws))
      spawn { read_messages }
      command("Page.enable")
    end

    # Navigates to *path* (or an absolute URL) and waits for the document.
    def visit(path : String) : Nil
      url = if path.starts_with?("http://") || path.starts_with?("https://")
              path
            else
              "#{base_url}#{path.starts_with?('/') ? path : "/#{path}"}"
            end
      command("Page.navigate", params: JSON.parse({"url" => url}.to_json))
      wait_for_load
    end

    # Clicks a CSS selector, or a link/button whose text contains *target*.
    def click_on(target : String) : Nil
      clicked = evaluate_bool(<<-JS)
      (() => {
        const root = #{scope_js};
        if (!root) return false;
        let el = null;
        try { el = root.querySelector(#{target.to_json}); } catch (_) {}
        if (!el) {
          const candidates = [...root.querySelectorAll('a,button,input[type="submit"],input[type="button"],[role="button"]')];
          const wanted = #{target.to_json};
          el = candidates.find(node => ((node.innerText || node.value || "").trim() === wanted)) ||
               candidates.find(node => ((node.innerText || node.value || "").includes(wanted)));
        }
        if (!el) return false;
        el.click();
        return true;
      })()
      JS
      raise Error.new("No link or button matching #{target.inspect}") unless clicked
      sleep 50.milliseconds
      wait_for_load
    end

    # Fills an input/textarea/select found by label text, name, id or
    # placeholder.
    def fill_in(field : String, with value : String) : Nil
      filled = evaluate_bool(<<-JS)
      (() => {
        const el = #{find_field_js(field)};
        if (!el) return false;
        el.focus();
        el.value = #{value.to_json};
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
      JS
      raise Error.new("No field matching #{field.inspect}") unless filled
    end

    def check(field : String) : Nil
      toggle_checkbox(field, true)
    end

    def uncheck(field : String) : Nil
      toggle_checkbox(field, false)
    end

    def choose(field : String) : Nil
      chosen = evaluate_bool(<<-JS)
      (() => {
        const el = #{find_field_js(field, "input[type=radio]", "input[type=radio]")};
        if (!el) return false;
        el.checked = true;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
      JS
      raise Error.new("No radio matching #{field.inspect}") unless chosen
    end

    def select_option(field : String, with value : String) : Nil
      selected = evaluate_bool(<<-JS)
      (() => {
        const el = #{find_field_js(field, "select", "select")};
        if (!el) return false;
        el.value = #{value.to_json};
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return el.value === #{value.to_json};
      })()
      JS
      raise Error.new("No option #{value.inspect} for #{field.inspect}") unless selected
    end

    # Attaches the file at *path* to a file input found by label text,
    # name, id or placeholder.
    #
    # Uses `DOM.setFileInputFiles`. When the browser cannot read *path*
    # (sandboxed browsers such as the Chromium snap see a private `/tmp`),
    # it falls back to assigning a `File` through `DataTransfer`.
    def attach_file(field : String, path : String) : Nil
      absolute = File.expand_path(path)
      raise Error.new("File not found: #{path}") unless File.file?(absolute)

      marker = "saci-file-#{Random::Secure.hex(6)}"
      marked = evaluate_bool(<<-JS)
      (() => {
        const el = #{find_field_js(field, "input[type=file]", "input[type=file]")};
        if (!el) return false;
        el.setAttribute("data-saci-file", #{marker.to_json});
        return true;
      })()
      JS
      raise Error.new("No file field matching #{field.inspect}") unless marked

      selector = %([data-saci-file="#{marker}"])
      begin
        document = command("DOM.getDocument", params: JSON.parse({"depth" => 0}.to_json))
        root = document["root"]? || raise Error.new("DOM.getDocument returned no root")
        root_id = root["nodeId"]?.try(&.as_i64) || raise Error.new("DOM.getDocument returned no node id")
        node = command("DOM.querySelector", params: JSON.parse({
          "nodeId"   => root_id,
          "selector" => selector,
        }.to_json))
        node_id = node["nodeId"]?.try(&.as_i64) || 0
        raise Error.new("No file field matching #{field.inspect}") if node_id == 0
        command("DOM.setFileInputFiles", params: JSON.parse({
          "nodeId" => node_id,
          "files"  => [absolute],
        }.to_json))

        expected = File.size(absolute)
        unless file_input_size(selector) == expected
          fill_file_input_via_data_transfer(field, absolute)
          unless file_input_size(selector) == expected
            raise Error.new("Could not attach #{path.inspect} to #{field.inspect}")
          end
        end
      ensure
        begin
          evaluate_bool(<<-JS)
          (() => {
            const el = document.querySelector(#{selector.to_json});
            if (!el) return false;
            el.removeAttribute("data-saci-file");
            return true;
          })()
          JS
        rescue
        end
      end
    end

    # Accepts the next native JS dialog. Dialogs are accepted by default;
    # this only matters after `dismiss_dialog`.
    def accept_dialog : Nil
      @next_dialog_accept = true
    end

    # Dismisses the next native JS dialog, so `confirm` returns false and
    # `alert`/`prompt` close. One-shot: later dialogs are accepted again.
    # Call it before the action that opens the dialog.
    def dismiss_dialog : Nil
      @next_dialog_accept = false
    end

    # Runs the block with selectors rooted at *selector*.
    def within(selector : String, & : ->) : Nil
      previous = @scope
      @scope = selector
      begin
        yield
      ensure
        @scope = previous
      end
    end

    def assert_text(text : String, timeout : Time::Span = @timeout) : Nil
      wait_until(timeout, "text #{text.inspect}") { text_present?(text) }
    end

    def assert_no_text(text : String, timeout : Time::Span = @timeout) : Nil
      wait_until(timeout, "text #{text.inspect} to disappear") { !text_present?(text) }
    end

    def assert_selector(selector : String, text : String? = nil, timeout : Time::Span = @timeout) : Nil
      wait_until(timeout, "selector #{selector.inspect}") { selector_present?(selector, text) }
    end

    def assert_no_selector(selector : String, timeout : Time::Span = @timeout) : Nil
      wait_until(timeout, "selector #{selector.inspect} to disappear") { !selector_present?(selector, nil) }
    end

    def has_text?(text : String) : Bool
      text_present?(text)
    end

    def has_selector?(selector : String, text : String? = nil) : Bool
      selector_present?(selector, text)
    end

    def current_url : String
      evaluate_string("window.location.href")
    end

    def current_path : String
      evaluate_string("window.location.pathname")
    end

    def title : String
      evaluate_string("document.title")
    end

    def page_source : String
      evaluate_string("document.documentElement ? document.documentElement.outerHTML : ''")
    end

    # Evaluates JavaScript and returns its JSON value.
    def execute_script(script : String) : JSON::Any
      evaluate(script)["value"]? || JSON::Any.new(nil)
    end

    # Saves a PNG screenshot and returns its path.
    def screenshot(path : String) : String
      result = command("Page.captureScreenshot", params: JSON.parse({"format" => "png"}.to_json))
      encoded = result["data"]?.try(&.as_s) || raise Error.new("Screenshot did not return data")
      File.write(path, Base64.decode(encoded))
      path
    end

    def close : Nil
      return if @closed
      @closed = true
      begin
        @socket.close
      rescue
      end
      begin
        @messages.close
      rescue
      end
      begin
        @process.terminate
        @process.wait
      rescue
      end
      FileUtils.rm_rf(@profile)
    end

    # --- internals ---------------------------------------------------

    private def toggle_checkbox(field : String, checked : Bool) : Nil
      changed = evaluate_bool(<<-JS)
      (() => {
        const el = #{find_field_js(field, "input[type=checkbox]", "input[type=checkbox]")};
        if (!el) return false;
        el.checked = #{checked};
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
      JS
      raise Error.new("No checkbox matching #{field.inspect}") unless changed
    end

    # Size of the file currently selected in the input matching *selector*,
    # or -1 when the input is empty.
    private def file_input_size(selector : String) : Int64
      result = evaluate(<<-JS)
      (() => {
        const el = document.querySelector(#{selector.to_json});
        return el && el.files && el.files.length > 0 ? el.files[0].size : -1;
      })()
      JS
      result["value"]?.try(&.as_i64?) || -1_i64
    end

    # In-page fallback for browsers that cannot read the host's temp files.
    private def fill_file_input_via_data_transfer(field : String, absolute : String) : Nil
      encoded = Base64.strict_encode(File.read(absolute))
      filename = File.basename(absolute)
      attached = evaluate_bool(<<-JS)
      (() => {
        const el = #{find_field_js(field, "input[type=file]", "input[type=file]")};
        if (!el || typeof DataTransfer === "undefined") return false;
        const bytes = Uint8Array.from(atob(#{encoded.to_json}), char => char.charCodeAt(0));
        const transfer = new DataTransfer();
        transfer.items.add(new File([bytes], #{filename.to_json}, { type: "application/octet-stream" }));
        el.files = transfer.files;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })()
      JS
      raise Error.new("No file field matching #{field.inspect}") unless attached
    end

    # JS expression resolving a form field by label text, name, id or
    # placeholder, optionally restricted to a selector.
    private def find_field_js(field : String, selector : String = "input,textarea,select", fallback : String = selector) : String
      <<-JS
      (() => {
        const root = #{scope_js};
        if (!root) return null;
        const wanted = #{field.to_json};
        const labels = [...root.querySelectorAll('label')];
        const label = labels.find(node => (node.innerText || "").trim() === wanted) ||
                      labels.find(node => (node.innerText || "").includes(wanted));
        if (label) {
          const byFor = label.htmlFor ? document.getElementById(label.htmlFor) : null;
          const inside = label.querySelector(#{selector.to_json});
          if (byFor && byFor.matches(#{selector.to_json})) return byFor;
          if (inside) return inside;
        }
        return [...root.querySelectorAll(#{fallback.to_json})].find(node =>
          node.name === wanted || node.id === wanted || node.placeholder === wanted
        ) || null;
      })()
      JS
    end

    private def text_present?(text : String) : Bool
      evaluate_bool(<<-JS)
      (() => {
        const root = #{scope_js};
        const body = root === document ? document.body : root;
        return !!body && ((body.innerText || body.textContent || "").includes(#{text.to_json}));
      })()
      JS
    end

    private def selector_present?(selector : String, text : String?) : Bool
      text_js = text ? "el.innerText.includes(#{text.to_json})" : "true"
      evaluate_bool(<<-JS)
      (() => {
        const root = #{scope_js};
        if (!root) return false;
        const el = root.querySelector(#{selector.to_json});
        return !!el && (#{text_js});
      })()
      JS
    end

    private def scope_js : String
      @scope ? "document.querySelector(#{@scope.to_json})" : "document"
    end

    private def wait_for_load : Nil
      wait_until do
        begin
          evaluate_string("document.readyState") == "complete"
        rescue Error
          false
        end
      end
    end

    private def wait_until(timeout : Time::Span = @timeout, what : String = "condition", & : -> Bool) : Nil
      deadline = Time.instant + timeout
      loop do
        return if yield
        if Time.instant >= deadline
          raise Error.new("Timed out after #{timeout} waiting for #{what}")
        end
        sleep 25.milliseconds
      end
    end

    private def evaluate_string(script : String) : String
      evaluate(script)["value"]?.try(&.as_s) || ""
    end

    private def evaluate_bool(script : String) : Bool
      evaluate(script)["value"]?.try(&.as_bool) || false
    end

    private def evaluate(script : String) : JSON::Any
      result = command("Runtime.evaluate", params: JSON.parse({
        "expression"    => script,
        "returnByValue" => true,
        "awaitPromise"  => true,
      }.to_json))
      if details = result["exceptionDetails"]?
        message = details["exception"]?.try { |exception| exception["description"]?.try(&.as_s) } || details.to_json
        raise Error.new("JavaScript error: #{message}")
      end
      result["result"]? || JSON::Any.new(nil)
    end

    private def command(method : String, params : JSON::Any? = nil) : JSON::Any
      id = send_command(method, params)

      deadline = Time.instant + @timeout
      loop do
        remaining = deadline - Time.instant
        if remaining <= Time::Span.zero
          raise Error.new("DevTools command #{method} timed out")
        end
        select
        when message = @messages.receive
          if message_id = message["id"]?.try(&.as_i64?)
            next unless message_id == id.to_i64
            if error = message["error"]?
              raise Error.new("#{method}: #{error.to_json}")
            end
            return message["result"]? || JSON::Any.new(nil)
          else
            dispatch_event(message)
          end
        when timeout(remaining)
          raise Error.new("DevTools command #{method} timed out")
        end
      end
    rescue ex : Channel::ClosedError
      raise Error.new("Chrome closed the DevTools connection (#{method})")
    end

    private def send_command(method : String, params : JSON::Any? = nil) : Int32
      @id += 1
      id = @id
      payload = JSON::Any.new({
        "id"     => JSON::Any.new(id.to_i64),
        "method" => JSON::Any.new(method),
      })
      payload.as_h["params"] = params if params
      @socket.send(payload.to_json)
      id
    end

    # Runs handlers for DevTools events that arrive while a command is in
    # flight. Native dialogs must be answered here: Chrome blocks the
    # renderer until `Page.handleJavaScriptDialog` arrives.
    private def dispatch_event(message : JSON::Any) : Nil
      case message["method"]?.try(&.as_s)
      when "Page.javascriptDialogOpening"
        accept = @next_dialog_accept
        @next_dialog_accept = true
        @last_dialog_message = message["params"]?.try { |params| params["message"]?.try(&.as_s) } || ""
        send_command("Page.handleJavaScriptDialog", JSON.parse({"accept" => accept}.to_json))
      end
    end

    private def read_messages : Nil
      while message = @socket.receive?
        @messages.send(JSON.parse(message.to_s)) if message.is_a?(String)
      end
    rescue
    ensure
      @messages.close
    end

    private def drain_stderr : Nil
      IO.copy(@process.error, @stderr)
    rescue
    end

    private def wait_for_page_ws : String
      deadline = Time.instant + [@timeout, 10.seconds].max
      last_error = nil
      loop do
        begin
          response = HTTP::Client.get("http://127.0.0.1:#{@port}/json/list")
          if response.status_code == 200
            pages = JSON.parse(response.body).as_a
            page = pages.find { |entry| entry["type"]?.try(&.as_s) == "page" }
            if page
              return page["webSocketDebuggerUrl"].as_s
            end
          end
        rescue ex
          last_error = ex
        end
        if Time.instant >= deadline
          log = @stderr.to_s.lines.last(10).join("\n")
          raise Error.new("Chrome did not expose a page on port #{@port}: #{last_error}\n#{log}")
        end
        sleep 50.milliseconds
      end
    end

    private def free_port : Int32
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      server.close
      port
    end
  end
end
