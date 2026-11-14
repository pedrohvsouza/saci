require "colorize"

module Saci
  module CLI
    # Progress line for slow steps (compiling the app, migrations, specs):
    #
    # ```text
    # ⠹ Compiling phvsz… 4.2s
    # ✓ Compiled phvsz in 11.8s
    # ```
    #
    # It animates on STDERR only when that is a terminal, so pipes, CI logs
    # and files get two plain lines (`Compiling phvsz...` and the result).
    # `SACI_SPINNER=0` turns the animation off, `SACI_SPINNER=1` forces it;
    # `NO_COLOR` drops the colors.
    class Spinner
      FRAMES   = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
      INTERVAL = 80.milliseconds

      def self.animate?(io : IO = STDERR) : Bool
        case ENV["SACI_SPINNER"]?.try(&.downcase)
        when "1", "true", "always" then return true
        when "0", "false", "never" then return false
        end
        return false if ENV["CI"]?.presence || ENV["TERM"]? == "dumb"
        io.is_a?(IO::FileDescriptor) && io.tty?
      end

      def self.color?(io : IO = STDERR) : Bool
        return false if ENV["NO_COLOR"]?.presence
        io.is_a?(IO::FileDescriptor) && io.tty?
      end

      # "4.2s", or "1m 07s" past a minute.
      def self.format_elapsed(span : Time::Span) : String
        seconds = span.total_seconds
        return "%.1fs" % seconds if seconds < 60
        minutes = (seconds // 60).to_i
        "#{minutes}m #{"%02d" % (seconds - minutes * 60).to_i}s"
      end

      # Shows the spinner while the block runs. The block's truthiness
      # picks the final line: `✓ <done> in 1.2s` or `✗ <label> failed after 1.2s`.
      def self.run(label : String, done : String, io : IO = STDERR, & : -> Bool) : Bool
        spinner = new(label, done, io)
        spinner.start
        ok = false
        begin
          ok = yield
        ensure
          spinner.stop(ok)
        end
        ok
      end

      getter label : String

      @started : Time::Instant? = nil
      @running = false
      @finished : Channel(Nil)? = nil

      def initialize(@label : String, @done : String, @io : IO = STDERR,
                     @animate : Bool = Spinner.animate?(io), @color : Bool = Spinner.color?(io))
      end

      def start : self
        @started = Time.instant
        if @animate
          @running = true
          finished = Channel(Nil).new(1)
          @finished = finished
          spawn(name: "saci-spinner") do
            frame = 0
            while @running
              @io << "\r\e[2K" << paint(FRAMES[frame % FRAMES.size], :cyan) << ' ' << @label << "… " << paint(elapsed, :dark_gray)
              @io.flush
              frame += 1
              sleep INTERVAL
            end
            finished.send(nil)
          end
        else
          @io.puts "#{@label}..."
          @io.flush
        end
        self
      end

      def stop(success : Bool) : Nil
        if @animate && @running
          @running = false
          @finished.try(&.receive)
          @io << "\r\e[2K"
        end
        if success
          @io.puts "#{paint("✓", :green)} #{@done} #{paint("in #{elapsed}", :dark_gray)}"
        else
          @io.puts "#{paint("✗", :red)} #{@label} failed #{paint("after #{elapsed}", :dark_gray)}"
        end
        @io.flush
      end

      private def elapsed : String
        started = @started
        started ? Spinner.format_elapsed(Time.instant - started) : "0.0s"
      end

      private def paint(text : String, color : Symbol) : String
        return text unless @color
        case color
        when :green     then text.colorize(:green).to_s
        when :red       then text.colorize(:red).to_s
        when :cyan      then text.colorize(:cyan).to_s
        when :dark_gray then text.colorize(:dark_gray).to_s
        else                 text
        end
      end
    end

    # Compiles with `crystal build` behind a `Spinner`, then runs the
    # binary. `crystal run` compiles and runs in one process, so it gives no
    # moment to stop a spinner before the program's own output starts.
    # Compiler output (warnings, errors) is captured during the build and
    # printed once the progress line is done.
    module Compile
      BIN_DIR = File.join("tmp", ".saci-bin")

      # `crystal build <args>`; true when it succeeded.
      def self.build(args : Array(String), name : String) : Bool
        crystal = Util.crystal_bin!
        log = IO::Memory.new
        ok = Spinner.run("Compiling #{name}", "Compiled #{name}") do
          Process.run(crystal, args: ["build"] + args, output: log, error: log).success?
        end
        unless log.empty?
          STDERR.print(log.to_s)
          STDERR.flush
        end
        ok
      end

      # Builds `entry` into a throwaway binary and runs it. Nil when the
      # build failed (its errors are already printed).
      def self.run_status(entry : String, flags : Array(String) = [] of String, args : Array(String) = [] of String,
                          name : String = entry, env : Hash(String, String)? = nil,
                          output : Process::Stdio = Process::Redirect::Inherit,
                          error : Process::Stdio = Process::Redirect::Inherit) : Process::Status?
        bin = binary_path(entry)
        return nil unless build(flags + ["-o", bin, entry], name)
        begin
          Process.run(bin, args: args, env: env, input: Process::Redirect::Inherit, output: output, error: error)
        ensure
          remove_binary(bin)
        end
      end

      # Same as `run_status`, as a CLI exit code (0 or 1).
      def self.run(entry : String, flags : Array(String) = [] of String, args : Array(String) = [] of String,
                   name : String = entry, env : Hash(String, String)? = nil,
                   output : Process::Stdio = Process::Redirect::Inherit) : Int32
        status = run_status(entry, flags, args, name: name, env: env, output: output)
        status && status.success? ? 0 : 1
      end

      def self.binary_path(entry : String) : String
        Dir.mkdir_p(BIN_DIR)
        File.join(BIN_DIR, "#{File.basename(entry, ".cr").lchop('.')}-#{Process.pid}")
      end

      def self.remove_binary(bin : String) : Nil
        {bin, "#{bin}.dwarf"}.each { |path| File.delete(path) if File.exists?(path) }
      rescue File::Error
      end
    end
  end
end
