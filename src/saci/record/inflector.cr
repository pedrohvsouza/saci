module Saci
  module Record
    module Inflector
      # "SpecAdminUser" -> "spec_admin_user"
      def self.underscore(name : String) : String
        s = name.gsub("::", "/")
        s = s.gsub(/([A-Z]+)([A-Z][a-z])/, "\\1_\\2")
        s = s.gsub(/([a-z0-9])([A-Z])/, "\\1_\\2")
        s.downcase
      end

      def self.pluralize(word : String) : String
        return word if word.empty?
        if word.ends_with?("s") || word.ends_with?("x") || word.ends_with?("z") || word.ends_with?("ch") || word.ends_with?("sh")
          word + "es"
        elsif word.ends_with?("y") && word.size > 1 && !"aeiou".includes?(word[-2].downcase)
          word[0...-1] + "ies"
        else
          word + "s"
        end
      end

      # "SpecUser" -> "spec_users"
      def self.tableize(class_name : String) : String
        pluralize(underscore(class_name.split("::").last))
      end
    end
  end
end
