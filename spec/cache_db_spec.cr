require "spec"
require "../src/saci"

# DB-backed cache (G145/G163). Every test uses its own SQLite file through
# `DbStore.new(url:)`, so nothing here needs a live PostgreSQL/MySQL server
# (the adapter-specific SQL paths are shared/guarded in `cache_db.cr`).

CACHE_DB_TMP = "/tmp/opencode"

private def cache_db_new(*, namespace : String = "", max_entries : Int32? = nil, max_bytes : Int64? = nil) : Tuple(Saci::Cache::DbStore, String)
  Dir.mkdir_p(CACHE_DB_TMP)
  path = File.join(CACHE_DB_TMP, "saci_cache_spec_#{Random::Secure.hex(8)}.db")
  store = Saci::Cache::DbStore.new(
    url: "sqlite3://#{path}",
    namespace: namespace,
    max_entries: max_entries,
    max_bytes: max_bytes)
  {store, path}
end

private def cache_db_close(store : Saci::Cache::DbStore, path : String) : Nil
  store.close
  ["", "-wal", "-shm"].each { |suffix| File.delete?("#{path}#{suffix}") }
end

describe Saci::Cache::DbStore do
  it "creates its schema automatically and round-trips values" do
    store, path = cache_db_new
    begin
      store.read("missing").should be_nil
      store.exist?("missing").should be_false
      store.delete("missing").should be_false

      store.write("k", "v").should be_true
      store.read("k").should eq("v")
      store.exist?("k").should be_true

      # Same type-tagged encoding as MemoryStore/RedisStore.
      store.write("i", 42_i64)
      store.write("f", 1.5_f64)
      store.write("bt", true)
      store.write("bf", false)
      now = Time.utc
      store.write("t", now)
      store.write("n", nil)

      store.read("i").should be_nil
      store.read_value("i").should eq(42_i64)
      store.read_value("f").should eq(1.5_f64)
      store.read_value("bt").should eq(true)
      store.read_value("bf").should eq(false)
      store.read_value("t").as(Time).to_unix_ns.should eq(now.to_unix_ns)
      store.read_value("n").should be_nil
      # A stored Nil is a present entry, and fetch treats it as a hit.
      store.exist?("n").should be_true
      calls = 0
      store.fetch_value("n") { calls += 1; "x" }.should be_nil
      calls.should eq(0)

      calls = 0
      store.fetch("memo") { calls += 1; "computed" }.should eq("computed")
      store.fetch("memo") { calls += 1; "computed" }.should eq("computed")
      calls.should eq(1)

      store.delete("k").should be_true
      store.read("k").should be_nil
      store.delete("k").should be_false
    ensure
      cache_db_close(store, path)
    end
  end

  it "expires entries lazily and prunes expired rows" do
    store, path = cache_db_new
    begin
      store.write("short", "v", expires_in: 100.milliseconds)
      store.write("forever", "v")
      store.read("short").should eq("v")
      store.exist?("short").should be_true
      sleep 150.milliseconds

      store.read("short").should be_nil
      store.read_value("short").should be_nil
      store.exist?("short").should be_false
      store.fetch("short") { "fresh" }.should eq("fresh")
      store.read("forever").should eq("v")

      store.write("old", "v", expires_in: 1.millisecond)
      sleep 10.milliseconds
      store.prune_expired.should eq(1_i64)
      store.count.should eq(2_i64)

      store.write("old2", "v", expires_in: 1.millisecond)
      sleep 10.milliseconds
      store.prune.should eq(1_i64) # Rails/Solid Cache alias
      store.count.should eq(2_i64)
    ensure
      cache_db_close(store, path)
    end
  end

  it "isolates keys by namespace" do
    store, path = cache_db_new(namespace: "a")
    begin
      store.write("k", "va")
      store.namespace = "b"
      store.read("k").should be_nil
      store.write("k", "vb")
      store.read("k").should eq("vb")
      store.namespace = "a"
      store.read("k").should eq("va")
      store.delete_matched("k").should eq(1_i64)
      store.namespace = "b"
      store.read("k").should eq("vb")
    ensure
      cache_db_close(store, path)
    end
  end

  it "increments/decrements atomically in SQL and preserves counter shape" do
    store, path = cache_db_new
    begin
      store.increment("c").should eq(1_i64)
      store.increment("c").should eq(2_i64)
      store.increment("c", by: 8).should eq(10_i64)
      store.read_value("c").should eq(10_i64)
      store.decrement("c", by: 3).should eq(7_i64)
      store.read_value("c").should eq(7_i64)

      store.write("s", "5")
      store.increment("s", by: 2).should eq(7_i64)
      store.read("s").should eq("7")

      store.write("nope", "abc")
      expect_raises(ArgumentError, /non-numeric/) { store.increment("nope") }

      store.write("float", 1.5_f64)
      expect_raises(ArgumentError, /non-numeric/) { store.increment("float") }

      store.write("expired", 100_i64, expires_in: 50.milliseconds)
      sleep 70.milliseconds
      store.increment("expired", by: 3).should eq(3_i64)
      store.read_value("expired").should eq(3_i64)
    ensure
      cache_db_close(store, path)
    end
  end

  it "never loses concurrent increments" do
    store, path = cache_db_new
    begin
      fibers = 16
      per_fiber = 10
      done = Channel(Nil).new(fibers)
      results = Channel(Int64).new(fibers * per_fiber)

      fibers.times do
        spawn do
          per_fiber.times { results.send(store.increment("counter")) }
          done.send(nil)
        end
      end
      fibers.times { done.receive }

      returned = [] of Int64
      results.close
      results.each { |value| returned << value }
      returned.should contain(1_i64)
      returned.size.should eq(fibers * per_fiber)
      returned.uniq.size.should eq(fibers * per_fiber)
      store.read_value("counter").should eq((fibers * per_fiber).to_i64)
    ensure
      cache_db_close(store, path)
    end
  end

  it "supports delete_matched glob patterns" do
    store, path = cache_db_new
    begin
      store.write("user:1", "a")
      store.write("user:2", "b")
      store.write("account:1", "c")
      store.write("users", "d")
      store.delete_matched("user:*").should eq(2_i64)
      store.read("user:1").should be_nil
      store.read("account:1").should eq("c")
      store.read("users").should eq("d")
    ensure
      cache_db_close(store, path)
    end
  end

  it "trims by max_entries (oldest first)" do
    store, path = cache_db_new(max_entries: 2)
    begin
      4.times { |i| store.write("k#{i}", "v#{i}") }
      store.count.should eq(2_i64)
      store.read("k0").should be_nil
      store.read("k1").should be_nil
      store.read("k2").should eq("v2")
      store.read("k3").should eq("v3")
      store.trim.should eq(0_i64)
    ensure
      cache_db_close(store, path)
    end
  end

  it "trims by max_bytes" do
    store, path = cache_db_new(max_bytes: 20_i64)
    begin
      5.times { |i| store.write("k#{i}", "0123456789") } # 12 encoded bytes each
      store.total_bytes.should be <= 20_i64
      store.count.should eq(1_i64)
      store.read("k4").should eq("0123456789")
      store.read("k0").should be_nil
    ensure
      cache_db_close(store, path)
    end
  end

  it "supports a separate connection/database file" do
    store, path = cache_db_new
    other = nil
    begin
      store.write("shared", "value")
      # A second store on the same file sees the entry (persisted, not
      # in-process state).
      other = Saci::Cache::DbStore.new(url: "sqlite3://#{path}")
      other.read("shared").should eq("value")
      other.write("from-second", 9_i64)
      store.read_value("from-second").should eq(9_i64)
    ensure
      other.try(&.close)
      cache_db_close(store, path)
    end
  end

  it "supports a custom table and the class-level schema helper" do
    Dir.mkdir_p(CACHE_DB_TMP)
    path = File.join(CACHE_DB_TMP, "saci_cache_custom_#{Random::Secure.hex(8)}.db")
    db = DB.open("sqlite3://#{path}")
    begin
      Saci::Cache::DbStore.ensure_schema!(db, table: "custom_cache_entries")
      store = Saci::Cache::DbStore.new(db, table: "custom_cache_entries", auto_schema: false)
      store.write("k", "v")
      store.read("k").should eq("v")
    ensure
      db.close
      ["", "-wal", "-shm"].each { |suffix| File.delete?("#{path}#{suffix}") }
    end
  end

  it "supports read_multi/write_multi/fetch_multi/delete_multi" do
    store, path = cache_db_new
    begin
      store.write("a", "1")
      store.write("b", 2_i64)
      store.write("n", nil)

      found = store.read_multi(["a", "b", "n", "missing"])
      found["a"].should eq("1")
      found["b"].should eq(2_i64)
      found.has_key?("n").should be_true
      found["n"].should be_nil
      found.has_key?("missing").should be_false

      store.write_multi({"c" => "3", "d" => 4_i64})
      store.read("c").should eq("3")
      store.read_value("d").should eq(4_i64)
      # Literal hashes (String | Int32) infer without an explicit cast.
      store.write_multi({"e" => "5", "f" => 6})
      store.read("e").should eq("5")
      store.read_value("f").should eq(6_i64)

      computed = [] of String
      fetched = store.fetch_multi(["a", "new"]) do |key|
        computed << key
        "computed-#{key}"
      end
      computed.should eq(["new"])
      fetched["a"].should eq("1")
      fetched["new"].should eq("computed-new")
      store.read("new").should eq("computed-new")

      store.delete_multi(["a", "b", "missing"]).should eq(2_i64)
      store.exist?("a").should be_false
      store.exist?("c").should be_true
    ensure
      cache_db_close(store, path)
    end
  end

  it "stores bytes and JSON explicitly while keeping String compatibility" do
    store, path = cache_db_new
    begin
      bytes = Bytes[0_u8, 1_u8, 2_u8, 254_u8, 255_u8]
      store.write_bytes("bin", bytes).should be_true
      store.read_bytes("bin").should eq(bytes)
      store.exist?("bin").should be_true
      store.write("bin-overload", bytes)
      store.read_bytes("bin-overload").should eq(bytes)

      json = JSON.parse(%({"answer":42,"nested":{"ok":true}}))
      store.write_json("json", json)
      store.read_json("json").not_nil!.to_json.should eq(json.to_json)
      store.write("json-overload", json)
      store.read_json("json-overload").not_nil!.to_json.should eq(json.to_json)

      # JSON stored as a plain String (the Memory/Redis-compatible path).
      store.write("json-string", %({"hello":"world"}))
      store.read("json-string").should eq(%({"hello":"world"}))
    ensure
      cache_db_close(store, path)
    end
  end

  it "clears every namespace" do
    store, path = cache_db_new(namespace: "a")
    begin
      store.write("k", "1")
      store.namespace = "b"
      store.write("k", "2")
      store.clear
      store.count.should eq(0_i64)
      store.read("k").should be_nil
    ensure
      cache_db_close(store, path)
    end
  end
