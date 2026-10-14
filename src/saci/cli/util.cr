module Saci
  module CLI
    class Error < Exception
    end

    module Util
      APP_NAME_RE = /\A[a-z][a-z0-9_]*\z/

      def self.check_app_name!(name : String) : String
        unless APP_NAME_RE.matches?(name)
          raise Error.new("Invalid app name '#{name}'. Use lowercase letters, numbers and underscores, starting with a letter (e.g. `saci new blog`).")
        end
        name
      end

      # "blog_post" -> "BlogPost", "posts" -> "Posts"
      def self.class_name(word : String) : String
        word.split("_").map(&.capitalize).join("")
      end

      # "BlogPost" -> "blog_post"
      def self.file_name(word : String) : String
        Record::Inflector.underscore(word)
      end

      def self.timestamp_version(time : Time = Time.local) : String
        time.to_s("%Y%m%d%H%M%S")
      end

      def self.shard_name(dir : String) : String
        path = File.join(dir, "shard.yml")
        raise Error.new("No shard.yml found in #{dir}. Run this command from your app directory.") unless File.exists?(path)
        m = File.read(path).match(/^name:\s*(.+?)\s*$/m)
        raise Error.new("Could not read app name from #{path}.") unless m
        m[1].strip
      end

      def self.crystal_bin! : String
        Process.find_executable("crystal") || raise Error.new("`crystal` executable not found in PATH.")
      end
    end
  end
end
