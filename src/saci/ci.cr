require "file_utils"

module Saci
  # Local CI runner DSL (G121, Rails 8.1 `config/ci.rb` + `bin/ci`).
  #
  # The app convention is `config/ci.cr` (`.rb` is also accepted for
  # familiarity, but it must contain Crystal code):
  #
  # ```
  # require "saci"
  #
  # Saci::CI.step "Format" do
  #   system("crystal tool format --check src spec")
  # end
  #
  # Saci::CI.run "Specs", "crystal spec --no-color"
  # Saci::CI.run "Build", "crystal build src/my_app.cr -o /tmp/my_app"
  # ```
  #
  # `step` runs a compiled block in-process (fail by raising or calling
  # `Saci::CI.fail!`); `run` shells out to a command and fails on a
  # non-zero exit status. `saci ci` executes the registered steps in
  # order, reports per-step timing, and exits 1 when anything failed.
  module CI
    # Raised by `fail!` (and by `run` on a non-zero exit status).
    class StepFailed < Exception
    end

    record Step, name : String, action : Proc(Nil)

    @@steps = [] of Step
    @@mutex = Mutex.new

    # Registers an in-process step.
    def self.step(name : String, &block : -> Nil) : Nil
      @@mutex.synchronize { @@steps << Step.new(name, block) }
    end

    # Registers a shell-command step with an explicit label.
    def self.run(name : String, command : String) : Nil
      command_copy = command
      @@mutex.synchronize do
        @@steps << Step.new(name, -> { run_command(command_copy) })
      end
    end

    # Registers a shell-command step whose label is the command itself.
    def self.run(command : String) : Nil
      run(command, command)
    end

    # Steps registered so far (in execution order).
    def self.steps : Array(Step)
      @@mutex.synchronize { @@steps.dup }
    end

    def self.size : Int32
      @@mutex.synchronize { @@steps.size }
    end

    def self.reset! : Nil
      @@mutex.synchronize { @@steps.clear }
    end

    def self.clear! : Nil
      reset!
    end

    def self.fail!(message : String = "CI step failed") : NoReturn
      raise StepFailed.new(message)
    end

    def self.check(condition : Bool, message : String = "CI check failed") : Nil
      fail!(message) unless condition
    end

    # Executes every registered step, printing timing + a failure summary.
    # Returns 0 when everything passed, 1 otherwise. Never raises for a
    # step failure (the summary is the contract), but an empty registry is
    # an error because it almost always means config/ci.cr was not loaded.
    def self.run_all(io : IO = STDOUT) : Int32
      steps = self.steps
      if steps.empty?
        io.puts "No CI steps registered. Add Saci::CI.step/Saci::CI.run calls to config/ci.cr."
        return 1
      end

      started = Time.instant
      failures = [] of Tuple(String, String)
      steps.each do |step|
        io.puts "== #{step.name} =="
        io.flush
        step_started = Time.instant
        begin
          step.action.call
          io.puts "  PASS (#{format_ms(Time.instant - step_started)})"
        rescue ex : StepFailed
          failures << {step.name, ex.message || "step failed"}
          io.puts "  FAIL (#{format_ms(Time.instant - step_started)})"
          io.puts "    error: #{ex.message || "step failed"}"
        rescue ex
          failures << {step.name, ex.message || ex.class.name}
          io.puts "  FAIL (#{format_ms(Time.instant - step_started)})"
          io.puts "    #{ex.class}: #{ex.message || "error"}"
        end
        io.flush
      end

      elapsed = Time.instant - started
      io.puts ""
      if failures.empty?
        io.puts "#{steps.size} step#{steps.size == 1 ? "" : "s"}, 0 failures (#{format_ms(elapsed)})"
        0
      else
        io.puts "#{steps.size} step#{steps.size == 1 ? "" : "s"}, #{failures.size} failure#{failures.size == 1 ? "" : "s"} (#{format_ms(elapsed)})"
        failures.each { |(name, message)| io.puts "  failed: #{name} — #{message}" }
        1
      end
    end

    private def self.run_command(command : String) : Nil
      status = Process.run(command, shell: true, output: STDOUT, error: STDERR)
      unless status.success?
        raise StepFailed.new("command exited with status #{status.exit_code}: #{command}")
      end
    end

    private def self.format_ms(span : Time::Span) : String
      "#{(span.total_milliseconds).round(1)}ms"
    end
  end
end
