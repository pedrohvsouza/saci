module Saci
  module Record
    # Default HABTM join table name: both table names sorted lexicographically
    # (Rails' `create_join_table` convention).
    def self.habtm_join_table(left : String, right : String) : String
      [left, right].sort.join("_")
    end
  end

  class Record::Base
    # `has_and_belongs_to_many` (G33) — a join table with no model class.
    #
    # ```
    # class Article < Saci::Record::Base
    #   column id : Int64, primary: true
    #   column title : String
    #   has_and_belongs_to_many :tags, join_table: "articles_tags",
    #     foreign_key: "article_id", association_foreign_key: "tag_id"
    # end
    #
    # article.tags                # => Query(Tag)
    # article.tags << tag         # INSERT join row (idempotent)
    # article.tags.delete(tag)    # DELETE join row
    # article.tags = [tag1, tag2] # replace all join rows
    # Article.includes(:tags)     # 2 queries, no N+1
    # ```
    #
    # Defaults: `join_table` is the two table names sorted (`articles_tags`),
    # `foreign_key` is `<owner>_id`, `association_foreign_key` is
    # `<target>_id`. `dependent:` is intentionally not accepted (delete the
    # join rows explicitly or use a `has_many :through` join model).
    macro has_and_belongs_to_many(name, class_name = nil, join_table = nil, foreign_key = nil, association_foreign_key = nil)
      {% n = name.id.stringify %}
      {% sing = n.ends_with?("ies") ? n[0...-3] + "y" : (n.ends_with?("s") ? n[0...-1] : n) %}
      {% k = (class_name ? class_name.id.stringify : sing.camelcase).id %}

      def __saci_habtm_{{name.id}}_table : String
        {% if join_table %}
          {{join_table.id.stringify}}
        {% else %}
          Saci::Record.habtm_join_table(self.class.table_name, {{k}}.table_name)
        {% end %}
      end

      def __saci_habtm_{{name.id}}_fk : String
        {% if foreign_key %}
          {{foreign_key.id.stringify}}
        {% else %}
          Saci::Record::Inflector.underscore(self.class.name.split("::").last) + "_id"
        {% end %}
      end

      def __saci_habtm_{{name.id}}_afk : String
        {% if association_foreign_key %}
          {{association_foreign_key.id.stringify}}
        {% else %}
          Saci::Record::Inflector.underscore({{k}}.name.split("::").last) + "_id"
        {% end %}
      end

      def {{name.id}} : Saci::Record::Query({{k}})
        if __saci_assoc_cache.has_key?({{n}})
          %cached = __saci_assoc_cache[{{n}}].as(Array(Saci::Record::Base)).map { |%el| %el.as({{k}}) }
          return {{k}}.where("1 = 1").__saci_with_records(%cached).__saci_with_habtm(self, __saci_habtm_{{name.id}}_table, __saci_habtm_{{name.id}}_fk, __saci_habtm_{{name.id}}_afk)
        end
        %owner_pk = __saci_get_attr(self.class.__saci_primary_key)
        return {{k}}.where("1 = 0") if %owner_pk.nil?
        %ad = Saci::Record.adapter_of(self.class.connection)
        %table = Saci::Record.quote(__saci_habtm_{{name.id}}_table, %ad)
        %fk = Saci::Record.quote(__saci_habtm_{{name.id}}_fk, %ad)
        %afk = Saci::Record.quote(__saci_habtm_{{name.id}}_afk, %ad)
        %ids = [] of Saci::Record::Value
        Saci::Record.query_compat(self.class.connection,
          "SELECT " + %afk + " FROM " + %table + " WHERE " + %fk + " = ?",
          [Saci::Record.to_db(%owner_pk, %ad)] of Saci::Record::Value) do |%rs|
          %rs.each { %ids << Saci::Record.read_generic(%rs) }
        end
        return {{k}}.where("1 = 0").__saci_with_habtm(self, __saci_habtm_{{name.id}}_table, __saci_habtm_{{name.id}}_fk, __saci_habtm_{{name.id}}_afk) if %ids.empty?
        %tpk = Saci::Record.quote({{k}}.primary_key_name, %ad)
        %ph = Array(String).new(%ids.size, "?").join(", ")
        {{k}}.where(%tpk + " IN (" + %ph + ")", %ids).__saci_with_habtm(self, __saci_habtm_{{name.id}}_table, __saci_habtm_{{name.id}}_fk, __saci_habtm_{{name.id}}_afk)
      end

      # Adds one join row (idempotent) and returns the target record.
      def add_{{name.id}}(record : {{k}}) : {{k}}
        %owner_pk = __saci_get_attr(self.class.__saci_primary_key)
        raise Saci::Record::RecordNotSaved.new("Cannot add to #{ {{n}} } on an unsaved #{self.class}") if %owner_pk.nil?
        %target_pk = record.__saci_get_attr({{k}}.__saci_primary_key)
        raise Saci::Record::RecordNotSaved.new("Cannot add an unsaved {{k}} to #{ {{n}} }") if %target_pk.nil?
        %ad = Saci::Record.adapter_of(self.class.connection)
        %table = Saci::Record.quote(__saci_habtm_{{name.id}}_table, %ad)
        %fk = Saci::Record.quote(__saci_habtm_{{name.id}}_fk, %ad)
        %afk = Saci::Record.quote(__saci_habtm_{{name.id}}_afk, %ad)
        %count = Saci::Record.scalar_compat(self.class.connection,
          "SELECT COUNT(*) FROM " + %table + " WHERE " + %fk + " = ? AND " + %afk + " = ?",
          [Saci::Record.to_db(%owner_pk, %ad), Saci::Record.to_db(%target_pk, %ad)] of Saci::Record::Value)
        unless %count.as(Int64) > 0
          Saci::Record.exec_compat(self.class.connection,
            "INSERT INTO " + %table + " (" + %fk + ", " + %afk + ") VALUES (?, ?)",
            [Saci::Record.to_db(%owner_pk, %ad), Saci::Record.to_db(%target_pk, %ad)] of Saci::Record::Value)
        end
        record
      end

      def <<(record : {{k}}) : {{k}}
        add_{{name.id}}(record)
      end

      # Removes the join row for `record` (the target row itself is kept).
      def delete_{{name.id}}(record : {{k}}) : {{k}}
        %owner_pk = __saci_get_attr(self.class.__saci_primary_key)
        %target_pk = record.__saci_get_attr({{k}}.__saci_primary_key)
        if !%owner_pk.nil? && !%target_pk.nil?
          %ad = Saci::Record.adapter_of(self.class.connection)
          Saci::Record.exec_compat(self.class.connection,
            "DELETE FROM " + Saci::Record.quote(__saci_habtm_{{name.id}}_table, %ad) +
              " WHERE " + Saci::Record.quote(__saci_habtm_{{name.id}}_fk, %ad) + " = ?" +
              " AND " + Saci::Record.quote(__saci_habtm_{{name.id}}_afk, %ad) + " = ?",
            [Saci::Record.to_db(%owner_pk, %ad), Saci::Record.to_db(%target_pk, %ad)] of Saci::Record::Value)
        end
        record
      end

      # `article.tags.delete(tag)` compatibility alias.
      def delete(record : {{k}}) : {{k}}
        delete_{{name.id}}(record)
      end

      # Replaces every join row for this owner.
      def {{name.id}}=(records : Array({{k}})) : Array({{k}})
        %owner_pk = __saci_get_attr(self.class.__saci_primary_key)
        raise Saci::Record::RecordNotSaved.new("Cannot assign #{ {{n}} } on an unsaved #{self.class}") if %owner_pk.nil?
        %ad = Saci::Record.adapter_of(self.class.connection)
        %table = Saci::Record.quote(__saci_habtm_{{name.id}}_table, %ad)
        %fk = Saci::Record.quote(__saci_habtm_{{name.id}}_fk, %ad)
        %afk = Saci::Record.quote(__saci_habtm_{{name.id}}_afk, %ad)
        Saci::Record.exec_compat(self.class.connection,
          "DELETE FROM " + %table + " WHERE " + %fk + " = ?",
          [Saci::Record.to_db(%owner_pk, %ad)] of Saci::Record::Value)
        records.each do |%rec|
          %tpk = %rec.__saci_get_attr({{k}}.__saci_primary_key)
          next if %tpk.nil?
          Saci::Record.exec_compat(self.class.connection,
            "INSERT INTO " + %table + " (" + %fk + ", " + %afk + ") VALUES (?, ?)",
            [Saci::Record.to_db(%owner_pk, %ad), Saci::Record.to_db(%tpk, %ad)] of Saci::Record::Value)
        end
        __saci_set_assoc({{n}}, records.map(&.as(Saci::Record::Base)))
        records
      end

      def __saci_assoc_current(assoc_name : String) : Array(Saci::Record::Base)
        if assoc_name == {{n}}
          if __saci_assoc_cache.has_key?({{n}})
            __saci_assoc_cache[{{n}}].as(Array(Saci::Record::Base)).dup
          else
            self.{{name.id}}.to_a.map(&.as(Saci::Record::Base))
          end
        else
          previous_def
        end
      end

      def self.__saci_preload_{{name.id}}(records : Array(Saci::Record::Base)) : Nil
        %owner_ids = [] of Saci::Record::Value
        records.each do |%rec|
          %pk = %rec.__saci_get_attr(self.__saci_primary_key)
          %owner_ids << %pk unless %pk.nil?
        end
        %grouped = {} of Saci::Record::Value => Array(Saci::Record::Value)
        %all_target_ids = [] of Saci::Record::Value
        unless %owner_ids.empty?
          %puniq = %owner_ids.uniq
          %ad = Saci::Record.adapter_of(self.connection)
          # Respect explicit join_table/foreign keys by reading the same
          # naming helpers used by the instance getter.
          %sample = self.new
          %table = Saci::Record.quote(%sample.__saci_habtm_{{name.id}}_table, %ad)
          %fk = Saci::Record.quote(%sample.__saci_habtm_{{name.id}}_fk, %ad)
          %afk = Saci::Record.quote(%sample.__saci_habtm_{{name.id}}_afk, %ad)
          %ph = Array(String).new(%puniq.size, "?").join(", ")
          Saci::Record.query_compat(self.connection,
            "SELECT " + %fk + ", " + %afk + " FROM " + %table + " WHERE " + %fk + " IN (" + %ph + ")",
            %puniq) do |%rs|
            %rs.each do
              %owner = Saci::Record.read_generic(%rs)
              %target = Saci::Record.read_generic(%rs)
              next if %owner.nil? || %target.nil?
              (%grouped[%owner] ||= [] of Saci::Record::Value) << %target
              %all_target_ids << %target
            end
          end
        end
        %found = {} of Saci::Record::Value => Saci::Record::Base
        unless %all_target_ids.empty?
          %tuniq = %all_target_ids.uniq
          %tph = Array(String).new(%tuniq.size, "?").join(", ")
          %tad = Saci::Record.adapter_of({{k}}.connection)
          {{k}}.where(Saci::Record.quote({{k}}.primary_key_name, %tad) + " IN (" + %tph + ")", %tuniq).to_a.each do |%t|
            %found[%t.__saci_get_attr({{k}}.primary_key_name)] = %t
          end
        end
        records.each do |%rec|
          %pk = %rec.__saci_get_attr(self.__saci_primary_key)
          %list = [] of Saci::Record::Base
          if !%pk.nil?
            (%grouped[%pk]? || [] of Saci::Record::Value).each do |%tid|
              if %hit = %found[%tid]?
                %list << %hit
              end
            end
          end
          %rec.__saci_set_assoc({{n}}, %list)
        end
      end

      def self.__saci_preload_assoc(records : Array(Saci::Record::Base), assoc_name : String) : Nil
        if assoc_name == {{n}}
          __saci_preload_{{name.id}}(records)
        else
          previous_def
        end
      end

      def self.__saci_assoc_kinds : Hash(String, Symbol)
        %kinds = previous_def.dup
        %kinds[{{n}}] = :habtm
        %kinds
      end

      def self.__saci_assoc_meta(assoc_name : String) : Saci::Record::AssocMeta?
        if assoc_name == {{n}}
          Saci::Record::AssocMeta.new(:habtm, {{k}}.table_name, nil, nil,
            -> { {{k}}.new.as(Saci::Record::Base) },
            ->(id : Saci::Record::Value) { {{k}}.find(id).as(Saci::Record::Base) })
        else
          previous_def
        end
      end

      def self.__saci_join_sql(assoc_name : String) : String?
        if assoc_name == {{n}}
          ad = Saci::Record.adapter_of(self.connection)
          %sample = self.new
          base = Saci::Record.quote(self.table_name, ad)
          base_pk = Saci::Record.quote(self.__saci_primary_key, ad)
          join = Saci::Record.quote(%sample.__saci_habtm_{{name.id}}_table, ad)
          fk = Saci::Record.quote(%sample.__saci_habtm_{{name.id}}_fk, ad)
          afk = Saci::Record.quote(%sample.__saci_habtm_{{name.id}}_afk, ad)
          target = Saci::Record.quote({{k}}.table_name, ad)
          target_pk = Saci::Record.quote({{k}}.primary_key_name, ad)
          "INNER JOIN " + join + " ON " + join + "." + fk + " = " + base + "." + base_pk +
            " INNER JOIN " + target + " ON " + target + "." + target_pk + " = " + join + "." + afk
        else
          previous_def
        end
      end
    end
  end
end
