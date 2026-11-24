require "db"

# crystal-db's `DB::Database` does not keep the URI it was opened with, so
# `Saci::Record.connection = DB.open("sqlite3://...?foreign_keys=off")`
# could not see the explicit opt-out. Every `DB.open` funnels through
# `DB.build_database(URI)`; record the URI there so Saci can read the
# connection options back.
class DB::Database
  # URI this database was opened with (`DB.open`), or nil when it was
  # built directly through `Database.new`.
  property saci_uri : URI? = nil
end

module DB
  private def self.build_database(uri : URI)
    db = previous_def
    db.saci_uri = uri
    db
  end
end
