require "spec"
require "file_utils"
require "json"
require "../src/saci"
require "../src/saci/support/duration"
require "../src/saci/support/inflections"
require "../src/saci/support/core_ext"
require "../src/saci/support/notifications"
require "../src/saci/support/current_attributes"
require "../src/saci/support/instrumentation"
require "../src/saci/support/record_extensions"

SUPPORT_LOCALE_TMP = "/tmp/opencode/saci-support-i18n"

def support_with_i18n(files : Hash(String, String), &block : -> Nil) : Nil
  old_path = Saci::I18n.load_path.dup
  old_default = Saci::I18n.default_locale
  old_fallbacks = Saci::I18n.fallbacks
  old_enforce = Saci::I18n.enforce_available_locales
  old_raise = Saci::I18n.raise_on_missing_translations
  begin
    FileUtils.rm_rf(SUPPORT_LOCALE_TMP)
    Dir.mkdir_p(SUPPORT_LOCALE_TMP)
    paths = files.map do |name, content|
      path = File.join(SUPPORT_LOCALE_TMP, name)
      File.write(path, content)
      path
    end
    Saci::I18n.load_path.replace(paths)
    Saci::I18n.fallbacks = false
    Saci::I18n.enforce_available_locales = false
    Saci::I18n.raise_on_missing_translations = false
    Saci::I18n.reset_missing_handler!
    Saci::I18n.reload!
    Saci::I18n.locale = Saci::I18n.default_locale
    yield
  ensure
    Saci::I18n.load_path.replace(old_path)
    Saci::I18n.default_locale = old_default
    Saci::I18n.locale = old_default
    Saci::I18n.fallbacks = old_fallbacks
    Saci::I18n.enforce_available_locales = old_enforce
    Saci::I18n.raise_on_missing_translations = old_raise
    Saci::I18n.reset_missing_handler!
    Saci::I18n.reload!
    FileUtils.rm_rf(SUPPORT_LOCALE_TMP)
  end
end

SUPPORT_EN_YML = <<-YAML
en:
  hello: "Hello"
  greeting: "Hello, %{name}!"
  items:
    zero: "no items"
    one: "%{count} item"
    other: "%{count} items"
  time:
    formats:
      short: "%H:%M on %d %b"
  date:
    formats:
      long: "%B %d, %Y"
YAML

SUPPORT_ES_YML = <<-YAML
es:
  hello: "Hola"
  items:
    one: "%{count} elemento"
    other: "%{count} elementos"
YAML

SUPPORT_FR_YML = <<-YAML
fr:
  hello: "Bonjour"
  items:
    one: "%{count} élément"
    other: "%{count} éléments"
YAML

class SupportUser < Saci::Record::Base
  column id : Int64, primary: true
  column name : String
  column admin : Bool
end

class SupportEventJob < Saci::Job::Base
  def perform(payload : JSON::Any) : Nil
    Saci::Current.job = "SupportEventJob"
  end
end

class SupportMailer < Saci::Mailer::Base
  default_from "noreply@example.com"

  def self.welcome(email : String) : Saci::Mailer::Mail
    mail(to: email, subject: "Welcome!") do |format|
      format.text { "Welcome, #{email}!" }
    end
  end
end

class SupportEventsController < Saci::Controller
  def show
    render text: "request_id=#{Saci::Current.request_id? || "none"} zone=#{Time.zone.name}"
  end
end

class SupportSettings
  include Saci::ClassAttributes
  class_attribute theme, String, "light"
end

class SupportAnimal
  include Saci::Descendants
end

class SupportDog < SupportAnimal
end

class SupportPuppy < SupportDog
end

