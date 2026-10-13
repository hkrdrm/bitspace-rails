# frozen_string_literal: true

# Accounts had no creation time. Existing rows stay NULL rather than being
# stamped with the migration time, which would be a made-up date; the
# default applies to every account created from now on, including the ones
# Rodauth inserts without naming the column.
Sequel.migration do
  up do
    alter_table(:accounts) do
      add_column :created_at, DateTime
      set_column_default :created_at, Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    alter_table(:accounts) { drop_column :created_at }
  end
end
