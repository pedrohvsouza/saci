require "file"
require "../mailer"
require "./inbound_email"

module Saci
  module Mailbox
    # Raised by the assertion helpers when expectations do not hold. Kept
    # independent from `Spec` so this file can be required by applications
    # that do not load the spec framework.
    class AssertionFailed < Error
    end

    # Action Mailbox/Action Mailer-flavored testing helpers.
    #
    # Include at the top of a spec file (or inside a `describe`):
    #
    # ```
    # require "../src/saci/mailbox"
    # include Saci::Mailbox::TestHelpers
    #
    # it "stores and processes mail" do
    #   inbound = create_inbound_email_from_mail(
    #     from: "jane@example.com",
    #     to: "support@example.com",
    #     subject: "Help",
    #     body: "Please help")
    #   perform_processing(inbound)
    #   inbound.processed?.should be_true
    #   assert_emails_received(1)
    # end
    # ```
    module TestHelpers
      extend self

      # Persists a `Saci::Mailer::Mail` as an inbound email (its `to_mime`
      # wire form is parsed back, so this exercises the same code path as
      # provider ingress).
      def create_inbound_email_from_mail(mail : Saci::Mailer::Mail) : InboundEmail
        InboundEmail.receive(mail.to_mime)
      end

      # Builds + persists an inbound email from simple fields.
      def create_inbound_email_from_mail(*, from : String = "sender@example.com",
                                         to : String = "support@example.com",
                                         subject : String = "Hello",
                                         body : String = "Hello",
                                         html_body : String? = nil,
                                         cc : Array(String) = [] of String,
                                         headers : Hash(String, String) = {} of String => String) : InboundEmail
        mail = Saci::Mailer::Mail.new(
          [to],
          from,
          subject,
          body,
          html_body,
          cc: cc,
          headers: headers
        )
        create_inbound_email_from_mail(mail)
      end

      # Reads an `.eml` fixture. `name` may be a path or a fixture name;
      # names are searched under `spec/fixtures/action_mailbox`,
      # `spec/fixtures/mailbox`, `spec/fixtures/emails` and `spec/fixtures`.
      def create_inbound_email_from_fixture(name : String) : InboundEmail
        path = fixture_path(name)
        create_inbound_email_from_source(File.read(path))
      end

      # Parses + persists a raw MIME source.
      def create_inbound_email_from_source(raw_email : String) : InboundEmail
        InboundEmail.receive(raw_email)
      end

      # Runs the routed mailbox for an inbound email.
      def perform_processing(inbound_email : InboundEmail) : InboundEmail
        Saci::Mailbox.process!(inbound_email)
      end

      # Asserts that exactly `count` inbound emails have been persisted.
      def assert_emails_received(count : Int32 = 1) : Nil
        actual = InboundEmail.count.to_i
        return if actual == count
        raise AssertionFailed.new("Expected #{count} inbound email(s), found #{actual}")
      end

      def assert_no_emails : Nil
        assert_emails_received(0)
      end

      # Test-isolation helper: deletes every inbound email row.
      def clear_inbound_emails! : Nil
        InboundEmail.all.to_a.each(&.destroy)
      end

      private def fixture_path(name : String) : String
        candidates = [] of String
        if File.file?(name)
          candidates << name
        else
          file_names = [name, "#{name}.eml", "#{name}.mail"]
          directories = [
            Saci::Mailbox.fixture_path,
            "spec/fixtures/action_mailbox",
            "spec/fixtures/mailbox",
            "spec/fixtures/emails",
            "spec/fixtures",
          ]
          directories.each do |directory|
            file_names.each do |file_name|
              path = File.join(directory, file_name)
              candidates << path if File.file?(path)
            end
          end
        end
        candidates.first? || raise Error.new(
          "Mailbox fixture #{name.inspect} not found (looked in #{Saci::Mailbox.fixture_path}, " \
          "spec/fixtures/action_mailbox, spec/fixtures/mailbox, spec/fixtures/emails, spec/fixtures)"
        )
      end
    end
  end
end
