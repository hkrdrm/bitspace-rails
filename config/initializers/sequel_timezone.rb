# Store and read every timestamp as UTC, matching Rails (Time.zone is UTC)
# and Postgres (the server runs in GMT). Unset, Sequel used the Ruby
# process's local zone: its timestamps plugin wrote local wall time while
# Time.current and database defaults wrote UTC, and every value read back
# as local, five hours off on a Central-time machine. Viewers see times in
# their own zone through the local_time helper.
Sequel.default_timezone = :utc
