# Superuser flag, admin area, and user dashboard

**Date:** 2026-09-21
**Status:** Approved for planning

## Goal

Add a `superuser` flag to accounts, a superuser-only admin area, and a
logged-in user dashboard covering account, orders, and checkout. Build
the views; leave the behaviour behind them unimplemented, with one
deliberate exception (traffic collection, below).

Everything visible follows the bitspace style already established on
the home, contact, and auth pages: white page, Anton display headings
in a black line over a `brand-green` line, `border-2 border-brand-green
rounded-xl` cards, olive-green uppercase CTAs, the orange-dot section
divider.

## Non-goals

- No order, cart, product, address, or payment-method persistence.
  Every table and figure on these pages is placeholder markup.
- No Stripe integration. Checkout leaves a mount point for it.
- No admin mutations. Row actions render but do nothing.
- No drop migration for `comics` / `comic_issues`. The code that used
  those tables is deleted; the tables stay until explicitly dropped.

## Data model

### `accounts.superuser`

```ruby
# db/migrate/<timestamp>_add_superuser_to_accounts.rb
Sequel.migration do
  change do
    alter_table :accounts do
      add_column :superuser, TrueClass, null: false, default: false
    end
  end
end
```

```ruby
# app/models/account.rb
class Account < Sequel::Model
  include Rodauth::Rails.model
  plugin :enum
  plugin :boolean_readers        # provides #superuser?
  enum :status, unverified: 1, verified: 2, closed: 3
end
```

Sequel does not generate `?` readers for plain columns; the existing
`unverified?` / `verified?` come from the `enum` plugin. The
`boolean_readers` plugin supplies `superuser?`.

Granting the flag is a console operation:

```
bin/rails runner 'Account.where(email: "you@example.com").update(superuser: true)'
```

### `page_views`

```ruby
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

`account_id` is a plain integer, not a foreign key: a page view should
survive the account that made it being closed or deleted.

## Authorization

`ApplicationController` gains:

```ruby
def require_superuser
  authenticate
  raise ActionController::RoutingError, "Not Found" unless current_account&.superuser?
end
```

A 404 rather than a 403, so the admin area is not discoverable by
probing. `Admin::BaseController` sets `before_action :require_superuser`
once and every admin controller inherits from it. `DashboardController`
uses `before_action :authenticate`.

**Cleanup in the same file:** `current_session` and `current_user`
reference a `User::Session` constant that does not exist in this
codebase and would raise `NameError` if called. Both are dead and get
deleted.

## Routes

```ruby
get "dashboard"          => "dashboard#index",  as: :dashboard
get "dashboard/account"  => "dashboard#account",  as: :dashboard_account
get "dashboard/orders"   => "dashboard#orders",   as: :dashboard_orders
get "dashboard/checkout" => "dashboard#checkout", as: :dashboard_checkout

namespace :admin do
  root "overview#index"
  get "accounts" => "accounts#index", as: :accounts
  get "orders"   => "orders#index",   as: :orders
  get "traffic"  => "traffic#index",  as: :traffic
end
```

Removed: `comics`, `issues`, `issues/:id`, `dashboard/new_issue`,
`dashboard/create_issue`.

## Admin pages

All under `/admin`, all superuser-gated, all rendered inside a tab
strip sub-nav (Overview · Accounts · Orders · Traffic).

### `admin/overview#index` — Overview

Named `Admin::OverviewController`, not `Admin::DashboardController`, so
it is never confused with the top-level `DashboardController` that
serves the user dashboard.


Header "STUDIO / CONTROL." A four-up row of stat tiles (total accounts,
verified accounts, orders, revenue), then a two-column split: a traffic
summary panel (humans vs bots over the last 7 days, reading real data)
and a recent-activity list (placeholder).

### `admin/accounts#index` — Accounts

Table: email, status badge (unverified / verified / closed, coloured
from the existing enum), superuser indicator, created date, and a row
action menu. Placeholder rows. Above it, a search input and status
filter chips, both inert.

### `admin/orders#index` — Orders

Table: order number, customer email, date, item count, total, status
badge (pending / paid / printing / shipped / cancelled). Placeholder
rows, plus an empty state to show alongside.

### `admin/traffic#index` — Traffic

The only admin page reading real data. Four stat tiles (views today,
unique IPs, human share, bot share), a humans-vs-bots table by day, a
top-paths table, a top-IPs table, and a top-user-agents table. Each
reads from `page_views` and renders the empty state when there is
nothing yet.

## User dashboard pages

All under `/dashboard`, login-gated, inside a tab strip sub-nav
(Overview · Account · Orders · Checkout).

### `dashboard#index` — Overview

Header "YOUR / STUDIO." Recent orders card, account summary card,
quick-link row.

### `dashboard#account` — Account

Profile panel showing the signed-in email with "Change email" and
"Change password" linking to the real rodauth routes
(`change_login_path`, `change_password_path`), which already work. Then
a saved-addresses panel and a saved-payment-methods panel, both
placeholder card lists with add/edit/remove buttons. A close-account
link to the rodauth route sits at the bottom in a muted danger style.

