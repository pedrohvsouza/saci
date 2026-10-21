module Saci
  # User task registry backing the `lib/tasks/*.cr` convention (Rails
  # `lib/tasks/*.rake` equivalent, G118/G229).
  #
  # Task files are ordinary Crystal files containing one or more
  # definitions:
  #
  # ```
  # # lib/tasks/reports/daily.cr
  # task "reports:daily", "Send the daily report" do
  #   puts "Sending report..."
  #   # Models are loaded and the database is connected by `saci task`.
  # end
  # ```
  #
  # `Saci::Task.define` is the explicit form (no top-level DSL needed):
  #
  # ```
  # Saci::Task.define("reports:daily", "Send the daily report") do
  #   # ...
  # end
  # ```
  #
  # There is deliberately no runtime file loading: Crystal has no
  # runtime `require`/eval. The CLI builds a temporary runner that
  # `require`s every `lib/tasks/**/*.cr` at compile time, so task bodies
  # are normal compiled Crystal with full access to the app's models.
  #
  # Descriptions can also be supplied Rails-style:
  #
  # ```
  # desc "Send the daily report"
  # task "reports:daily" do
  #   # ...
  # end
  # ```
  module Task
    # Raised by `run` when no such task was defined/loaded.
    class NotFound < Exception
    end

    # One registered task. `block` is compiled into the runner binary.
    record Definition, name : String, description : String, block : Proc(Nil)

    @@tasks = {} of String => Definition
    @@pending_description : String = ""
    @@mutex = Mutex.new

    # Registers a task. Re-defining the same name replaces it (a later
    # `require` wins, matching Ruby/Rake's re-definition behavior).
    def self.define(name : String, description : String = "", &block : -> Nil) : Nil
      desc = description
      if desc.empty?
        stored = @@mutex.synchronize { @@pending_description }
        desc = stored
        @@mutex.synchronize { @@pending_description = "" }
      end
      definition = Definition.new(name, desc, block)
      @@mutex.synchronize { @@tasks[name] = definition }
    end

    # Explicit variant for callers that already have a `Proc(Nil)`.
    def self.register(name : String, description : String = "", block : Proc(Nil) = -> { }) : Nil
      @@mutex.synchronize { @@tasks[name] = Definition.new(name, description, block) }
    end

    # Stores the description used by the next `task`/`define` call that
    # omits one (`desc "..." ; task "..."`).
    def self.desc(description : String) : Nil
      @@mutex.synchronize { @@pending_description = description }
    end

    def self.tasks : Array(Definition)
      @@mutex.synchronize { @@tasks.values.sort_by(&.name) }
    end

    def self.names : Array(String)
      tasks.map(&.name)
    end

    def self.find?(name : String) : Definition?
      @@mutex.synchronize { @@tasks[name]? }
    end

    # Runs a registered task. Raises `NotFound` with the available names
    # when the task was not loaded into this binary.
    def self.run(name : String) : Nil
      definition = find?(name)
      unless definition
        available = names
        hint = available.empty? ? "No tasks were loaded (expected lib/tasks/*.cr)." : "Available: #{available.join(", ")}."
        raise NotFound.new("Unknown task '#{name}'. #{hint}")
      end
      definition.block.call
    end

    # Clears the registry (spec isolation).
    def self.reset! : Nil
      @@mutex.synchronize do
        @@tasks.clear
        @@pending_description = ""
      end
    end

    def self.clear! : Nil
      reset!
    end
  end
end

# Top-level DSL used by `lib/tasks/*.cr` (Rails/Rake-style). These are
# private Object methods, so task files can call them without a namespace.
def task(name : String, description : String = "", &block : -> Nil) : Nil
  Saci::Task.define(name, description, &block)
end

def desc(description : String) : Nil
  Saci::Task.desc(description)
end
