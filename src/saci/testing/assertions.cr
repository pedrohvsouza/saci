module Saci
  module Testing
    # Rails-style assertion helpers for mailer deliveries, job enqueues and
    # performances, cable broadcasts/streams, value changes and query
    # counts. Included into `Object` by `saci/testing.cr`, so they are
    # available inside `it` blocks without a receiver.
    #
    # ```
    # assert_emails(1) { WelcomeMailer.welcome("a@b.c").deliver_now }
    # assert_enqueued_jobs(1) { WelcomeJob.perform_later(user_id: 1) }
    # assert_performed_jobs(1) { WelcomeJob.perform_later(user_id: 1) }
    # assert_enqueued_with(job: WelcomeJob, args: {user_id: 1}) { ... }
    # assert_broadcasts("room:1", 1) { Saci::Cable.broadcast("room:1", {text: "hi"}) }
    # assert_changes(-> { User.count }, from: 0, to: 1) { User.create!(...) }
    # assert_queries(1) { User.create!(...) }
    # ```
    module Assertions
      # Sentinel distinguishing "keyword omitted" from an explicit `nil`.
      class UnsetValue
      end

      UNSET = UnsetValue.new

      # -- mailer ------------------------------------------------------------

      # Number of mails delivered inside the block (forces the `:test`
      # delivery adapter for the duration, restoring the previous one).
      def assert_emails(count : Int, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        with_mailer_test_adapter do
          before = Mailer.deliveries.size
          yield
          actual = Mailer.deliveries.size - before
          unless actual == count
            __saci_fail("Expected #{count} email(s), got #{actual}", file, line)
          end
        end
      end

      def assert_no_emails(file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        assert_emails(0, file, line) { yield }
      end

      # Asserts that `deliver_later` enqueued a `Saci::Mailer::DeliveryJob`
      # matching the given address/subject/body. All three are optional.
      def assert_enqueued_email_with(to : String? = nil, subject : String? = nil, body : String? = nil,
                                     file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        with_job_test_adapter do
          before = Job.enqueued_jobs
          yield
          candidates = Job.enqueued_jobs[before.size..]
          matched = candidates.any? do |entry|
            next false unless entry[:job] == Mailer::DeliveryJob.name
            payload = JSON.parse(entry[:payload])
            (to.nil? || mail_list(payload["to"]?).includes?(to)) &&
              (subject.nil? || payload["subject"]?.try(&.as_s?) == subject) &&
              (body.nil? || (payload["body_text"]?.try(&.as_s?) || "").includes?(body))
          end
          unless matched
            __saci_fail("Expected an enqueued email (to: #{to.inspect}, subject: #{subject.inspect}, body: #{body.inspect}), got #{candidates.inspect}", file, line)
          end
        end
      end

      # -- jobs --------------------------------------------------------------

      # Jobs enqueued inside the block (forces the `:test` queue adapter).
      def assert_enqueued_jobs(count : Int, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        with_job_test_adapter do
          before = Job.enqueued_jobs.size
          yield
          actual = Job.enqueued_jobs.size - before
          unless actual == count
            __saci_fail("Expected #{count} enqueued job(s), got #{actual}", file, line)
          end
        end
      end

      def assert_no_enqueued_jobs(file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        assert_enqueued_jobs(0, file, line) { yield }
      end

      # Asserts an enqueued job of the given class, optionally with JSON
      # arguments (NamedTuple/Hash/Array/String/JSON::Any).
      def assert_enqueued_with(job : Saci::Job::Base.class, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        assert_enqueued_with(job, nil, file, line) { yield }
      end

      def assert_enqueued_with(job : Saci::Job::Base.class, args : Object, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        with_job_test_adapter do
          before = Job.enqueued_jobs
          yield
          candidates = Job.enqueued_jobs[before.size..]
          matched = candidates.any? do |entry|
            next false unless entry[:job] == job.name
            args.nil? || json_equal?(entry[:payload], args)
          end
          unless matched
            __saci_fail("Expected an enqueued #{job.name} with args #{args.inspect}, got #{candidates.inspect}", file, line)
          end
        end
      end

      # Jobs performed inside the block (forces the `:inline` adapter so
      # `perform_later` actually executes; `perform_now` is always counted).
      def assert_performed_jobs(count : Int, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        with_job_inline_adapter do
          before = Probes.performed_jobs.size
          yield
          actual = Probes.performed_jobs.size - before
          unless actual == count
            __saci_fail("Expected #{count} performed job(s), got #{actual}", file, line)
          end
        end
      end

      def assert_no_performed_jobs(file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        assert_performed_jobs(0, file, line) { yield }
      end

      def assert_performed_with(job : Saci::Job::Base.class, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        assert_performed_with(job, nil, file, line) { yield }
      end

      def assert_performed_with(job : Saci::Job::Base.class, args : Object, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        with_job_inline_adapter do
          before = Probes.performed_jobs.size
          yield
          candidates = Probes.performed_jobs[before..]
          matched = candidates.any? do |entry|
            next false unless entry[:job] == job.name
            args.nil? || json_equal?(entry[:payload], args)
          end
          unless matched
            __saci_fail("Expected a performed #{job.name} with args #{args.inspect}, got #{candidates.inspect}", file, line)
          end
        end
      end

      # -- cable -------------------------------------------------------------

      def assert_broadcasts(stream : String, count : Int, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        before = Probes.broadcasts.size
        yield
        actual = Probes.broadcasts[before..].count { |entry| entry[:stream] == stream }
        unless actual == count
          __saci_fail("Expected #{count} broadcast(s) on #{stream.inspect}, got #{actual}", file, line)
        end
      end

      def assert_no_broadcasts(stream : String? = nil, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        before = Probes.broadcasts.size
        yield
        recent = Probes.broadcasts[before..]
        recent = recent.select { |entry| entry[:stream] == stream } if stream
        unless recent.empty?
          __saci_fail("Expected no broadcasts#{stream ? " on #{stream.inspect}" : ""}, got #{recent.inspect}", file, line)
        end
      end

      # Asserts the current `Saci::Cable.server` has an active subscription
      # to `stream` (typically after a `Cable::TestClient#subscribe`).
      def assert_has_stream(stream : String, file : String = __FILE__, line : Int32 = __LINE__) : Nil
        unless Cable.server.has_stream?(stream)
          __saci_fail("Expected a subscription to stream #{stream.inspect}, active streams: #{Cable.server.stream_names.inspect}", file, line)
        end
      end

      def assert_no_streams(file : String = __FILE__, line : Int32 = __LINE__) : Nil
        names = Cable.server.stream_names
        unless names.empty?
          __saci_fail("Expected no active streams, got #{names.inspect}", file, line)
        end
      end

      # -- value changes -----------------------------------------------------

      # `from`/`to` are compared with `==`; omit a keyword to leave that side
      # unasserted. When both are omitted the expression must change.
      def assert_changes(expression : -> T, from : Object = UNSET, to : Object = UNSET,
                         file : String = __FILE__, line : Int32 = __LINE__, &) : Nil forall T
        before = expression.call
        yield
        after = expression.call
        from_given = !from.is_a?(UnsetValue)
        to_given = !to.is_a?(UnsetValue)

        if from_given && before != from
          __saci_fail("Expected expression to change from #{from.inspect}, but it was #{before.inspect}", file, line)
        end
        if to_given && after != to
          __saci_fail("Expected expression to change to #{to.inspect}, but it was #{after.inspect}", file, line)
        end
        if !from_given && !to_given && before == after
          __saci_fail("Expected expression to change, but it stayed #{before.inspect}", file, line)
        end
      end

      def assert_no_changes(expression : -> T, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil forall T
        before = expression.call
        yield
        after = expression.call
        unless before == after
          __saci_fail("Expected expression to stay #{before.inspect}, but it became #{after.inspect}", file, line)
        end
      end

      def assert_difference(expression : -> T, delta : Number = 1, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil forall T
        before = expression.call
        yield
        after = expression.call
        actual = numeric_value(after, file, line) - numeric_value(before, file, line)
        unless actual == delta.to_f64
          __saci_fail("Expected difference #{delta}, got #{actual}", file, line)
        end
      end

      def assert_no_difference(expression : -> T, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil forall T
        assert_difference(expression, 0, file, line) { yield }
      end

      # -- queries -----------------------------------------------------------

      # Number of SQL statements executed inside the block (all ORM reads
      # and writes flow through the `Record` execution choke points).
      def assert_queries(count : Int, file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        _, actual = Queries.measure { yield }
        unless actual == count
          __saci_fail("Expected #{count} SQL quer#{count == 1 ? "y" : "ies"}, got #{actual}", file, line)
        end
      end

      def assert_no_queries(file : String = __FILE__, line : Int32 = __LINE__, &) : Nil
        assert_queries(0, file, line) { yield }
      end

      # -- internals ---------------------------------------------------------

      private def with_mailer_test_adapter(& : -> T) : T forall T
        previous = Mailer.delivery_adapter
        Mailer.delivery_adapter = :test
        begin
          yield
        ensure
          Mailer.delivery_adapter = previous
        end
      end

      private def with_job_test_adapter(& : -> T) : T forall T
        previous = Job.queue_adapter
        Job.queue_adapter = :test
        begin
          yield
        ensure
          Job.queue_adapter = previous
        end
      end

      private def with_job_inline_adapter(& : -> T) : T forall T
        previous = Job.queue_adapter
        Job.queue_adapter = :inline
        begin
          yield
        ensure
          Job.queue_adapter = previous
        end
      end

      private def mail_list(value : JSON::Any?) : Array(String)
        case value
        when Nil then [] of String
        else          value.as_a?.try(&.map(&.as_s)) || [] of String
        end
      rescue
        [] of String
      end

      private def json_equal?(payload : String, expected : Object) : Bool
        expected_json = expected.is_a?(String) ? expected : expected.to_json
        JSON.parse(payload) == JSON.parse(expected_json)
      rescue
        false
      end

      private def numeric_value(value : Object, file : String, line : Int32) : Float64
        case value
        when Number
          value.to_f64
        else
          __saci_fail("assert_difference expression must return a number, got #{value.inspect} (#{value.class})", file, line)
        end
      end

      private def __saci_fail(message : String, file : String, line : Int32) : NoReturn
        raise Spec::AssertionFailed.new(message, file, line)
      end
    end
  end
end