describe "Saci::TimeZone" do
  after_each do
    Saci::TimeZone.reset_default!
    Saci::TimeZone.clear!
    Saci::Time.zone_default = "UTC"
  end

  it "loads IANA zones and lists names" do
    zone = Saci::TimeZone.find("America/New_York")
    zone.name.should eq("America/New_York")
    Saci::TimeZone.find?("Nowhere/Atlantis").should be_nil
    Saci::TimeZone.names.should_not be_empty
    Saci::TimeZone.names.should contain("UTC") if Saci::TimeZone.names.includes?("UTC")
  end

  it "tracks DST offsets from tzdata" do
    winter = Time.utc(2024, 1, 15, 12).in_time_zone("America/New_York")
    summer = Time.utc(2024, 7, 15, 12).in_time_zone("America/New_York")
    winter.utc_offset.should eq(-5.hours)
    summer.utc_offset.should eq(-4.hours)
    zone = Saci::TimeZone.find("Europe/Madrid")
    zone.dst?(Time.utc(2024, 7, 1)).should be_true
    zone.dst?(Time.utc(2024, 1, 1)).should be_false
  end

  it "applies fiber-local scoped overrides" do
    Saci::Time.zone = "UTC"
    Saci::TimeZone.with_zone("Asia/Tokyo") do
      Saci::Time.zone.name.should eq("Asia/Tokyo")
      Time.current.utc_offset.should eq(9.hours)
      Saci::TimeZone.with_zone("America/New_York") do
        Saci::Time.zone.name.should eq("America/New_York")
      end
      Saci::Time.zone.name.should eq("Asia/Tokyo")
    end
    Saci::Time.zone.name.should eq("UTC")
  end

  it "uses the process default from Time.zone_default" do
    Saci::Time.zone_default = "Europe/Madrid"
    Saci::TimeZone.default.name.should eq("Europe/Madrid")
    Saci::Time.zone.name.should eq("Europe/Madrid")
  end

  it "reads SACI_TIME_ZONE when no explicit default is set" do
    previous = ENV["SACI_TIME_ZONE"]?
    begin
      ENV["SACI_TIME_ZONE"] = "Asia/Tokyo"
      Saci::TimeZone.reset_default!
      Saci::TimeZone.default.name.should eq("Asia/Tokyo")
      Saci::Time.current.utc_offset.should eq(9.hours)
    ensure
      if previous
        ENV["SACI_TIME_ZONE"] = previous
      else
        ENV.delete("SACI_TIME_ZONE")
      end
      Saci::TimeZone.reset_default!
    end
  end

  it "keeps zone overrides isolated across fibers" do
    done = Channel(String).new(2)
    spawn do
      Saci::TimeZone.with_zone("Asia/Tokyo") do
        sleep 0.03.seconds
        done.send(Time.zone.name)
      end
    end
    spawn do
      Saci::TimeZone.with_zone("Europe/Paris") do
        sleep 0.03.seconds
        done.send(Time.zone.name)
      end
    end
    [done.receive, done.receive].sort.should eq(["Asia/Tokyo", "Europe/Paris"])
  end
end

describe "time and date helpers" do
  it "builds Rails-style beginning/end boundaries" do
    t = Time.utc(2024, 1, 31, 10, 20, 30)
    t.beginning_of_week.should eq(Time.utc(2024, 1, 29))
    t.end_of_week.day.should eq(4)
    t.beginning_of_day.should eq(Time.utc(2024, 1, 31))
    t.beginning_of_month.should eq(Time.utc(2024, 1, 1))
    t.end_of_month.day.should eq(31)
    t.beginning_of_year.should eq(Time.utc(2024, 1, 1))
    t.end_of_year.month.should eq(12)
  end

  it "advances and changes calendar fields" do
    t = Time.utc(2024, 1, 31, 10, 20, 30)
    t.advance(months: 1).should eq(Time.utc(2024, 2, 29, 10, 20, 30))
    t.advance(days: 1).should eq(Time.utc(2024, 2, 1, 10, 20, 30))
    t.advance(1.hour).should eq(Time.utc(2024, 1, 31, 11, 20, 30))
    t.change(hour: 5, minute: 0).should eq(Time.utc(2024, 1, 31, 5, 0, 30))
  end

  it "supports all_day, on_day?, to_date and to_fs" do
    t = Time.utc(2024, 1, 31, 10, 20, 30)
    t.all_day.begin.should eq(Time.utc(2024, 1, 31))
    t.all_day.end.day.should eq(31)
    t.on_day?(Time.utc(2024, 1, 31, 23, 59)).should be_true
    t.on_day?(Time.utc(2024, 2, 1)).should be_false
    t.to_date.should eq(Date.new(2024, 1, 31))
    t.to_fs(:db).should eq("2024-01-31 10:20:30")
    t.to_s(:db).should eq("2024-01-31 10:20:30")
    t.to_fs(:short).should contain("Jan")
  end

  it "provides a calendar-aware Date" do
    d = Date.new(2024, 2, 29)
    (d + 1).should eq(Date.new(2024, 3, 1))
    (d - 1).should eq(Date.new(2024, 2, 28))
    (Date.new(2024, 3, 1) - Date.new(2024, 2, 1)).should eq(29)
    d.end_of_month.should eq(d)
    d.beginning_of_month.should eq(Date.new(2024, 2, 1))
    d.advance(months: 12).should eq(Date.new(2025, 2, 28))
    d.to_fs(:long).should eq("February 29, 2024")
    Date.parse("2024-03-15").should eq(Date.new(2024, 3, 15))
  end

  it "respects Time.zone in Date.current" do
    Saci::Time.zone = "UTC"
    Date.current.year.should be >= 2024
  ensure
    Saci::Time.zone = "UTC"
  end
