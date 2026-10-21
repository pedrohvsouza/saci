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

      # App name when run inside a Saci app, nil elsewhere (commands like
      # `about`/`stats` stay useful outside an app).
      def self.app_name? : String?
        path = File.join(Dir.current, "shard.yml")
        return nil unless File.exists?(path)
        if m = File.read(path).match(/^name:\s*(.+?)\s*$/m)
          m[1].strip
        end
      end

      # Database adapter picked by `saci new` (detected from the
      # entrypoint's driver require). Falls back to SQLite.
      def self.db_kind(name : String) : String
        entry = File.join("src", "#{name}.cr")
        return "sqlite" unless File.exists?(entry)
        src = File.read(entry)
        return "postgres" if src.includes?("require \"pg\"")
        return "mysql" if src.includes?("require \"mysql\"")
        "sqlite"
      end

      # Default database URL for an environment (same convention as the
      # generated entrypoint / spec helper / db/migrate.cr).
      def self.db_default(name : String, kind : String, env : String) : String
        New.db_url_default(name, kind, env)
      end

      # `require` line for a file shipped inside `src/saci/` (tasks, ci,
      # db_tasks) that is called from a generated `tmp/` runner. Uses the
      # installed shard (`saci/...`) when present, else a file-relative
      # path back into this framework checkout (spec fixtures skip shards).
      def self.internal_require(relative : String, from_dir : String = "tmp") : String
        return "require \"saci/#{relative}\"" if Dir.exists?("lib/saci")
        target = File.join(New::SACI_ROOT, "src", "saci", relative)
        rel = relative_path(File.expand_path(from_dir), target)
        rel = "./#{rel}" unless rel.starts_with?(".")
        "require \"#{rel}\""
      end

      # File-relative require from `from_dir` to `to_path` (no extension).
      def self.relative_path(from_dir : String, to_path : String) : String
        from = from_dir.split("/").reject(&.empty?)
        to = to_path.split("/").reject(&.empty?)
        common = 0
        while common < from.size && common < to.size && from[common] == to[common]
          common += 1
        end
        ups = (from.size - common).times.map { ".." }.to_a
        (ups + to[common..]).join("/")
      end
    end
  end
end
