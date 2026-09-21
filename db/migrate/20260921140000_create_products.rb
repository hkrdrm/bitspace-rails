# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :products do
      primary_key :id
      String    :name, null: false
      String    :slug, null: false, unique: true
      String    :description, text: true
      String    :image
      Integer   :base_price_cents, null: false
      TrueClass :active, null: false, default: true
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false
    end

    create_table :product_variants do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String  :size, null: false
      String  :color, null: false
      Integer :price_cents, null: false
      Integer :stock, null: false, default: 0
      Integer :position, null: false

      index [ :product_id, :size, :color ], unique: true
    end
  end
end