end

describe "duration helpers" do
  it "provides zone-aware from_now/ago for spans" do
    Saci::Time.zone = "UTC"
    (5.minutes.from_now - Time.current).total_minutes.should be_close(5.0, 0.1)
    (Time.current - 2.hours.ago).total_hours.should be_close(2.0, 0.1)
  end

  it "keeps months calendar-aware" do
    (1.month.from(Time.utc(2024, 1, 31))).should eq(Time.utc(2024, 2, 29))
    (2.months.from_now(Time::Location::UTC) > Time.utc).should be_true
    (12.months.before(Time.utc(2024, 3, 1))).should eq(Time.utc(2023, 3, 1))
  end

  it "provides byte helpers" do
    1.kilobyte.should eq(1_024)
    1.megabyte.should eq(1_048_576)
    1.5.gigabytes.should eq(1_610_612_736)
    2.terabytes.should eq(2_i64 * 1_024_i64 * 1_024_i64 * 1_024_i64 * 1_024_i64)
  end

  it "formats durations with to_fs" do
    90.minutes.to_fs(:long).should eq("1 hour, 30 minutes")
    1.day.to_fs.should eq("1 day")
    90.minutes.to_fs(:short).should eq("1h 30m")
    2.months.to_fs.should eq("2 months")
    14.months.to_fs.should eq("1 year, 2 months")
  end
end

describe "inflections" do
  it "pluralizes, singularizes, and handles irregulars" do
    inf = Saci::Record::Inflector
    inf.pluralize("post").should eq("posts")
    inf.pluralize("category").should eq("categories")
    inf.pluralize("person").should eq("people")
    inf.pluralize("child").should eq("children")
    inf.pluralize("person", 1).should eq("person")
    inf.pluralize("person", 3).should eq("people")
    inf.singularize("people").should eq("person")
    inf.singularize("posts").should eq("post")
    inf.singularize("categories").should eq("category")
  end

  it "converts naming conventions" do
    inf = Saci::Record::Inflector
    inf.camelize("active_record").should eq("ActiveRecord")
    inf.camelize("admin/user").should eq("Admin::User")
    inf.camelize("admin/user", false).should eq("admin::User")
    inf.underscore("ActiveRecord").should eq("active_record")
    inf.humanize("user_name").should eq("User name")
    inf.humanize("user_id").should eq("User")
    inf.titleize("x_men_rise").should eq("X Men Rise")
    inf.parameterize("Hello World!").should eq("hello-world")
    inf.tableize("Admin::User").should eq("admin_users")
    inf.classify("admin_users").should eq("AdminUser")
    inf.demodulize("Admin::User").should eq("User")
    inf.ordinalize(1).should eq("1st")
    inf.ordinalize(12).should eq("12th")
    inf.ordinalize(23).should eq("23rd")
    inf.foreign_key("Admin::User").should eq("user_id")
  end
end

