class Account < Sequel::Model
  include Rodauth::Rails.model
  plugin :enum
  plugin :boolean_readers
  enum :status, unverified: 1, verified: 2, closed: 3
end
