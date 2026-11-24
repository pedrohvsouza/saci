require "file_utils"
require "../../src/saci/cli/new_command"

# Symlink the framework's lib into a fixture app (the current directory)
# so bare `db`/`sqlite3` requires resolve without `shards install`
# (fixtures skip shards). Each shard is linked on its own, so `lib/tasks/`
# written by a spec stays in the fixture instead of landing in the
# framework's lib.
def link_framework_lib! : Nil
  framework_lib = File.join(Saci::CLI::New::SACI_ROOT, "lib")
  Dir.mkdir_p("lib")
  Dir.each_child(framework_lib) do |entry|
    next if entry == "tasks"
    target = File.join("lib", entry)
    File.symlink(File.join(framework_lib, entry), target) unless File.exists?(target) || File.symlink?(target)
  end
end
