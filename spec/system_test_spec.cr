require "spec"
require "../src/saci"

class SystemTestPageController < Saci::Controller
  def index
    render html: <<-HTML
    <!doctype html>
    <html>
    <body>
      <h1>System test page</h1>
      <form action="/echo" method="post">
        <label for="name">Name</label>
        <input id="name" name="name" placeholder="Your name">
        <label><input type="checkbox" name="subscribe"> Subscribe</label>
        <label for="plan">Plan</label>
        <select id="plan" name="plan">
          <option value="free">Free</option>
          <option value="pro">Pro</option>
        </select>
        <button type="submit">Send</button>
      </form>
    </body>
    </html>
    HTML
  end

  def echo
    name = params["name"]? || ""
    render html: <<-HTML
    <!doctype html>
    <html>
    <body><h1>Echo</h1><p>Hi #{HTML.escape(name)}</p><a href="/system">Back</a></body>
    </html>
    HTML
  end
end

def system_test_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/system", SystemTestPageController, :index
    r.post "/echo", SystemTestPageController, :echo
  end
end

describe Saci::SystemTest do
  it "drives a page with forms, clicks, scopes and screenshots" do
    pending! "Chrome/Chromium not found (set CHROME_BIN)" unless Saci::SystemTest.available?

    Saci::SystemTest.serve(system_test_router, timeout: 10.seconds) do |page|
      page.visit "/system"
      page.assert_text "System test page"
      page.within("h1") { page.assert_text "System test page" }

      page.within("form") do
        page.fill_in "Name", with: "Ada"
        page.check "Subscribe"
        page.select_option "Plan", with: "pro"
        page.assert_selector "input[name=subscribe]:checked"
        page.assert_selector "select[name=plan]"
      end

      page.execute_script("document.body.dataset.probe = 'ok'")
      page.execute_script("document.body.dataset.probe").as_s.should eq("ok")

      screenshot = File.join("/tmp/opencode", "saci-system-#{Random.rand(1_000_000)}.png")
      begin
        page.screenshot(screenshot)
        File.size(screenshot).should be > 0
      ensure
        File.delete(screenshot) if File.exists?(screenshot)
      end

      page.click_on "Send"
      page.assert_text "Hi Ada"
      page.assert_text "Echo"
      page.assert_no_text "System test page"
      page.assert_selector "h1"
      page.assert_no_selector "form"
      page.current_path.should eq("/echo")
      page.has_selector?("a", text: "Back").should be_true
    end
  end

  it "reports that a browser is available" do
    pending! "Chrome/Chromium not found (set CHROME_BIN)" unless Saci::SystemTest.available?
    Saci::SystemTest.available?.should be_true
  end
end
