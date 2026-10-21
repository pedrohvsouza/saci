# Saci's testing shelf: fixtures, factories, transactional tests, time
# travel, assertion helpers (mailer/job/cable/change/query), `assert_select`
# and the test database lifecycle.
#
# Require the framework first:
#
# ```
# require "saci"
# require "saci/testing"
# ```
#
# or add `require "./saci/testing"` at the end of `src/saci.cr` (the
# coordinator owns that file). Everything in this shelf is spec-only and
# pulls in the `spec` stdlib for assertion failures.
require "spec"

require "./testing/queries"
require "./testing/record_hooks"
require "./testing/time_helpers"
require "./testing/fixtures"
require "./testing/factory"
require "./testing/transactional"
require "./testing/probes"
require "./testing/assert_select"
require "./testing/assertions"
require "./testing/database"
require "./testing/parallel"

module Saci
  module Testing
  end
end

# Top-level DSL: macros (`load_fixtures`, `fixture`, `factory`,
# `transactional_tests`) and assertion/time methods become available inside
# `describe`/`it` blocks without a receiver.
include Saci::Testing::FixtureDSL
include Saci::Testing::Factory::DSL
include Saci::Testing::TimeDSL
include Saci::Testing::Assertions
include Saci::Testing::AssertSelectDSL
include Saci::Testing::TransactionalDSL

# Safety net: a non-block `travel_to`/`travel`/`freeze_time` must not leak
# into the next example. Block forms already restore in `ensure`; this
# cleanup is for the explicit non-block API.
Spec.after_each do
  Saci::Testing.travel_back
  Saci::Testing::Queries.reset!
end
