# frozen_string_literal: true

# Orders, their item snapshots, and the one-row store settings (shipping rate,
# pickup text, sales tax). Items copy what was bought so products stay
# deletable: variant_id goes NULL and the snapshot remains.
Sequel.migration do
  change do
    create_table :store_settings do
      primary_key :id
      Integer   :shipping_cents, null: false, default: 800
      String    :pickup_instructions, text: true, null: false, default: "Pickup in McComb, MS. We'll reach out when it's ready."
      TrueClass :tax_enabled, null: false, default: false
      Integer   :tax_rate_bps
      String    :stripe_tax_rate_id
      Integer   :stripe_tax_rate_bps
      DateTime  :updated_at
    end

    create_table :orders do
      primary_key :id
      String    :number, null: false, unique: true
      String    :token, null: false, unique: true
      foreign_key :account_id, :accounts, type: :Bignum, on_delete: :set_null
      String    :email
      String    :status, null: false, default: "pending"
      String    :fulfillment, null: false
      Integer   :subtotal_cents, null: false
      Integer   :shipping_cents, null: false, default: 0
      Integer   :tax_cents, null: false, default: 0
      Integer   :total_cents, null: false
      Integer   :tax_rate_bps
      Integer   :refunded_cents, null: false, default: 0
      String    :ship_name
      String    :ship_address, text: true
      String    :tracking_number
      TrueClass :oversold, null: false, default: false
      String    :stripe_session_id, unique: true
      String    :stripe_payment_intent_id
      DateTime  :paid_at
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false

      index :account_id
      index :status
      index :stripe_payment_intent_id
    end

    create_table :order_items do
      primary_key :id
      foreign_key :order_id, :orders, null: false, on_delete: :cascade
      foreign_key :variant_id, :product_variants, on_delete: :set_null
      String  :product_name, null: false
      String  :variant_label, null: false
      String  :sku
      Integer :unit_price_cents, null: false
      Integer :quantity, null: false

      constraint(:order_items_positive_quantity) { quantity > 0 }
      index :order_id
    end
  end
end