### `dashboard#orders` — Orders

Order history table: order number, date, items, total, status badge,
"View" action. Placeholder rows plus an empty state.

### `dashboard#checkout` — Checkout

One page, three stacked panels, then the submit:

1. **Order summary** — line items with thumbnail, name, variant,
   quantity, line total; then subtotal, shipping, tax, total.
2. **Shipping** — saved addresses as radio rows, plus an "Add a new
   address" disclosure containing a full address form.
3. **Payment** — saved cards as radio rows, plus an "Add a new card"
   disclosure. The new-card region is an explicit Stripe seam:

   ```erb
   <%# Stripe Elements mounts here. The static fields below are
       placeholders and get replaced by the Element on wiring. %>
   <div id="payment-element" data-stripe-mount>
   ```

   Card fields render as ordinary inputs inside that div so the page
   looks complete now and the Element drops in later without
   restructuring the panel.

4. **Place order** — the standard green CTA, disabled, with an order
   total beside it.

## Shared view components

The auth work established the vocabulary; this generalises it.

- **`shared/_page_header`** — extracted from `_auth_page`: the Anton
  two-line heading, optional lede, and the section divider.
  `_auth_page` is refactored to use it, so auth, dashboard, and admin
  share one header. No visual change to the auth pages.
- **`shared/_panel`** — the `border-2 border-brand-green rounded-xl`
  card with an optional title row.
- **`shared/_stat_tile`** — label, big Anton figure, optional delta.
- **`shared/_status_badge`** — small uppercase pill; a `tone` local
  maps to green / orange / gray.
- **`shared/_data_table`** — wrapper giving consistent header, row
  borders, horizontal scroll on narrow screens.
- **`shared/_empty_state`** — icon, line of copy, optional CTA.
- **`shared/_tab_nav`** — the sub-nav strip, given a list of
  label/path pairs and the current path.

## Traffic collection

The one piece built functional.

```ruby
# app/controllers/concerns/records_page_views.rb
BOT = /bot|crawl|spider|slurp|bingpreview|facebookexternalhit|
       headless|curl|wget|python-requests|scrapy|monitor/xi
```

An `after_action` in `ApplicationController` inserts one `page_views`
row per request, subject to:

- GET requests only
- HTML responses only (`request.format.html?`)
- skip `/up` (the health check would swamp the table)
- the whole body wrapped in `rescue StandardError` — a logging failure
  must never break a page render

`bot` is set from the user-agent regex. `account_id` is
`current_account&.id` when logged in. `ip` is `request.remote_ip`.

Two accepted trade-offs, both fine at this size and worth revisiting if
traffic grows:

- **Synchronous insert.** One extra INSERT per HTML request, on the
  request thread. Moving it to `solid_queue` is the escape hatch.
- **Raw IPs stored, unbounded retention.** If this site ever needs to
  care about GDPR/CCPA, truncate the last octet and add a retention
  sweep. Noted, not built.

## Deletions

The comics/issues fork is unused and goes:

```
app/controllers/comics_controller.rb
app/controllers/issues_controller.rb
app/models/comic.rb
app/models/issue.rb
app/views/comics/
app/views/issues/
app/views/dashboard/new_issue.html.erb
app/javascript/controllers/issue_controller.js
```

Plus `DashboardController#new_issue` and `#create_issue`, and the four
comics/issues routes. `test/fixtures/sample_posts.yml` is checked and
removed if it refers to them.

`app/javascript/controllers/dashboard_controller.js` is a stub with a
`greet` method wired to the old placeholder `dashboard/index`; it goes
too, along with its registration in `controllers/index.js`.

The `comics` and `comic_issues` tables and their migration stay. The
migration is history and should not be edited; dropping the tables is
destructive and is a separate, explicit decision.

## Testing

`test/controllers` and `test/system` are currently empty. A pure view
scaffold does not warrant a suite, but three things here are real
behaviour and get tests:

1. **Authorization** — a non-superuser account gets 404 from every
   `/admin` route; a superuser gets 200; a signed-out visitor gets
   redirected to login.
2. **Dashboard gating** — signed-out visitors are redirected away from
   all four `/dashboard` routes.
3. **Traffic collector** — a GET on an HTML page inserts one row with
   the right path and bot classification; `/up` inserts none; a raised
   error inside the recorder does not break the response.

Everything else is verified by rendering each page and eyeballing it at
desktop and phone width.

## Follow-ups, not in scope

- Stripe Elements wiring at the checkout seam.
- Real order / cart / address / payment-method models.
- Admin mutations (toggle superuser, change order status).
- Moving page-view inserts off the request thread.
- Nav integration: `layouts/partials/_login_menu.html.erb` exists but
  is not rendered by `_navigation`. Dashboard and admin links belong in
  the main nav for signed-in users; that is a separate change.