describe "core extensions" do
  it "symbolizes and stringifies hash keys" do
    Saci.symbolize_keys({"a" => 1, "b" => 2}).should eq({:a => 1, :b => 2})
    {"a" => 1, "b" => 2}.symbolize_keys["b"].should eq(2)
    {:a => 1}.symbolize_keys[:a].should eq(1)
    {:a => 1}.stringify_keys.should eq({"a" => 1})
  end

  it "deep merges and deep duplicates" do
    base = {"a" => {"x" => 1}, "b" => 2} of String => Hash(String, Int32) | Int32
    other = {"a" => {"y" => 2}, "c" => 3} of String => Hash(String, Int32) | Int32
    merged = base.deep_merge(other)
    merged["a"].as(Hash(String, Int32))["y"].should eq(2)
    merged["c"].should eq(3)
    copy = base.deep_dup
    copy["a"].as(Hash(String, Int32))["x"] = 99
    base["a"].as(Hash(String, Int32))["x"].should eq(1)
  end

  it "slices, excepts, and builds query strings" do
    {"a" => 1, "b" => 2, "c" => 3}.slice("a", "c").should eq({"a" => 1, "c" => 3})
    {"a" => 1, "b" => 2, "c" => 3}.except("b").should eq({"a" => 1, "c" => 3})
    {"b" => "two words", "a" => 1}.to_query.should eq("a=1&b=two+words")
  end

  it "adds array sentence and grouping helpers" do
    ([] of String).to_sentence.should eq("")
    ["a"].to_sentence.should eq("a")
    ["a", "b"].to_sentence.should eq("a and b")
    ["a", "b", "c"].to_sentence.should eq("a, b, and c")
    [1, 2, 3, 4, 5].in_groups(2).should eq([[1, 2, 3], [4, 5]])
    [1, 2, 3].in_groups(2, 0).should eq([[1, 2], [3, 0]])
    [1, 2, 3].to_param.should eq("1/2/3")
  end

  it "adds presence/blank semantics" do
    ([] of Int32).blank?.should be_true
    ({} of String => Int32).blank?.should be_true
    "   ".blank?.should be_true
    false.blank?.should be_true
    0.blank?.should be_false
    "a".presence.should eq("a")
    "".presence.should be_nil
    [1].presence.should eq([1])
  end

  it "squishes strings and wraps safe buffers" do
    "  a \n b  ".squish.should eq("a b")
    buffer = "<b>hi</b>".html_safe
    buffer.html_safe?.should be_true
    "<b>".html_safe?.should be_false
    (buffer + "!").to_s.should eq("<b>hi</b>!")
  end

  it "provides OrderedOptions, indifferent access and StringInquirer" do
    opts = Saci::OrderedOptions(Int32 | String).new
    opts[:retries] = 3
    opts["name"] = "job"
    opts[:retries].should eq(3)
    opts["name"].should eq("job")
    opts.fetch(:missing, 0).should eq(0)

    h = Saci::HashWithIndifferentAccess(Int32).new
    h[:count] = 2
    h["count"].should eq(2)
    h.has_key?(:count).should be_true

    inquiry = Saci::StringInquirer.new("production")
    inquiry.is?("production").should be_true
    inquiry.is?(:staging).should be_false
    inquiry.to_s.should eq("production")
  end

  it "supports class_attribute and descendant tracking" do
    SupportSettings.theme.should eq("light")
    SupportSettings.theme = "dark"
    SupportSettings.new.theme.should eq("dark")
    SupportSettings.theme = "light"

    SupportAnimal.subclasses.should eq(["SupportDog"])
    SupportAnimal.descendants.sort.should eq(["SupportDog", "SupportPuppy"])
    SupportDog.subclasses.should eq(["SupportPuppy"])
  end
end

describe "Saci::Current" do
  after_each { Saci::Current.reset }

  it "stores fiber-local attributes and resets" do
    Saci::Current.request_id = "req-1"
    Saci::Current.request_id.should eq("req-1")
    Saci::Current.reset
    Saci::Current.request_id?.should be_nil
    expect_raises(Saci::CurrentAttributes::MissingAttribute) { Saci::Current.request_id }
  end

  it "stores record users" do
    user = SupportUser.new
    user.name = "Ada"
    user.id = 7_i64
    Saci::Current.user = user
    Saci::Current.user.as(SupportUser).name.should eq("Ada")
  end

  it "restores previous values around set blocks" do
    Saci::Current.request_id = "outer"
    Saci::Current.set(request_id: "inner") do
      Saci::Current.request_id.should eq("inner")
    end
    Saci::Current.request_id.should eq("outer")
    Saci::Current.set(locale: "es")
    Saci::Current.locale.should eq("es")
  end

  it "keeps attributes isolated across fibers" do
    done = Channel(String).new(2)
    spawn do
      Saci::Current.request_id = "one"
      sleep 0.03.seconds
      done.send(Saci::Current.request_id.not_nil!)
    end
    spawn do
      Saci::Current.request_id = "two"
      sleep 0.03.seconds
      done.send(Saci::Current.request_id.not_nil!)
    end
    [done.receive, done.receive].sort.should eq(["one", "two"])
  end
