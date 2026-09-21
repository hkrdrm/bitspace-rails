# Superuser Flag, Admin Area, and User Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `superuser` flag to accounts, a superuser-only `/admin` area, and a login-gated `/dashboard` with account, orders, and checkout pages — views only, except a real page-view traffic collector.

**Architecture:** Rails 8 + Sequel (not ActiveRecord). Authentication is rodauth via `rodauth-rails`. `Admin::BaseController` carries a single `before_action :require_superuser` that raises `ActionController::RoutingError` (404, so `/admin` is not discoverable); every admin controller inherits it. `DashboardController` uses `before_action :authenticate`. All pages are built from a small set of shared partials in `app/views/shared/` so admin, dashboard, and the existing auth pages share one visual vocabulary.

**Tech Stack:** Rails 8.0, Ruby 3.3.1, Sequel + `sequel-rails`, PostgreSQL, rodauth-rails 2.1, Tailwind CSS v4 (`tailwindcss-rails`), Stimulus via importmap, Minitest.

**Spec:** `docs/superpowers/specs/2026-09-21-superuser-admin-and-user-dashboard-design.md`

## Global Constraints

- **This app uses Sequel, not ActiveRecord.** Models subclass `Sequel::Model`. Migrations are `Sequel.migration do change do ... end end`. Query with `Account.where(...)`, `dataset.delete`, `select_map`. There is no `ApplicationRecord`.
- **Tests are not transactional.** `use_transactional_tests` is an ActiveRecord feature and does nothing here. Every test must clean up rows it creates. The YAML fixtures in `test/fixtures/` are dead ActiveRecord leftovers — do not enable them.
- **The AR fixture lifecycle is neutralized in `test/test_helper.rb` (done in Task 1).** `ActiveRecord::Base` is a defined constant here (solid_cache, solid_queue, solid_cable, ActionText, ActiveStorage and ActionMailbox all require it) even though `active_record/railtie` is not loaded and AR has no connection. That is enough for `rails/test_help` to mix `ActiveRecord::TestFixtures` into every test case, whose `setup_fixtures` hook then raises `ActiveRecord::ConnectionNotDefined` in `before_setup`. Commenting out `fixtures :all` does **not** prevent this. Do not remove the `setup_fixtures`/`teardown_fixtures` overrides.
- **Style tokens** (defined in `app/assets/tailwind/application.css`, use these exact names): `font-display` (Anton), `text-ink` / `bg-ink` (`#0d1114`), `brand-green` (`#5c7a1e`), `brand-green-dark` (`#4a621a`), `brand-orange` (`#dd440c`).
- **Page chrome convention:** every page wraps content in `<div class="bg-white text-ink">` because `body` is `bg-gray-900 text-white` in the layout.
- **Do not run `bin/rails tailwindcss:build`.** The `bin/dev` watcher handles CSS rebuilds. New utility classes appear after the next `bin/dev` run.
- **Test command:** `bin/rails test test/` for all, `bin/rails test path/to/file.rb -n test_name` for one. Use `bin/rails test test/` and **not** bare `bin/rails test`: the bare form triggers sequel-rails' test-database maintenance, which tries to drop and recreate the database through `template1`. The test database lives on the DigitalOcean managed cluster, which rejects that (`pg_hba.conf`), so the bare command aborts before running anything. CI runs `bin/rails db:migrate test test:system`.
- **Migrations:** after writing one, run `bin/rails db:migrate` and `RAILS_ENV=test bin/rails db:migrate`. `db/schema.rb` is generated — commit the regenerated file, never hand-edit it.
- **Lint:** `bin/rubocop` (rubocop-rails-omakase) runs in CI. Run it before each commit.
- **Views only.** Orders, carts, products, addresses, and payment methods have no models and no persistence. Every figure, row, and badge on those pages is hardcoded placeholder markup. The single exception is Task 6's traffic collector.

---

### Task 1: Remove the comics/issues fork

Dead code from a previous direction. Removing it first keeps later tasks from having to reason about it.

**Files:**
- Delete: `app/controllers/comics_controller.rb`, `app/controllers/issues_controller.rb`
- Delete: `app/models/comic.rb`, `app/models/issue.rb`
- Delete: `app/views/comics/` (whole directory), `app/views/issues/` (whole directory)
- Delete: `app/views/dashboard/new_issue.html.erb`
- Delete: `app/javascript/controllers/issue_controller.js`, `app/javascript/controllers/dashboard_controller.js`
- Modify: `config/routes.rb`, `app/controllers/dashboard_controller.rb`
- Test: `test/integration/removed_routes_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: a `DashboardController` with only `#index`, and a routes file with only `root`, `up`, `contact`, and `dashboard`.

Note: `app/javascript/controllers/index.js` uses `eagerLoadControllersFrom`, which discovers controllers automatically. There is no registration list to edit — deleting the files is sufficient.

The `comics` and `comic_issues` tables and their migration (`db/migrate/20250513172418_create_comics_and_issues.rb`) **stay**. Do not write a drop migration and do not edit that file.

- [x] **Step 1: Write the failing test**

Create `test/integration/removed_routes_test.rb`:

```ruby
require "test_helper"

class RemovedRoutesTest < ActionDispatch::IntegrationTest
  test "comics route is gone" do
    get "/comics"
    assert_response :not_found
  end

  test "issues routes are gone" do
    get "/issues"
    assert_response :not_found

    get "/issues/1"
    assert_response :not_found
  end

  # RodauthApp gates every path starting with "/dashboard" in middleware, ahead of
  # Rails routing, so an unauthenticated request to a removed dashboard path
  # redirects to /login and can never surface as a 404. Assert against the router
  # itself, which is what "the route is gone" actually means.
  test "new_issue route is gone" do
    assert_routing_error "/dashboard/new_issue"
    assert_routing_error "/dashboard/create_issue", method: :post

    assert_equal({ controller: "dashboard", action: "index" },
      Rails.application.routes.recognize_path("/dashboard", method: :get))
  end

  test "home page still renders" do
    get "/"
    assert_response :success
  end

  test "contact page still renders" do
    get "/contact"
    assert_response :success
  end

  private
    def assert_routing_error(path, method: :get)
      assert_raises(ActionController::RoutingError, "expected no route for #{method.to_s.upcase} #{path}") do
        Rails.application.routes.recognize_path(path, method: method)
      end
    end
end
```

- [x] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/removed_routes_test.rb`
Expected: the three "route is gone" tests FAIL (comics 200, issues 406, dashboard routing assertion) and the two "still renders" tests pass.

Note: this is also where the ActiveRecord fixture problem surfaces. Before the `test/test_helper.rb` fix described in Global Constraints, all five tests error with `ActiveRecord::ConnectionNotDefined` in `before_setup` instead. Fix the helper first, then re-run.

- [x] **Step 3: Delete the files**

```bash
cd /home/zerosum/workspace/bitspace-rails
git rm -r app/views/comics app/views/issues
git rm app/controllers/comics_controller.rb app/controllers/issues_controller.rb
git rm app/models/comic.rb app/models/issue.rb
git rm app/views/dashboard/new_issue.html.erb
git rm app/javascript/controllers/issue_controller.js
git rm app/javascript/controllers/dashboard_controller.js
```

- [x] **Step 4: Trim the routes file**

Replace `config/routes.rb` with:

```ruby
Rails.application.routes.draw do
  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "home#index"

  get "contact"   => "home#contact",    as: :contact
  get "dashboard" => "dashboard#index", as: :dashboard
end
```

- [x] **Step 5: Trim the dashboard controller**

Replace `app/controllers/dashboard_controller.rb` with:

```ruby
class DashboardController < ApplicationController
  def index
  end
end
```

- [x] **Step 6: Replace the placeholder dashboard view**

`app/views/dashboard/index.html.erb` currently wires a deleted Stimulus controller. Replace it with a minimal on-brand stub; Task 8 fills it in properly:

```erb
<div class="bg-white text-ink">
  <section class="max-w-7xl mx-auto px-6 py-16">
    <h1 class="font-display text-5xl tracking-tight">DASHBOARD</h1>
  </section>
</div>
```

- [x] **Step 7: Run the tests**

Run: `bin/rails test test/integration/removed_routes_test.rb`
Expected: 5 tests, 5 assertions groups passing, 0 failures.

- [x] **Step 8: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`
Expected: no failures, no offenses.

- [x] **Step 9: Commit**

