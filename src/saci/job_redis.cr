require "digest/sha1"
require "digest/sha256"
require "json"
require "./cable"

module Saci
  module Job
    # Redis-backed durable queue (`queue_adapter = :redis`).
    #
    # ```
    # Saci::Job::Redis.configure(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379"))
    # Saci::Job.queue_adapter = :redis
    # WelcomeJob.perform_later({user_id: 1}) # stored in Redis, survives restarts
    # Saci::Job::Redis.drain                 # run everything due, inline
    #
    # # …or supervise in your worker process:
    # spawn do
    #   loop do
    #     Saci::Job::Redis.work_once
    #     sleep 1.second
    #   end
    # end
    # ```
    #
    # It uses the same pure-socket RESP2 client as `Cable::RedisServer`, so
    # it adds no shard and no link requirement. Every state change is one
    # Lua script, so a crash never leaves a job half-moved between keys.
    #
    # Semantics mirror `Job::Db`:
    # * at-least-once; jobs MUST be idempotent. A claimed job whose worker
    #   disappears is reclaimed once `lock_timeout` passes (a job that runs
    #   longer than `lock_timeout` can therefore run twice).
    # * claim order is priority DESC, run_at ASC, id ASC. Priorities are
    #   clamped to `-PRIORITY_LIMIT..PRIORITY_LIMIT`.
    # * retries reuse the job's own `retry_on` rules; final failures move
    #   to the dead set with their error and are reported once through
    #   `Job.on_error`.
    # * `unique:` jobs hold a `<prefix>:unique:<sha256>` key owned by the
    #   job id, with the same three modes as the DB adapter.
    #   `while_executing` locks expire with `lock_timeout`.
    # * continuation checkpoints are stored on the job after every step.
    # * with `Job.enqueue_after_transaction_commit = true`, enqueues inside
    #   a `Record.transaction` wait for the commit.
    #
    # Key layout under `prefix` (default `saci:jobs`): `seq`, `queues`,
    # `job:<id>` (hash), `ready:<queue>`, `scheduled:<queue>`,
    # `running:<queue>` and `dead` (sorted sets), and `unique:<sha256>`.
    module Redis
      DEFAULT_PREFIX = "saci:jobs"
      PRIORITY_LIMIT = 1000
      # Weight of one priority step in a ready score, in milliseconds
      # (about 139 years). Scores stay below 2**53, so Redis keeps them
      # exact.
      PRIORITY_WEIGHT = 2_i64 ** 42

      class Down < Exception
      end

      # A claimed job. `id` is the zero-padded member stored in Redis.
      struct Claim
        getter id : String
        getter class_name : String
        getter payload : String
        getter queue : String
        getter attempts : Int32
        getter checkpoint : Array(String)
        getter batch_id : String?

        def initialize(@id, @class_name, @payload, @queue, @attempts, @checkpoint, @batch_id)
        end
      end

      ENQUEUE_SCRIPT = <<-LUA
        local p, q = ARGV[1], ARGV[2]
        local id = string.format('%016d', redis.call('INCR', p .. ':seq'))
        if ARGV[11] == '1' then
          if not redis.call('SET', p .. ':unique:' .. ARGV[9], id, 'NX') then return '' end
        end
        local key = p .. ':job:' .. id
        redis.call('HSET', key, 'class', ARGV[3], 'payload', ARGV[4], 'queue', q,
          'priority', ARGV[6], 'attempts', '0', 'run_at', ARGV[5],
          'ready_score', ARGV[12], 'created_at', ARGV[7])
        if ARGV[8] ~= '' then redis.call('HSET', key, 'unique_mode', ARGV[8], 'unique_key', ARGV[9]) end
        if ARGV[10] ~= '' then redis.call('HSET', key, 'batch_id', ARGV[10]) end
        redis.call('SADD', p .. ':queues', q)
        if tonumber(ARGV[5]) <= tonumber(ARGV[7]) then
          redis.call('ZADD', p .. ':ready:' .. q, ARGV[12], id)
        else
          redis.call('ZADD', p .. ':scheduled:' .. q, ARGV[5], id)
        end
        return id
        LUA

      CLAIM_SCRIPT = <<-LUA
        local p, now, expiry, worker, ttl = ARGV[1], ARGV[2], ARGV[3], ARGV[4], ARGV[5]
        local queues = {}
        if #ARGV > 5 then
          for i = 6, #ARGV do queues[#queues + 1] = ARGV[i] end
        else
          queues = redis.call('SMEMBERS', p .. ':queues')
        end
        local function requeue(from, q, ids)
          for _, id in ipairs(ids) do
            redis.call('ZREM', from, id)
            local key = p .. ':job:' .. id
            local score = redis.call('HGET', key, 'ready_score')
            if score then
              if redis.call('HGET', key, 'unique_mode') == 'while_executing' then
                local ukey = p .. ':unique:' .. redis.call('HGET', key, 'unique_key')
                if redis.call('GET', ukey) == id then redis.call('DEL', ukey) end
              end
              redis.call('ZADD', p .. ':ready:' .. q, score, id)
            end
          end
        end
        local best_id, best_q, best_score
        for _, q in ipairs(queues) do
          local scheduled = p .. ':scheduled:' .. q
          requeue(scheduled, q, redis.call('ZRANGEBYSCORE', scheduled, '-inf', now, 'LIMIT', 0, 500))
          local running = p .. ':running:' .. q
          requeue(running, q, redis.call('ZRANGEBYSCORE', running, '-inf', now, 'LIMIT', 0, 500))
          local ready = p .. ':ready:' .. q
          local heads = redis.call('ZRANGE', ready, 0, 49, 'WITHSCORES')
          for i = 1, #heads, 2 do
            local id, score = heads[i], tonumber(heads[i + 1])
            local key = p .. ':job:' .. id
            if redis.call('EXISTS', key) == 0 then
              redis.call('ZREM', ready, id)
            else
              local free = true
              if redis.call('HGET', key, 'unique_mode') == 'while_executing' then
                local holder = redis.call('GET', p .. ':unique:' .. redis.call('HGET', key, 'unique_key'))
                free = (not holder) or holder == id
              end
              if free then
                if best_score == nil or score < best_score or (score == best_score and id < best_id) then
                  best_id, best_q, best_score = id, q, score
                end
                break
              end
            end
          end
        end
        if not best_id then return false end
        local key = p .. ':job:' .. best_id
        local mode = redis.call('HGET', key, 'unique_mode')
        if mode then
          local ukey = p .. ':unique:' .. redis.call('HGET', key, 'unique_key')
          if mode == 'until_executing' then
            if redis.call('GET', ukey) == best_id then redis.call('DEL', ukey) end
          elseif mode == 'while_executing' then
            redis.call('SET', ukey, best_id, 'PX', ttl)
          end
        end
        redis.call('ZREM', p .. ':ready:' .. best_q, best_id)
        redis.call('ZADD', p .. ':running:' .. best_q, expiry, best_id)
        local attempts = redis.call('HINCRBY', key, 'attempts', 1)
        redis.call('HSET', key, 'locked_by', worker)
        return {best_id, redis.call('HGET', key, 'class'), redis.call('HGET', key, 'payload'),
          best_q, tostring(attempts), redis.call('HGET', key, 'checkpoint') or '',
          redis.call('HGET', key, 'batch_id') or ''}
        LUA

      # ARGV: prefix, id, queue, outcome ("ok" | "dead"), error, failed_at_ms.
      FINISH_SCRIPT = <<-LUA
        local p, id, q = ARGV[1], ARGV[2], ARGV[3]
        local key = p .. ':job:' .. id
        redis.call('ZREM', p .. ':running:' .. q, id)
        redis.call('ZREM', p .. ':ready:' .. q, id)
        redis.call('ZREM', p .. ':scheduled:' .. q, id)
        local mode = redis.call('HGET', key, 'unique_mode')
        if mode == 'until_executed' or mode == 'while_executing' then
          local ukey = p .. ':unique:' .. redis.call('HGET', key, 'unique_key')
          if redis.call('GET', ukey) == id then redis.call('DEL', ukey) end
        end
        if ARGV[4] == 'ok' then
          redis.call('DEL', key)
        elseif redis.call('EXISTS', key) == 1 then
          redis.call('HSET', key, 'error', ARGV[5], 'failed_at', ARGV[6])
          redis.call('HDEL', key, 'locked_by')
          redis.call('ZADD', p .. ':dead', ARGV[6], id)
        end
        return 1
        LUA

      # ARGV: prefix, id, steps_json.
      CHECKPOINT_SCRIPT = <<-LUA
        local key = ARGV[1] .. ':job:' .. ARGV[2]
        if redis.call('EXISTS', key) == 0 then return 0 end
        redis.call('HSET', key, 'checkpoint', ARGV[3])
        return 1
        LUA

      # ARGV: prefix, id, now_ms, ready_score.
      RETRY_DEAD_SCRIPT = <<-LUA
        local p, id = ARGV[1], ARGV[2]
        local key = p .. ':job:' .. id
        if redis.call('ZSCORE', p .. ':dead', id) == false or redis.call('EXISTS', key) == 0 then return 0 end
        local mode = redis.call('HGET', key, 'unique_mode')
        if mode == 'until_executed' or mode == 'until_executing' then
          if not redis.call('SET', p .. ':unique:' .. redis.call('HGET', key, 'unique_key'), id, 'NX') then return 0 end
        end
        local q = redis.call('HGET', key, 'queue')
        redis.call('ZREM', p .. ':dead', id)
        redis.call('HDEL', key, 'error', 'failed_at', 'checkpoint')
        redis.call('HSET', key, 'attempts', '0', 'run_at', ARGV[3], 'ready_score', ARGV[4])
        redis.call('SADD', p .. ':queues', q)
        redis.call('ZADD', p .. ':ready:' .. q, ARGV[4], id)
        return 1
        LUA

      # ARGV: prefix, id.
      DROP_DEAD_SCRIPT = <<-LUA
        if redis.call('ZREM', ARGV[1] .. ':dead', ARGV[2]) == 0 then return 0 end
        redis.call('DEL', ARGV[1] .. ':job:' .. ARGV[2])
        return 1
        LUA

      # ARGV: prefix, cutoff_ms.
      PRUNE_DEAD_SCRIPT = <<-LUA
        local dead = ARGV[1] .. ':dead'
        local ids = redis.call('ZRANGEBYSCORE', dead, '-inf', '(' .. ARGV[2], 'LIMIT', 0, 1000)
        for _, id in ipairs(ids) do
          redis.call('ZREM', dead, id)
          redis.call('DEL', ARGV[1] .. ':job:' .. id)
        end
        return #ids
        LUA

      @@url : String = ENV["REDIS_URL"]? || "redis://127.0.0.1:6379"
      @@prefix : String = DEFAULT_PREFIX
      @@concurrency : Int32 = 5
      @@lock_timeout : Time::Span = 10.minutes
      @@queues : Array(String)? = nil
      @@worker_id : String? = nil
      @@running : Int32 = 0
      @@mutex = Mutex.new
      @@conn : Cable::RedisWire::Conn? = nil
      @@conn_mutex = Mutex.new
      @@script_shas = {} of String => String

      # `url` defaults to `REDIS_URL` (or `redis://127.0.0.1:6379`).
      # `queues:` restricts `drain`/`work_once` to those queue names when no
      # per-call queue is given. `prefix:` namespaces every key, so several
      # apps can share one Redis database.
      def self.configure(url : String? = nil,
                         prefix : String? = nil,
                         concurrency : Int32 = 5,
                         lock_timeout : Time::Span = 10.minutes,
                         worker_id : String? = nil,
                         queues : Array(String)? = nil) : Nil
        @@mutex.synchronize do
          @@url = url if url
          @@prefix = prefix if prefix
          @@concurrency = concurrency
          @@lock_timeout = lock_timeout
          @@worker_id = worker_id if worker_id
          @@queues = queues
        end
        disconnect!
      end

      def self.url : String
        @@mutex.synchronize { @@url }
      end

      def self.prefix : String
        @@mutex.synchronize { @@prefix }
      end

      def self.concurrency : Int32
        @@mutex.synchronize { @@concurrency }
      end

      def self.lock_timeout : Time::Span
        @@mutex.synchronize { @@lock_timeout }
      end

      def self.queues : Array(String)?
        @@mutex.synchronize { @@queues }
      end

      def self.worker_id : String
        @@mutex.synchronize { @@worker_id ||= Random::Secure.hex(8) }
      end

      def self.worker_id=(value : String) : Nil
        @@mutex.synchronize { @@worker_id = value }
      end

      # Closes the shared connection; the next call reconnects.
      def self.disconnect! : Nil
        @@conn_mutex.synchronize do
          @@conn.try(&.close)
          @@conn = nil
        end
      end

      # Score of a ready job: lower runs first.
      def self.ready_score(run_at : Time, priority : Int32) : Int64
        clamped = priority.clamp(-PRIORITY_LIMIT, PRIORITY_LIMIT).to_i64
        run_at.to_unix_ms - clamped * PRIORITY_WEIGHT
      end

      # Stores one job for execution at `run_at`. Returns the new job id,
      # `0` when a unique lock suppressed the enqueue, or `-1` when the
      # enqueue waits for the surrounding transaction to commit.
      def self.enqueue(class_name : String, queue : String, payload_json : String,
                       run_at : Time = Time.utc, priority : Int32 = 0,
                       unique_mode : Symbol? = nil, unique_key : String? = nil,
                       batch_id : String? = nil) : Int64
        if db = deferral_database
          Record.defer_after_commit(db) do
            begin
              enqueue_now(class_name, queue, payload_json, run_at, priority, unique_mode, unique_key, batch_id)
            rescue ex
              Job.report_error(class_name, ex)
            end
          end
          return -1_i64
        end
        enqueue_now(class_name, queue, payload_json, run_at, priority, unique_mode, unique_key, batch_id)
      end

      private def self.deferral_database : DB::Database?
        return nil unless Job.enqueue_after_transaction_commit?
        return nil unless Record.transaction_open?
        connection = Record.connection
        return nil unless connection.is_a?(DB::Connection)
        Record.tx_database_for(connection)
      rescue
        nil
      end

      private def self.enqueue_now(class_name : String, queue : String, payload_json : String,
                                   run_at : Time, priority : Int32, unique_mode : Symbol?,
                                   unique_key : String?, batch_id : String?) : Int64
        mode = unique_mode.try(&.to_s) || ""
        key_hash = unique_key && !mode.empty? ? Digest::SHA256.hexdigest(unique_key) : ""
        held = (mode == "until_executed" || mode == "until_executing") && !key_hash.empty?
        clamped = priority.clamp(-PRIORITY_LIMIT, PRIORITY_LIMIT)
        reply = eval(ENQUEUE_SCRIPT, [
          prefix, queue, class_name, payload_json, run_at.to_unix_ms.to_s,
          clamped.to_s, Time.utc.to_unix_ms.to_s, mode, key_hash, batch_id || "",
          held ? "1" : "0", ready_score(run_at, clamped).to_s,
        ])
        id = reply.as?(String) || ""
        id.empty? ? 0_i64 : id.to_i64
      end

      # Claims due jobs (up to free concurrency slots) and runs each in its
      # own fiber. Returns the number claimed. Non-blocking.
      def self.work_once(queue : String? = nil) : Int32
        slots = concurrency - running_count
        return 0 if slots <= 0
        selected = queue ? [queue] : queues
        claimed = 0
        slots.times do
          claim = claim_one(selected)
          break unless claim
          claimed += 1
          running_increment
          spawn do
            begin
              run_claimed(claim)
            rescue ex
              Job.report_error(claim.class_name, ex)
            ensure
              running_decrement
            end
          end
        end
        claimed
      end

      # Claims due jobs and runs them inline until none remain. Returns the
      # number completed. The deterministic path for specs and scripts.
      def self.drain(queue : String? = nil) : Int32
        selected = queue ? [queue] : queues
        done = 0
        while claim = claim_one(selected)
          run_claimed(claim)
          done += 1
        end
        done
      end

      # Claims the next due job, or nil. Public so custom workers and specs
      # can drive execution themselves; pair it with `run_claimed`.
      def self.claim_one(selected : Array(String)? = queues) : Claim?
        now = Time.utc
        ttl = lock_timeout.total_milliseconds.to_i64.clamp(1_i64, Int64::MAX)
        args = [prefix, now.to_unix_ms.to_s, (now.to_unix_ms + ttl).to_s, worker_id, ttl.to_s]
        selected.try { |names| args.concat(names) }
        reply = eval(CLAIM_SCRIPT, args)
        fields = reply.as?(Array(Cable::RedisWire::RedisValue))
        return nil unless fields && fields.size == 7
        values = fields.map { |field| field.is_a?(String) ? field : field.to_s }
        checkpoint = parse_checkpoint(values[5])
        batch = values[6].empty? ? nil : values[6]
        Claim.new(values[0], values[1], values[2], values[3], values[4].to_i32? || 1, checkpoint, batch)
      end

      # Runs one claimed job to a terminal state: success and discards
      # delete it, final failures move it to the dead set.
      def self.run_claimed(claim : Claim) : Nil
        klass = Job.lookup(claim.class_name)
        unless klass
          finish(claim, "unknown job class #{claim.class_name.inspect}")
          Batch.__job_finished(claim.batch_id, true) if claim.batch_id
          Job.report_error(claim.class_name, Exception.new("unknown job class"))
          return
        end
        sink = ->(steps : Array(String)) do
          eval(CHECKPOINT_SCRIPT, [prefix, claim.id, steps.to_json])
          nil
        end
        failure : String? = nil
        begin
          Job.execute(klass, claim.payload, claim.attempts, claim.checkpoint, sink,
            enforce_in_memory_unique: false)
        rescue ex
          failure = "#{ex.class}: #{ex.message}"
        end
        finish(claim, failure)
        Batch.__job_finished(claim.batch_id, !failure.nil?) if claim.batch_id
      rescue ex : Down
        # The job stays in the running set and is reclaimed after
        # `lock_timeout`.
        Job.report_error(claim.class_name, ex)
      end

      private def self.finish(claim : Claim, error : String?) : Nil
        eval(FINISH_SCRIPT, [prefix, claim.id, claim.queue, error ? "dead" : "ok",
                             error || "", Time.utc.to_unix_ms.to_s])
      end

      # Jobs not yet finished (ready, scheduled and running), in `queue` or
      # in every known queue.
      def self.pending_count(queue : String? = nil) : Int64
        names = queue ? [queue] : known_queues
        return 0_i64 if names.empty?
        p = prefix
        commands = names.flat_map do |name|
          %w[ready scheduled running].map { |set| ["ZCARD", "#{p}:#{set}:#{name}"] }
        end
        pipeline(commands).sum { |count| count.as?(Int64) || 0_i64 }
      end

      def self.dead_count : Int64
        call(["ZCARD", "#{prefix}:dead"]).as?(Int64) || 0_i64
      end

      # Newest-first dead-letter listing for ops inspection.
      def self.dead_jobs(limit : Int32 = 50) : Array(NamedTuple(id: Int64, job: String, attempts: Int64, error: String))
        p = prefix
        ids = strings(call(["ZREVRANGE", "#{p}:dead", "0", (limit - 1).clamp(0, Int32::MAX).to_s]))
        return [] of NamedTuple(id: Int64, job: String, attempts: Int64, error: String) if ids.empty?
        rows = pipeline(ids.map { |id| ["HMGET", "#{p}:job:#{id}", "class", "attempts", "error"] })
        ids.zip(rows).compact_map do |id, row|
          values = row.as?(Array(Cable::RedisWire::RedisValue))
          next unless values && (job = values[0].as?(String))
          {id:       id.to_i64,
           job:      job,
           attempts: values[1].as?(String).try(&.to_i64?) || 0_i64,
           error:    values[2].as?(String) || ""}
        end
      end

      # Requeues a dead job for immediate execution. Returns false when
      # missing or suppressed by the job's unique lock.
      def self.retry_dead(id : Int64) : Bool
        member = member_id(id)
        priority = call(["HGET", "#{prefix}:job:#{member}", "priority"]).as?(String).try(&.to_i32?) || 0
        now = Time.utc
        eval(RETRY_DEAD_SCRIPT, [prefix, member, now.to_unix_ms.to_s, ready_score(now, priority).to_s]) == 1_i64
      end

      # Drops a dead job without running it. Returns false when missing.
      def self.drop_dead(id : Int64) : Bool
        eval(DROP_DEAD_SCRIPT, [prefix, member_id(id)]) == 1_i64
      end

      # Deletes dead jobs older than `older_than` (default 30 days).
      # Returns the number removed.
      def self.prune_dead(older_than : Time::Span = 30.days) : Int64
        prune_dead_before(Time.utc - older_than)
      end

      def self.prune_dead_before(cutoff : Time) : Int64
        removed = 0_i64
        loop do
          batch = eval(PRUNE_DEAD_SCRIPT, [prefix, cutoff.to_unix_ms.to_s]).as?(Int64) || 0_i64
          removed += batch
          break if batch < 1000
        end
        removed
      end

      # Deletes every key under `prefix` (spec isolation).
      def self.clear_all! : Nil
        pattern = "#{prefix.gsub(/([*?\[\]\\])/, "\\\\\\1")}:*"
        cursor = "0"
        loop do
          reply = call(["SCAN", cursor, "MATCH", pattern, "COUNT", "500"]).as?(Array(Cable::RedisWire::RedisValue))
          break unless reply && reply.size == 2
          cursor = reply[0].as?(String) || "0"
          keys = strings(reply[1])
          call(["DEL"] + keys) unless keys.empty?
          break if cursor == "0"
        end
      end

      def self.member_id(id : Int64) : String
        id.to_s.rjust(16, '0')
      end

      private def self.known_queues : Array(String)
        strings(call(["SMEMBERS", "#{prefix}:queues"])).sort!
      end

      private def self.strings(value : Cable::RedisWire::RedisValue) : Array(String)
        value.as?(Array(Cable::RedisWire::RedisValue)).try(&.compact_map(&.as?(String))) || [] of String
      end

      private def self.parse_checkpoint(raw : String) : Array(String)
        return [] of String if raw.empty?
        Array(String).from_json(raw)
      rescue JSON::ParseException
        [] of String
      end

      private def self.running_count : Int32
        @@mutex.synchronize { @@running }
      end

      private def self.running_increment : Nil
        @@mutex.synchronize { @@running += 1 }
      end

      private def self.running_decrement : Nil
        @@mutex.synchronize { @@running -= 1 }
      end

      # Runs a script through EVALSHA, loading it with EVAL on NOSCRIPT
      # (first call, or after the server restarted or ran SCRIPT FLUSH).
      private def self.eval(script : String, args : Array(String)) : Cable::RedisWire::RedisValue
        sha = @@mutex.synchronize { @@script_shas[script] ||= Digest::SHA1.hexdigest(script) }
        with_conn do |conn|
          begin
            conn.call(["EVALSHA", sha, "0"] + args)
          rescue ex : Cable::RedisDown
            raise ex unless ex.message.try(&.includes?("NOSCRIPT"))
            conn.call(["EVAL", script, "0"] + args)
          end
        end
      end

      private def self.call(args : Array(String)) : Cable::RedisWire::RedisValue
        with_conn(&.call(args))
      end

      private def self.pipeline(commands : Array(Array(String))) : Array(Cable::RedisWire::RedisValue)
        with_conn { |conn| conn.call_pipeline(commands).as(Cable::RedisWire::RedisValue) }.as(Array(Cable::RedisWire::RedisValue))
      end

      # Error replies (`-ERR ...`) also surface as `RedisDown`; those are
      # not retried, since a second connection would fail the same way.
      private def self.with_conn(& : Cable::RedisWire::Conn -> Cable::RedisWire::RedisValue) : Cable::RedisWire::RedisValue
        @@conn_mutex.synchronize do
          attempts = 0
          loop do
            attempts += 1
            begin
              conn = @@conn ||= Cable::RedisWire::Conn.new(Cable::RedisWire.parse_url(url))
              return yield conn
            rescue ex : Cable::RedisDown
              message = ex.message || "unreachable"
              raise Down.new(message) if message.starts_with?("redis error:")
              @@conn.try(&.close)
              @@conn = nil
              raise Down.new(message) if attempts >= 2
            end
          end
        end
      end
    end
  end
end
