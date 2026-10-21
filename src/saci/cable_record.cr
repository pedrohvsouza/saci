require "./cable"

module Saci
  module Cable
    # Default namespace for record-derived streams (`saci:Post:1`).
    DEFAULT_BROADCAST_NAMESPACE = "saci"

    # Derives the pub/sub stream name for a record (G94).
    #
    # * plain records: `saci:<Model>:<id>` (e.g. `saci:Post:1`); an unsaved
    #   record uses `new` as its key;
    # * a model declaring `broadcasts_for :posts` (or an explicit
    #   `prefix:` argument) gets Rails-like `posts:<id>`;
    # * collections of records are mapped individually, sorted, and joined
    #   with `:` (Rails' `broadcasting_for([a, b])` behavior);
    # * strings pass through unchanged (optionally prefixed), so
    #   `stream_for "room:1"` keeps working.
    def self.broadcasting_for(stream : String, prefix : String? = nil) : String
      prefix ? "#{prefix}:#{stream}" : stream
    end

    def self.broadcasting_for(records : Enumerable(T), prefix : String? = nil) : String forall T
      names = [] of String
      records.each { |record| names << broadcasting_for(record, prefix) }
      names.sort.join(":")
    end

    def self.broadcasting_for(record : Saci::Record::Base, prefix : String? = nil) : String
      custom = prefix || record.__saci_cable_broadcast_prefix
      id = record[record.class.primary_key_name]
      key = id.nil? ? "new" : id.to_s
      if custom
        "#{custom}:#{key}"
      else
        "#{DEFAULT_BROADCAST_NAMESPACE}:#{record.class.name.split("::").last}:#{key}"
      end
    end

    # Fallback for lightweight/non-ORM record-like objects exposing `id`
    # (useful in specs and for plain value objects). ORM models use the
    # overload above so custom primary keys are honored.
    def self.broadcasting_for(record : T, prefix : String? = nil) : String forall T
      {% if T.has_method?("id") %}
        {% if T.has_method?("__saci_cable_broadcast_prefix") %}
          custom = prefix || record.__saci_cable_broadcast_prefix
        {% else %}
          custom = prefix
        {% end %}
        id = record.id
        key = id.nil? ? "new" : id.to_s
        if custom
          "#{custom}:#{key}"
        else
          "#{DEFAULT_BROADCAST_NAMESPACE}:#{record.class.name.split("::").last}:#{key}"
        end
      {% else %}
        {% raise "Saci::Cable.broadcasting_for expects a String, a record with #id, or an Enumerable, got #{T}" %}
      {% end %}
    end
  end
end

module Saci
  module Record
    class Base
      # Declares the stream prefix for this model (G94):
      #
      # ```
      # class Post < ApplicationRecord
      #   broadcasts_for :posts
      # end
      #
      # Saci::Cable.broadcasting_for(post) # => "posts:1"
      # ```
      #
      # Without the declaration the default `saci:Model:id` naming is used;
      # a bare `broadcasts_for` uses the model's table name (Rails-like
      # `posts:1`), and an argument sets a custom prefix.
      macro broadcasts_for(prefix = nil)
        def __saci_cable_broadcast_prefix : String?
          {% if prefix %}
            {{prefix}}.to_s
          {% else %}
            self.class.__saci_table_name
          {% end %}
        end
      end

      # Default (no `broadcasts_for` declaration).
      def __saci_cable_broadcast_prefix : String?
        nil
      end

      # Instance convenience for publishers:
      # `post.broadcasting_stream # => "posts:1"`.
      def broadcasting_stream : String
        Saci::Cable.broadcasting_for(self)
      end
    end
  end
end
