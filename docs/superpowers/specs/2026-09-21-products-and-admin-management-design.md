# Products, Public Catalog, and Admin Product Management — Design

**Date:** 2026-09-21
**Status:** Approved, ready for implementation planning

## Goal

Give the shop real products. Add `products` and `product_variants` tables with a
Sequel model apiece, a read-only public catalog at `/shop`, full product
management inside the existing `/admin` namespace, and sample shirts seeded from
artwork already in the repo.

This is the first domain model in the application. Everything built before it was
views-only, with the single exception of page view recording.

## Decisions

Four decisions were settled before design, and the rest of this document follows
from them.

**Scope is admin management plus a read-only public catalog.** No cart, no
add-to-cart, no checkout integration. The existing checkout page keeps its
hardcoded placeholder markup; wiring it to real products is separate work.

**Sizes are rows in a `product_variants` table, not an array column.** A shirt in
2XL routinely costs more than the same shirt in M, and a variant row is
somewhere to hang that price. It is also the thing an order line item will
eventually reference: pointing at a variant pins down exactly what was bought,
where a size string does not. The cost is one extra table and a join.

**Images are a filename in a column, not uploads.** ActiveStorage is not
available here — it is built on ActiveRecord, and `config/application.rb`
deliberately omits `active_record/railtie` because Sequel owns `database.yml`.
Making it work would mean booting ActiveRecord alongside Sequel with its own
connection, which is a larger change than this feature justifies. Shrine is the
Sequel-native alternative and remains the right answer when uploads are actually
wanted. For now `products.image` holds a filename resolved against
`app/assets/images/`, which is enough to seed real-looking products today and
does not paint us into a corner.

**Every product carries the same six sizes.** `S, M, L, XL, 2XL, 3XL`, fixed. The
admin form shows six rows, each with a price and an availability checkbox. This
keeps the form to a single page with no add-remove JavaScript, lets `size` be
validated against a known set, and makes a 2XL upcharge just a different number
in a box.

## Data model

Money is stored as integer cents everywhere. No floats, no decimals.

### `products`

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `name` | String | not null |
| `slug` | String | not null, unique index |
| `description` | String (text) | |
| `image` | String | nullable; filename under `app/assets/images/` |
| `base_price_cents` | Integer | not null |
| `active` | TrueClass | not null, default `true` |
| `created_at` | DateTime | not null |
| `updated_at` | DateTime | not null |

### `product_variants`

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `product_id` | foreign key → `products` | not null, `on_delete: :cascade` |
| `size` | String | not null, one of `Product::SIZES` |
| `price_cents` | Integer | not null |
| `available` | TrueClass | not null, default `true` |
| `position` | Integer | not null |
| | | unique index on `[product_id, size]` |

A real foreign key with cascade delete, unlike `page_views.account_id`. The
reasoning differs: a page view should outlive the account that made it, whereas a
variant is owned by its product and is meaningless without it.

`position` exists so the ladder renders in size order rather than alphabetically,
where `2XL` would sort before `S`.

### Migration notes

Sequel migration syntax, one migration creating both tables:

```ruby
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
      String    :size, null: false
      Integer   :price_cents, null: false
      TrueClass :available, null: false, default: true
      Integer   :position, null: false

      index [ :product_id, :size ], unique: true
    end
  end
end
```

Run in both environments (`bin/rails db:migrate` and `RAILS_ENV=test bin/rails
db:migrate`) and commit the regenerated `db/schema.rb`.

## Models

```ruby
class Product < Sequel::Model
  SIZES = %w[S M L XL 2XL 3XL].freeze

  one_to_many :variants, class: :ProductVariant, order: :position
  plugin :validation_helpers
  plugin :timestamps, update_on_create: true
  plugin :boolean_readers
end
```

Validations: `name` and `slug` present; `slug` unique and formatted
`/\A[a-z0-9-]+\z/`; `base_price_cents` present and not negative.

```ruby
class ProductVariant < Sequel::Model
  many_to_one :product
  plugin :validation_helpers
  plugin :boolean_readers
end
```

Validations: `size` included in `Product::SIZES`; `price_cents` present and not
negative; `[product_id, size]` unique.

`Product` gains two query helpers used by both the catalog and the admin list:

- `Product.published` — a `dataset_module` scope: `where(active: true).order(:name)`.
  Named `published` rather than `active` so it cannot be misread as the `active`
  column, which `boolean_readers` already exposes on instances as `#active?`.
- `#price_range` — returns `[min, max]` of `price_cents` across **available**
  variants, so a card can render `$12.00` or `$12.00 – $14.00` without the view
  doing arithmetic. When a product has no available variants, it falls back to
  `[base_price_cents, base_price_cents]` so the catalog still shows a price
  rather than blank or nil.

Sequel does not have `accepts_nested_attributes_for`. Variant writes are handled
explicitly in the controller rather than through a model plugin, so the data flow
stays readable.

## Routes

```ruby
# public
get "shop"       => "shop#index", as: :shop
get "shop/:slug" => "shop#show",  as: :shop_product

# inside the existing admin namespace
namespace :admin do
  resources :products, except: [ :show ]
end
```

`/shop` rather than `/products` because the homepage already says SHOP. The
public product route is keyed by slug, not id.

`except: [:show]` — the admin has no separate detail view; the edit form is the
detail view.

## Controllers

**`ShopController < ApplicationController`** — public, no `authenticate`.
`#index` lists active products with their variants; `#show` finds by slug and
raises `ActionController::RoutingError` when the product is missing or inactive,
so an unpublished product 404s rather than leaking its existence.

