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
      <form action="/upload" method="post" enctype="multipart/form-data">
        <label for="avatar">Avatar</label>
        <input id="avatar" name="avatar" type="file">
        <button type="submit">Upload</button>
      </form>
      <button type="button" id="confirm-button">Delete</button>
      <p id="confirm-result">Waiting</p>
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

  def upload
    if file = params.file("avatar")
      render html: <<-HTML
      <!doctype html>
      <html>
      <body>
        <h1>Upload</h1>
        <p>File: #{HTML.escape(file.filename)}</p>
        <pre>#{HTML.escape(file.read)}</pre>
      </body>
      </html>
      HTML
    else
      render html: "<!doctype html><html><body><h1>Upload</h1><p>No file</p></body></html>"
    end
  end
end

def system_test_router : Saci::Router
  Saci::Router.new.draw do |r|
    r.get "/system", SystemTestPageController, :index
    r.post "/echo", SystemTestPageController, :echo
    r.post "/upload", SystemTestPageController, :upload
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

  it "attaches a file to a file input" do
    pending! "Chrome/Chromium not found (set CHROME_BIN)" unless Saci::SystemTest.available?

    path = File.join("/tmp/opencode", "saci-upload-#{Process.pid}-#{Random.rand(1_000_000)}.txt")
    File.write(path, "avatar-bytes")
    begin
      Saci::SystemTest.serve(system_test_router, timeout: 10.seconds) do |page|
        page.visit "/system"
        page.attach_file "Avatar", path
        page.click_on "Upload"
        page.assert_text "Upload"
        page.assert_text "File: #{File.basename(path)}"
        page.assert_text "avatar-bytes"
        page.current_path.should eq("/upload")
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "accepts confirm dialogs by default and dismisses them on request" do
    pending! "Chrome/Chromium not found (set CHROME_BIN)" unless Saci::SystemTest.available?

    Saci::SystemTest.serve(system_test_router, timeout: 10.seconds) do |page|
      page.visit "/system"
      page.execute_script(<<-JS)
      document.getElementById("confirm-button").addEventListener("click", () => {
        document.getElementById("confirm-result").textContent = confirm("Delete this post?") ? "Confirmed" : "Dismissed";
      });
      JS
      page.assert_text "Waiting"

      page.click_on "Delete"
      page.assert_text "Confirmed"
      page.last_dialog_message.should eq("Delete this post?")

      page.dismiss_dialog
      page.click_on "Delete"
      page.assert_text "Dismissed"
      page.last_dialog_message.should eq("Delete this post?")
    end
  end

  it "reports that a browser is available" do
    pending! "Chrome/Chromium not found (set CHROME_BIN)" unless Saci::SystemTest.available?
    Saci::SystemTest.available?.should be_true
  end
end
