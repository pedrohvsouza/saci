module Saci
  module CLI
    # File watching + rebuild/restart loop behind `saci serve --watch`.
    #
    # Crystal compiles to a native binary, so hot-reload means: watch source
    # files, rebuild with `crystal run`, restart the child process. Polling
    # (mtime snapshots) keeps this dependency-free and portable.
    module Watch
      alias Snapshot = Hash(String, Time)

      DEFAULT_INTERVAL = 0.5
      DEBOUNCE_QUIET   = 0.5
      KILL_GRACE       = 5.0

      WATCH_DIRS  = ["src", "db", "config"]
      WATCH_FILES = ["shard.yml", "shard.lock"]
      IGNORE_DIRS = ["tmp", "log", ".git", "lib", ".shards", "bin"]
      IGNORE_RES  = [/\.db$/, /\.log$/, /\.tmp$/]

      def self.watched?(path : String) : Bool
        return false unless File.file?(path)
        parts = path.split(File::SEPARATOR)
        return false if parts.any? { |p| IGNORE_DIRS.includes?(p) }
        IGNORE_RES.none? { |re| re.matches?(path) }
      end

      def self.roots : Array(String)
        dirs = WATCH_DIRS.select { |d| Dir.exists?(d) }
        dirs + WATCH_FILES.select { |f| File.exists?(f) }
      end

      def self.snapshot(paths : Array(String) = roots) : Snapshot
        snap = Snapshot.new
        paths.each do |path|
          if Dir.exists?(path)
            Dir.glob("#{path}/**/*") do |entry|
              next unless watched?(entry)
              begin
                snap[entry] = File.info(entry).modification_time
              rescue
                # Deleted mid-scan; ignore.
              end
            end
          elsif watched?(path)
            begin
              snap[path] = File.info(path).modification_time
            rescue
              # Deleted mid-scan; ignore.
            end
          end
        end
        snap
      end

      def self.changed?(old_snapshot : Snapshot, new_snapshot : Snapshot) : Bool
        return true if old_snapshot.size != new_snapshot.size
        old_snapshot.any? { |path, mtime| new_snapshot[path]? != mtime }
      end

      # Supervises the app in `dir`: rebuilds with `crystal build` into
      # `tmp/` (ignored by the watcher) and restarts the resulting binary.
      # Building (instead of `crystal run`) keeps supervision to a SINGLE
      # child process — `crystal run` spawns the app as a grandchild, which
      # would survive TERM and keep holding the port (stale orphan server).
      # Returns 0 on clean shutdown (INT/TERM).
      def self.serve(entry : String, bin_path : String, env : Hash(String, String), build_base : Array(String), interval : Float64 = DEFAULT_INTERVAL) : Int32
        shutdown = false
        Signal::INT.trap { shutdown = true }
        Signal::TERM.trap { shutdown = true }

        Dir.mkdir_p(File.dirname(bin_path))
        baseline = snapshot
        puts "[saci] watching #{roots.join(", ")} — Ctrl-C to stop"

        loop do
          break 0 if shutdown
          if build(entry, bin_path, build_base)
            break 0 if shutdown
            child = spawn_app(bin_path, env)
            outcome = monitor(child, baseline, interval, -> { shutdown })

            stop(child)
            break 0 if shutdown

            case outcome
            when :changed
              # Debounce: wait for writes to settle, confirm against baseline.
              sleep DEBOUNCE_QUIET.seconds
              break 0 if shutdown
              if changed?(baseline, snapshot)
                puts "[saci] change detected — rebuilding..."
                baseline = snapshot
                next
              end
              # Settled back (e.g. editor swap files) — keep watching.
              baseline = snapshot
            when :died
              puts "[saci] process exited — fix errors or save a file to rebuild (Ctrl-C to stop)"
              baseline = wait_for_change(baseline, interval, -> { shutdown })
            end
          else
            # Build failed — wait for a fix instead of hot-spinning.
            puts "[saci] build failed — fix errors or save a file to rebuild (Ctrl-C to stop)"
            baseline = wait_for_change(baseline, interval, -> { shutdown })
          end
        end
        0
      end

      private def self.build(entry : String, bin_path : String, build_base : Array(String)) : Bool
        cmd = build_base + ["-o", bin_path, entry]
        puts "[saci] building: #{cmd.join(" ")}"
        Process.run(cmd[0], args: cmd[1..], output: STDOUT, error: STDERR).success?
      end

      private def self.spawn_app(bin_path : String, env : Hash(String, String)) : Process
        puts "[saci] starting #{bin_path}"
        Process.new(bin_path, env: env, output: STDOUT, error: STDERR)
      end

      # Blocks until the child dies, files change, or shutdown is requested.
      private def self.monitor(child : Process, baseline : Snapshot, interval : Float64, shutdown_flag : -> Bool) : Symbol
        loop do
          return :shutdown if shutdown_flag.call
          return :died if child.terminated?
          return :changed if changed?(baseline, snapshot)
          sleep interval.seconds
        end
      end

      # Blocks until files change or shutdown is requested. Returns the
      # fresh baseline.
      private def self.wait_for_change(baseline : Snapshot, interval : Float64, shutdown_flag : -> Bool) : Snapshot
        loop do
          return baseline if shutdown_flag.call
          fresh = snapshot
          return fresh if changed?(baseline, fresh)
          sleep interval.seconds
        end
      end

      private def self.stop(child : Process) : Nil
        return if child.terminated?
        begin
          child.terminate
        rescue
          return
        end
        deadline = Time.instant + KILL_GRACE.seconds
        until child.terminated? || Time.instant > deadline
          sleep 0.1.seconds
        end
        begin
          child.signal(Signal::KILL) unless child.terminated?
        rescue
        end
      end
    end
  end
end
