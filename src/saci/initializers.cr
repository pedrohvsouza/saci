module Saci
  # Boot lifecycle callbacks (`config/initializers` / Railties equivalent).
  #
  # ```
  # Saci::Initializers.before_configuration do
  #   Saci.log_level = :debug
  # end
  #
  # Saci::Initializers.to_prepare do
  #   # Re-run after a reload; must be idempotent.
  # end
  #
  # Saci::Initializers.after_initialize do
  #   # Runs once, after configuration and the first `to_prepare` pass.
  # end
  #
  # Saci::Application.new(router).boot # runs the lifecycle once
  # ```
  #
  # `to_prepare` callbacks are reload-safe by design: `run_to_prepare!` may be
  # called repeatedly (for example by `Application#reload!`), so callbacks must
  # be idempotent. `before_configuration` and `after_initialize` run once per
  # process.
  class Initializers
    alias Callback = Proc(Nil)

    @@before_configuration = [] of Callback
    @@to_prepare = [] of Callback
    @@after_initialize = [] of Callback
    @@mutex = Mutex.new
    @@ran = false

    def self.before_configuration(&block : ->) : Nil
      callback = -> { block.call; nil }
      @@mutex.synchronize { @@before_configuration << callback }
    end

    def self.to_prepare(&block : ->) : Nil
      callback = -> { block.call; nil }
      @@mutex.synchronize { @@to_prepare << callback }
    end

    def self.after_initialize(&block : ->) : Nil
      callback = -> { block.call; nil }
      @@mutex.synchronize { @@after_initialize << callback }
    end

    # Runs before_configuration, one to_prepare pass, then after_initialize.
    # Subsequent calls are no-ops; use `run_to_prepare!` for reload hooks.
    def self.run! : Nil
      callbacks = @@mutex.synchronize do
        next nil if @@ran
        @@ran = true
        {@@before_configuration.dup, @@to_prepare.dup, @@after_initialize.dup}
      end
      return unless callbacks

      before, prepare, after = callbacks
      before.each(&.call)
      run_to_prepare!
      after.each(&.call)
    end

    # Executes the `to_prepare` callbacks again. Callbacks must be idempotent
    # (this is the reload-safe hook).
    def self.run_to_prepare! : Nil
      callbacks = @@mutex.synchronize { @@to_prepare.dup }
      callbacks.each(&.call)
    end

    def self.ran? : Bool
      @@mutex.synchronize { @@ran }
    end

    # Clears registered callbacks and the "ran" flag. Specs use this to avoid
    # leaking lifecycle state between examples.
    def self.reset! : Nil
      @@mutex.synchronize do
        @@before_configuration.clear
        @@to_prepare.clear
        @@after_initialize.clear
        @@ran = false
      end
    end

    def self.before_configuration_callbacks : Array(Callback)
      @@mutex.synchronize { @@before_configuration.dup }
    end

    def self.to_prepare_callbacks : Array(Callback)
      @@mutex.synchronize { @@to_prepare.dup }
    end

    def self.after_initialize_callbacks : Array(Callback)
      @@mutex.synchronize { @@after_initialize.dup }
    end
  end

  def self.initializers : Initializers.class
    Initializers
  end

  def self.before_configuration(&block : ->) : Nil
    Initializers.before_configuration(&block)
  end

  def self.to_prepare(&block : ->) : Nil
    Initializers.to_prepare(&block)
  end

  def self.after_initialize(&block : ->) : Nil
    Initializers.after_initialize(&block)
  end
end
