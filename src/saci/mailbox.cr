require "json"
require "http/server"
require "http/server/handlers/websocket_handler"

# These are normally loaded by `src/saci.cr`; requiring them here keeps
# `require "saci/mailbox"` usable on its own (and makes the require order
# explicit when the coordinator wires this file into the framework).
require "./params"
require "./controller"
require "./exceptions"
require "./cookies"
require "./session"
require "./csrf"
require "./secure_headers"
require "./i18n"
require "./application"
require "./router"

require "./mailbox/message"
require "./mailbox/inbound_email"
require "./mailbox/base"
require "./mailbox/router"
require "./mailbox/ingress"
require "./mailbox/test_helpers"

module Saci
  # Action Mailbox equivalent for inbound email (G76).
  #
  # ```
  # class SupportMailbox < Saci::Mailbox::Base
  #   def process
  #     Ticket.create!(subject: mail.subject, body: mail.text_body)
  #   end
  # end
  #
  # class SpamMailbox < Saci::Mailbox::Base
  #   def process
  #     bounce_with "Re: #{mail.subject}", "Rejected as spam"
  #   end
  # end
  #
  # Saci::Mailbox.router = Saci::Mailbox::Router.new.draw do |r|
  #   r.route ->(inbound : Saci::Mailbox::InboundEmail) {
  #     inbound.mail.subject.includes?("SPAM")
  #   }, mailbox: SpamMailbox
  #   r.route SupportMailbox, to: "support@example.com"
  #   r.route all: :backup
  # end
  #
  # router = Saci::Router.new.draw do |r|
  #   Saci::Mailbox.mount(r)
  # end
  # ```
  #
  # Persistence is opt-in: call `Saci::Mailbox.ensure_schema!` once at boot
  # (or use `InboundEmail.create_table` in a migration). In-memory
  # `InboundEmail.build(raw)` works without a database; ingress and
  # `receive`/test helpers need the table.
  module Mailbox
    class UnknownMailboxError < Error
    end

    # Registry populated by `Mailbox::Base.inherited` (Crystal cannot
    # constantize at runtime). Keys are lowercased full names, demodulized
    # names and underscored names without the `Mailbox` suffix, so
    # `route all: :backup` resolves `BackupMailbox`.
    @@mailboxes = {} of String => Base.class
    @@mailboxes_mutex = Mutex.new

    @@router : Router? = nil
    @@router_mutex = Mutex.new

    @@ingress_password : String? = nil
    @@max_ingress_size : Int64 = 10_i64 * 1024 * 1024
    @@incinerate_after_processing : Bool = false
    @@relay_from : String = "mailbox@localhost"
    @@bounce_from : String = "mailbox@localhost"
    @@fixture_path : String = "spec/fixtures/action_mailbox"
    @@config_mutex = Mutex.new

    def self.register(mailbox : Base.class) : Nil
      full = mailbox.name
      short = full.split("::").last
      stripped = short.sub(/Mailbox\z/, "")
      keys = [
        full,
        short,
        full.gsub("::", "_"),
        stripped,
        underscore(stripped),
      ]
      @@mailboxes_mutex.synchronize do
        keys.each { |key| @@mailboxes[key.downcase] = mailbox unless key.empty? }
      end
    end

    # Resolves a mailbox class, symbol or string (`SupportMailbox`,
    # `:support`, `"support_mailbox"`, `"MyApp::SupportMailbox"`).
    def self.resolve_mailbox(mailbox : Base.class) : Base.class
      mailbox
    end

    # Union form used by the keyword route DSL, where the value may be a
    # class, symbol or string depending on the branch taken.
    def self.resolve_mailbox(value : Base.class | String | Symbol) : Base.class
      case value
      when String, Symbol then resolve_mailbox(value)
      else                     value
      end
    end

    def self.resolve_mailbox(value : String | Symbol) : Base.class
      key = value.to_s.downcase
      mailbox = @@mailboxes_mutex.synchronize { @@mailboxes[key]? }
      return mailbox if mailbox
      candidates = [underscore(key), "#{underscore(key)}_mailbox", "#{key}mailbox"]
      @@mailboxes_mutex.synchronize do
        candidates.each do |candidate|
          if found = @@mailboxes[candidate]?
            return found
          end
        end
      end
      raise UnknownMailboxError.new(
        "Unknown mailbox #{value.inspect}. Registered mailboxes: #{mailbox_names.join(", ")}"
      )
    end

    def self.registered_mailboxes : Array(Base.class)
      @@mailboxes_mutex.synchronize { @@mailboxes.values.uniq }
    end

    def self.mailbox_names : Array(String)
      registered_mailboxes.map(&.name).sort
    end

    def self.router : Router
      @@router_mutex.synchronize do
        @@router || raise ConfigurationError.new(
          "Saci::Mailbox.router is not configured. Build one with " \
          "`Saci::Mailbox.router = Saci::Mailbox::Router.new.draw { |r| ... }`"
        )
      end
    end

    def self.router? : Router?
      @@router_mutex.synchronize { @@router }
    end

    def self.router=(router : Router) : Router
      @@router_mutex.synchronize { @@router = router }
      router
    end

    def self.draw(&block : Router ->) : Router
      router = Router.new
      yield router
      self.router = router
      router
    end

    # Routes + processes an inbound email. Idempotent for already
    # processed/bounced records. Returns the inbound email.
    def self.process!(inbound_email : InboundEmail) : InboundEmail
      return inbound_email if inbound_email.processed? || inbound_email.bounced?
      mailbox = router.mailbox_for(inbound_email)
      mailbox.perform_processing
      inbound_email
    end

    # Alias used by provider ingress / application code.
    def self.deliver(inbound_email : InboundEmail) : InboundEmail
      process!(inbound_email)
    end

    def self.mailbox_for(inbound_email : InboundEmail) : Base
      router.mailbox_for(inbound_email)
    end

    def self.mailbox_for(mail : Message) : Base
      router.mailbox_for(mail)
    end

    def self.ingress_password : String?
      configured = @@config_mutex.synchronize { @@ingress_password }
      return configured unless configured.nil?
      from_env = ENV["SACI_MAILBOX_INGRESS_PASSWORD"]?
      from_env && !from_env.empty? ? from_env : nil
    end

    def self.ingress_password=(password : String?) : Nil
      @@config_mutex.synchronize { @@ingress_password = password }
    end

    def self.max_ingress_size : Int64
      @@config_mutex.synchronize { @@max_ingress_size }
    end

    def self.max_ingress_size=(bytes : Int) : Nil
      raise ArgumentError.new("max_ingress_size must be positive") if bytes <= 0
      @@config_mutex.synchronize { @@max_ingress_size = bytes.to_i64 }
    end

    def self.incinerate_after_processing? : Bool
      @@config_mutex.synchronize { @@incinerate_after_processing }
    end

    def self.incinerate_after_processing=(value : Bool) : Nil
      @@config_mutex.synchronize { @@incinerate_after_processing = value }
    end

    def self.relay_from : String
      @@config_mutex.synchronize { @@relay_from }
    end

    def self.relay_from=(address : String) : Nil
      @@config_mutex.synchronize { @@relay_from = address }
    end

    def self.bounce_from : String
      @@config_mutex.synchronize { @@bounce_from }
    end

    def self.bounce_from=(address : String) : Nil
      @@config_mutex.synchronize { @@bounce_from = address }
    end

    def self.fixture_path : String
      @@config_mutex.synchronize { @@fixture_path }
    end

    def self.fixture_path=(path : String) : Nil
      @@config_mutex.synchronize { @@fixture_path = path }
    end

    # Idempotently creates `saci_inbound_emails` (tracked in
    # `schema_migrations`). Safe to call on every boot; still tolerates a
    # table provisioned manually outside the migrator.
    def self.ensure_schema!(db : DB::Database | DB::Connection = Saci::Record.connection) : Nil
      return if InboundEmail.table_exists?(db)
      migrations = [CreateInboundEmails] of Saci::Record::Migration.class
      begin
        Saci::Record::Migrator.migrate(db, migrations)
      rescue ex
        # A table provisioned outside the migrator still counts as ready.
        raise ex unless InboundEmail.table_exists?(db)
      end
    end

    # Alias matching the common Rails initializer phrasing.
    def self.create_inbound_emails_table(db : DB::Database | DB::Connection = Saci::Record.connection) : Nil
      ensure_schema!(db)
    end

    # Test-isolation: clears the router, mounted ingress paths and config
    # overrides. Mailbox classes stay registered (they are compile-time
    # artifacts).
    def self.reset! : Nil
      @@router_mutex.synchronize { @@router = nil }
      Ingress.clear!
      @@config_mutex.synchronize do
        @@ingress_password = nil
        @@max_ingress_size = 10_i64 * 1024 * 1024
        @@incinerate_after_processing = false
        @@relay_from = "mailbox@localhost"
        @@bounce_from = "mailbox@localhost"
        @@fixture_path = "spec/fixtures/action_mailbox"
      end
    end

    private def self.underscore(value : String) : String
      value.gsub(/([a-z0-9])([A-Z])/, "\\1_\\2").downcase
    end
  end
end
