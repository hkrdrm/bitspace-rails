Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "home#index"

  get "contact"   => "home#contact",    as: :contact
  get "dashboard" => "dashboard#index", as: :dashboard

  namespace :admin do
    root "overview#index"
    get "accounts" => "accounts#index", as: :accounts
    get "orders"   => "orders#index",   as: :orders
    get "traffic"  => "traffic#index",  as: :traffic
  end
end
