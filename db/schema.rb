Sequel.migration do
  change do
    create_table(:accounts) do
      primary_key :id, :type=>:Bignum
      column :email, "citext", :null=>false
      column :status, "integer", :default=>1, :null=>false
      column :password_hash, "text"
      column :superuser, "boolean", :default=>false, :null=>false
      column :created_at, "timestamp without time zone", :default=>Sequel::CURRENT_TIMESTAMP
    end
    
    create_table(:comics) do
      primary_key :id
      column :name, "text"
      column :artist_name, "text"
      column :description, "text"
      column :release_date, "date"
      column :poster_url, "text"
      column :created_at, "timestamp without time zone"
      column :updated_at, "timestamp without time zone"
      column :deleted_at, "timestamp without time zone"
    end
    
    create_table(:page_views) do
      primary_key :id
      column :path, "text", :null=>false
      column :ip, "text"
      column :user_agent, "text"
      column :bot, "boolean", :default=>false, :null=>false
      column :account_id, "integer"
      column :created_at, "timestamp without time zone", :null=>false
      
      index [:bot]
      index [:created_at]
    end
    
    create_table(:products) do
      primary_key :id
      column :name, "text", :null=>false
      column :slug, "text", :null=>false
      column :description, "text"
      column :image, "text"
      column :price_cents, "integer", :null=>false
      column :active, "boolean", :default=>true, :null=>false
      column :created_at, "timestamp without time zone", :null=>false
      column :updated_at, "timestamp without time zone", :null=>false
      
      index [:slug], :name=>:products_slug_key, :unique=>true
    end
    
    create_table(:schema_migrations) do
      column :filename, "text", :null=>false
      
      primary_key [:filename]
    end
    
    create_table(:store_settings) do
      primary_key :id
      column :shipping_cents, "integer", :default=>800, :null=>false
      column :pickup_instructions, "text", :default=>"Pickup in McComb, MS. We'll reach out when it's ready.", :null=>false
      column :tax_enabled, "boolean", :default=>false, :null=>false
      column :tax_rate_bps, "integer"
      column :stripe_tax_rate_id, "text"
      column :stripe_tax_rate_bps, "integer"
      column :updated_at, "timestamp without time zone"
    end
    
    create_table(:account_login_change_keys) do
      foreign_key :id, :accounts, :type=>"bigint", :null=>false, :key=>[:id]
      column :key, "text", :null=>false
      column :login, "text", :null=>false
      column :deadline, "timestamp without time zone", :null=>false
      
      primary_key [:id]
    end
    
    create_table(:account_password_reset_keys) do
      foreign_key :id, :accounts, :type=>"bigint", :null=>false, :key=>[:id]
      column :key, "text", :null=>false
      column :deadline, "timestamp without time zone", :null=>false
      column :email_last_sent, "timestamp without time zone", :default=>Sequel::CURRENT_TIMESTAMP, :null=>false
      
      primary_key [:id]
    end
    
    create_table(:account_remember_keys) do
      foreign_key :id, :accounts, :type=>"bigint", :null=>false, :key=>[:id]
      column :key, "text", :null=>false
      column :deadline, "timestamp without time zone", :null=>false
      
      primary_key [:id]
    end
    
    create_table(:account_verification_keys) do
      foreign_key :id, :accounts, :type=>"bigint", :null=>false, :key=>[:id]
      column :key, "text", :null=>false
      column :requested_at, "timestamp without time zone", :default=>Sequel::CURRENT_TIMESTAMP, :null=>false
      column :email_last_sent, "timestamp without time zone", :default=>Sequel::CURRENT_TIMESTAMP, :null=>false
      
      primary_key [:id]
    end
    
    create_table(:comic_issues) do
      primary_key :id
      foreign_key :comic_id, :comics, :key=>[:id]
      column :name, "text"
      column :description, "text"
      column :issue_number, "text"
      column :issue_date, "date"
      column :cover_url, "text"
      column :image_url, "text"
      column :grid_rows_x, "integer"
      column :grid_rows_y, "integer"
      column :created_at, "timestamp without time zone"
      column :updated_at, "timestamp without time zone"
      column :deleted_at, "timestamp without time zone"
    end
    
    create_table(:orders) do
      primary_key :id
      column :number, "text", :null=>false
      column :token, "text", :null=>false
      foreign_key :account_id, :accounts, :type=>"bigint", :key=>[:id], :on_delete=>:set_null
      column :email, "text"
      column :status, "text", :default=>"pending", :null=>false
      column :fulfillment, "text", :null=>false
      column :subtotal_cents, "integer", :null=>false
      column :shipping_cents, "integer", :default=>0, :null=>false
      column :tax_cents, "integer", :default=>0, :null=>false
      column :total_cents, "integer", :null=>false
      column :tax_rate_bps, "integer"
      column :refunded_cents, "integer", :default=>0, :null=>false
      column :ship_name, "text"
      column :ship_address, "text"
      column :tracking_number, "text"
      column :oversold, "boolean", :default=>false, :null=>false
      column :stripe_session_id, "text"
      column :stripe_payment_intent_id, "text"
      column :paid_at, "timestamp without time zone"
      column :created_at, "timestamp without time zone", :null=>false
      column :updated_at, "timestamp without time zone", :null=>false
      
      index [:account_id]
      index [:number], :name=>:orders_number_key, :unique=>true
      index [:status]
      index [:stripe_payment_intent_id]
      index [:stripe_session_id], :name=>:orders_stripe_session_id_key, :unique=>true
      index [:token], :name=>:orders_token_key, :unique=>true
    end
    
    create_table(:product_options) do
      primary_key :id
      foreign_key :product_id, :products, :null=>false, :key=>[:id], :on_delete=>:cascade
      column :name, "text", :null=>false
      column :position, "integer", :null=>false
      
      index [:product_id, :name], :unique=>true
    end
    
    create_table(:product_variants) do
      primary_key :id
      foreign_key :product_id, :products, :null=>false, :key=>[:id], :on_delete=>:cascade
      column :options_key, "text", :null=>false
      column :price_override_cents, "integer"
      column :stock, "integer", :default=>0, :null=>false
      column :sku, "text"
      column :position, "integer", :null=>false
      
      index [:product_id, :options_key], :unique=>true
      index [:sku], :name=>:product_variants_sku_key, :unique=>true
    end
    
    create_table(:option_values) do
      primary_key :id
      foreign_key :product_option_id, :product_options, :null=>false, :key=>[:id], :on_delete=>:cascade
      column :name, "text", :null=>false
      column :position, "integer", :null=>false
      column :swatch_hex, "text"
      column :swatch_image, "text"
      column :image, "text"
      
      index [:product_option_id, :name], :unique=>true
    end
    
    create_table(:order_items) do
      primary_key :id
      foreign_key :order_id, :orders, :null=>false, :key=>[:id], :on_delete=>:cascade
      foreign_key :variant_id, :product_variants, :key=>[:id], :on_delete=>:set_null
      column :product_name, "text", :null=>false
      column :variant_label, "text", :null=>false
      column :sku, "text"
      column :unit_price_cents, "integer", :null=>false
      column :quantity, "integer", :null=>false
      
      index [:order_id]
    end
    
    create_table(:variant_option_values) do
      foreign_key :product_variant_id, :product_variants, :null=>false, :key=>[:id], :on_delete=>:cascade
      foreign_key :option_value_id, :option_values, :null=>false, :key=>[:id], :on_delete=>:cascade
      
      primary_key [:product_variant_id, :option_value_id]
      
      index [:option_value_id]
    end
  end
end
              Sequel.migration do
                change do
                  self << "SET search_path TO \"$user\", public"
                  self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20250513161713_create_rodauth.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20250513172418_create_comics_and_issues.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20260921120000_add_superuser_to_accounts.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20260921130000_create_page_views.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20260921140000_create_products.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20261013120000_rebuild_products_with_options.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20261013170000_add_created_at_to_accounts.rb')"
self << "INSERT INTO \"schema_migrations\" (\"filename\") VALUES ('20261013200000_create_orders_and_store_settings.rb')"
                end
              end
