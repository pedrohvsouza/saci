require "json"
require "./params"
require "./record"
require "./pagination"

module Saci
  # Ransack-style filtering (G303).
  #
  # ```
  # class Post < Saci::Record::Base
  #   searchable_attributes :title, :status, :views, :created_at
  # end
  #
  # search = Saci::Search.new(Post, params)
  # search.result # => Record::Query(Post)
  # search.sort("views desc").result
  # search.page # => Saci::Pagination::Page(Post)
  #
  # # Same thing through the generated class helper:
  # Post.search(params).page
  # ```
  #
  # Params are accepted as `Saci::Params`, `Hash(String, String)`,
  # `Hash(String, JSON::Any)`, `JSON::Any`, or nil. Both the nested
  # `q[name_cont]=x` spelling (as parsed by `Saci::Params`) and a flat
  # JavaScript-friendly hash are handled.
  #
  # Supported predicates:
  # `_eq`, `_not_eq`, `_cont`, `_start`, `_end`, `_gt`, `_gteq`, `_lt`,
  # `_lteq`, `_in`, `_null`, `_present`, `_matches`, `_does_not_match`.
  # `q[s]` accepts `"created_at desc"` or a comma-separated list.
  #
  # Identifier safety: an attribute must be in the model's
  # `searchable_attributes`/`ransackable_attributes` whitelist *and* be a
  # real column. Names are quoted with `Saci::Record.quote`; values are
  # always bound. Unknown attributes/predicates are ignored, never
  # interpolated into SQL.
  #
  # `searchable_attributes` defaults to every model column. Declare it
  # explicitly to hide sensitive columns. The primary key is always
  # searchable so `q[id_in]=...` works.
  class Search(T)
    SUFFIXES = [
      "does_not_match",
      "not_eq",
      "present",
      "matches",
      "gteq",
      "lteq",
      "start",
      "end",
      "cont",
      "null",
      "gte",
      "lte",
      "eq",
      "gt",
      "lt",
      "in",
    ]

    getter model : T.class
    getter query : Record::Query(T)
    getter page_number : Int32
    getter per_page : Int32

    @column_types : Hash(String, String)
    @searchable : Array(String)

    def initialize(@model : T.class, params = nil, base : Record::Query(T)? = nil)
      @column_types = @model.__saci_column_names.to_h
      @searchable = @model.__saci_searchable_attributes.select { |name| @column_types.has_key?(name) }
      pk = @model.__saci_primary_key
      @searchable << pk unless @searchable.includes?(pk)
      @query = base || @model.all
      @page_number = 1
      @per_page = Pagination::DEFAULT_PER_PAGE
      apply_params(Search.flatten_params(params))
    end

    def result : Record::Query(T)
      @query
    end

    def to_a : Array(T)
      @query.to_a
    end

    def count : Int64
      @query.count
    end

    def each(& : T ->) : Nil
      @query.each { |record| yield record }
    end

    def empty? : Bool
      @query.first.nil?
    end

    # Explicit sort. A plain name uses `dir`; a string containing spaces or
    # commas is parsed as Ransack's `q[s]` ("views desc, id asc").
    def sort(value : String | Symbol, dir : Symbol = :asc) : self
      text = value.to_s
      if text.includes?(' ') || text.includes?(',')
        apply_sort(text)
      else
        return self unless @searchable.includes?(text)
        @query = @query.order(text, dir)
      end
      self
    end

    def page(number : Int? = nil, per_page : Int? = nil) : Pagination::Page(T)
      Pagination.paginate(@query, number || @page_number, per_page || @per_page)
    end

    def paginate(number : Int? = nil, per_page : Int? = nil) : Pagination::Page(T)
      page(number, per_page)
    end

    def searchable_attributes : Array(String)
      @searchable.dup
    end

    private def apply_params(flat : Hash(String, String)) : Nil
      flat.each do |key, raw|
        if key.starts_with?("q[") && key.ends_with?("]")
          inner = key[2...-1]
          case inner
          when "s"
            apply_sort(raw)
          when "page"
            @page_number = parse_positive(raw, 1)
          when "per_page"
            @per_page = parse_positive(raw, Pagination::DEFAULT_PER_PAGE)
          else
            apply_predicate(inner, raw)
          end
        elsif key == "s" || key == "sort"
          apply_sort(raw)
        elsif key == "page"
          @page_number = parse_positive(raw, 1)
        elsif key == "per_page"
          @per_page = parse_positive(raw, Pagination::DEFAULT_PER_PAGE)
        end
      end
    end

    private def parse_positive(raw : String, fallback : Int32) : Int32
      value = raw.to_i?
      value && value > 0 ? value.to_i32 : fallback
    end

    private def apply_predicate(key : String, raw : String) : Nil
      parts = Search.split_predicate(key)
      return unless parts
      attribute = parts[0]
      predicate = parts[1]
      return unless @searchable.includes?(attribute)
      type = @column_types[attribute]?
      return unless type

      unless ["null", "present", "in"].includes?(predicate)
        return if raw.empty?
      end

      ad = Record.adapter_of(@model.connection)
      column = "#{Record.quote(@model.table_name, ad)}.#{Record.quote(attribute, ad)}"

      case predicate
      when "null"
        @query = @query.where("#{column} IS #{Search.truthy?(raw) ? "" : "NOT "}NULL")
      when "present"
        @query = @query.where("#{column} IS #{Search.truthy?(raw) ? "NOT " : ""}NULL")
      when "eq", "not_eq", "gt", "gteq", "lt", "lteq"
        value = Search.coerce(raw, type)
        return if value.nil?
        operator = case predicate
                   when "eq"     then "="
                   when "not_eq" then "<>"
                   when "gt"     then ">"
                   when "gteq"   then ">="
                   when "lt"     then "<"
                   else               "<="
                   end
        @query = @query.where("#{column} #{operator} ?", [value] of Record::Value)
      when "cont", "start", "end", "matches", "does_not_match"
        expression = Search.text_expression(column, type, ad)
        pattern = case predicate
                  when "start" then "#{raw}%"
                  when "end"   then "%#{raw}"
                  else              "%#{raw}%"
                  end
        if predicate == "matches"
          @query = @query.where("LOWER(#{expression}) LIKE LOWER(?)", [pattern] of Record::Value)
        elsif predicate == "does_not_match"
          @query = @query.where("LOWER(#{expression}) NOT LIKE LOWER(?)", [pattern] of Record::Value)
        else
          @query = @query.where("#{expression} LIKE ?", [pattern] of Record::Value)
        end
      when "in"
        values = raw.split(',').map(&.strip).reject(&.empty?)
        if values.empty?
          @query = @query.where("1 = 0")
          return
        end
        coerced = [] of Record::Value
        values.each do |item|
          value = Search.coerce(item, type)
          coerced << value unless value.nil?
        end
        if coerced.empty?
          @query = @query.where("1 = 0")
        else
          placeholders = coerced.map { "?" }.join(", ")
          @query = @query.where("#{column} IN (#{placeholders})", coerced)
        end
      end
    end

    private def apply_sort(raw : String) : Nil
      raw.split(',').each do |part|
        tokens = part.strip.split(/\s+/)
        next if tokens.empty?
        attribute = tokens[0]
        next unless @searchable.includes?(attribute)
        direction = tokens[1]?.try(&.downcase) == "desc" ? :desc : :asc
        @query = @query.order(attribute, direction)
      end
    end

    # Flattens every accepted params shape into `q[key]`-style strings.
    def self.flatten_params(params) : Hash(String, String)
      flat = {} of String => String
      case params
      when Nil
        # no filters
      when Saci::Params
        if query = params.dig("q")
          flatten_json(query, "q", flat)
        end
        params.to_h.each do |key, value|
          next if key == "q"
          flat[key] = value
        end
      when JSON::Any
        flatten_json(params, "", flat)
      when Hash
        params.each do |key, value|
          flatten_any(key.to_s, value, flat)
        end
      else
        flat["q"] = params.to_s
      end
      flat
    end

    private def self.flatten_any(prefix : String, value, flat : Hash(String, String)) : Nil
      case value
      when JSON::Any
        flatten_json(value, prefix, flat)
      when Hash
        value.each { |key, item| flatten_any(join_key(prefix, key.to_s), item, flat) }
      when Array
        flat[prefix] = value.map { |item| item.to_s }.join(",")
      when Nil
        flat[prefix] = ""
      else
        flat[prefix] = value.to_s
      end
    end

    private def self.flatten_json(any : JSON::Any, prefix : String, flat : Hash(String, String)) : Nil
      if hash = any.as_h?
        hash.each { |key, item| flatten_json(item, join_key(prefix, key), flat) }
      elsif array = any.as_a?
        flat[prefix] = array.map { |item| Saci::Params.scalar_string(item) || item.to_json }.join(",")
      else
        scalar = Saci::Params.scalar_string(any)
        flat[prefix] = scalar.nil? ? any.to_json : scalar
      end
    end

    private def self.join_key(prefix : String, key : String) : String
      prefix.empty? ? key : "#{prefix}[#{key}]"
    end

    def self.split_predicate(key : String) : Tuple(String, String)?
      SUFFIXES.each do |suffix|
        needle = "_#{suffix}"
        if key.ends_with?(needle) && key.size > needle.size
          return {key[0...-needle.size], suffix}
        end
      end
      nil
    end

    def self.truthy?(value : String) : Bool
      !["0", "false", "f", "no", "off", ""].includes?(value.strip.downcase)
    end

    def self.parse_bool(value : String) : Bool?
      case value.strip.downcase
      when "1", "true", "t", "yes", "on"  then true
      when "0", "false", "f", "no", "off" then false
      else                                     nil
      end
    end

    def self.coerce(raw : String, type : String) : Record::Value
      case type
      when "Int64"         then raw.to_i64?
      when "Int32"         then raw.to_i32?
      when "Float64"       then raw.to_f64?
      when "Bool"          then parse_bool(raw)
      when "Time"          then Record.parse_time(raw)
      when "Array(String)" then raw.split(',').map(&.strip)
      else                      raw
      end
    end

    def self.text_expression(column : String, type : String, adapter : Record::Adapter) : String
      return column if type == "String"
      case adapter
      when :postgres
        "#{column}::text"
      when :mysql
        "CAST(#{column} AS CHAR)"
      else
        "CAST(#{column} AS TEXT)"
      end
    end
  end

  # Alias type for callers that prefer the `Filter` spelling.
  class Filter(T) < Search(T)
  end
end

# Model-facing macros/helpers. `searchable_attributes` and its Ransack-ish
# alias both generate the same class method used by `Saci::Search`.
class Saci::Record::Base
  macro searchable_attributes(*names)
    def self.__saci_searchable_attributes : Array(String)
      [{% for name in names %}{{name.id.stringify}},{% end %}] of String
    end
  end

  macro ransackable_attributes(*names)
    def self.__saci_searchable_attributes : Array(String)
      [{% for name in names %}{{name.id.stringify}},{% end %}] of String
    end
  end

  def self.__saci_searchable_attributes : Array(String)
    __saci_column_names.map(&.[0])
  end

  def self.search(params, base : Saci::Record::Query(self)? = nil) : Saci::Search(self)
    Saci::Search(self).new(self, params, base)
  end

  def self.filter(params, base : Saci::Record::Query(self)? = nil) : Saci::Filter(self)
    Saci::Filter(self).new(self, params, base)
  end
end
