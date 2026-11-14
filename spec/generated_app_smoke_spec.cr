require "spec"
require "file_utils"
require "../src/saci"
require "../src/saci/cli/util"
require "../src/saci/cli/new_command"
require "../src/saci/cli/generate_command"

# End-to-end check that what `saci new` and every `saci generate` kind
# write compiles, passes its own specs and is formatter-clean. Other CLI
# specs only look for strings in the output; this one builds the app.
# It compiles a whole app (a few minutes), so it only runs with
# `SACI_SMOKE=1 crystal spec spec/generated_app_smoke_spec.cr` (CI job
# `smoke`).
SMOKE_GENERATORS = [
  ["model", "Account", "name:string", "bio:text", "age:integer", "score:float",
   "active:boolean", "born_at:datetime", "views:bigint"],
  ["controller", "Admin", "index", "show"],
  ["migration", "AddNicknameToAccounts", "nickname:string"],
  ["migration", "AddIndexToAccounts", "name", "--unique"],
  ["job", "Archive"],
  ["mailer", "Account"],
  ["channel", "Chat"],
  ["scaffold", "Product", "title:string", "price:integer"],
  ["model", "Order", "total:integer", "paid:boolean"],
  ["admin", "Order", "total:integer", "paid:boolean"],
  ["task", "reports:daily"],
  ["helper", "Format"],
  ["test", "Account"],
  ["integration_test", "Checkout"],
  ["resource", "Comment", "body:text"],
  ["model", "Invoice", "number:string"],
  ["scaffold_controller", "Invoice", "number:string"],
  ["benchmark", "Search"],
]

# `authentication` makes every controller require a login, so the specs
# other generators write would get 302s. It gets an app of its own.
SMOKE_AUTH_GENERATORS = [["authentication"]]

private def smoke_run(dir : String, cmd : String, args : Array(String)) : Nil
  output = IO::Memory.new
  status = Process.run(cmd, args, chdir: dir, input: Process::Redirect::Close, output: output, error: output)
  fail "`#{cmd} #{args.join(" ")}` failed in the generated app:\n#{output}" unless status.success?
end

# Generates an app, runs `generators` in it, then checks formatting,
# both entrypoints and the app's own specs.
private def smoke_app(name : String, generators : Array(Array(String))) : Nil
  root = File.expand_path("..", __DIR__)
  dir = File.join(Dir.tempdir, "saci-smoke-#{name}-#{Process.pid}-#{Random.rand(1_000_000)}")
  begin
    Saci::CLI::New.create(name, dir: dir, saci_path: root, skip_shards: true, skip_git: true)
    # Stand-in for `shards install`: the framework checkout and its shards.
    Dir.mkdir_p(File.join(dir, "lib"))
    File.symlink(root, File.join(dir, "lib", "saci"))
    %w(db sqlite3).each { |shard| File.symlink(File.join(root, "lib", shard), File.join(dir, "lib", shard)) }

    Dir.cd(dir) do
      generators.each do |args|
        Saci::CLI::Generate.run(args + ["--force"]).should eq(0)
      end
    end

    crystal = Saci::CLI::Util.crystal_bin!
    smoke_run(dir, crystal, ["tool", "format", "--check", "src", "spec", "db", "config"])
    smoke_run(dir, crystal, ["build", "--no-codegen", "src/#{name}.cr"])
    smoke_run(dir, crystal, ["build", "--no-codegen", "db/migrate.cr"])
    smoke_run(dir, crystal, ["spec", "--no-color"])
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "generated app smoke test" do
  {% if env("SACI_SMOKE") == "1" %}
    it "builds and passes its specs after every generator" do
      smoke_app("smoke_app", SMOKE_GENERATORS)
    end

    it "builds and passes its specs after the authentication generator" do
      smoke_app("smoke_auth", SMOKE_AUTH_GENERATORS)
    end
  {% else %}
    pending "builds and passes its specs after every generator (set SACI_SMOKE=1 at compile time)"
  {% end %}
end