end

describe "Saci::Cache DB store selection" do
  before_each { Saci::Cache.reset! }
  after_each { Saci::Cache.reset! }

  it "supports store = :memory" do
    Saci::Cache.store = :memory
    Saci::Cache.write("k", "v")
    Saci::Cache.read("k").should eq("v")
  end

  it "supports store = :db on the primary connection and use_database!" do
    Dir.mkdir_p(CACHE_DB_TMP)
    path = File.join(CACHE_DB_TMP, "saci_cache_primary_#{Random::Secure.hex(8)}.db")
    previous = Saci::Record.configuration_names.includes?("primary") ? Saci::Record.database("primary") : nil
    db = Saci::Record.connect("sqlite3://#{path}")
    begin
      Saci::Cache.store = :db
      Saci::Cache.write("primary", "yes")
      Saci::Cache.read("primary").should eq("yes")
      Saci::Cache.store.should be_a(Saci::Cache::DbStore)

      # `use_database!` swaps the global store and returns it.
      cache = Saci::Cache.use_database!(db, namespace: "env", max_entries: 10)
      Saci::Cache.store.should be(cache)
      Saci::Cache.write("scoped", "v")
      cache.read("scoped").should eq("v")
      Saci::Cache.cache_store.should be(cache)
    ensure
      Saci::Cache.reset!
      db.close
      ["", "-wal", "-shm"].each { |suffix| File.delete?("#{path}#{suffix}") }
      Saci::Record.assign_primary(previous) if previous
    end
  end

  it "keeps MemoryStore the default" do
    Saci::Cache.store.should be_a(Saci::Cache::MemoryStore)
  end

  it "supports use_database! with a dedicated URL" do
    Dir.mkdir_p(CACHE_DB_TMP)
    path = File.join(CACHE_DB_TMP, "saci_cache_url_#{Random::Secure.hex(8)}.db")
    cache = Saci::Cache.use_database!(url: "sqlite3://#{path}", max_entries: 5)
    begin
      Saci::Cache.write("url", "yes")
      Saci::Cache.read("url").should eq("yes")
      cache.count.should eq(1_i64)
    ensure
      Saci::Cache.reset!
      cache.close
      ["", "-wal", "-shm"].each { |suffix| File.delete?("#{path}#{suffix}") }
    end
  end

  it "supports named databases (connection isolation)" do
    Dir.mkdir_p(CACHE_DB_TMP)
    path = File.join(CACHE_DB_TMP, "saci_cache_named_#{Random::Secure.hex(8)}.db")
    name = "cache_spec_#{Random::Secure.hex(4)}"
    db = Saci::Record.establish_connection(name, "sqlite3://#{path}")
    begin
      cache = Saci::Cache.use_database!(database: name, namespace: "named")
      Saci::Cache.write("k", "named-value")
      cache.read("k").should eq("named-value")
      cache.namespace.should eq("named")
    ensure
      Saci::Cache.reset!
      Saci::Record.remove_connection(name)
      ["", "-wal", "-shm"].each { |suffix| File.delete?("#{path}#{suffix}") }
    end
  end

  it "exposes module-level multi-key helpers on any store" do
    Saci::Cache.write_multi({"a" => "1", "b" => 2})
    found = Saci::Cache.read_multi(["a", "b", "missing"])
    found["a"].should eq("1")
    found["b"].should eq(2_i64)
    found.has_key?("missing").should be_false

    fetched = Saci::Cache.fetch_multi(["a", "c"]) { |key| "computed-#{key}" }
    fetched["a"].should eq("1")
    fetched["c"].should eq("computed-c")
    Saci::Cache.read("c").should eq("computed-c")

    Saci::Cache.delete_multi(["a", "b", "missing"]).should eq(2_i64)
    Saci::Cache.exist?("a").should be_false
  end
end
