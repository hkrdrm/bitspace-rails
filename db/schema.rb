Sequel.migration do
  change do
    create_table(:accounts) do
      primary_key :id, :type=>:Bignum
      column :email, "citext", :null=>false
      column :status, "integer", :default=>1, :null=>false
      column :password_hash, "text"
      column :superuser, "boolean", :default=>false, :null=>false
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
      column :base_price_cents, "integer", :null=>false
      column :active, "boolean", :default=>true, :null=>false
      column :created_at, "timestamp without time zone", :null=>false
      column :updated_at, "timestamp without time zone", :null=>false
      
      index [:slug], :name=>:products_slug_key, :unique=>true
    end
    
    create_table(:schema_migrations) do
      column :filename, "text", :null=>false
      
      primary_key [:filename]
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
    
    create_table(:product_variants) do
      primary_key :id
      foreign_key :product_id, :products, :null=>false, :key=>[:id], :on_delete=>:cascade
      column :size, "text", :null=>false
      column :color, "text", :null=>false
      column :price_cents, "integer", :null=>false
      column :stock, "integer", :default=>0, :null=>false
      column :position, "integer", :null=>false
      
      index [:product_id, :size, :color], :unique=>true
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
                end
              end