```bash
git add -A
git commit -m "Remove unused comics and issues fork

The comics/issues direction is not part of this fork. Removes their
controllers, models, views, Stimulus controllers, and routes. The
comics and comic_issues tables are left in place; dropping them is a
separate, explicit decision."
```

---

### Task 2: Add the superuser flag and test helpers

**Files:**
- Create: `db/migrate/<timestamp>_add_superuser_to_accounts.rb`
- Modify: `app/models/account.rb`
- Modify: `test/test_helper.rb`
- Modify: `db/schema.rb` (regenerated by the migration — commit, don't edit)
- Test: `test/models/account_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `accounts.superuser` — boolean, `NOT NULL DEFAULT false`
  - `Account#superuser?` → `true`/`false` (from Sequel's `boolean_readers` plugin)
  - `create_account(email: nil, password: "password123", status: 2, superuser: false)` → `Account` — test helper on `ActiveSupport::TestCase`, generates a unique `@example.test` email when none is given
  - `sign_in(account, password: "password123")` — test helper on `ActionDispatch::IntegrationTest`, POSTs to `/login`

- [x] **Step 1: Write the failing test**

Create `test/models/account_test.rb`:

```ruby
require "test_helper"

class AccountTest < ActiveSupport::TestCase
  test "accounts are not superusers by default" do
    account = create_account
    assert_equal false, account.superuser?
  end

  test "an account can be made a superuser" do
    account = create_account(superuser: true)
    assert_equal true, account.superuser?
  end

  test "superuser can be toggled after creation" do
    account = create_account
    account.update(superuser: true)
    assert_equal true, account.reload.superuser?
  end
end
```

- [x] **Step 2: Add the test helpers**

Replace `test/test_helper.rb` with:

```ruby
ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Sequel gives us no transactional tests, and parallel workers share one
    # database here, so tests run serially and clean up after themselves.
    parallelize(workers: 1)

    # Every account created by a test uses an @example.test address so teardown
    # can find and remove it. Rodauth's after_login hook writes a remember key,
    # and those rows reference accounts, so they go first.
    ACCOUNT_KEY_TABLES = %i[
      account_remember_keys
      account_verification_keys
      account_password_reset_keys
      account_login_change_keys
    ].freeze

    teardown do
      ids = Account.where(Sequel.like(:email, "%@example.test")).select_map(:id)
      unless ids.empty?
        ACCOUNT_KEY_TABLES.each do |table|
          Account.db[table].where(id: ids).delete if Account.db.table_exists?(table)
        end
        Account.where(id: ids).delete
      end
    end

    def create_account(email: nil, password: "password123", status: 2, superuser: false)
      Account.create(
        email: email || "test-#{SecureRandom.hex(6)}@example.test",
        password_hash: RodauthApp.rodauth.allocate.password_hash(password),
        status: status,
        superuser: superuser
      )
    end
  end
end

class ActionDispatch::IntegrationTest
  def sign_in(account, password: "password123")
    post "/login", params: { email: account.email, password: password }
  end
end
```

**Correction applied during execution:** the replacement file shown above drops the `setup_fixtures`/`teardown_fixtures` overrides added in Task 1, which would make every test error again before its body runs. The committed file keeps them alongside the helpers below. Do not paste this block over the real file verbatim.

Two things to know about this file. `parallelize(workers: 1)` replaces the previous `workers: :number_of_processors`: Rails' parallel testing creates a database per worker for ActiveRecord only, so Sequel workers would all hammer the same database and collide. The `status: 2` default on `create_account` means verified — rodauth refuses to log in unverified accounts.

- [x] **Step 3: Run test to verify it fails**

Run: `bin/rails test test/models/account_test.rb`
Expected: FAIL with `Sequel::DatabaseError` or `NoMethodError: undefined method 'superuser?'` — the column does not exist yet.

- [x] **Step 4: Write the migration**

Create `db/migrate/20260921120000_add_superuser_to_accounts.rb`:

```ruby
# frozen_string_literal: true

Sequel.migration do
  change do
    alter_table :accounts do
      add_column :superuser, TrueClass, null: false, default: false
    end
  end
end
```

`TrueClass` is how Sequel's schema DSL spells a boolean column; it produces PostgreSQL `boolean`.

- [x] **Step 5: Run the migration in both environments**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
```

Expected: both succeed, and `db/schema.rb` now shows `column :superuser, "boolean", :default=>false, :null=>false` inside `create_table(:accounts)`.

- [x] **Step 6: Add the boolean_readers plugin**

Replace `app/models/account.rb` with:

```ruby
class Account < Sequel::Model
  include Rodauth::Rails.model
  plugin :enum
  plugin :boolean_readers
  enum :status, unverified: 1, verified: 2, closed: 3
end
```

Sequel does not create `?` readers for plain columns the way ActiveRecord does. The `unverified?` / `verified?` / `closed?` methods already on this model come from the `enum` plugin; `boolean_readers` is what supplies `superuser?`.

- [x] **Step 7: Run tests to verify they pass**

Run: `bin/rails test test/models/account_test.rb`
Expected: 3 runs, 3 assertions, 0 failures.

- [x] **Step 8: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [x] **Step 9: Commit**

```bash
git add -A
git commit -m "Add superuser flag to accounts

Boolean column, default false, with Sequel's boolean_readers plugin
for Account#superuser?. Adds test helpers for building and signing in
accounts, and switches the suite to a single worker since Sequel does
not get Rails' per-worker parallel test databases."
```

---

### Task 3: Shared view components

The vocabulary every admin and dashboard page is built from. Extracting `_page_header` out of the existing `_auth_page` means auth, admin, and dashboard share one header rather than three copies.

**Files:**
- Create: `app/views/shared/_page_header.html.erb`, `_panel.html.erb`, `_stat_tile.html.erb`, `_status_badge.html.erb`, `_data_table.html.erb`, `_empty_state.html.erb`, `_tab_nav.html.erb`
- Modify: `app/views/shared/_auth_page.html.erb`
- Test: `test/integration/auth_pages_render_test.rb`

**Interfaces:**
- Consumes: nothing.
- Produces these partials and their exact locals:
  - `shared/page_header` — `heading_top:`, `heading_bottom:`, `lede:` (optional)
  - `shared/panel` — rendered with `render layout:`; `title:` (optional), `subtitle:` (optional); yields body
  - `shared/stat_tile` — `label:`, `value:`, `delta:` (optional)
  - `shared/status_badge` — `label:`, `tone:` (`:green` / `:orange` / `:gray`, default `:gray`)
  - `shared/data_table` — rendered with `render layout:`; `headers:` (array of strings); yields `<tr>` rows
  - `shared/empty_state` — `message:`, `cta_label:` (optional), `cta_path:` (optional)
  - `shared/tab_nav` — `tabs:` (array of `[label, path]` pairs), `current:` (a path string)

- [ ] **Step 1: Write the failing test**

The auth pages are being refactored underneath, so this test is the regression guard. Create `test/integration/auth_pages_render_test.rb`:

```ruby
require "test_helper"

class AuthPagesRenderTest < ActionDispatch::IntegrationTest
  test "login page renders with its heading" do
    get "/login"
    assert_response :success
    assert_select "h1 span", text: "WELCOME"
    assert_select "h1 span", text: "BACK."
  end

  test "create account page renders with its heading" do
    get "/create-account"
    assert_response :success
    assert_select "h1 span", text: "JOIN"
    assert_select "h1 span", text: "BITSPACE."
  end

  test "reset password request page renders" do
    get "/reset-password-request"
    assert_response :success
    assert_select "h1 span", text: "RESET YOUR"
  end
end
```

- [ ] **Step 2: Run test to verify it passes**

Run: `bin/rails test test/integration/auth_pages_render_test.rb`
Expected: PASS — these pages already work. This is a characterization test; it must keep passing after the refactor in Step 4.

- [ ] **Step 3: Create the shared partials**

`app/views/shared/_page_header.html.erb`:

```erb
<%
  lede = local_assigns[:lede]
%>
<section class="max-w-4xl mx-auto px-6 pt-12 pb-10 md:pt-16 text-center">
  <h1 class="font-display text-5xl md:text-6xl leading-[0.95] tracking-tight">
    <span class="block text-black"><%= heading_top %></span>
    <span class="block text-brand-green"><%= heading_bottom %></span>
  </h1>
  <% if lede.present? %>
    <p class="mt-6 text-lg text-gray-700 max-w-md mx-auto"><%= lede %></p>
  <% end %>
</section>

<%= render "shared/section_divider" %>
```

`app/views/shared/_panel.html.erb`:

```erb
<%
  title    = local_assigns[:title]
  subtitle = local_assigns[:subtitle]
%>
<div class="border-2 border-brand-green rounded-xl p-6 md:p-8">
  <% if title.present? %>
    <div class="mb-6">
      <h2 class="font-display text-2xl tracking-wide uppercase text-black"><%= title %></h2>
      <% if subtitle.present? %>
        <p class="mt-1 text-sm text-gray-600"><%= subtitle %></p>
      <% end %>
    </div>
  <% end %>

  <%= yield %>
</div>
```

`app/views/shared/_stat_tile.html.erb`:

```erb
<div class="border-2 border-brand-green rounded-xl p-5">
  <div class="text-xs font-bold uppercase tracking-widest text-gray-500"><%= label %></div>
  <div class="mt-2 font-display text-4xl tracking-tight text-black"><%= value %></div>
  <% if local_assigns[:delta].present? %>
    <div class="mt-1 text-xs font-bold text-brand-green"><%= delta %></div>
  <% end %>
</div>
```

`app/views/shared/_status_badge.html.erb`:

```erb
<%
  tone = local_assigns.fetch(:tone, :gray)
  tone_classes = case tone
                 when :green  then "bg-brand-green text-white"
                 when :orange then "bg-brand-orange text-white"
                 else              "bg-gray-200 text-gray-700"
                 end
%>
<span class="inline-block px-2 py-1 rounded text-[10px] font-bold uppercase tracking-widest <%= tone_classes %>"><%= label %></span>
```

`app/views/shared/_data_table.html.erb`:

```erb
<div class="overflow-x-auto">
  <table class="w-full text-left text-sm">
    <thead>
      <tr class="border-b-2 border-brand-green">
        <% headers.each do |header| %>
          <th class="py-3 pr-6 text-xs font-bold uppercase tracking-widest text-gray-500 whitespace-nowrap"><%= header %></th>
        <% end %>
      </tr>
    </thead>
    <tbody class="divide-y divide-gray-200">
      <%= yield %>
    </tbody>
  </table>
</div>
```

`app/views/shared/_empty_state.html.erb`:

```erb
<div class="py-12 text-center">
  <span class="inline-block w-3 h-3 rounded-full bg-brand-orange"></span>
  <p class="mt-4 text-sm text-gray-600"><%= message %></p>
  <% if local_assigns[:cta_label].present? && local_assigns[:cta_path].present? %>
    <%= link_to cta_label, cta_path, class: "mt-6 inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded" %>
  <% end %>
</div>
```

`app/views/shared/_tab_nav.html.erb`:

```erb
<div class="border-b-2 border-brand-green/30">
  <nav class="max-w-7xl mx-auto px-6 flex flex-wrap gap-x-8">
    <% tabs.each do |tab_label, tab_path| %>
      <% active = (current == tab_path) %>
      <%= link_to tab_label, tab_path, class: "py-3 font-bold text-sm uppercase tracking-wide border-b-4 -mb-0.5 #{active ? "border-brand-green text-brand-green" : "border-transparent text-gray-600 hover:text-brand-green"}" %>
    <% end %>
  </nav>
</div>
```

- [ ] **Step 4: Refactor _auth_page to use the shared header**

Replace `app/views/shared/_auth_page.html.erb` with:

```erb
<%
  footer = local_assigns[:footer]
%>
<div class="bg-white text-ink">

  <%= render "shared/page_header",
        heading_top: heading_top,
        heading_bottom: heading_bottom,
        lede: local_assigns[:lede] %>

  <%# ---------- Form card ---------- %>
  <section class="max-w-4xl mx-auto px-6 py-12">
    <div class="max-w-md mx-auto border-2 border-brand-green rounded-xl p-6 md:p-8">
      <%= yield %>
    </div>

    <% if footer.present? %>
      <div class="max-w-md mx-auto mt-8 text-center">
        <%== footer %>
      </div>
    <% end %>
  </section>
</div>
```

- [ ] **Step 5: Run the regression test**

Run: `bin/rails test test/integration/auth_pages_render_test.rb`
Expected: 3 runs, 0 failures. The auth pages must be byte-for-byte equivalent in structure — same headings, same card, same footer links.

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add shared view components for admin and dashboard

Extracts the Anton page header out of _auth_page into a shared
_page_header so auth, admin and dashboard share one header, and adds
panel, stat tile, status badge, data table, empty state and tab nav
partials. Adds a characterization test covering the auth pages so the
extraction is provably non-breaking."
```

---

### Task 4: Admin namespace, superuser gate, and overview page

**Files:**
- Create: `app/controllers/admin/base_controller.rb`, `app/controllers/admin/overview_controller.rb`
- Create: `app/views/admin/overview/index.html.erb`
- Create: `app/views/admin/_tabs.html.erb`
- Modify: `app/controllers/application_controller.rb`, `config/routes.rb`
- Test: `test/integration/admin_authorization_test.rb`

**Interfaces:**
- Consumes: `create_account(superuser:)` and `sign_in(account)` from Task 2; `shared/page_header`, `shared/stat_tile`, `shared/panel` from Task 3.
- Produces:
  - `ApplicationController#require_superuser` — raises `ActionController::RoutingError` unless a signed-in superuser
  - `Admin::BaseController` — `before_action :require_superuser`; all admin controllers inherit it
  - `admin_root_path` → `/admin`
  - `admin/_tabs` partial — renders the admin sub-nav; no locals

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_authorization_test.rb`:

```ruby
require "test_helper"

class AdminAuthorizationTest < ActionDispatch::IntegrationTest
  test "signed out visitors are redirected away from admin" do
    get "/admin"
    assert_response :redirect
  end

  test "a signed in non-superuser gets a 404 from admin" do
    account = create_account(superuser: false)
    sign_in account

    get "/admin"
    assert_response :not_found
  end

  test "a superuser can reach the admin overview" do
    account = create_account(superuser: true)
    sign_in account

    get "/admin"
    assert_response :success
    assert_select "h1 span", text: "STUDIO"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/admin_authorization_test.rb`
Expected: all three FAIL — `/admin` is not routed yet, so every request 404s and the redirect/success assertions fail.

- [ ] **Step 3: Add the gate and remove dead code from ApplicationController**

Replace `app/controllers/application_controller.rb` with:

```ruby
class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  helper_method :current_account

  private

  def current_account
    rodauth.rails_account
  end

  def authenticate
    rodauth.require_account
  end

  # A 404 rather than a 403: an admin area that answers "forbidden" tells a
  # prober it exists.
  def require_superuser
    authenticate
    raise ActionController::RoutingError, "Not Found" unless current_account&.superuser?
  end
end
```

The removed `current_session` and `current_user` methods referenced a `User::Session` constant that does not exist in this codebase; calling either would have raised `NameError`.

- [ ] **Step 4: Add the admin controllers**

Create `app/controllers/admin/base_controller.rb`:

```ruby
module Admin
  class BaseController < ApplicationController
    before_action :require_superuser
  end
end
```

Create `app/controllers/admin/overview_controller.rb`:

```ruby
module Admin
  class OverviewController < BaseController
    def index
    end
  end
end
```

Named `OverviewController` rather than `DashboardController` so it is never confused with the top-level `DashboardController` serving the user dashboard.

- [ ] **Step 5: Add the routes**

In `config/routes.rb`, add below the `dashboard` line:

```ruby
  namespace :admin do
    root "overview#index"
    get "accounts" => "accounts#index", as: :accounts
    get "orders"   => "orders#index",   as: :orders
    get "traffic"  => "traffic#index",  as: :traffic
  end
```

Plain `get` routes rather than `resources` — `resources :traffic` would generate `admin_traffic_index_path`, because "traffic" is its own plural.

The `accounts`, `orders`, and `traffic` controllers arrive in Tasks 5 and 7. Their routes are added now so the tabs partial can link to them without raising `NameError` on an undefined path helper.

- [ ] **Step 6: Add the admin tabs partial**

Create `app/views/admin/_tabs.html.erb`:

```erb
<%= render "shared/tab_nav",
      current: request.path,
      tabs: [
        [ "Overview", admin_root_path ],
        [ "Accounts", admin_accounts_path ],
        [ "Orders",   admin_orders_path ],
        [ "Traffic",  admin_traffic_path ]
      ] %>
```

- [ ] **Step 7: Build the overview page**

Create `app/views/admin/overview/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header",
        heading_top: "STUDIO",
        heading_bottom: "CONTROL.",
        lede: "Everything behind the counter." %>

  <%= render "admin/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12 space-y-10">
    <div class="grid grid-cols-2 md:grid-cols-4 gap-6">
      <%= render "shared/stat_tile", label: "Accounts",  value: "128", delta: "+6 this week" %>
      <%= render "shared/stat_tile", label: "Verified",  value: "104" %>
      <%= render "shared/stat_tile", label: "Orders",    value: "42",  delta: "+3 this week" %>
      <%= render "shared/stat_tile", label: "Revenue",   value: "$1,860" %>
    </div>

    <div class="grid md:grid-cols-2 gap-8">
      <%= render layout: "shared/panel", locals: { title: "Traffic", subtitle: "Last 7 days" } do %>
        <p class="text-sm text-gray-600">
          Page views are being recorded. See the
          <%= link_to "traffic page", admin_traffic_path, class: "font-bold text-brand-green underline decoration-2 underline-offset-4" %>
          for the breakdown.
        </p>
      <% end %>

      <%= render layout: "shared/panel", locals: { title: "Recent activity" } do %>
        <ul class="space-y-3 text-sm text-gray-700">
          <li class="flex justify-between gap-4"><span>New account registered</span><span class="text-gray-400">2h ago</span></li>
          <li class="flex justify-between gap-4"><span>Order #1042 marked shipped</span><span class="text-gray-400">5h ago</span></li>
          <li class="flex justify-between gap-4"><span>Order #1041 paid</span><span class="text-gray-400">Yesterday</span></li>
        </ul>
      <% end %>
    </div>
  </section>
</div>
```

- [ ] **Step 8: Create placeholder controllers so the tabs resolve**

The tabs link to three routes whose controllers do not exist yet, which would 500 if clicked. Create minimal versions now; Tasks 5 and 7 fill in their views.

`app/controllers/admin/accounts_controller.rb`:

```ruby
module Admin
  class AccountsController < BaseController
    def index
    end
  end
end
```

`app/controllers/admin/orders_controller.rb`:

```ruby
module Admin
  class OrdersController < BaseController
    def index
    end
  end
end
```

`app/controllers/admin/traffic_controller.rb`:

```ruby
module Admin
  class TrafficController < BaseController
    def index
    end
  end
end
```

And a one-line placeholder view for each, at `app/views/admin/accounts/index.html.erb`, `app/views/admin/orders/index.html.erb`, and `app/views/admin/traffic/index.html.erb`:

```erb
<div class="bg-white text-ink"><section class="max-w-7xl mx-auto px-6 py-16"></section></div>
```

- [ ] **Step 9: Run the tests**

Run: `bin/rails test test/integration/admin_authorization_test.rb`
Expected: 3 runs, 0 failures.

- [ ] **Step 10: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Add superuser-gated admin namespace and overview page

require_superuser raises a routing error rather than returning 403 so
the admin area is not discoverable by probing. Admin::BaseController
carries the gate once and every admin controller inherits it. Also
removes current_user/current_session from ApplicationController, which
referenced a User::Session constant that does not exist."
```

---

### Task 5: Admin accounts and orders pages

**Files:**
- Modify: `app/views/admin/accounts/index.html.erb`, `app/views/admin/orders/index.html.erb`
- Test: `test/integration/admin_pages_test.rb`

**Interfaces:**
- Consumes: `shared/page_header`, `shared/panel`, `shared/data_table`, `shared/status_badge`, `shared/empty_state`, `admin/tabs`.
- Produces: no new interfaces — these are leaf pages.

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_pages_test.rb`:

```ruby
require "test_helper"

class AdminPagesTest < ActionDispatch::IntegrationTest
  setup do
    @superuser = create_account(superuser: true)
    sign_in @superuser
  end

  test "accounts page renders a table of accounts" do
    get "/admin/accounts"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Email"
  end

  test "orders page renders a table of orders" do
    get "/admin/orders"
    assert_response :success
    assert_select "h1 span", text: "ALL"
    assert_select "table thead th", text: "Order"
  end

  test "non-superusers cannot reach either page" do
    plain = create_account(superuser: false)
    sign_in plain

    get "/admin/accounts"
    assert_response :not_found

    get "/admin/orders"
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/admin_pages_test.rb`
Expected: the first two tests FAIL on the `assert_select` — the placeholder views from Task 4 have no headings or tables. The third passes already.

- [ ] **Step 3: Build the accounts page**

Replace `app/views/admin/accounts/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "ALL", heading_bottom: "ACCOUNTS." %>

  <%= render "admin/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <%= render layout: "shared/panel", locals: { title: "Accounts", subtitle: "128 total, 104 verified" } do %>
      <div class="mb-6 flex flex-wrap items-center gap-4">
        <input type="search" placeholder="Search by email"
               class="w-full max-w-xs px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
        <div class="flex flex-wrap gap-2">
          <% [ "All", "Verified", "Unverified", "Closed" ].each_with_index do |filter, i| %>
            <span class="px-3 py-1 rounded-full text-xs font-bold uppercase tracking-widest <%= i.zero? ? "bg-brand-green text-white" : "bg-gray-100 text-gray-600" %>"><%= filter %></span>
          <% end %>
        </div>
      </div>

      <%= render layout: "shared/data_table", locals: { headers: [ "Email", "Status", "Role", "Created", "" ] } do %>
        <%
          rows = [
            [ "freddie@queen.com",  "Verified",   :green,  "Superuser", "2026-01-14" ],
            [ "brian@queen.com",    "Verified",   :green,  "Customer",  "2026-02-02" ],
            [ "roger@queen.com",    "Unverified", :orange, "Customer",  "2026-08-30" ],
            [ "john@queen.com",     "Closed",     :gray,   "Customer",  "2025-11-19" ]
          ]
        %>
        <% rows.each do |email, status, tone, role, created| %>
          <tr>
            <td class="py-3 pr-6 font-bold"><%= email %></td>
            <td class="py-3 pr-6"><%= render "shared/status_badge", label: status, tone: tone %></td>
            <td class="py-3 pr-6 text-gray-600"><%= role %></td>
            <td class="py-3 pr-6 text-gray-600 whitespace-nowrap"><%= created %></td>
            <td class="py-3 text-right">
              <span class="font-bold text-xs uppercase tracking-widest text-brand-green">Manage</span>
            </td>
          </tr>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

- [ ] **Step 4: Build the orders page**

Replace `app/views/admin/orders/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "ALL", heading_bottom: "ORDERS." %>

  <%= render "admin/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <%= render layout: "shared/panel", locals: { title: "Orders", subtitle: "42 total" } do %>
      <%= render layout: "shared/data_table", locals: { headers: [ "Order", "Customer", "Date", "Items", "Total", "Status", "" ] } do %>
        <%
          rows = [
            [ "#1042", "freddie@queen.com", "2026-09-19", 3, "$54.00", "Shipped",  :green ],
            [ "#1041", "brian@queen.com",   "2026-09-18", 1, "$12.00", "Paid",     :green ],
            [ "#1040", "roger@queen.com",   "2026-09-16", 6, "$96.00", "Printing", :orange ],
            [ "#1039", "john@queen.com",    "2026-09-12", 2, "$24.00", "Cancelled", :gray ]
          ]
        %>
        <% rows.each do |number, customer, date, items, total, status, tone| %>
          <tr>
            <td class="py-3 pr-6 font-bold"><%= number %></td>
            <td class="py-3 pr-6 text-gray-600"><%= customer %></td>
            <td class="py-3 pr-6 text-gray-600 whitespace-nowrap"><%= date %></td>
            <td class="py-3 pr-6 text-gray-600"><%= items %></td>
            <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= total %></td>
            <td class="py-3 pr-6"><%= render "shared/status_badge", label: status, tone: tone %></td>
            <td class="py-3 text-right">
              <span class="font-bold text-xs uppercase tracking-widest text-brand-green">View</span>
            </td>
          </tr>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/integration/admin_pages_test.rb`
Expected: 3 runs, 0 failures.

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add admin accounts and orders pages

Placeholder rows throughout; no models back either table yet."
```

---

### Task 6: Page view recording

The one piece of real behaviour in this plan.

**Files:**
- Create: `db/migrate/<timestamp>_create_page_views.rb`
- Create: `app/models/page_view.rb`
- Create: `app/controllers/concerns/records_page_views.rb`
- Modify: `app/controllers/application_controller.rb`
- Modify: `db/schema.rb` (regenerated)
- Test: `test/integration/page_view_recording_test.rb`

**Interfaces:**
- Consumes: `current_account` from `ApplicationController`.
- Produces:
  - `PageView` — `Sequel::Model`, columns `id`, `path`, `ip`, `user_agent`, `bot`, `account_id`, `created_at`
  - `RecordsPageViews` — concern; `include` it and an `after_action :record_page_view` is installed
  - `RecordsPageViews::BOT_PATTERN` — `Regexp` matched against the user agent

- [ ] **Step 1: Write the failing test**

Create `test/integration/page_view_recording_test.rb`:

```ruby
require "test_helper"

class PageViewRecordingTest < ActionDispatch::IntegrationTest
  setup { PageView.dataset.delete }
  teardown { PageView.dataset.delete }

  test "a GET on an html page is recorded" do
    get "/"

    assert_equal 1, PageView.count
    view = PageView.first
    assert_equal "/", view.path
    assert_equal false, view.bot
  end

  test "a known bot user agent is flagged" do
    get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (compatible; Googlebot/2.1)" }

    assert_equal true, PageView.first.bot
  end

  test "a browser user agent is not flagged" do
    get "/", headers: { "HTTP_USER_AGENT" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36" }

    assert_equal false, PageView.first.bot
  end

  test "the health check is not recorded" do
    get "/up"

    assert_equal 0, PageView.count
  end

  test "non-GET requests are not recorded" do
    post "/login", params: { email: "nobody@example.test", password: "wrong" }

    assert_equal 0, PageView.count
  end

  test "a signed in account is attributed" do
    account = create_account
    sign_in account
    PageView.dataset.delete

    get "/"

    assert_equal account.id, PageView.first.account_id
  end

  test "a recorder failure does not break the response" do
    PageView.stub(:create, ->(*) { raise "boom" }) do
      get "/"
      assert_response :success
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/page_view_recording_test.rb`
Expected: FAIL with `NameError: uninitialized constant PageView`.

- [ ] **Step 3: Write the migration**

Create `db/migrate/20260921130000_create_page_views.rb`:

```ruby
# frozen_string_literal: true

Sequel.migration do
  change do
    create_table :page_views do
      primary_key :id
      String      :path,       null: false
      String      :ip
      String      :user_agent, text: true
      TrueClass   :bot,        null: false, default: false
      Integer     :account_id
      DateTime    :created_at, null: false

      index :created_at
      index :bot
    end
  end
end
```

`account_id` is a plain integer rather than a foreign key on purpose: a page view should outlive the account that made it.

- [ ] **Step 4: Run the migration in both environments**

```bash
bin/rails db:migrate
RAILS_ENV=test bin/rails db:migrate
```

- [ ] **Step 5: Add the model**

Create `app/models/page_view.rb`:

```ruby
class PageView < Sequel::Model
end
```

- [ ] **Step 6: Add the concern**

Create `app/controllers/concerns/records_page_views.rb`:

```ruby
module RecordsPageViews
  extend ActiveSupport::Concern

  BOT_PATTERN = /
    bot|crawl|spider|slurp|bingpreview|facebookexternalhit|
    headless|curl|wget|python-requests|scrapy|monitor
  /xi

  # The health check fires constantly and would swamp the table.
  SKIP_PATHS = [ "/up" ].freeze

  included do
    after_action :record_page_view
  end

  private

  def record_page_view
    return unless request.get?
    return unless request.format.html?
    return if SKIP_PATHS.include?(request.path)

    PageView.create(
      path: request.path,
      ip: request.remote_ip,
      user_agent: request.user_agent,
      bot: bot_user_agent?(request.user_agent),
      account_id: current_account&.id,
      created_at: Time.current
    )
  rescue StandardError => e
    # Analytics must never take a page down with it.
    Rails.logger.warn("page view not recorded: #{e.class}: #{e.message}")
  end

  def bot_user_agent?(user_agent)
    return false if user_agent.blank?

    BOT_PATTERN.match?(user_agent)
  end
end
```

- [ ] **Step 7: Include the concern**

In `app/controllers/application_controller.rb`, add the include directly below `allow_browser`:

```ruby
  include RecordsPageViews
```

- [ ] **Step 8: Run the tests**

Run: `bin/rails test test/integration/page_view_recording_test.rb`
Expected: 7 runs, 0 failures.

If the "signed in account is attributed" test fails with a `nil` `account_id`, check that `sign_in` actually succeeded — rodauth refuses unverified accounts, and `create_account` defaults to `status: 2` (verified) for exactly this reason.

- [ ] **Step 9: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "Record page views for traffic reporting

One row per HTML GET, with a user-agent bot classification, skipping
the health check. The recorder is wrapped in a rescue so an analytics
failure can never break a page render.

Stores raw IPs with no retention limit, which is the simple thing at
this scale; truncation and a sweep are the follow-up if this site ever
needs to care about GDPR."
```

---

### Task 7: Admin traffic page

**Files:**
- Modify: `app/controllers/admin/traffic_controller.rb`, `app/views/admin/traffic/index.html.erb`
- Test: `test/integration/admin_traffic_test.rb`

**Interfaces:**
- Consumes: `PageView` from Task 6; the shared partials from Task 3.
- Produces: no new interfaces.

This is the only admin page reading real data.

- [ ] **Step 1: Write the failing test**

Create `test/integration/admin_traffic_test.rb`:

```ruby
require "test_helper"

class AdminTrafficTest < ActionDispatch::IntegrationTest
  setup do
    PageView.dataset.delete
    @superuser = create_account(superuser: true)
    sign_in @superuser
  end

  teardown { PageView.dataset.delete }

  test "renders an empty state when nothing has been recorded" do
    PageView.dataset.delete

    get "/admin/traffic"
    assert_response :success
    assert_select "h1 span", text: "SITE"
  end

  test "counts humans and bots separately" do
    3.times { PageView.create(path: "/", ip: "1.2.3.4", user_agent: "Chrome", bot: false, created_at: Time.current) }
    2.times { PageView.create(path: "/", ip: "5.6.7.8", user_agent: "Googlebot", bot: true, created_at: Time.current) }

    get "/admin/traffic"
    assert_response :success
    assert_select "body", text: /3/
    assert_select "body", text: /2/
  end

  test "non-superusers cannot reach it" do
    sign_in create_account(superuser: false)

    get "/admin/traffic"
    assert_response :not_found
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/admin_traffic_test.rb`
Expected: the first two FAIL on `assert_select` — the placeholder view is empty.

- [ ] **Step 3: Write the controller**

Replace `app/controllers/admin/traffic_controller.rb`:

```ruby
module Admin
  class TrafficController < BaseController
    WINDOW = 7

    def index
      since = WINDOW.days.ago

      recent = PageView.where { created_at >= since }

      @total   = recent.count
      @humans  = recent.where(bot: false).count
      @bots    = recent.where(bot: true).count
      @unique_ips = recent.distinct.select_map(:ip).compact.size

      @by_day = recent
        .select { [ Sequel.function(:date, :created_at).as(:day), bot, Sequel.function(:count, Sequel.lit("*")).as(:views) ] }
        .group(Sequel.function(:date, :created_at), :bot)
        .order(Sequel.desc(:day))
        .all

      @top_paths  = top(recent, :path)
      @top_ips    = top(recent, :ip)
      @top_agents = top(recent, :user_agent)
    end

    private

    def top(dataset, column, limit: 8)
      dataset
        .select { [ column, Sequel.function(:count, Sequel.lit("*")).as(:views) ] }
        .exclude(column => nil)
        .group(column)
        .order(Sequel.desc(:views))
        .limit(limit)
        .all
    end
  end
end
```

- [ ] **Step 4: Build the view**

Replace `app/views/admin/traffic/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header",
        heading_top: "SITE",
        heading_bottom: "TRAFFIC.",
        lede: "Last #{Admin::TrafficController::WINDOW} days." %>

  <%= render "admin/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12 space-y-10">
    <div class="grid grid-cols-2 md:grid-cols-4 gap-6">
      <%= render "shared/stat_tile", label: "Page views", value: @total %>
      <%= render "shared/stat_tile", label: "Unique IPs", value: @unique_ips %>
      <%= render "shared/stat_tile", label: "Humans",     value: @humans %>
      <%= render "shared/stat_tile", label: "Bots",       value: @bots %>
    </div>

    <% if @total.zero? %>
      <%= render layout: "shared/panel", locals: { title: "Nothing recorded yet" } do %>
        <%= render "shared/empty_state", message: "Page views appear here as soon as someone visits the site." %>
      <% end %>
    <% else %>
      <%= render layout: "shared/panel", locals: { title: "By day" } do %>
        <%= render layout: "shared/data_table", locals: { headers: [ "Day", "Audience", "Views" ] } do %>
          <% @by_day.each do |row| %>
            <tr>
              <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= row[:day] %></td>
              <td class="py-3 pr-6">
                <%= render "shared/status_badge",
                      label: row[:bot] ? "Bot" : "Human",
                      tone:  row[:bot] ? :orange : :green %>
              </td>
              <td class="py-3 pr-6 text-gray-600"><%= row[:views] %></td>
            </tr>
          <% end %>
        <% end %>
      <% end %>

      <div class="grid md:grid-cols-2 gap-8">
        <%= render layout: "shared/panel", locals: { title: "Top paths" } do %>
          <%= render layout: "shared/data_table", locals: { headers: [ "Path", "Views" ] } do %>
            <% @top_paths.each do |row| %>
              <tr>
                <td class="py-3 pr-6 font-bold break-all"><%= row[:path] %></td>
                <td class="py-3 text-gray-600"><%= row[:views] %></td>
              </tr>
            <% end %>
          <% end %>
        <% end %>

        <%= render layout: "shared/panel", locals: { title: "Top IPs" } do %>
          <%= render layout: "shared/data_table", locals: { headers: [ "IP", "Views" ] } do %>
            <% @top_ips.each do |row| %>
              <tr>
                <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= row[:ip] %></td>
                <td class="py-3 text-gray-600"><%= row[:views] %></td>
              </tr>
            <% end %>
          <% end %>
        <% end %>
      </div>

      <%= render layout: "shared/panel", locals: { title: "Top user agents" } do %>
        <%= render layout: "shared/data_table", locals: { headers: [ "User agent", "Views" ] } do %>
          <% @top_agents.each do |row| %>
            <tr>
              <td class="py-3 pr-6 text-gray-700 break-all"><%= truncate(row[:user_agent], length: 90) %></td>
              <td class="py-3 text-gray-600"><%= row[:views] %></td>
            </tr>
          <% end %>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/integration/admin_traffic_test.rb`
Expected: 3 runs, 0 failures.

Watch for one thing: the admin page request is itself an HTML GET and gets recorded, so counts include the visit that rendered the page. The tests assert on the seeded rows being present rather than on exact totals, which is why they use `/3/` rather than `text: "3"`.

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add admin traffic page

Reads real page_views rows: humans vs bots by day, top paths, IPs and
user agents, with an empty state before any traffic lands."
```

---

### Task 8: User dashboard — overview and account

**Files:**
- Modify: `app/controllers/dashboard_controller.rb`, `config/routes.rb`
- Create: `app/views/dashboard/_tabs.html.erb`
- Modify: `app/views/dashboard/index.html.erb`
- Create: `app/views/dashboard/account.html.erb`
- Test: `test/integration/dashboard_authorization_test.rb`

**Interfaces:**
- Consumes: `authenticate` from `ApplicationController`; the shared partials from Task 3.
- Produces:
  - `dashboard_path`, `dashboard_account_path`, `dashboard_orders_path`, `dashboard_checkout_path`
  - `dashboard/_tabs` partial — no locals

- [ ] **Step 1: Write the failing test**

Create `test/integration/dashboard_authorization_test.rb`:

```ruby
require "test_helper"

class DashboardAuthorizationTest < ActionDispatch::IntegrationTest
  PATHS = %w[/dashboard /dashboard/account /dashboard/orders /dashboard/checkout].freeze

  test "signed out visitors are redirected away from every dashboard page" do
    PATHS.each do |path|
      get path
      assert_response :redirect, "expected #{path} to redirect when signed out"
    end
  end

  test "a signed in account can reach every dashboard page" do
    sign_in create_account

    PATHS.each do |path|
      get path
      assert_response :success, "expected #{path} to render when signed in"
    end
  end

  test "the account page links to the rodauth routes" do
    sign_in create_account

    get "/dashboard/account"
    assert_select "a[href=?]", "/change-password"
    assert_select "a[href=?]", "/change-login"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/dashboard_authorization_test.rb`
Expected: FAIL — `/dashboard/account` and the others are not routed, and `/dashboard` currently renders for signed-out visitors.

- [ ] **Step 3: Add the routes**

In `config/routes.rb`, replace the single `dashboard` line with:

```ruby
  get "dashboard"          => "dashboard#index",    as: :dashboard
  get "dashboard/account"  => "dashboard#account",  as: :dashboard_account
  get "dashboard/orders"   => "dashboard#orders",   as: :dashboard_orders
  get "dashboard/checkout" => "dashboard#checkout", as: :dashboard_checkout
```

- [ ] **Step 4: Write the controller**

Replace `app/controllers/dashboard_controller.rb`:

```ruby
class DashboardController < ApplicationController
  before_action :authenticate

  def index
  end

  def account
  end

  def orders
  end

  def checkout
  end
end
```

- [ ] **Step 5: Add the dashboard tabs partial**

Create `app/views/dashboard/_tabs.html.erb`:

```erb
<%= render "shared/tab_nav",
      current: request.path,
      tabs: [
        [ "Overview", dashboard_path ],
        [ "Account",  dashboard_account_path ],
        [ "Orders",   dashboard_orders_path ],
        [ "Checkout", dashboard_checkout_path ]
      ] %>
```

- [ ] **Step 6: Build the overview page**

Replace `app/views/dashboard/index.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header",
        heading_top: "YOUR",
        heading_bottom: "STUDIO.",
        lede: "Orders, details and checkout in one place." %>

  <%= render "dashboard/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12 space-y-8">
    <div class="grid md:grid-cols-2 gap-8">
      <%= render layout: "shared/panel", locals: { title: "Recent orders" } do %>
        <%= render layout: "shared/data_table", locals: { headers: [ "Order", "Date", "Total", "Status" ] } do %>
          <% [ [ "#1042", "2026-09-19", "$54.00", "Shipped", :green ],
               [ "#1041", "2026-09-18", "$12.00", "Paid", :green ] ].each do |number, date, total, status, tone| %>
            <tr>
              <td class="py-3 pr-6 font-bold"><%= number %></td>
              <td class="py-3 pr-6 text-gray-600 whitespace-nowrap"><%= date %></td>
              <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= total %></td>
              <td class="py-3"><%= render "shared/status_badge", label: status, tone: tone %></td>
            </tr>
          <% end %>
        <% end %>
        <div class="mt-6">
          <%= link_to "All orders", dashboard_orders_path, class: "font-bold text-sm uppercase tracking-wide underline decoration-2 underline-offset-4 text-brand-green" %>
        </div>
      <% end %>

      <%= render layout: "shared/panel", locals: { title: "Your details" } do %>
        <dl class="space-y-4 text-sm">
          <div>
            <dt class="text-xs font-bold uppercase tracking-widest text-gray-500">Email</dt>
            <dd class="mt-1 font-bold"><%= current_account&.email %></dd>
          </div>
          <div>
            <dt class="text-xs font-bold uppercase tracking-widest text-gray-500">Default shipping</dt>
            <dd class="mt-1 text-gray-700">114 Main St, McComb, MS 39648</dd>
          </div>
        </dl>
        <div class="mt-6">
          <%= link_to "Manage account", dashboard_account_path, class: "font-bold text-sm uppercase tracking-wide underline decoration-2 underline-offset-4 text-brand-green" %>
        </div>
      <% end %>
    </div>
  </section>
</div>
```

- [ ] **Step 7: Build the account page**

Create `app/views/dashboard/account.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "YOUR", heading_bottom: "ACCOUNT." %>

  <%= render "dashboard/tabs" %>

  <section class="max-w-4xl mx-auto px-6 py-12 space-y-8">
    <%= render layout: "shared/panel", locals: { title: "Sign in details" } do %>
      <dl class="space-y-4 text-sm">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <dt class="text-xs font-bold uppercase tracking-widest text-gray-500">Email</dt>
            <dd class="mt-1 font-bold"><%= current_account&.email %></dd>
          </div>
          <%= link_to "Change email", rodauth.change_login_path, class: "font-bold text-sm uppercase tracking-wide underline decoration-2 underline-offset-4 text-brand-green" %>
        </div>
        <div class="flex flex-wrap items-center justify-between gap-4 pt-4 border-t border-gray-200">
          <div>
            <dt class="text-xs font-bold uppercase tracking-widest text-gray-500">Password</dt>
            <dd class="mt-1 font-bold">&bull;&bull;&bull;&bull;&bull;&bull;&bull;&bull;</dd>
          </div>
          <%= link_to "Change password", rodauth.change_password_path, class: "font-bold text-sm uppercase tracking-wide underline decoration-2 underline-offset-4 text-brand-green" %>
        </div>
      </dl>
    <% end %>

    <%= render layout: "shared/panel", locals: { title: "Shipping addresses" } do %>
      <div class="space-y-4">
        <% [ [ "Home", "114 Main St, McComb, MS 39648", true ],
             [ "Studio", "22 Delaware Ave, McComb, MS 39648", false ] ].each do |name, line, is_default| %>
          <div class="flex flex-wrap items-start justify-between gap-4 p-4 border-2 border-gray-200 rounded-lg">
            <div>
              <div class="font-bold text-sm flex items-center gap-2">
                <%= name %>
                <% if is_default %><%= render "shared/status_badge", label: "Default", tone: :green %><% end %>
              </div>
              <div class="mt-1 text-sm text-gray-600"><%= line %></div>
            </div>
            <div class="flex gap-4 text-xs font-bold uppercase tracking-widest text-brand-green">
              <span>Edit</span><span>Remove</span>
            </div>
          </div>
        <% end %>
      </div>
      <button type="button" class="mt-6 inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded">
        Add an address <span aria-hidden="true">&rarr;</span>
      </button>
    <% end %>

    <%= render layout: "shared/panel", locals: { title: "Payment methods" } do %>
      <div class="space-y-4">
        <div class="flex flex-wrap items-center justify-between gap-4 p-4 border-2 border-gray-200 rounded-lg">
          <div>
            <div class="font-bold text-sm flex items-center gap-2">
              Visa ending 4242
              <%= render "shared/status_badge", label: "Default", tone: :green %>
            </div>
            <div class="mt-1 text-sm text-gray-600">Expires 04/29</div>
          </div>
          <div class="flex gap-4 text-xs font-bold uppercase tracking-widest text-brand-green">
            <span>Edit</span><span>Remove</span>
          </div>
        </div>
      </div>
      <button type="button" class="mt-6 inline-flex items-center gap-2 bg-brand-green hover:bg-brand-green-dark text-white font-bold text-sm tracking-wide uppercase px-6 py-3 rounded">
        Add a card <span aria-hidden="true">&rarr;</span>
      </button>
    <% end %>

    <div class="text-center pt-4">
      <%= link_to "Close your account", rodauth.close_account_path, class: "text-xs font-bold uppercase tracking-widest text-gray-400 hover:text-brand-orange underline decoration-2 underline-offset-4" %>
    </div>
  </section>
</div>
```

- [ ] **Step 8: Add placeholder views for the remaining two routes**

So the tabs do not 500 before Task 9. Create `app/views/dashboard/orders.html.erb` and `app/views/dashboard/checkout.html.erb`, each containing:

```erb
<div class="bg-white text-ink"><section class="max-w-7xl mx-auto px-6 py-16"></section></div>
```

- [ ] **Step 9: Run the tests**

Run: `bin/rails test test/integration/dashboard_authorization_test.rb`
Expected: 3 runs, 0 failures.

- [ ] **Step 10: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "Add user dashboard overview and account pages

Both login-gated. The account page links to the real rodauth routes
for changing email, changing password and closing the account, since
those already work; addresses and payment methods are placeholders."
```

---

### Task 9: User dashboard — orders and checkout

**Files:**
- Modify: `app/views/dashboard/orders.html.erb`, `app/views/dashboard/checkout.html.erb`
- Test: `test/integration/dashboard_pages_test.rb`

**Interfaces:**
- Consumes: everything from Task 8.
- Produces: no new interfaces. The checkout page establishes one convention later work depends on — a `<div id="payment-element" data-stripe-mount>` where Stripe Elements will mount.

- [ ] **Step 1: Write the failing test**

Create `test/integration/dashboard_pages_test.rb`:

```ruby
require "test_helper"

class DashboardPagesTest < ActionDispatch::IntegrationTest
  setup { sign_in create_account }

  test "orders page renders an order history table" do
    get "/dashboard/orders"
    assert_response :success
    assert_select "h1 span", text: "YOUR"
    assert_select "table thead th", text: "Order"
  end

  test "checkout page renders all three sections" do
    get "/dashboard/checkout"
    assert_response :success
    assert_select "h2", text: "ORDER SUMMARY"
    assert_select "h2", text: "SHIPPING"
    assert_select "h2", text: "PAYMENT"
  end

  test "checkout leaves a stripe mount point" do
    get "/dashboard/checkout"
    assert_select "div#payment-element[data-stripe-mount]"
  end
end
```

Note the `h2` assertions match the uppercase text rendered by `shared/_panel`, which applies `uppercase` as a CSS class — so the assertion must match the source text, not the rendered casing. Pass the titles in as already-uppercase strings (`title: "Order summary"` would fail this assertion). The view below passes `"ORDER SUMMARY"`, `"SHIPPING"`, `"PAYMENT"` verbatim.

- [ ] **Step 2: Run test to verify it fails**

Run: `bin/rails test test/integration/dashboard_pages_test.rb`
Expected: all three FAIL — both views are the empty placeholders from Task 8.

- [ ] **Step 3: Build the orders page**

Replace `app/views/dashboard/orders.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "YOUR", heading_bottom: "ORDERS." %>

  <%= render "dashboard/tabs" %>

  <section class="max-w-7xl mx-auto px-6 py-12">
    <%= render layout: "shared/panel", locals: { title: "Order history" } do %>
      <%= render layout: "shared/data_table", locals: { headers: [ "Order", "Date", "Items", "Total", "Status", "" ] } do %>
        <%
          rows = [
            [ "#1042", "2026-09-19", 3, "$54.00", "Shipped",  :green ],
            [ "#1041", "2026-09-18", 1, "$12.00", "Paid",     :green ],
            [ "#1036", "2026-08-30", 6, "$96.00", "Printing", :orange ],
            [ "#1021", "2026-07-11", 2, "$24.00", "Cancelled", :gray ]
          ]
        %>
        <% rows.each do |number, date, items, total, status, tone| %>
          <tr>
            <td class="py-3 pr-6 font-bold"><%= number %></td>
            <td class="py-3 pr-6 text-gray-600 whitespace-nowrap"><%= date %></td>
            <td class="py-3 pr-6 text-gray-600"><%= items %></td>
            <td class="py-3 pr-6 font-bold whitespace-nowrap"><%= total %></td>
            <td class="py-3 pr-6"><%= render "shared/status_badge", label: status, tone: tone %></td>
            <td class="py-3 text-right">
              <span class="font-bold text-xs uppercase tracking-widest text-brand-green">View</span>
            </td>
          </tr>
        <% end %>
      <% end %>
    <% end %>
  </section>
</div>
```

- [ ] **Step 4: Build the checkout page**

Replace `app/views/dashboard/checkout.html.erb`:

```erb
<div class="bg-white text-ink">
  <%= render "shared/page_header", heading_top: "YOUR", heading_bottom: "CHECKOUT." %>

  <%= render "dashboard/tabs" %>

  <section class="max-w-3xl mx-auto px-6 py-12 space-y-8">

    <%# ---------- 1. Order summary ---------- %>
    <%= render layout: "shared/panel", locals: { title: "ORDER SUMMARY" } do %>
      <ul class="space-y-4">
        <% [ [ "Bitspace Classic Tee", "Black / L", 2, "$24.00" ],
             [ "Studio Poster", "18x24", 1, "$18.00" ],
             [ "Sticker Pack", "Assorted", 1, "$12.00" ] ].each do |name, variant, qty, line_total| %>
          <li class="flex items-center gap-4">
            <div class="w-14 h-14 rounded-lg bg-gray-100 shrink-0"></div>
            <div class="flex-1">
              <div class="font-bold text-sm"><%= name %></div>
              <div class="text-xs text-gray-500"><%= variant %> &middot; Qty <%= qty %></div>
            </div>
            <div class="font-bold text-sm whitespace-nowrap"><%= line_total %></div>
          </li>
        <% end %>
      </ul>

      <dl class="mt-6 pt-6 border-t-2 border-brand-green/30 space-y-2 text-sm">
        <div class="flex justify-between"><dt class="text-gray-600">Subtotal</dt><dd>$54.00</dd></div>
        <div class="flex justify-between"><dt class="text-gray-600">Shipping</dt><dd>$6.00</dd></div>
        <div class="flex justify-between"><dt class="text-gray-600">Tax</dt><dd>$4.20</dd></div>
        <div class="flex justify-between pt-2 border-t border-gray-200 font-display text-xl">
          <dt>TOTAL</dt><dd>$64.20</dd>
        </div>
      </dl>
    <% end %>

    <%# ---------- 2. Shipping ---------- %>
    <%= render layout: "shared/panel", locals: { title: "SHIPPING" } do %>
      <div class="space-y-3">
        <% [ [ "Home", "114 Main St, McComb, MS 39648", true ],
             [ "Studio", "22 Delaware Ave, McComb, MS 39648", false ] ].each_with_index do |(name, line, checked), i| %>
          <label class="flex items-start gap-3 p-4 border-2 <%= checked ? "border-brand-green" : "border-gray-200" %> rounded-lg cursor-pointer">
            <input type="radio" name="shipping_address" class="mt-1 accent-brand-green" <%= "checked" if checked %>>
            <span>
              <span class="block font-bold text-sm"><%= name %></span>
              <span class="block mt-1 text-sm text-gray-600"><%= line %></span>
            </span>
          </label>
        <% end %>
      </div>

      <details class="mt-6 group">
        <summary class="cursor-pointer font-bold text-sm uppercase tracking-wide text-brand-green underline decoration-2 underline-offset-4">
          Add a new address
        </summary>
        <div class="mt-6 grid sm:grid-cols-2 gap-4">
          <% [ [ "Full name", "name", "sm:col-span-2" ],
               [ "Street address", "line1", "sm:col-span-2" ],
               [ "Apartment, suite (optional)", "line2", "sm:col-span-2" ],
               [ "City", "city", "" ],
               [ "State", "state", "" ],
               [ "ZIP code", "zip", "" ],
               [ "Country", "country", "" ] ].each do |field_label, field_name, span| %>
            <div class="<%= span %>">
              <label for="ship_<%= field_name %>" class="block text-xs font-bold uppercase tracking-widest text-gray-500"><%= field_label %></label>
              <input id="ship_<%= field_name %>" name="ship_<%= field_name %>" type="text"
                     class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
            </div>
          <% end %>
        </div>
      </details>
    <% end %>

    <%# ---------- 3. Payment ---------- %>
    <%= render layout: "shared/panel", locals: { title: "PAYMENT" } do %>
      <div class="space-y-3">
        <label class="flex items-start gap-3 p-4 border-2 border-brand-green rounded-lg cursor-pointer">
          <input type="radio" name="payment_method" class="mt-1 accent-brand-green" checked>
          <span>
            <span class="block font-bold text-sm">Visa ending 4242</span>
            <span class="block mt-1 text-sm text-gray-600">Expires 04/29</span>
          </span>
        </label>
      </div>

      <details class="mt-6">
        <summary class="cursor-pointer font-bold text-sm uppercase tracking-wide text-brand-green underline decoration-2 underline-offset-4">
          Pay with a new card
        </summary>

        <%# Stripe Elements mounts into #payment-element. The inputs below are
            placeholder markup so the panel looks complete now; wiring Stripe
            replaces this div's contents and nothing around it. %>
        <div id="payment-element" data-stripe-mount class="mt-6 grid sm:grid-cols-2 gap-4">
          <div class="sm:col-span-2">
            <label for="card_number" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Card number</label>
            <input id="card_number" name="card_number" type="text" inputmode="numeric" autocomplete="cc-number" placeholder="4242 4242 4242 4242"
                   class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
          </div>
          <div>
            <label for="card_expiry" class="block text-xs font-bold uppercase tracking-widest text-gray-500">Expiry</label>
            <input id="card_expiry" name="card_expiry" type="text" autocomplete="cc-exp" placeholder="MM / YY"
                   class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
          </div>
          <div>
            <label for="card_cvc" class="block text-xs font-bold uppercase tracking-widest text-gray-500">CVC</label>
            <input id="card_cvc" name="card_cvc" type="text" inputmode="numeric" autocomplete="cc-csc" placeholder="123"
                   class="mt-2 w-full px-3 py-2 text-sm text-ink bg-white border-2 border-gray-300 rounded-md focus:outline-none focus:ring-2 focus:border-brand-green focus:ring-brand-green/40">
          </div>
        </div>
      </details>

      <label class="mt-6 flex items-center gap-3 text-sm text-gray-700">
        <input type="checkbox" class="accent-brand-green" checked>
        Billing address is the same as shipping
      </label>
    <% end %>

    <%# ---------- Place order ---------- %>
    <div class="flex flex-wrap items-center justify-between gap-4">
      <div class="font-display text-2xl">TOTAL $64.20</div>
      <button type="button" disabled
              class="inline-flex items-center justify-center gap-2 bg-brand-green text-white font-bold text-sm tracking-wide uppercase px-8 py-3 rounded opacity-50 cursor-not-allowed">
        Place order <span aria-hidden="true">&rarr;</span>
      </button>
    </div>
    <p class="text-xs text-gray-500 text-center">Checkout is not wired up yet.</p>
  </section>
</div>
```

- [ ] **Step 5: Run the tests**

Run: `bin/rails test test/integration/dashboard_pages_test.rb`
Expected: 3 runs, 0 failures.

- [ ] **Step 6: Run the full suite and lint**

Run: `bin/rails test test/ && bin/rubocop`
Expected: whole suite green.

- [ ] **Step 7: Verify every page renders in a browser**

```bash
bin/rails runner 'Account.where(email: "zerosum022@gmail.com").update(superuser: true)'
bin/dev
```

Visit each of the following and check the layout at desktop width and at 390px:
`/dashboard`, `/dashboard/account`, `/dashboard/orders`, `/dashboard/checkout`, `/admin`, `/admin/accounts`, `/admin/orders`, `/admin/traffic`.

`bin/dev` must be run in a real terminal — its Tailwind watcher exits immediately without a TTY and takes the server down with it. This run is also what compiles the new utility classes these pages introduce.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add user dashboard orders and checkout pages

Checkout is one page with order summary, shipping selection and
payment selection. The new-card region is a marked Stripe seam:
#payment-element holds placeholder inputs that Elements replaces
without restructuring the panel."
```

---

## Self-Review Notes

Checked against the spec:

- **Superuser flag** — Task 2. Includes the `boolean_readers` correction.
- **Authorization, 404 not 403** — Task 4.
- **ApplicationController dead-code cleanup** — Task 4, Step 3.
- **Routes** — Task 4 (admin), Task 8 (dashboard). The spec's route block is reproduced exactly.
- **Admin overview / accounts / orders / traffic** — Tasks 4, 5, 7.
- **Dashboard overview / account / orders / checkout** — Tasks 8, 9.
- **Shared components** (all seven, plus the `_auth_page` refactor) — Task 3.
- **Traffic collection** — Task 6, with all four guards from the spec (GET only, HTML only, skip `/up`, rescue-wrapped).
- **Deletions** — Task 1. Tables and their migration deliberately untouched.
- **Testing** — the spec names three areas; they are Tasks 4 and 8 (authorization), 8 (dashboard gating), and 6 (collector).

Two places this plan corrects the spec:

1. The spec says the Stimulus controller registration in `app/javascript/controllers/index.js` must be edited. It must not — that file uses `eagerLoadControllersFrom`, which discovers controllers from the importmap automatically. Deleting the files is the whole job.
2. The spec leaves `test/fixtures/sample_posts.yml` conditional on whether it references comics or issues. It does not — it is a generic `title`/`body` scaffold leftover for a `Post` model that never existed. It is out of scope and stays.
   **Corrected during Task 1:** the reasoning given here ("`fixtures :all` is commented out, so nothing loads it") was wrong. `ActiveRecord::TestFixtures#setup_fixtures` loads fixtures unconditionally and raises `ActiveRecord::ConnectionNotDefined` before any test body runs. See the Global Constraints entry above; Task 1 fixes this in `test/test_helper.rb`.

One thing the spec did not anticipate, added here: `test/test_helper.rb` sets `parallelize(workers: :number_of_processors)`. Rails provisions a database per worker for ActiveRecord only, so Sequel-backed parallel workers would share one database and collide. Task 2 drops it to a single worker.
