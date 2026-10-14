module Saci
  # Enables true parallelism. Crystal runs single-threaded by default; call
  # once at boot (before serving) to spread fibers across threads:
  #
  # ```
  # Saci.enable_multithreading! if ENV["SACI_MT"]? == "1"
  # ```
  #
  # Workers default to `Fiber::ExecutionContext.default_workers_count`
  # (honors `CRYSTAL_WORKERS`, else CPU count). The binary must be compiled
  # with multithreading enabled — `saci serve --mt` does this automatically
  # (`-Dexecution_context`); plain `crystal build` stays single-threaded and
  # the call below is a harmless no-op.
  {% if flag?(:execution_context) || flag?(:preview_mt) %}
    def self.enable_multithreading!(workers : Int32 = Fiber::ExecutionContext.default_workers_count) : Nil
      ctx = Fiber::ExecutionContext.default
      ctx.resize(workers)
      ctx.scale_up(workers)
      @@mt_enabled = true
    end

    def self.multithreaded? : Bool
      @@mt_enabled
    end
  {% else %}
    def self.enable_multithreading!(workers : Int32 = 1) : Nil
    end

    def self.multithreaded? : Bool
      false
    end
  {% end %}

  @@mt_enabled : Bool = false
end
