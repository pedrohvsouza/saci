require "./saci"
require "./saci/cli/util"
require "./saci/cli/new_command"
require "./saci/cli/generate_command"
require "./saci/cli/serve_command"
require "./saci/cli/test_command"
require "./saci/cli/secret_command"
require "./saci/cli/credentials_command"
require "./saci/cli/watch"
require "./saci/cli"

exit Saci::CLI.run(ARGV)
