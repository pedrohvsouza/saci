require "json"

module Saci
  module Mailer
    # Mailer-specific test assertions. Include it in a spec:
    #
    # ```
    # include Saci::Mailer::TestHelpers
    #
    # it "sends a welcome" do
    #   assert_emails(1) { UserMailer.welcome("a@b.c").deliver_now }
    # end
    # ```
    #
    # These helpers use `Saci::Mailer.deliveries` (the `:test` adapter) and
    # `Saci::Job.enqueued_jobs` (the `:test` queue adapter), so they are
    # intentionally framework-independent (no dependency on the Spec shard).
    module TestHelpers
      class AssertionFailed < Exception
      end

      # Asserts that the block added exactly `count` mails to the test
      # delivery collection.
      def assert_emails(count : Int32 = 1, &) : Nil
        before = Mailer.deliveries.size
        yield
        actual = Mailer.deliveries.size - before
        unless actual == count
          raise AssertionFailed.new("Expected #{count} email(s), got #{actual}")
        end
      end

      def assert_no_emails(&) : Nil
        assert_emails(0) { yield }
      end

      # Asserts that the block enqueued a delivery job whose rendered payload
      # carries the given mailer/action metadata. `mailer` may be the class or
      # its name.
      #
      # ```
      # assert_enqueued_email_with(UserMailer, :welcome) do
      #   UserMailer.with(email: "a@b.c").welcome.deliver_later
      # end
      # ```
      def assert_enqueued_email_with(mailer : Base.class, action : String | Symbol, *,
                                     params : Hash(String, String)? = nil,
                                     queue : String? = nil, &) : Nil
        assert_enqueued_email_with(mailer.name, action, params: params, queue: queue) { yield }
      end

      def assert_enqueued_email_with(mailer : String | Symbol, action : String | Symbol, *,
                                     params : Hash(String, String)? = nil,
                                     queue : String? = nil, &) : Nil
        before = Job.enqueued_jobs.size
        yield
        candidates = Job.enqueued_jobs[before..]
        expected_mailer = mailer.to_s
        expected_action = action.to_s
        found = candidates.any? do |entry|
          payload = JSON.parse(entry[:payload])
          entry[:job].includes?("Mailer::DeliveryJob") &&
            payload["_mailer"]?.try(&.as_s?) == expected_mailer &&
            payload["_action"]?.try(&.as_s?) == expected_action &&
            (queue.nil? || payload["_queue"]?.try(&.as_s?) == queue) &&
            matches_params?(payload, params)
        end
        unless found
          raise AssertionFailed.new(
            "Expected an enqueued email for #{expected_mailer}##{expected_action}, " \
            "got #{candidates.size} enqueued job(s)")
        end
      end

      def assert_enqueued_emails(count : Int32 = 1, &) : Nil
        before = Job.enqueued_jobs.size
        yield
        actual = Job.enqueued_jobs[before..].count { |entry| entry[:job].includes?("Mailer::DeliveryJob") }
        unless actual == count
          raise AssertionFailed.new("Expected #{count} enqueued email(s), got #{actual}")
        end
      end

      private def matches_params?(payload : JSON::Any, params : Hash(String, String)?) : Bool
        return true if params.nil?
        actual = payload["_params"]?.try(&.as_h?) || {} of String => JSON::Any
        params.all? do |key, value|
          actual[key]?.try(&.as_s?) == value
        end
      end
    end
  end
end
