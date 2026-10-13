# frozen_string_literal: true

# Replaces the fixed size-by-colour variant grid with per-product options.
# There was no real product data when this was written (confirmed 2026-10-13),
# so the product tables are dropped and rebuilt rather than converted.
# Development gets its sample products back from bin/rails db:seed.
Sequel.migration do
  up do
    drop_table :product_variants
    drop_table :products

    create_table :products do
      primary_key :id
      String    :name, null: false
      String    :slug, null: false, unique: true
      String    :description, text: true
      String    :image
      Integer   :price_cents, null: false
      TrueClass :active, null: false, default: true
      DateTime  :created_at, null: false
      DateTime  :updated_at, null: false
    end

    create_table :product_options do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String  :name, null: false
      Integer :position, null: false

      index [ :product_id, :name ], unique: true
    end

    create_table :option_values do
      primary_key :id
      foreign_key :product_option_id, :product_options, null: false, on_delete: :cascade
      String  :name, null: false
      Integer :position, null: false
      String  :swatch_hex
      String  :swatch_image
      String  :image

      index [ :product_option_id, :name ], unique: true
    end

    create_table :product_variants do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String  :options_key, null: false
      Integer :price_override_cents
      Integer :stock, null: false, default: 0
      String  :sku, unique: true
      Integer :position, null: false

      index [ :product_id, :options_key ], unique: true
    end

    create_table :variant_option_values do
      foreign_key :product_variant_id, :product_variants, null: false, on_delete: :cascade
      foreign_key :option_value_id, :option_values, null: false, on_delete: :cascade
      primary_key [ :product_variant_id, :option_value_id ]

      index :option_value_id
    end
  end

  down do
    raise Sequel::Error, "irreversible: the size-by-colour shape cannot hold arbitrary options"
  end
end
