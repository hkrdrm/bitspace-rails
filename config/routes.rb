Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "home#index"

  get "contact"   => "home#contact",    as: :contact
  get "shop"       => "shop#index", as: :shop
  get "shop/:slug" => "shop#show",  as: :shop_product
  get "dashboard"          => "dashboard#index",    as: :dashboard
  get "dashboard/account"  => "dashboard#account",  as: :dashboard_account
  get "dashboard/orders"   => "dashboard#orders",   as: :dashboard_orders
  get "dashboard/checkout" => "dashboard#checkout", as: :dashboard_checkout

  namespace :admin do
    root "overview#index"
    get "accounts" => "accounts#index", as: :accounts
    get "orders"   => "orders#index",   as: :orders
    get "traffic"  => "traffic#index",  as: :traffic
    resources :products, except: [ :show ]
  end
end