end

describe "Saci::I18n depth" do
  it "uses per-locale plural rules (en/es/fr)" do
    support_with_i18n({"en.yml" => SUPPORT_EN_YML, "es.yml" => SUPPORT_ES_YML, "fr.yml" => SUPPORT_FR_YML}) do
      Saci::I18n.t("items", count: 0).should eq("no items")
      Saci::I18n.t("items", count: 1).should eq("1 item")
      Saci::I18n.t("items", count: 5).should eq("5 items")
      Saci::I18n.t("items", locale: :es, count: 0).should eq("0 elementos")
      Saci::I18n.t("items", locale: :es, count: 1).should eq("1 elemento")
      Saci::I18n.t("items", locale: :fr, count: 0).should eq("0 élément")
      Saci::I18n.t("items", locale: :fr, count: 1).should eq("1 élément")
      Saci::I18n.t("items", locale: :fr, count: 4).should eq("4 éléments")
    end
  end

  it "follows configured fallback chains" do
    support_with_i18n({"en.yml" => SUPPORT_EN_YML, "es.yml" => SUPPORT_ES_YML}) do
      Saci::I18n.fallbacks = {"es-MX" => ["es"]}
      Saci::I18n.t("hello", locale: "es-MX").should eq("Hola")
      Saci::I18n.t("items", locale: "es-MX", count: 2).should eq("2 elementos")
      Saci::I18n.t("greeting", locale: "es-MX", name: "Ada").should eq("Hello, Ada!")
    end
  end

  it "localizes dates and times with translation formats" do
    support_with_i18n({"en.yml" => SUPPORT_EN_YML, "es.yml" => SUPPORT_ES_YML}) do
      time = Time.utc(2024, 3, 15, 9, 30)
      Saci::I18n.l(time, format: :short, locale: :en).should eq("09:30 on 15 Mar")
      Saci::I18n.l(time, format: :short, locale: :es).should eq("09:30 on 15 Mar") # falls back to en pattern
      Saci::I18n.l(time, format: :long, locale: :en).should contain("2024")
      date = Date.new(2024, 3, 15)
      Saci::I18n.l(date, format: :long, locale: :en).should eq("March 15, 2024")
      Saci::I18n.l(date, format: :db).should eq("2024-03-15")
      Saci::I18n.l(time, format: "%Y-%m-%d").should eq("2024-03-15")
    end
  end

  it "enforces available locales" do
    support_with_i18n({"en.yml" => SUPPORT_EN_YML, "es.yml" => SUPPORT_ES_YML}) do
      Saci::I18n.enforce_available_locales = true
      expect_raises(Saci::I18n::InvalidLocale) do
        Saci::I18n.with_locale("de") { }
      end
      Saci::I18n.with_locale("es") { Saci::I18n.locale.should eq("es") }
      Saci::I18n.t("hello", locale: "es").should eq("Hola")
    end
  end

  it "raises or delegates missing translations" do
    support_with_i18n({"en.yml" => SUPPORT_EN_YML}) do
      Saci::I18n.raise_on_missing_translations = true
      expect_raises(Saci::I18n::MissingTranslation) { Saci::I18n.t("nope") }
      Saci::I18n.t("nope", default: "fallback").should eq("fallback")
      Saci::I18n.raise_on_missing_translations = false

      seen = [] of String
      Saci::I18n.on_missing do |locale, key, _options|
        seen << "#{locale}.#{key}"
        "custom missing"
      end
      Saci::I18n.t("nope").should eq("custom missing")
      seen.should eq(["en.nope"])
      Saci::I18n.reset_missing_handler!
      Saci::I18n.t("nope").should eq("translation missing: en.nope")
    end
  end

  it "keeps nested keys, symbol keys, and interpolation working" do
    support_with_i18n({"en.yml" => SUPPORT_EN_YML, "es.yml" => SUPPORT_ES_YML}) do
      Saci::I18n.t(:hello).should eq("Hello")
      Saci::I18n.t("greeting", name: "Ada").should eq("Hello, Ada!")
      Saci::I18n.exists?("hello").should be_true
      Saci::I18n.exists?("nope").should be_false
      Saci::I18n.available_locales.sort.should eq(["en", "es"])
    end
  end
