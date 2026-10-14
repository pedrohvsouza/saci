require "spec"
require "file_utils"
require "../src/saci"

LOCALE_TMP = "/tmp/opencode/saci-i18n"

def write_locale_file(name : String, content : String) : String
  Dir.mkdir_p(LOCALE_TMP)
  path = File.join(LOCALE_TMP, name)
  File.write(path, content)
  path
end

def with_i18n(files : Hash(String, String), &block : -> Nil) : Nil
  old_path = Saci::I18n.load_path.dup
  old_default = Saci::I18n.default_locale
  begin
    FileUtils.rm_rf(LOCALE_TMP)
    paths = files.map { |name, content| write_locale_file(name, content) }
    Saci::I18n.load_path.replace(paths)
    Saci::I18n.reload!
    Saci::I18n.locale = Saci::I18n.default_locale
    yield
  ensure
    Saci::I18n.load_path.replace(old_path)
    Saci::I18n.default_locale = old_default
    Saci::I18n.locale = old_default
    Saci::I18n.reload!
    FileUtils.rm_rf(LOCALE_TMP)
  end
end

EN_YML = <<-YAML
en:
  hello: "Hello"
  greeting: "Hello, %{name}!"
  items:
    zero: "no items"
    one: "%{count} item"
    other: "%{count} items"
  nested:
    deep:
      value: 42
YAML

ES_YML = <<-YAML
es:
  hello: "Hola"
  greeting: "Hola, %{name}!"
YAML

describe Saci::I18n do
  it "looks up simple and nested keys" do
    with_i18n({"en.yml" => EN_YML}) do
      Saci::I18n.t("hello").should eq("Hello")
      Saci::I18n.t(:hello).should eq("Hello")
      Saci::I18n.t("nested.deep.value").should eq("42")
    end
  end

  it "interpolates values and raises on missing ones" do
    with_i18n({"en.yml" => EN_YML}) do
      Saci::I18n.t("greeting", name: "Ada").should eq("Hello, Ada!")
      expect_raises(Saci::I18n::MissingInterpolation) do
        Saci::I18n.t("greeting")
      end
    end
  end

  it "pluralizes with zero/one/other and interpolates count" do
    with_i18n({"en.yml" => EN_YML}) do
      Saci::I18n.t("items", count: 0).should eq("no items")
      Saci::I18n.t("items", count: 1).should eq("1 item")
      Saci::I18n.t("items", count: 5).should eq("5 items")
    end
  end

  it "falls back to the default locale, then a missing string" do
    with_i18n({"en.yml" => EN_YML, "es.yml" => ES_YML}) do
      Saci::I18n.t("hello", locale: :es).should eq("Hola")
      Saci::I18n.t("nested.deep.value", locale: :es).should eq("42")
      Saci::I18n.t("nope").should eq("translation missing: en.nope")
      Saci::I18n.t("nope", default: "fallback").should eq("fallback")
    end
  end

  it "supports with_locale nesting and restoration" do
    with_i18n({"en.yml" => EN_YML, "es.yml" => ES_YML}) do
      Saci::I18n.locale.should eq("en")
      Saci::I18n.with_locale(:es) do
        Saci::I18n.locale.should eq("es")
        Saci::I18n.with_locale(:en) do
          Saci::I18n.locale.should eq("en")
        end
        Saci::I18n.locale.should eq("es")
      end
      Saci::I18n.locale.should eq("en")
    end
  end

  it "keeps locales isolated across fibers" do
    with_i18n({"en.yml" => EN_YML, "es.yml" => ES_YML}) do
      done_ch = Channel(String).new(2)
      spawn do
        Saci::I18n.with_locale(:es) do
          sleep 0.05.seconds
          done_ch.send(Saci::I18n.t("hello"))
        end
      end
      spawn do
        Saci::I18n.with_locale(:en) do
          sleep 0.05.seconds
          done_ch.send(Saci::I18n.t("hello"))
        end
      end
      [done_ch.receive, done_ch.receive].sort.should eq(["Hello", "Hola"])
      Saci::I18n.locale.should eq("en")
    end
  end

  it "parses locales and Accept-Language headers" do
    with_i18n({"en.yml" => EN_YML, "es.yml" => ES_YML}) do
      Saci::I18n.available_locales.sort.should eq(["en", "es"])
      Saci::I18n.parse_locale("es").should eq("es")
      Saci::I18n.parse_locale("fr").should eq("en")
      Saci::I18n.parse_locale(nil).should eq("en")
      Saci::I18n.locale_from_header("es-MX,es;q=0.9,en;q=0.8").should eq("es")
      Saci::I18n.locale_from_header("fr-FR,de;q=0.7").should eq("en")
      Saci::I18n.locale_from_header(nil).should eq("en")
    end
  end

  it "translates via the controller helper with request locale" do
    with_i18n({"en.yml" => EN_YML, "es.yml" => ES_YML}) do
      router = Saci::Router.new.draw do |r|
        r.get "/hi", I18nDemoController, :show
      end
      Saci::TestSession.serve(router) do |app|
        app.get("/hi?locale=es&name=Ada").body.should eq("Hola, Ada!")
        app.get("/hi?name=Ada").body.should eq("Hello, Ada!")
      end
    end
  end
end

class I18nDemoController < Saci::Controller
  before_action :set_locale

  def show
    render text: t("greeting", name: params["name"]? || "?")
  end

  private def set_locale
    Saci::I18n.locale = Saci::I18n.parse_locale(params["locale"]?)
  end
end
