Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "home#index"

  get "contact"   => "home#contact",    as: :contact
  get "shop"       => "shop#index", as: :shop
  get "shop/:slug" => "shop#show",  as: :shop_product
  resource :cart, only: :show
  post   "cart/items"             => "cart_items#create",  as: :cart_items
  patch  "cart/items/:variant_id" => "cart_items#update",  as: :cart_item
  delete "cart/items/:variant_id" => "cart_items#destroy"
  post   "checkout"               => "checkouts#create",   as: :checkout
  get    "orders/:token"          => "orders#show",        as: :order
  post "stripe/webhooks" => "stripe_webhooks#create", as: :stripe_webhooks
  get "dashboard"          => "dashboard#index",    as: :dashboard
  get "dashboard/account"  => "dashboard#account",  as: :dashboard_account
  get "dashboard/orders"   => "dashboard#orders",   as: :dashboard_orders

  namespace :admin do
    root "overview#index"
    get "accounts" => "accounts#index", as: :accounts
    resources :orders, only: [ :index, :show, :update ], param: :number
    get "traffic"  => "traffic#index",  as: :traffic
    resources :products, except: [ :show ]
    resource :settings, only: [ :show, :update ]
  end
end