**`Admin::ProductsController < Admin::BaseController`** — inherits
`before_action :require_superuser`, so the superuser gate and its 404-not-403
behaviour apply with no extra code. Actions: `index`, `new`, `create`, `edit`,
`update`, `destroy`.

`create` and `update` write the product and its six variants in a single
transaction (`Product.db.transaction`), so a validation failure on one variant
cannot leave a half-updated ladder behind. On failure they re-render the form
with the submitted values and the model's errors.

Parameters are read explicitly by key rather than mass-assigned.

## Views

All pages follow the existing conventions: wrapped in `<div class="bg-white
text-ink">`, built from the `shared/` partial vocabulary, using the
`font-display` / `text-ink` / `brand-green` / `brand-orange` tokens.

**`admin/products/index`** — `shared/page_header` ("ALL / PRODUCTS."),
`admin/tabs`, then a `shared/data_table` with thumbnail, name, price range, count
of available sizes, a `shared/status_badge` for active or draft, and an edit
link. `shared/empty_state` when there are no products.

**`admin/products/_form`** — shared by `new` and `edit`. Name, slug, description,
image filename with a live preview, base price, then six fixed size rows. Follows
the app's form convention: `form_with ... data: { turbo: false }`. Validation
errors render inline above the form.

**`admin/products/new` / `edit`** — thin wrappers around the form partial. The
edit page also carries the delete button.

**`shop/index`** — page header, then a responsive grid of product cards: image,
name, price or price range.

**`shop/show`** — large image, name, description, price, and the size ladder.
Unavailable sizes render struck through and greyed rather than being hidden, so
"2XL sold out" reads correctly instead of looking like 2XL was never offered.

**Navigation** — a "Shop" link joins "Contact" in
`app/views/layouts/partials/_navigation.html.erb`. A fifth "Products" tab joins
the admin sub-nav in `app/views/admin/_tabs.html.erb`.

**`ApplicationHelper#price(cents)`** — formats integer cents for display. One
helper, used by every page that shows money.

## Sample data

`db/seeds.rb`, idempotent on slug so re-running changes nothing. Three shirts
built from artwork already in `app/assets/images/`:

| Name | Slug | Image | S–XL | 2XL–3XL | Notes |
|---|---|---|---|---|---|
| 3 Crow | `3-crow` | `3crow.png` | $12.00 | $14.00 | all sizes available |
| See That Shit | `see-that-shit` | `see_that_shit.png` | $12.00 | $14.00 | 3XL unavailable |
| Third Eye Smiley | `third-eye-smiley` | `3rd_eye_smiley.png` | $12.00 | $14.00 | all sizes available |

Pricing follows the homepage, which advertises $12 a shirt. One product ships
with 3XL marked unavailable so the sold-out treatment on `/shop/:slug` is
visible without anyone having to edit data first.

All three seed as `active: true`. The inactive case is covered by tests rather
than by seed data, so the catalog looks complete on a fresh database.

Loaded with `bin/rails db:seed`.

## Testing

Tests run serially against a real PostgreSQL database and must clean up after
themselves; there are no transactional tests. Every test that creates products
deletes them in teardown.

**Model tests** — slug uniqueness and format; `size` rejected when outside
`Product::SIZES`; negative prices rejected; cascade delete removes variants with
their product; `price_range` across mixed variant prices.

**Admin authorization** — every product route (`index`, `new`, `create`, `edit`,
`update`, `destroy`) redirects when signed out and 404s for a signed-in
non-superuser. This matters more than usual because these are the first routes
that change state.

**Admin CRUD** — a real round trip: create a product and assert the row and six
variants exist; update it and assert the values changed; delete it and assert
both the product and its variants are gone. Invalid input re-renders the form and
writes nothing.

**Public catalog** — `/shop` lists active products and omits inactive ones;
`/shop/:slug` renders a product and 404s for an unknown or inactive slug;
unavailable sizes appear but are marked.

## Risks and notes

**These are the first non-GET routes in the application.** Everything prior was a
read. CSRF protection is on outside the test environment, flash messages have not
been exercised, and validation error rendering is new. This is where the tests
should be most thorough.

**Hard delete.** Nothing references products yet, so removing a row is safe today.
`active` is the normal unpublish mechanism; delete is for mistakes. Once order
line items reference variants, delete must become archive-only or it will orphan
order history. Worth revisiting then, not now.

**The page view collector records `/shop` traffic.** That is desirable — the
traffic page will start showing real product interest — but it is a reminder that
every public page render writes a row synchronously.

**Image filenames are unvalidated against the filesystem.** A typo yields a broken
image rather than an error. The admin form's live preview makes this visible at
entry time, which is the cheap mitigation.

## Out of scope

Cart and add-to-cart. Checkout integration. File uploads. Stock or inventory
counts. Categories, tags, or collections. Product search and filtering. Bulk
operations. Multiple images per product. Colour as a variant axis — this shop
prints on a single garment colour per design, and adding a second axis now would
double the variant grid for no current benefit.

## Inherited constraints

These hold across the codebase and apply to this work:

- **Sequel, not ActiveRecord.** Models subclass `Sequel::Model`; migrations are
  `Sequel.migration do change do ... end end`. There is no `ApplicationRecord`
  worth inheriting.
- **Run the suite as `bin/rails test test/`.** Bare `bin/rails test` triggers
  sequel-rails' test database maintenance, which tries to drop and recreate
  through `template1`; the managed cluster rejects that.
- **Do not remove the `setup_fixtures` / `teardown_fixtures` overrides** in
  `test/test_helper.rb`. Without them every test errors before its body runs.
- **Do not run `bin/rails tailwindcss:build`.** The `bin/dev` watcher handles CSS.
- **`bin/rubocop` and `bin/brakeman --no-pager` both run in CI** and must exit 0.
