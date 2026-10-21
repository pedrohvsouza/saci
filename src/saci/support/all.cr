# Aggregated require for the support layer that depends on the full framework
# (ORM, jobs, mailers). The coordinator/application should require this at the
# very end of `src/saci.cr`:
#
#   require "./saci/support/all"
#
# Time zone/date/duration, core extensions, logging, and notifications are
# loaded earlier from `i18n.cr`/`logging.cr`.
require "./inflections"
require "./current_attributes"
require "./record_extensions"
require "./instrumentation"