end

describe "Saci::Notifications" do
  after_each { Saci::Notifications.unsubscribe_all }

  it "instruments blocks with monotonic durations and payloads" do
    events = [] of Saci::Notifications::Event
    sub = Saci::Notifications.subscribe("work.saci") { |event| events << event }
    result = Saci::Notifications.instrument("work.saci", {"name" => "ada"}) do
      sleep 0.01.seconds
      42
    end
    result.should eq(42)
    events.size.should eq(1)
    events.first.name.should eq("work.saci")
    events.first["name"].should eq("ada")
    events.first.duration.should be > 0.0
    Saci::Notifications.unsubscribe(sub).should be_true
    Saci::Notifications.instrument("work.saci") { nil }
    events.size.should eq(1)
  end

  it "supports regex subscriptions and exception payloads" do
    names = [] of String
    Saci::Notifications.subscribe(/\.saci\z/) { |event| names << event.name }
    Saci::Notifications.publish("one.saci", {"a" => 1})
    expect_raises(Exception, "boom") do
      Saci::Notifications.instrument("two.saci") { raise "boom" }
    end
    names.should eq(["one.saci", "two.saci"])
  end

  it "provides Saci.event.notify with context" do
    seen = [] of String
    Saci.event.subscribe("user.created") { |event| seen << "#{event["user"]}:#{event["trace"]?}" }
    Saci.event.with_context({"trace" => "abc"}) do
      Saci.event.notify("user.created", {"user" => "ada"})
    end
    seen.should eq(["ada:abc"])
  end
end

describe "framework instrumentation" do
  after_each { Saci::Notifications.unsubscribe_all }

  it "emits process_action.saci and request-scoped Current/zone" do
    events = [] of Saci::Notifications::Event
    Saci::Notifications.subscribe("process_action.saci") { |event| events << event }
    router = Saci::Router.new.draw do |r|
      r.get "/events", SupportEventsController, :show
    end
    Saci::TestSession.serve(router) do |app|
      response = app.get("/events", HTTP::Headers{"X-Time-Zone" => "Asia/Tokyo"})
      response.body.should contain("request_id=")
      response.body.should contain("zone=Asia/Tokyo")
    end
    events.size.should eq(1)
    events.first["controller"].should eq("SupportEventsController")
    events.first["action"].should eq("show")
    Saci::Current.request_id?.should be_nil
    Time.zone.name.should eq("UTC")
  end

  it "emits enqueue/perform events for jobs" do
    events = [] of Saci::Notifications::Event
    Saci::Notifications.subscribe("perform.saci") { |event| events << event }
    Saci::Notifications.subscribe("enqueue.saci") { |event| events << event }
    old_adapter = Saci::Job.queue_adapter
    begin
      Saci::Job.queue_adapter = :inline
      SupportEventJob.perform_later({"a" => 1})
    ensure
      Saci::Job.queue_adapter = old_adapter
    end
    events.map(&.name).sort.should eq(["enqueue.saci", "perform.saci"])
    events.find { |event| event.name == "perform.saci" }.not_nil!["job"].should eq("SupportEventJob")
  end

  it "emits deliver.saci for mailers" do
    events = [] of Saci::Notifications::Event
    Saci::Notifications.subscribe("deliver.saci") { |event| events << event }
    old_adapter = Saci::Mailer.delivery_adapter
    begin
      Saci::Mailer.delivery_adapter = :test
      Saci::Mailer.clear_deliveries!
      SupportMailer.welcome("a@b.c").deliver_now
    ensure
      Saci::Mailer.delivery_adapter = old_adapter
    end
    events.size.should eq(1)
    events.first["subject"].should eq("Welcome!")
  end

  it "emits sql.saci for ORM queries" do
    events = [] of Saci::Notifications::Event
    Saci::Notifications.subscribe("sql.saci") { |event| events << event }
    db = DB.open("sqlite3::memory:")
    begin
      Saci::Record.exec_compat(db, "SELECT 1")
    ensure
      db.close
    end
    events.size.should eq(1)
    events.first["sql"].should eq("SELECT 1")
  end
