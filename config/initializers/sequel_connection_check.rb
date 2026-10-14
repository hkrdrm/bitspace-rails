# The remote Postgres closes connections that sit idle for a few minutes, and
# Sequel would hand the closed one to the next request, which then failed with
# Sequel::DatabaseDisconnectError. connection_validator runs a cheap query on
# any connection idle longer than IDLE_SECONDS before handing it out, and
# swaps in a new connection when that fails.
module SequelConnectionCheck
  IDLE_SECONDS = 30
end

Sequel::Model.db.extension(:connection_validator)
Sequel::Model.db.pool.connection_validation_timeout = SequelConnectionCheck::IDLE_SECONDS
