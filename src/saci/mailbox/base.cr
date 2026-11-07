require "../smtp"
require "../mailer"
require "./inbound_email"

module Saci
  module Mailbox
    # Raised by `Base#bounce_with` to abort the rest of `process`. The
    # processor catches it and leaves the inbound email in the `bounced`
    # state.
    class Bounce < Error
    end

    # Base class for inbound mailboxes.
    #
    # ```
    # class SupportMailbox < Saci::Mailbox::Base
    #   before_processing :mark_seen
    #   rescue_from Saci::Mailbox::ParseError do |error|
    #     # handle gracefully
    #   end
    #
    #   def process
    #     if mail.subject.includes?("spam")
    #       bounce_with Saci::Mailer::Mail.new(
    #         [mail.from], "support@example.com", "Re: #{mail.subject}", "Rejected")
    #     else
    #       Ticket.create!(subject: mail.subject, body: mail.text_body)
    #     end
    #   end
    #
    #   private def mark_seen
    #     # ...
    #   end
    # end
    # ```
    #
    # Lifecycle: `before_processing` (parent-first), `around_processing`
    # (wraps `process`), `process`, `after_processing` (always, including
    # bounces/failures). `rescue_from` handlers may claim exceptions;
    # unclaimed exceptions mark the inbound email `failed` and re-raise.
    abstract class Base
      getter inbound_email : InboundEmail
      getter mail : Message

      def initialize(@inbound_email : InboundEmail)
        @mail = @inbound_email.mail_message
      end

      # Implement the mailbox behavior. Everything is available through
      # `mail`, `inbound_email`, `deliver`, `bounce_with`, `relay_to`,
      # `incinerate` and `forget`. The return value is ignored, so a last
      # expression like `Ticket.create!(...)` needs no explicit type.
      abstract def process

      # Runs the callback chain around `process` and updates the inbound
      # email status. Called by `Saci::Mailbox.process!` / the ingress
      # controller; user code normally implements `process` instead.
      def perform_processing : InboundEmail
        return inbound_email if inbound_email.processed? || inbound_email.bounced?

        inbound_email.mark_processing!
        error : Exception? = nil

        begin
          run_before_processing
          run_around_processing { process }
        rescue Bounce
          # bounce_with already delivered the bounce and marked the record.
        rescue ex
          handled = begin
            run_rescue(ex)
          rescue handler_ex
            inbound_email.mark_failed!(handler_ex.message)
            error = handler_ex
            true
          end
          unless handled
            inbound_email.mark_failed!(ex.message)
            error = ex
          end
        end

        # Success or a claimed exception leaves the record in `processing`.
        inbound_email.mark_processed! if inbound_email.processing?

        begin
          run_after_processing
        rescue after_ex
          error ||= after_ex
        end

        if Saci::Mailbox.incinerate_after_processing? && (inbound_email.processed? || inbound_email.bounced?)
          inbound_email.incinerate
        end

        raise error if error
        inbound_email
      end

      def run_before_processing : Nil
        __saci_mailbox_before_processing
      end

      def run_around_processing(&block : -> Nil) : Nil
        __saci_mailbox_around_processing { block.call }
      end

      def run_after_processing : Nil
        __saci_mailbox_after_processing
      end

      def run_rescue(ex : Exception) : Bool
        __saci_mailbox_rescue(ex)
      end

      # Delivers a reply/notification through `Saci::Mailer` (respects the
      # configured delivery adapter, including `:test` in specs).
      def deliver(message : Saci::Mailer::Mail) : Nil
        message.deliver_now
      end

      # Delivers a bounce and aborts processing. The inbound email becomes
      # `bounced?`; the exception is swallowed by `perform_processing`.
      def bounce_with(message : Saci::Mailer::Mail) : Nil
        deliver(message)
        inbound_email.mark_bounced!
        raise Bounce.new
      end

      # Convenience bounce builder (`bounce_with` with a plain body).
      def bounce_with(subject : String, body : String, to : String? = nil, from : String? = nil) : Nil
        recipient = to || mail.from
        sender = from || Saci::Mailbox.bounce_from
        bounce_with(Saci::Mailer::Mail.new([recipient], sender, subject, body))
      end

      # Forwards the inbound mail to `address` through the mailer. This is a
      # plain text/HTML relay; binary attachments are not re-attached (the
      # raw source remains available via `inbound_email.raw_email`).
      def relay_to(address : String, subject_prefix : String = "Fwd: ") : Saci::Mailer::Mail
        sender = mail.from.empty? ? Saci::Mailbox.relay_from : mail.from
        forwarded = Saci::Mailer::Mail.new(
          [address],
          sender,
          "#{subject_prefix}#{mail.subject}",
          mail.text_body,
          mail.html_body,
          headers: {
            "X-Saci-Forwarded-Message-Id" => mail.message_id,
            "X-Saci-Forwarded-From"       => mail.from,
          }
        )
        deliver(forwarded)
        forwarded
      end

      # Drops the raw MIME source now.
      def incinerate : Nil
        inbound_email.incinerate
      end

      # Drops the raw MIME source through the job queue.
      def incinerate_later : Nil
        inbound_email.incinerate_later
      end

      # Alias for `incinerate` matching Action Mailbox's terminology.
      def forget : Nil
        inbound_email.forget
      end

      macro inherited
        # Register the class so `route all: :support` / `mailbox: "support"`
        # can resolve it at runtime (Crystal has no runtime `constantize`).
        Saci::Mailbox.register({{@type}})

        def __saci_mailbox_before_processing : Nil
          super
        end

        def __saci_mailbox_after_processing : Nil
          super
        end

        def __saci_mailbox_around_processing(&__saci_proceed : -> Nil) : Nil
          super { __saci_proceed.call }
        end

        def __saci_mailbox_rescue(__saci_exc : Exception) : Bool
          super
        end
      end

      def __saci_mailbox_before_processing : Nil
      end

      def __saci_mailbox_after_processing : Nil
      end

      def __saci_mailbox_around_processing(&__saci_proceed : -> Nil) : Nil
        __saci_proceed.call
      end

      def __saci_mailbox_rescue(__saci_exc : Exception) : Bool
        false
      end

      macro before_processing(name = nil, &block)
        def __saci_mailbox_before_processing : Nil
          previous_def
          {% if name %}
            self.{{name.id}}
          {% elsif block %}
            {{block.body}}
          {% end %}
        end
      end

      macro after_processing(name = nil, &block)
        def __saci_mailbox_after_processing : Nil
          previous_def
          {% if name %}
            self.{{name.id}}
          {% elsif block %}
            {{block.body}}
          {% end %}
        end
      end

      # `around_processing :wrap` (where `wrap` yields) or
      # `around_processing do |proceed| ... proceed.call ... end`.
      macro around_processing(name = nil, &block)
        def __saci_mailbox_around_processing(&__saci_proceed : -> Nil) : Nil
          {% if name %}
            self.{{name.id}} do
              previous_def { __saci_proceed.call }
            end
          {% elsif block %}
            {% if block.args.size != 1 %}
              {% raise "around_processing block must take one argument (proceed)" %}
            {% end %}
            {{block.args[0].id}} = __saci_proceed
            {{block.body}}
          {% else %}
            previous_def { __saci_proceed.call }
          {% end %}
        end
      end

      macro rescue_from(*excs, &block)
        def __saci_mailbox_rescue(__saci_exc : Exception) : Bool
          {% for exc in excs %}
            if __saci_exc.is_a?({{exc}})
              {% if block.args.size > 0 %}
                {{block.args[0].id}} = __saci_exc.as({{exc}})
              {% end %}
              {{block.body}}
              return true
            end
          {% end %}
          previous_def
        end
      end
    end
  end
end