end

describe "structured logging and filter parameters" do
  after_each do
    ENV.delete("SACI_LOG_FORMAT")
    Saci.filter_parameters = ["passw", "email", "secret", "token", "_key", "crypt", "salt", "certificate", "otp", "ssn", "cvv", "cvc"]
    Saci.filter_redirect = [] of String
    Saci.log_tags = [:request_id, :remote_ip, :method, :path] of String | Symbol
    Saci.logger = ::Log.for("saci")
    Saci.slow_query_threshold = 200.milliseconds
    Saci.reset_slow_query_handler!
  end

  it "filters Rails' default sensitive keys by substring" do
    Saci.filter_params({
      "user"            => "ada",
      "password"        => "x",
      "email"           => "a@b.c",
      "api_token"       => "t",
      "secret"          => "s",
      "cvv"             => "123",
      "salt"            => "y",
      "user_name"       => "ada",
      "certificate_pem" => "z",
    }).should eq({
      "user"            => "ada",
      "password"        => "[FILTERED]",
      "email"           => "[FILTERED]",
      "api_token"       => "[FILTERED]",
      "secret"          => "[FILTERED]",
      "cvv"             => "[FILTERED]",
      "salt"            => "[FILTERED]",
      "user_name"       => "ada",
      "certificate_pem" => "[FILTERED]",
    })
  end

  it "filters redirect URLs" do
    Saci.filter_redirect = ["/sign_in"]
    Saci.filter_redirect_value("/sign_in?token=abc").should eq("[FILTERED]")
    Saci.filter_redirect_value("/posts").should eq("/posts")
  end

  it "emits JSON request log lines in JSON mode" do
    ENV["SACI_LOG_FORMAT"] = "json"
    line = Saci.request_log_line("GET", "/posts", 200, 3.5, {"password" => "x", "a" => "1"}, "abc")
    parsed = JSON.parse(line)
    parsed["status"].should eq(200)
    parsed["request_id"].should eq("abc")
    parsed["method"].should eq("GET")
    parsed["params"]["password"].should eq("[FILTERED]")
    parsed["duration_ms"].should eq(3.5)
  end

  it "broadcasts to multiple loggers" do
    first = ::Log.new("first", ::Log::MemoryBackend.new, ::Log::Severity::Debug)
    second = ::Log.new("second", ::Log::MemoryBackend.new, ::Log::Severity::Debug)
    logger = Saci.broadcast_logger(first, second)
    logger.info { "hello" }
    first.backend.as(::Log::MemoryBackend).entries.size.should eq(1)
    second.backend.as(::Log::MemoryBackend).entries.size.should eq(1)
  end

  it "tags requests and logs slow queries" do
    slow = [] of String
    Saci.slow_query_threshold = 1.millisecond
    Saci.on_slow_query { |sql, _duration| slow << sql }
    Saci.log_slow_query("SELECT pg_sleep(1)", 5.milliseconds)
    slow.should eq(["SELECT pg_sleep(1)"])

    router = Saci::Router.new.draw do |r|
      r.get("/tags") { |ctx, _params| ctx.response.print(Saci.current_tags.join(",")) }
    end
    Saci::TestSession.serve(router) do |app|
      body = app.get("/tags").body
      body.should contain("GET")
      body.should contain("/tags")
    end
  end
end

describe "Record as_json" do
  it "honors only/except" do
    user = SupportUser.new
    user.id = 3_i64
    user.name = "Ada"
    user.admin = true
    json = user.as_json(only: ["id", "name"])
    json.keys.sort.should eq(["id", "name"])
    json["id"].as_i64.should eq(3)
    json["name"].as_s.should eq("Ada")
    user.as_json(except: ["admin"]).keys.sort.should eq(["id", "name"])
    user.to_param.should eq("3")
  end
end
