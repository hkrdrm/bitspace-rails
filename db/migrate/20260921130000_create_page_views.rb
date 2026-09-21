# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :page_views do
      primary_key :id
      String      :path,       null: false
      String      :ip
      String      :user_agent, text: true
      TrueClass   :bot,        null: false, default: false
      Integer     :account_id
      DateTime    :created_at, null: false

      index :created_at
      index :bot
    end
  end
end
