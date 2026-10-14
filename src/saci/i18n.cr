require "yaml"

module Saci
  # Rails-I18n-style localization.
  #
  # ```
  # Saci::I18n.load_path << "config/locales/*.yml"
  # Saci::I18n.reload!
  #
  # Saci::I18n.t("hello")                                 # => "Hello"
  # Saci::I18n.t("greeting", name: "Ada")                 # interpolates %{name}
  # Saci::I18n.t("items", count: 3)                       # items.one / items.other (+zero)
  # Saci::I18n.with_locale(:es) { Saci::I18n.t("hello") } # fiber-local, nestable
  # ```
  #
  # Locale files mirror Rails (`config/locales/en.yml`):
  #
  # ```yaml
  # en:
  #   hello: "Hello"
  #   items:
  #     one: "%{count} item"
  #     other: "%{count} items"
  # ```
  #
  # Notes: locales accept `Symbol` or `String` (`:es` and `"es"` are the
  # same — Crystal has no runtime string-to-symbol conversion, so locales
  # normalize to strings internally). Missing keys fall back to the default
  # locale, then to `"translation missing: <locale>.<key>"`. The current
  # locale is stored per fiber, so concurrent requests never leak locales
  # into each other.
  module I18n
    alias Locale = Symbol | String

    class MissingInterpolation < Exception
    end

    @@default_locale : String = "en"
    @@load_path : Array(String) = ["config/locales/*.yml"]
    @@translations = {} of String => YAML::Any
    @@mutex = Mutex.new
    @@fiber_locales = {} of UInt64 => String
    @@fl_mutex = Mutex.new

    def self.default_locale : String
      @@default_locale
    end

    def self.default_locale=(locale : Locale) : Nil
      @@default_locale = locale.to_s
    end

    def self.load_path : Array(String)
      @@load_path
    end

    def self.available_locales : Array(String)
      @@mutex.synchronize do
        @@translations.each_key.compact_map { |full| full.split(".", 2).first }.to_set.to_a.sort
      end
    end

    def self.locale : String
      @@fl_mutex.synchronize { @@fiber_locales[Fiber.current.object_id]? } || @@default_locale
    end

    def self.locale=(locale : Locale) : Nil
      @@fl_mutex.synchronize { @@fiber_locales[Fiber.current.object_id] = locale.to_s }
    end

    def self.with_locale(locale : Locale, & : -> T) : T forall T
      key = Fiber.current.object_id
      str = locale.to_s
      prev = @@fl_mutex.synchronize { @@fiber_locales[key]? }
      @@fl_mutex.synchronize { @@fiber_locales[key] = str }
      begin
        yield
      ensure
        @@fl_mutex.synchronize do
          if before = prev
            @@fiber_locales[key] = before
          else
            @@fiber_locales.delete(key)
          end
        end
      end
    end

    # Loads every file matching `load_path` globs (later files win).
    def self.reload! : Nil
      fresh = {} of String => YAML::Any
      load_path.each do |pattern|
        Dir.glob(pattern) do |file|
          load_file_into(fresh, file)
        end
      end
      @@mutex.synchronize { @@translations = fresh }
    end

    # Looks up `key` ("a.b.c") with optional pluralization (`count:` picks
    # `zero`/`one`/`other`), `%{name}` interpolation (`count` is always
    # available), and default-locale fallback.
    def self.t(key : String | Symbol, locale : Locale? = nil, count : Int32 | Int64 | Float64 | Nil = nil, default : String? = nil, **values) : String
      loc = locale.try(&.to_s) || self.locale
      full_key = key.to_s
      unless count.nil?
        plural = (count == 0 && exists?("#{loc}.#{full_key}.zero")) ? "zero" : (count == 1 ? "one" : "other")
        full_key = "#{full_key}.#{plural}"
      end
      raw = lookup("#{loc}.#{full_key}") || lookup("#{default_locale}.#{full_key}")
      return default || "translation missing: #{loc}.#{key}" if raw.nil?
      merged = {} of String => String
      values.each { |name, value| merged[name.to_s] = value.to_s }
      merged["count"] = count.to_s unless count.nil?
      interpolate(raw.as_s? || raw.to_s, merged)
    end

    def self.translate(key : String | Symbol, locale : Locale? = nil, count : Int32 | Int64 | Float64 | Nil = nil, default : String? = nil, **values) : String
      t(key, **values, locale: locale, count: count, default: default)
    end

    # Matches a raw locale string against loaded locales, falling back to
    # the default locale.
    def self.parse_locale(raw : String?) : String
      return default_locale if raw.nil? || raw.empty?
      find_locale(raw) || default_locale
    end

    # Picks the best locale from an `Accept-Language` header value.
    def self.locale_from_header(header : String?) : String
      return default_locale if header.nil? || header.empty?
      header.split(",").map do |part|
        tag, _, q = part.strip.partition(";q=")
        quality = q.empty? ? 1.0 : (q.to_f? || 0.0)
        {tag.strip.downcase, quality}
      end.sort_by { |_, q| -q }.each do |(tag, _)|
        if found = find_locale(tag) || find_locale(tag.split("-").first)
          return found
        end
      end
      default_locale
    end

    private def self.find_locale(tag : String) : String?
      @@mutex.synchronize do
        @@translations.each_key do |full|
          name = full.split(".", 2).first
          return name if name == tag
        end
        nil
      end
    end

    private def self.exists?(full_key : String) : Bool
      @@mutex.synchronize { @@translations.has_key?(full_key) }
    end

    private def self.lookup(full_key : String) : YAML::Any?
      @@mutex.synchronize { @@translations[full_key]? }
    end

    private def self.load_file_into(store : Hash(String, YAML::Any), path : String) : Nil
      root = YAML.parse(File.read(path))
      root.as_h.each do |locale_key, tree|
        flatten_into(store, locale_key.to_s, tree, "")
      end
    end

    private def self.flatten_into(store : Hash(String, YAML::Any), locale : String, node : YAML::Any, prefix : String) : Nil
      if hash = node.as_h?
        hash.each do |key, value|
          flatten_into(store, locale, value, prefix.empty? ? key.to_s : "#{prefix}.#{key}")
        end
      else
        store["#{locale}.#{prefix}"] = node
      end
    end

    private def self.interpolate(template : String, values : Hash(String, String)) : String
      template.gsub(/\%\{([^}]+)\}/) do |match|
        key = match[2...-1]
        values[key]? || raise MissingInterpolation.new("missing interpolation argument #{key.inspect} in #{template.inspect}")
      end
    end
  end
end
