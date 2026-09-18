Sequel.migration do
  change do
    begin
      run "CREATE EXTENSION IF NOT EXISTS citext"
    rescue NoMethodError # migration is being reverted
    end

    create_table :accounts do
      primary_key :id, type: :Bignum
      citext :email, null: false
      constraint :valid_email, email: /^[^,;@ \r\n]+@[^,@; \r\n]+\.[^,@; \r\n]+$/
      Integer :status, null: false, default: 1
      index :email, unique: true, where: { status: [ 1, 2 ] }
      String :password_hash
    end

    # Used by the password reset feature
    create_table :account_password_reset_keys do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :deadline, null: false
      DateTime :email_last_sent, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    # Used by the account verification feature
    create_table :account_verification_keys do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :requested_at, null: false, default: Sequel::CURRENT_TIMESTAMP
      DateTime :email_last_sent, null: false, default: Sequel::CURRENT_TIMESTAMP
    end

    # Used by the verify login change feature
    create_table :account_login_change_keys do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      String :login, null: false
      DateTime :deadline, null: false
    end

    # Used by the remember me feature
    create_table :account_remember_keys do
      foreign_key :id, :accounts, primary_key: true, type: :Bignum
      String :key, null: false
      DateTime :deadline, null: false
    end
  end
end
