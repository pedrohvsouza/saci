require "random/secure"
require "../record"
require "../record/schema_check"
require "../job"
require "../job_db"
require "./message"

module Saci
  module Mailbox
    # Persistent inbound email (`saci_inbound_emails`). One row is created
    # per received message; the raw MIME source is retained until
    # `incinerate` (or automatic incineration after processing, if enabled).
    #
    # ```
    # inbound = Saci::Mailbox::InboundEmail.receive(raw_email)
    # inbound.mail_message.subject
    # inbound.process
    # inbound.processed? # => true
    # inbound.incinerate
    # ```
    #
    # Schema setup:
    #
    # ```
    # Saci::Mailbox.ensure_schema! # in a boot hook/spec
    #
    # # or in a migration:
    # class CreateInboundEmails < Saci::Record::Migration
    #   def change
    #     Saci::Mailbox::InboundEmail.create_table(self)
    #   end
    # end
    # ```
    class InboundEmail < Saci::Record::Base
      table "saci_inbound_emails"

      STATUS_PENDING    = "pending"
      STATUS_PROCESSING = "processing"
      STATUS_PROCESSED  = "processed"
      STATUS_BOUNCED    = "bounced"
      STATUS_FAILED     = "failed"

      column id : Int64, primary: true
      column message_id : String
      column status : String, default: STATUS_PENDING
      column raw_email : String
      column mail : JSON
      column created_at : Time

      @mail_message : Message? = nil
      @last_error : String? = nil

      before_save do
        self.created_at ||= Time.utc
      end

      # Error message from the most recent failed processing attempt (best
      # effort; not persisted because the schema stays intentionally small).
      getter last_error : String?

      # Adds the inbound-email table + unique message-id index to a
      # migration. Called from a user migration's `change`.
      def self.create_table(migration : Saci::Record::Migration) : Nil
        migration.create_table(table_name) do |t|
          t.string :message_id, null: false
          t.string :status, null: false, default: STATUS_PENDING
          t.text :raw_email
          t.text :mail
          t.datetime :created_at, null: false
        end
        migration.add_index(table_name, :message_id, unique: true, name: "index_saci_inbound_emails_on_message_id")
      end

      def self.table_exists?(db : DB::Database | DB::Connection = Saci::Record.connection) : Bool
        adapter = Saci::Record.adapter_of(db)
        sql = case adapter
              when :postgres
                "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public' AND tablename = ?"
              when :mysql
                "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?"
              else
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?"
              end
        count = 0_i64
        Saci::Record.query_compat(db, sql, [table_name] of Saci::Record::Value) do |rs|
          rs.each { count = rs.read(Int64) }
        end
        count > 0
      end

      # Builds an unsaved inbound email from raw MIME (test helpers and
      # in-memory processing). `receive` persists instead.
      def self.build(raw_email : String) : self
        build_from_message(Message.parse(raw_email), raw_email)
      end

      # Builds an unsaved inbound email from an already parsed message. Used
      # by router lookups that receive a `Message` directly; `raw_email` may
      # be nil for metadata-only messages.
      def self.build_from_message(message : Message, raw_email : String? = nil) : self
        inbound = new
        inbound.message_id = message.message_id.empty? ? generated_message_id : message.message_id
        inbound.status = STATUS_PENDING
        inbound.raw_email = raw_email || (message.raw.empty? ? nil : message.raw)
        inbound.mail = message.to_h.to_json
        inbound.created_at = Time.utc
        inbound
      end

      # Parses + persists a raw email. Message-ID is treated as the
      # idempotency key: receiving the same Message-ID twice returns the
      # existing row (Action Mailbox dedupes providers' retries this way).
      def self.receive(raw_email : String) : self
        message = Message.parse(raw_email)
        message_id = message.message_id.empty? ? generated_message_id : message.message_id
        if existing = find_by(message_id: message_id)
          return existing
        end
        inbound = new
        inbound.message_id = message_id
        inbound.status = STATUS_PENDING
        inbound.raw_email = raw_email
        inbound.mail = message.to_h.to_json
        inbound.created_at = Time.utc
        inbound.save!
        inbound
      rescue ex : DB::Error
        # A concurrent delivery of the same Message-ID can race the unique
        # index; return the winner.
        if existing = find_by(message_id: message_id)
          return existing
        end
        raise ex
      end

      def self.generated_message_id : String
        "<#{Random::Secure.hex(16)}@saci.local>"
      end

      # The `mail` column stores JSON metadata; this reader returns the
      # parsed `Message` instead (Rails `InboundEmail#mail` behavior). Use
      # `mail_json` for parsed JSON or `mail_metadata` for the raw string.
      def mail : Message
        mail_message
      end

      # Raw JSON metadata column value.
      def mail_metadata : String?
        @mail
      end

      # Parsed mail. Falls back to the stored JSON metadata once the raw
      # source has been incinerated (attachment bodies are no longer
      # available in that case).
      def mail_message : Message
        @mail_message ||= if raw = raw_email
                            Message.parse(raw)
                          elsif metadata = mail_json
                            Message.from_metadata(metadata)
                          else
                            Message.new
                          end
      end

      # Processes this inbound email through the configured router. Returns
      # self (idempotent for already processed/bounced mail).
      def process : self
        Saci::Mailbox.process!(self)
      end

      def pending? : Bool
        status.to_s == STATUS_PENDING
      end

      def processing? : Bool
        status.to_s == STATUS_PROCESSING
      end

      def processed? : Bool
        status.to_s == STATUS_PROCESSED
      end

      def bounced? : Bool
        status.to_s == STATUS_BOUNCED
      end

      def failed? : Bool
        status.to_s == STATUS_FAILED
      end

      # True once the raw MIME source has been removed.
      def incinerated? : Bool
        raw_email.nil?
      end

      def mark_processing! : Nil
        @last_error = nil
        transition_to(STATUS_PROCESSING)
      end

      def mark_processed! : Nil
        transition_to(STATUS_PROCESSED)
      end

      def mark_bounced! : Nil
        transition_to(STATUS_BOUNCED)
      end

      def mark_failed!(error : String? = nil) : Nil
        @last_error = error
        transition_to(STATUS_FAILED)
      end

      # Deletes the raw MIME source (the parsed metadata and status stay).
      # Safe to call repeatedly.
      def incinerate : self
        self.raw_email = nil
        update_columns(raw_email: nil) if persisted?
        self
      end

      # Enqueues incineration through `Saci::Job` (useful for large mails or
      # delayed cleanup). Falls back to immediate incineration for unsaved
      # records.
      def incinerate_later : self
        if persisted? && (id = self.id)
          IncinerationJob.perform_later({id: id})
        else
          incinerate
        end
        self
      end

      # Rails Mailbox-style alias: drop the raw source now.
      def forget : self
        incinerate
      end

      private def transition_to(value : String) : Nil
        self.status = value
        update_columns(status: value) if persisted?
      end
    end

    # Background incineration (used by `InboundEmail#incinerate_later`).
    class IncinerationJob < Saci::Job::Base
      queue_as :mailbox

      def perform(payload : JSON::Any) : Nil
        id = payload["id"]?.try(&.as_i64?)
        return unless id
        InboundEmail.find_by(id: id).try(&.incinerate)
      end
    end

    # Migration for `saci_inbound_emails`; also used by
    # `Saci::Mailbox.ensure_schema!`.
    class CreateInboundEmails < Saci::Record::Migration
      def change
        InboundEmail.create_table(self)
      end
    end
  end
end
