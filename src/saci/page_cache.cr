module Saci
  # File-backed page cache (Lobsters `caches_page` equivalent).
  #
  # ```
  # Saci::PageCache.write("/stories", rendered_html)
  # Saci::PageCache.read("/stories")     # => String | nil
  # Saci::PageCache.expire("/stories")   # => Bool
  # Saci::PageCache.expire_dir("/stories") # => Int32 (files removed)
  # ```
  #
  # Designed for a `CachePageJob` to call: render a path, `write` the body,
  # and serve `read` hits without rendering. `fetch` is the write-through
  # variant. Everything lives under `root` (`tmp/page_cache` by default —
  # gitignored, ephemeral). Paths with `..` are rejected (`ArgumentError`).
  module PageCache
    DEFAULT_ROOT = "tmp/page_cache"

    @@root : String = DEFAULT_ROOT
    @@mutex = Mutex.new

    def self.root : String
      @@mutex.synchronize { @@root }
    end

    def self.root=(path : String) : Nil
      @@mutex.synchronize { @@root = path.rstrip('/') }
    end

    def self.reset! : Nil
      @@mutex.synchronize { @@root = DEFAULT_ROOT }
    end

    # Filesystem path backing a URL path (extensionless paths gain `.html`,
    # directories gain `index.html`).
    def self.file_for(path : String) : String
      File.join(root, cache_key(path))
    end

    # Stores `content` for `path`. Returns the file written.
    def self.write(path : String, content : String) : String
      file = file_for(path)
      Dir.mkdir_p(File.dirname(file))
      File.write(file, content)
      file
    end

    # Cached body for `path`, or nil on a miss.
    def self.read(path : String) : String?
      file = file_for(path)
      File.file?(file) ? File.read(file) : nil
    end

    def self.exists?(path : String) : Bool
      File.file?(file_for(path))
    end

    # Removes one entry (pruning newly empty dirs). False when absent.
    def self.expire(path : String) : Bool
      file = file_for(path)
      return false unless File.file?(file)
      File.delete(file)
      prune_empty_dirs(File.dirname(file))
      true
    end

    # Removes every cached file under a URL prefix (`"/stories"` clears
    # `/stories` itself plus `/stories/top`, … but not `/story`). Returns
    # the file count removed.
    def self.expire_dir(dir : String) : Int32
      count = 0
      key = dir_key(dir)
      unless key.empty?
        base = File.join(root, key)
        if Dir.exists?(base)
          Dir.glob("#{base}/**/*").each do |entry|
            if File.file?(entry)
              File.delete(entry)
              count += 1
            end
          end
          prune_empty_dirs(base)
        end
      else
        Dir.glob("#{root}/**/*").each do |entry|
          if File.file?(entry)
            File.delete(entry)
            count += 1
          end
        end
      end
      # Plus the page stored exactly at this path (`/stories` itself).
      page = file_for(dir)
      if File.file?(page)
        File.delete(page)
        prune_empty_dirs(File.dirname(page))
        count += 1
      end
      count
    end

    # Empties the whole cache (keeps the root dir itself).
    def self.clear! : Nil
      r = root
      return unless Dir.exists?(r)
      Dir.glob("#{r}/**/*").each do |entry|
        File.delete(entry) if File.file?(entry)
      end
      Dir.glob("#{r}/**/*").select { |d| Dir.exists?(d) }.sort_by(&.size).reverse_each do |d|
        begin
          Dir.delete(d)
        rescue
        end
      end
    end

    # Write-through: returns the cached body, rendering + storing on a miss.
    def self.fetch(path : String, & : -> String) : String
      if hit = read(path)
        hit
      else
        content = yield
        write(path, content)
        content
      end
    end

    private def self.cache_key(path : String) : String
      parts = key_parts(path)
      key = parts.join("/")
      key = "index" if key.empty?
      key += "/index" if path_key_dir?(path) && key != "index"
      key += ".html" if File.extname(key).empty?
      key
    end

    private def self.dir_key(dir : String) : String
      key_parts(dir).join("/")
    end

    private def self.path_key_dir?(path : String) : Bool
      bare = path.split("?")[0].split("#")[0]
      bare.ends_with?("/")
    end

    private def self.key_parts(path : String) : Array(String)
      bare = path.split("?")[0].split("#")[0].strip.gsub(/\/+/, "/").lstrip('/')
      parts = bare.split("/").reject(&.empty?)
      if parts.any?(&.==(".."))
        raise ArgumentError.new("Saci::PageCache refuses path with '..' (#{path.inspect})")
      end
      parts
    end

    # Removes `dir` and its parents while they are empty, stopping at root.
    private def self.prune_empty_dirs(dir : String) : Nil
      r = root
      current = dir
      while current != r && current.starts_with?(r + "/") && Dir.exists?(current)
        break unless Dir.children(current).empty?
        Dir.delete(current)
        current = File.dirname(current)
      end
    end
  end
end
