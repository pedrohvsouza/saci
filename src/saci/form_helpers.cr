require "html"

module Saci
  # Non-model form helpers (`*_tag`) and form-option helpers. Model-bound
  # fields live on `Saci::FormBuilder` (reopened at the bottom of this file
  # with `fields_for`, `collection_select`, HTML5 input types, ...).
  module Views
    # Values accepted by the non-model tag helpers (`nil` omits `value`).
    alias FormValue = String | Int32 | Int64 | Float64 | Bool | Nil

    # `id` attribute derived from a field name: `"user[name]"` -> `"user_name"`.
    def self.tag_id(name : String) : String
      cleaned = name.gsub(/[^-a-zA-Z0-9:.]/, "_").gsub(/_+/, "_").gsub(/\A_+|_+\z/, "")
      cleaned.empty? ? "field" : cleaned
    end

    # `<form>` for non-model forms. Includes the `_method` override and CSRF
    # token (when supplied); the controller method supplies the token.
    def self.form_tag(action : String, method : String | Symbol = "post", authenticity_token : String? = nil, multipart : Bool = false, **attributes, &block : -> String) : String
      verb = method.to_s.downcase
      form_method = (verb == "get" || verb == "post") ? verb : "post"
      attrs = attributes_hash(attributes)
      attrs["action"] = action
      attrs["method"] = form_method
      attrs["enctype"] = "multipart/form-data" if multipart
      String.build do |io|
        io << "<form"
        render_attributes(io, attrs)
        io << '>'
        if form_method == "post" && verb != "post"
          io << %(<input type="hidden" name="_method" value=") << HTML.escape(verb.upcase) << %(">)
        end
        if token = authenticity_token
          io << %(<input type="hidden" name=") << CSRF::PARAM_NAME << %(" value=") << HTML.escape(token) << %(">)
        end
        io << block.call
        io << "</form>"
      end
    end

    def self.text_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("text", name, value, attributes)
    end

    def self.password_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("password", name, value, attributes)
    end

    def self.hidden_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("hidden", name, value, attributes)
    end

    def self.email_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("email", name, value, attributes)
    end

    def self.number_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("number", name, value, attributes)
    end

    def self.search_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("search", name, value, attributes)
    end

    def self.url_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("url", name, value, attributes)
    end

    def self.telephone_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("tel", name, value, attributes)
    end

    def self.date_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("date", name, value, attributes)
    end

    def self.datetime_local_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("datetime-local", name, value, attributes)
    end

    def self.time_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("time", name, value, attributes)
    end

    def self.month_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("month", name, value, attributes)
    end

    def self.week_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("week", name, value, attributes)
    end

    def self.color_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("color", name, value, attributes)
    end

    def self.range_field_tag(name : String, value : FormValue = nil, **attributes) : String
      input_tag("range", name, value, attributes)
    end

    def self.file_field_tag(name : String, **attributes) : String
      input_tag("file", name, nil, attributes)
    end

    def self.text_area_tag(name : String, content : FormValue = nil, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["name"] = name unless attrs.has_key?("name")
      attrs["id"] = tag_id(name) unless attrs.has_key?("id")
      build_tag("textarea", attrs, content.nil? ? "" : content.to_s, escape_content: true)
    end

    def self.check_box_tag(name : String, value : FormValue = "1", checked : Bool = false, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["type"] = "checkbox"
      attrs["name"] = name
      attrs["id"] = tag_id(name) unless attrs.has_key?("id")
      attrs["value"] = value.to_s
      attrs["checked"] = true if checked
      build_tag("input", attrs, nil, escape_content: true)
    end

    def self.radio_button_tag(name : String, value : FormValue, checked : Bool = false, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["type"] = "radio"
      attrs["name"] = name
      attrs["id"] = "#{tag_id(name)}_#{tag_id(value.to_s)}" unless attrs.has_key?("id")
      attrs["value"] = value.to_s
      attrs["checked"] = true if checked
      build_tag("input", attrs, nil, escape_content: true)
    end

    def self.submit_tag(value : FormValue = "Save", **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["type"] = "submit"
      attrs["value"] = value.to_s
      build_tag("input", attrs, nil, escape_content: true)
    end

    def self.label_tag(name : String? = nil, text : FormValue = nil, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["for"] = tag_id(name.not_nil!) if name && !attrs.has_key?("for")
      label_text = text.nil? ? (name || "") : text.to_s
      build_tag("label", attrs, label_text, escape_content: true)
    end

    def self.select_tag(name : String, option_tags : String? = nil, **attributes) : String
      attrs = attributes_hash(attributes)
      attrs["name"] = name unless attrs.has_key?("name")
      attrs["id"] = tag_id(name) unless attrs.has_key?("id")
      build_tag("select", attrs, option_tags || "", escape_content: false)
    end

    def self.select_tag(name : String, options : Array, selected : Object? = nil, **attributes) : String
      select_tag(name, options_for_select(options, selected), **attributes)
    end

    def self.select_tag(name : String, **attributes, &block : -> String) : String
      select_tag(name, block.call, **attributes)
    end

    # `<option>` tags for bare values, `{label, value}` tuples or
    # label => value hashes. `selected` may be a single value or an array.
    def self.options_for_select(container : Array, selected : Object? = nil) : String
      selected_values = case selected
                        when Nil   then [] of String
                        when Array then selected.map(&.to_s)
                        else            [selected.to_s]
                        end
      String.build do |io|
        container.each do |item|
          label, value = case item
                         when Tuple then {item[0].to_s, item[1].to_s}
                         when Array
                           item.size >= 2 ? {item[0].to_s, item[1].to_s} : {item.to_s, item.to_s}
                         when Hash
                           first = item.to_a.first?
                           first ? {first[0].to_s, first[1].to_s} : {"", ""}
                         else
                           {item.to_s, item.to_s}
                         end
          io << %(<option value=") << HTML.escape(value) << '"'
          io << " selected" if selected_values.includes?(value)
          io << '>' << HTML.escape(label) << "</option>"
        end
      end
    end

    # Options for a record/collection: `value_method`/`text_method` read
    # record attributes; tuple/hash/scalar elements work too (see
    # `options_for_select`).
    def self.options_from_collection_for_select(collection : Array, value_method : String | Symbol, text_method : String | Symbol, selected : Object? = nil) : String
      options_for_select(collection_option_pairs(collection, value_method.to_s, text_method.to_s), selected)
    end

    # `<optgroup>`s from either `{label, items}` tuples or records whose
    # `group_method` attribute holds the grouped items and
    # `group_label_method` names the label.
    def self.grouped_options_for_select(collection : Array, group_method : String | Symbol, group_label_method : String | Symbol, value_method : String | Symbol, text_method : String | Symbol, selected : Object? = nil) : String
      String.build do |io|
        collection.each do |group|
          label = ""
          items = [] of Tuple(String, String)
          case group
          when Tuple
            label = group[0].to_s
            raw = group[1]
            if raw.is_a?(Array)
              items = collection_option_pairs(raw, value_method.to_s, text_method.to_s)
            end
          when Array
            if group.size >= 2
              label = group[0].to_s
              raw = group[1]
              if raw.is_a?(Array)
                items = collection_option_pairs(raw, value_method.to_s, text_method.to_s)
              end
            end
          when Saci::Record::Base
            label = group.__saci_get_attr(group_label_method.to_s).to_s
            raw = group.__saci_get_attr(group_method.to_s)
            if raw.is_a?(Array)
              items = collection_option_pairs(raw, value_method.to_s, text_method.to_s)
            end
          else
            label = group.to_s
          end
          io << %(<optgroup label=") << HTML.escape(label) << %(">)
          io << options_for_select(items, selected)
          io << "</optgroup>"
        end
      end
    end

    # Basic `date_select`: year/month/day selects named `<name>[year]`,
    # `<name>[month]`, `<name>[day]`.
    def self.date_select(name : String, value : Time? = nil, start_year : Int32? = nil, end_year : Int32? = nil, **attributes) : String
      time = value || Time.utc
      first = start_year || (time.year - 5)
      last = end_year || (time.year + 5)
      prefix = tag_id(name)
      String.build do |io|
        io << select_tag("#{name}[year]", (first..last).map { |y| {y.to_s, y.to_s} }, time.year.to_s, id: "#{prefix}_year")
        io << select_tag("#{name}[month]", (1..12).map { |m| {"%02d" % m, m.to_s} }, time.month.to_s, id: "#{prefix}_month")
        io << select_tag("#{name}[day]", (1..31).map { |d| {"%02d" % d, d.to_s} }, time.day.to_s, id: "#{prefix}_day")
      end
    end

    # `date_select` plus hour/minute selects.
    def self.datetime_select(name : String, value : Time? = nil, **attributes) : String
      time = value || Time.utc
      prefix = tag_id(name)
      date_select(name, time, **attributes) +
        select_tag("#{name}[hour]", (0..23).map { |h| {"%02d" % h, h.to_s} }, time.hour.to_s, id: "#{prefix}_hour") +
        select_tag("#{name}[minute]", (0..59).map { |m| {"%02d" % m, m.to_s} }, time.minute.to_s, id: "#{prefix}_minute")
    end

    private def self.input_tag(type : String, name : String, value : FormValue, attributes) : String
      attrs = attributes_hash(attributes)
      attrs["type"] = type unless attrs.has_key?("type")
      attrs["name"] = name unless attrs.has_key?("name")
      attrs["id"] = tag_id(name) unless attrs.has_key?("id")
      attrs["value"] = value.to_s unless value.nil? || attrs.has_key?("value")
      build_tag("input", attrs, nil, escape_content: true)
    end

    # Normalizes mixed collections into `{label, value}` tuples.
    private def self.collection_option_pairs(collection : Array, value_method : String, text_method : String) : Array(Tuple(String, String))
      collection.map do |item|
        case item
        when Saci::Record::Base
          {item.__saci_get_attr(text_method).to_s, item.__saci_get_attr(value_method).to_s}
        when Tuple
          {item[0].to_s, item[1].to_s}
        when Array
          item.size >= 2 ? {item[0].to_s, item[1].to_s} : {item.to_s, item.to_s}
        when Hash
          first = item.to_a.first?
          first ? {first[0].to_s, first[1].to_s} : {"", ""}
        else
          {item.to_s, item.to_s}
        end
      end
    end
  end

  # Model-bound form builder (see `Controller#form_with`). Names scope to
  # `scope[field]`, ids to `scope_field`, and values default from `model:`.
  class FormBuilder
    # Nested fields: `f.fields_for("author", @story.author) { |a| a.text_field("name") }`
    # names fields `story[author][name]`. Without a record the scope alone
    # still nests (`f.fields_for("tags") { |t| ... }`).
    def fields_for(name : String | Symbol, record : Saci::Record::Base? = nil, &block : FormBuilder -> String) : String
      nested = FormBuilder.new(@url, @http_method, @authenticity_token, record, field_name(name.to_s), @multipart)
      yield nested
    end

    def fields_for(record : Saci::Record::Base, &block : FormBuilder -> String) : String
      fields_for(Record::Inflector.underscore(record.class.name.split("::").last), record, &block)
    end

    # `collection_select` / `grouped_collection_select` accept record
    # collections (`value_method`/`text_method` are column names) or plain
    # tuples/hashes/scalars.
    def collection_select(name : String, collection : Array, value_method : String | Symbol, text_method : String | Symbol, selected : Object? = nil, **attributes) : String
      current = selected.nil? ? model_string(name) : selected
      html = Views.options_from_collection_for_select(collection, value_method, text_method, current)
      self.select(name, html, current, **attributes)
    end

    def grouped_collection_select(name : String, collection : Array, group_method : String | Symbol, group_label_method : String | Symbol, value_method : String | Symbol, text_method : String | Symbol, selected : Object? = nil, **attributes) : String
      current = selected.nil? ? model_string(name) : selected
      html = Views.grouped_options_for_select(collection, group_method, group_label_method, value_method, text_method, current)
      self.select(name, html, current, **attributes)
    end

    def radio_button(name : String, value : Views::FormValue, checked : Bool? = nil, **attributes) : String
      string_value = value.to_s
      is_checked = checked.nil? ? model_string(name) == string_value : checked
      attrs = Views.attributes_hash(attributes)
      attrs["type"] = "radio"
      attrs["name"] = field_name(name)
      attrs["id"] = "#{field_id(name)}_#{Views.tag_id(string_value)}" unless attrs.has_key?("id")
      attrs["value"] = string_value
      attrs["checked"] = true if is_checked
      apply_error_class(attrs, name)
      Views.tag("input", attrs)
    end

    def number_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("number", name, field_value(value, model_string(name)), **attributes)
    end

    def email_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("email", name, field_value(value, model_string(name)), **attributes)
    end

    def url_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("url", name, field_value(value, model_string(name)), **attributes)
    end

    def telephone_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("tel", name, field_value(value, model_string(name)), **attributes)
    end

    def color_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("color", name, field_value(value, model_string(name)), **attributes)
    end

    def range_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("range", name, field_value(value, model_string(name)), **attributes)
    end

    def search_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("search", name, field_value(value, model_string(name)), **attributes)
    end

    def datetime_local_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("datetime-local", name, field_value(value, model_date_time(name)), **attributes)
    end

    def time_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("time", name, field_value(value, model_time(name)), **attributes)
    end

    def month_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("month", name, field_value(value, model_month(name)), **attributes)
    end

    def week_field(name : String, value : Views::FormValue = nil, **attributes) : String
      input("week", name, field_value(value, model_week(name)), **attributes)
    end

    def date_select(name : String, value : Time? = nil, **attributes) : String
      Views.date_select(field_name(name), value || model_time_value(name), **attributes)
    end

    def datetime_select(name : String, value : Time? = nil, **attributes) : String
      Views.datetime_select(field_name(name), value || model_time_value(name), **attributes)
    end

    # `select` with a prebuilt options string (e.g. `options_for_select`).
    def select(name : String, options_html : String, selected : Object? = nil, **attributes) : String
      attrs = Views.attributes_hash(attributes)
      attrs["name"] = field_name(name) unless attrs.has_key?("name")
      attrs["id"] = field_id(name) unless attrs.has_key?("id")
      apply_error_class(attrs, name)
      Views.content_tag("select", attrs) { options_html }
    end

    # `select` with a mixed collection (bare values, `{label, value}` tuples,
    # hashes or records).
    def select(name : String, options : Array, selected : Object? = nil, **attributes) : String
      current = selected.nil? ? model_string(name) : selected
      self.select(name, Views.options_for_select(options, current), current, **attributes)
    end

    private def apply_error_class(attrs : Hash, name : String) : Nil
      model = @model
      return unless model
      return if model.errors[name].empty?
      existing = attrs["class"]?
      attrs["class"] = existing ? "#{existing} field-with-errors" : "field-with-errors"
    end

    private def field_value(value : Views::FormValue, fallback : String?) : String?
      value.nil? ? fallback : value.to_s
    end

    private def model_time_value(name : String) : Time?
      v = model_raw(name)
      v.is_a?(Time) ? v : nil
    end

    private def model_date_time(name : String) : String?
      time = model_time_value(name)
      time.try(&.to_utc.to_s("%Y-%m-%dT%H:%M"))
    end

    private def model_time(name : String) : String?
      time = model_time_value(name)
      time.try(&.to_utc.to_s("%H:%M"))
    end

    private def model_month(name : String) : String?
      time = model_time_value(name)
      time.try(&.to_utc.to_s("%Y-%m"))
    end

    private def model_week(name : String) : String?
      time = model_time_value(name)
      time.try(&.to_utc.to_s("%G-W%V"))
    end
  end

  class Controller
    # Non-model form (`<%= form_tag("/search", method: :get) { ... } %>`).
    # Includes the CSRF token for non-GET methods.
    def form_tag(action : String, method : String | Symbol = "post", multipart : Bool = false, **attributes, &block : -> String) : String
      verb = method.to_s.downcase
      token = (verb == "get") ? nil : form_authenticity_token
      Views.form_tag(action, method, token, multipart, **attributes, &block)
    end

    def text_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.text_field_tag(name, value, **attributes)
    end

    def password_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.password_field_tag(name, value, **attributes)
    end

    def hidden_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.hidden_field_tag(name, value, **attributes)
    end

    def email_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.email_field_tag(name, value, **attributes)
    end

    def number_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.number_field_tag(name, value, **attributes)
    end

    def search_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.search_field_tag(name, value, **attributes)
    end

    def url_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.url_field_tag(name, value, **attributes)
    end

    def telephone_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.telephone_field_tag(name, value, **attributes)
    end

    def date_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.date_field_tag(name, value, **attributes)
    end

    def datetime_local_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.datetime_local_field_tag(name, value, **attributes)
    end

    def time_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.time_field_tag(name, value, **attributes)
    end

    def month_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.month_field_tag(name, value, **attributes)
    end

    def week_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.week_field_tag(name, value, **attributes)
    end

    def color_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.color_field_tag(name, value, **attributes)
    end

    def range_field_tag(name : String, value : String? = nil, **attributes) : String
      Views.range_field_tag(name, value, **attributes)
    end

    def file_field_tag(name : String, **attributes) : String
      Views.file_field_tag(name, **attributes)
    end

    def text_area_tag(name : String, content : String? = nil, **attributes) : String
      Views.text_area_tag(name, content, **attributes)
    end

    def check_box_tag(name : String, value : String = "1", checked : Bool = false, **attributes) : String
      Views.check_box_tag(name, value, checked, **attributes)
    end

    def radio_button_tag(name : String, value : String, checked : Bool = false, **attributes) : String
      Views.radio_button_tag(name, value, checked, **attributes)
    end

    def submit_tag(value : String = "Save", **attributes) : String
      Views.submit_tag(value, **attributes)
    end

    def label_tag(name : String? = nil, text : String? = nil, **attributes) : String
      Views.label_tag(name, text, **attributes)
    end

    def select_tag(name : String, option_tags : String? = nil, **attributes) : String
      Views.select_tag(name, option_tags, **attributes)
    end

    def select_tag(name : String, options : Array, selected : Object? = nil, **attributes) : String
      Views.select_tag(name, options, selected, **attributes)
    end

    def select_tag(name : String, **attributes, &block : -> String) : String
      Views.select_tag(name, **attributes, &block)
    end

    def options_for_select(container : Array, selected : Object? = nil) : String
      Views.options_for_select(container, selected)
    end

    def options_from_collection_for_select(collection : Array, value_method : String | Symbol, text_method : String | Symbol, selected : Object? = nil) : String
      Views.options_from_collection_for_select(collection, value_method, text_method, selected)
    end

    def date_select(name : String, value : Time? = nil, **attributes) : String
      Views.date_select(name, value, **attributes)
    end

    def datetime_select(name : String, value : Time? = nil, **attributes) : String
      Views.datetime_select(name, value, **attributes)
    end
  end
end
