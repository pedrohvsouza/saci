require "yaml"
require "./support/time_zone"
require "./support/time_helpers"

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
  # Saci::I18n.l(Time.current, format: :long)             # localized date/time
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
  #   time:
  #     formats:
  #       short: "%d %b %H:%M"
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

    # Raised for unknown locales when `enforce_available_locales` is on.
    class InvalidLocale < Exception
    end

    # Raised for missing keys when `raise_on_missing_translations` is on.
    class MissingTranslation < Exception
    end

    alias MissingHandler = Proc(String, String, Hash(String, String), String)
    alias PluralRule = Proc(Float64, String)

    DEFAULT_TIME_FORMATS = {
      "short"   => "%d %b %H:%M",
      "long"    => "%B %d, %Y %H:%M",
      "default" => "%a, %d %b %Y %H:%M:%S %z",
      "db"      => "%Y-%m-%d %H:%M:%S",
      "number"  => "%Y%m%d%H%M%S",
    } of String => String

    DEFAULT_DATE_FORMATS = {
      "short"   => "%b %d",
      "long"    => "%B %d, %Y",
      "default" => "%a, %d %b %Y",
      "db"      => "%Y-%m-%d",
      "iso8601" => "%Y-%m-%d",
      "us"      => "%m/%d/%Y",
    } of String => String

    DEFAULT_DATETIME_FORMATS = {
      "short"   => "%d %b %H:%M",
      "long"    => "%B %d, %Y %H:%M",
      "default" => "%a, %d %b %Y %H:%M:%S %z",
      "db"      => "%Y-%m-%d %H:%M:%S",
    } of String => String

    @@default_locale : String = "en"
    @@load_path : Array(String) = ["config/locales/*.yml"]
    @@translations = {} of String => YAML::Any
    @@mutex = Mutex.new
    @@fiber_locales = {} of UInt64 => String
    @@fl_mutex = Mutex.new

    @@fallbacks_enabled : Bool = false
    @@fallback_chains = {} of String => Array(String)
    @@enforce_available_locales : Bool = false
    @@raise_on_missing : Bool = false
    @@missing_handler : MissingHandler? = nil
    @@plural_rules = {} of String => PluralRule
    @@config_mutex = Mutex.new

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
      value = locale.to_s
      validate_locale!(value)
      @@fl_mutex.synchronize { @@fiber_locales[Fiber.current.object_id] = value }
    end

    def self.with_locale(locale : Locale, & : -> T) : T forall T
      key = Fiber.current.object_id
      str = locale.to_s
      validate_locale!(str)
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

    # -- fallbacks / missing translations / enforcement ---------------------

    # `fallbacks = true` enables per-locale chains plus the default locale.
    def self.fallbacks : Bool
      @@config_mutex.synchronize { @@fallbacks_enabled }
    end

    def self.fallbacks=(value : Bool) : Nil
      @@config_mutex.synchronize { @@fallbacks_enabled = value }
    end

    # Explicit chains, e.g. `{"es-MX" => ["es", "en"]}`.
    def self.fallbacks=(chains : Hash(String, Array(String))) : Nil
      @@config_mutex.synchronize do
        @@fallbacks_enabled = true
        @@fallback_chains = chains.transform_values(&.dup)
      end
    end

    def self.fallback_chains : Hash(String, Array(String))
      @@config_mutex.synchronize { @@fallback_chains.transform_values(&.dup) }
    end

    def self.enforce_available_locales : Bool
      @@config_mutex.synchronize { @@enforce_available_locales }
    end

    def self.enforce_available_locales=(value : Bool) : Nil
      @@config_mutex.synchronize { @@enforce_available_locales = value }
    end

    def self.raise_on_missing_translations : Bool
      @@config_mutex.synchronize { @@raise_on_missing }
    end

    def self.raise_on_missing_translations=(value : Bool) : Nil
      @@config_mutex.synchronize { @@raise_on_missing = value }
    end

    # Custom missing-translation handler `(locale, key, options) -> String`.
    def self.on_missing(&handler : String, String, Hash(String, String) -> String) : Nil
      @@config_mutex.synchronize do
        @@missing_handler = ->(locale : String, key : String, options : Hash(String, String)) do
          handler.call(locale, key, options)
        end
      end
    end

    def self.reset_missing_handler! : Nil
      @@config_mutex.synchronize { @@missing_handler = nil }
    end

    # Registers a pluralization rule for a locale; the block receives the
    # count and returns a form name ("zero"/"one"/"other"/"few"/"many").
    def self.pluralization_rule(locale : Locale, &rule : Float64 -> String) : Nil
      @@config_mutex.synchronize { @@plural_rules[locale.to_s] = rule }
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

    # Looks up `key` ("a.b.c") with optional pluralization (`count:` picks a
    # per-locale plural form), `%{name}` interpolation (`count` is always
    # available), fallback chains, and default-locale fallback.
    def self.t(key : String | Symbol, locale : Locale? = nil, count : Int | Float | Nil = nil, default : String? = nil, **values) : String
      loc = locale.try(&.to_s) || self.locale
      validate_locale!(loc)
      full_key = key.to_s
      merged = {} of String => String
      values.each { |name, value| merged[name.to_s] = value.to_s }
      merged["count"] = count.to_s unless count.nil?

      unless count.nil?
        full_key = "#{full_key}.#{plural_form(loc, full_key, count)}"
      end

      raw = lookup_in_chain(loc, full_key)
      return interpolate(raw.as_s? || raw.to_s, merged) unless raw.nil?
      return default if default
      missing_translation(loc, key.to_s, merged)
    end

    def self.translate(key : String | Symbol, locale : Locale? = nil, count : Int | Float | Nil = nil, default : String? = nil, **values) : String
      t(key, **values, locale: locale, count: count, default: default)
    end

    # Raising variant (`t!` in Rails applications).
    def self.t!(key : String | Symbol, locale : Locale? = nil, count : Int | Float | Nil = nil, default : String? = nil, **values) : String
      previous = @@config_mutex.synchronize { @@raise_on_missing }
      @@config_mutex.synchronize { @@raise_on_missing = true }
      begin
        t(key, **values, locale: locale, count: count, default: default)
      ensure
        @@config_mutex.synchronize { @@raise_on_missing = previous }
      end
    end

    def self.exists?(key : String | Symbol, locale : Locale? = nil) : Bool
      loc = locale.try(&.to_s) || self.locale
      !lookup_in_chain(loc, key.to_s).nil?
    end

    # Localizes a `Time`/`Date` using `time.formats.*`/`date.formats.*`
    # translations, falling back to Rails' built-in patterns.
    def self.l(value : Time, format : Symbol | String = :default, locale : Locale? = nil) : String
      value.to_s(format_pattern("time", format, locale))
    end

    def self.l(value : Date, format : Symbol | String = :default, locale : Locale? = nil) : String
      value.to_s(format_pattern("date", format, locale))
    end

    def self.localize(value : Time, format : Symbol | String = :default, locale : Locale? = nil) : String
      l(value, format: format, locale: locale)
    end

    def self.localize(value : Date, format : Symbol | String = :default, locale : Locale? = nil) : String
      l(value, format: format, locale: locale)
    end

    # Matches a raw locale string against loaded locales, falling back to
    # the default locale.
    def self.parse_locale(raw : String?) : String
      return default_locale if raw.nil? || raw.empty?
      find_locale(raw) || find_locale(raw.split("-").first) || default_locale
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

    # Ordered lookup chain for *locale*: the locale itself, its configured
    # fallback chain (when enabled), the default locale, then `en`.
    def self.lookup_chain(locale : String) : Array(String)
      chain = [locale]
      enabled, configured = @@config_mutex.synchronize { {@@fallbacks_enabled, @@fallback_chains[locale]?.try(&.dup)} }
      if enabled
        configured.try(&.each { |item| chain << item })
        chain << base_language(locale) if base_language(locale) != locale
      end
      chain << default_locale
      chain << "en" unless chain.includes?("en")
      chain.uniq
    end

    private def self.validate_locale!(locale : String) : Nil
      return unless enforce_available_locales
      return if locale == default_locale
      return if available_locales.includes?(locale)
      return if available_locales.includes?(base_language(locale))
      raise InvalidLocale.new("Invalid locale #{locale.inspect}; available: #{available_locales.join(", ")}")
    end

    private def self.missing_translation(locale : String, key : String, options : Hash(String, String)) : String
      handler, raising = @@config_mutex.synchronize { {@@missing_handler, @@raise_on_missing} }
      if handler
        handler.call(locale, key, options)
      elsif raising
        raise MissingTranslation.new("Translation missing: #{locale}.#{key}")
      else
        "translation missing: #{locale}.#{key}"
      end
    end

    private def self.format_pattern(kind : String, format : Symbol | String, locale : Locale?) : String
      return format if format.is_a?(String) && format.includes?('%')
      loc = locale.try(&.to_s) || self.locale
      name = format.to_s
      if raw = lookup_in_chain(loc, "#{kind}.formats.#{name}")
        return raw.as_s? || raw.to_s
      end
      defaults = case kind
                 when "date" then DEFAULT_DATE_FORMATS
                 when "time" then DEFAULT_TIME_FORMATS
                 else             DEFAULT_DATETIME_FORMATS
                 end
      defaults[name]? || defaults["default"]? || "%Y-%m-%d %H:%M:%S"
    end

    # Picks a plural form for *count* in *locale*, preferring forms that
    # actually exist for *key*.
    private def self.plural_form(locale : String, key : String, count : Int | Float) : String
      forms = plural_forms(locale, count.to_f64)
      forms.each do |form|
        return form if lookup_in_chain(locale, "#{key}.#{form}")
      end
      forms.last
    end

    private def self.plural_forms(locale : String, count : Float64) : Array(String)
      if rule = @@config_mutex.synchronize { @@plural_rules[locale]? || @@plural_rules[base_language(locale)]? }
        primary = rule.call(count)
        return primary == "other" ? ["other"] : [primary, "other"]
      end
      case base_language(locale)
      when "fr", "pt", "tr"
        # French/Portuguese: 0 and 1 are singular.
        (count == 0 || count == 1) ? ["one", "other"] : ["other"]
      when "en"
        if count == 1
          ["one", "other"]
        elsif count == 0
          ["zero", "other"]
        else
          ["other"]
        end
      when "es", "de", "it", "nl", "sv", "da"
        count == 1 ? ["one", "other"] : ["other"]
      else
        count == 1 ? ["one", "other"] : ["other"]
      end
    end

    private def self.base_language(locale : String) : String
      locale.split("-").first
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

    private def self.lookup(full_key : String) : YAML::Any?
      @@mutex.synchronize { @@translations[full_key]? }
    end

    private def self.lookup_in_chain(locale : String, key : String) : YAML::Any?
      lookup_chain(locale).each do |candidate|
        if raw = lookup("#{candidate}.#{key}")
          return raw
        end
      end
      nil
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
