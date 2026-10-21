# Rails-style inflections, layered onto `Saci::Record::Inflector` without
# editing the ORM-owned file. The original `pluralize`/`underscore`/
# `tableize` remain the base rules; this file adds the rest of the Rails
# vocabulary plus a small irregular table.
#
# `constantize` is intentionally not provided: Crystal has no runtime
# constant lookup/eval. Use a case/when registry or a macro in application
# code instead.
module Saci
  module Record
    module Inflector
      IRREGULAR = {
        "person"   => "people",
        "man"      => "men",
        "woman"    => "women",
        "child"    => "children",
        "sex"      => "sexes",
        "move"     => "moves",
        "zombie"   => "zombies",
        "mouse"    => "mice",
        "goose"    => "geese",
        "foot"     => "feet",
        "tooth"    => "teeth",
        "ox"       => "oxen",
        "datum"    => "data",
        "medium"   => "media",
        "analysis" => "analyses",
        "basis"    => "bases",
        "crisis"   => "crises",
        "thesis"   => "theses",
        "index"    => "indices",
        "matrix"   => "matrices",
        "vertex"   => "vertices",
        "leaf"     => "leaves",
        "wife"     => "wives",
        "life"     => "lives",
        "knife"    => "knives",
        "status"   => "statuses",
        "alias"    => "aliases",
        "quiz"     => "quizzes",
      }

      REVERSE_IRREGULAR = IRREGULAR.to_h { |singular, plural| {plural, singular} }

      # Redefines the ORM's suffix-only pluralizer with irregulars first.
      # (Crystal resolves reopened methods last-definition-wins.)
      def self.pluralize(word : String) : String
        return word if word.empty?
        lower = word.downcase
        if irregular = IRREGULAR[lower]?
          preserve_case(word, irregular)
        elsif (lower.ends_with?("lf") || lower.ends_with?("rf")) && lower.size > 2
          word[0...-1] + "ves"
        elsif lower.ends_with?("s") || lower.ends_with?("x") || lower.ends_with?("z") ||
              lower.ends_with?("ch") || lower.ends_with?("sh")
          word + "es"
        elsif lower.ends_with?("y") && lower.size > 1 && !"aeiou".includes?(lower[-2])
          word[0...-1] + "ies"
        else
          word + "s"
        end
      end

      # `pluralize("post")` / `pluralize("post", 2)`; count 1 keeps the word.
      def self.pluralize(word : String, count : Int) : String
        count == 1 ? word : pluralize(word)
      end

      def self.pluralize(word : String, count : Int64) : String
        count == 1 ? word : pluralize(word)
      end

      def self.plural(word : String) : String
        pluralize(word)
      end

      def self.singularize(word : String) : String
        return word if word.empty?
        lower = word.downcase
        if irregular = REVERSE_IRREGULAR[lower]?
          preserve_case(word, irregular)
        elsif lower.ends_with?("ies") && lower.size > 3
          word[0...-3] + "y"
        elsif lower.ends_with?("ives")
          word[0...-1]
        elsif lower.ends_with?("ves") && lower.size > 3
          word[0...-3] + "f"
        elsif lower.ends_with?("ses") || lower.ends_with?("xes") || lower.ends_with?("zes") ||
              lower.ends_with?("ches") || lower.ends_with?("shes")
          word[0...-2]
        elsif lower.ends_with?("ss")
          word
        elsif lower.ends_with?("s")
          word[0...-1]
        else
          word
        end
      end

      # "admin/user" -> "Admin::User"; "active_record" -> "ActiveRecord".
      def self.camelize(term : String, upper : Bool = true) : String
        camel = term.split('/').map do |part|
          part.split('_').map(&.capitalize).join
        end.join("::")
        upper ? camel : (camel.empty? ? camel : camel[0].downcase + camel[1..])
      end

      def self.humanize(term : String, capitalize : Bool = true) : String
        result = term.gsub(/_id\z/, "").gsub('_', ' ').strip
        capitalize ? result.capitalize : result
      end

      def self.titleize(term : String) : String
        humanize(term, capitalize: false).split(/\s+/).map(&.capitalize).join(' ')
      end

      def self.parameterize(term : String, separator : String = "-") : String
        sep = Regex.escape(separator)
        ascii = term.downcase
          .gsub(/[^a-z0-9]+/, separator)
          .gsub(/#{sep}{2,}/, separator)
          .gsub(/\A#{sep}+|#{sep}+\z/, "")
        ascii.empty? ? separator : ascii
      end

      def self.classify(table_name : String) : String
        camelize(singularize(table_name.sub(/\A.*[.\/]/, "")))
      end

      # "Admin::User" -> "admin_users" (namespaces become underscores).
      def self.tableize(class_name : String) : String
        pluralize(underscore(class_name).gsub('/', '_'))
      end

      def self.demodulize(class_name : String) : String
        class_name.split("::").last.split('/').last
      end

      def self.ordinalize(number : Int) : String
        abs = number.abs
        suffix = if (11..13).includes?(abs % 100)
                   "th"
                 else
                   case abs % 10
                   when 1 then "st"
                   when 2 then "nd"
                   when 3 then "rd"
                   else        "th"
                   end
                 end
        "#{number}#{suffix}"
      end

      def self.foreign_key(class_name : String, separate_class_id : Bool = false) : String
        base = underscore(demodulize(class_name))
        separate_class_id ? "#{base}_id" : (base.ends_with?("_id") ? base : "#{base}_id")
      end

      private def self.preserve_case(original : String, plural : String) : String
        original[0].uppercase? ? plural.capitalize : plural
      end
    end
  end
end
