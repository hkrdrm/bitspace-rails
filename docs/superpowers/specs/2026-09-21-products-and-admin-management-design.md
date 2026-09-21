# Products, Public Catalog, and Admin Product Management — Design

**Date:** 2026-09-21
**Status:** Approved, ready for implementation planning

## Goal

Give the shop real products. Add `products`, `product_variants` and
`product_colors` tables with a Sequel model apiece, a read-only public catalog at `/shop`, full product
management inside the existing `/admin` namespace, and sample shirts seeded from
artwork already in the repo.

This is the first domain model in the application. Everything built before it was
views-only, with the single exception of page view recording.

## Decisions

Five decisions were settled before design, and the rest of this document follows
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

**Garment colour is an option, not a second pricing axis.** The same design can
be offered on several garment colours, but a black 2XL and a white 2XL cost the
same. Colours therefore live in their own `product_colors` table rather than
multiplying the variant grid: three colours and six sizes produce nine rows, not
eighteen. Variants stay keyed on size alone, so the price form keeps its six
clean rows.

Colours are drawn from a fixed shop palette (`Product::COLORS`) and selected with
checkboxes, mirroring the decision above for sizes. A print shop stocks a known
set of blanks, so a fixed palette is honest about reality and keeps the admin
form on one page with no add-remove JavaScript.

Note that "colour" here means **garment** colour. The ink colour count the
homepage advertises ("1 or 2 colors") is a pricing input for custom work, not a
product variant, and is out of scope.

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

### `product_colors`

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `product_id` | foreign key → `products` | not null, `on_delete: :cascade` |
| `name` | String | not null, one of `Product::COLORS` keys |
| `hex` | String | not null; swatch colour, copied from the palette on write |
| `available` | TrueClass | not null, default `true` |
| `position` | Integer | not null |
| | | unique index on `[product_id, name]` |

`hex` is denormalised out of the palette constant deliberately. Storing it means
an existing product still renders its swatch correctly if the shop later retires
or restyles a palette entry, rather than breaking on a lookup that no longer
resolves.

A product with no colour rows is valid — its pages simply omit the colour
selector. That is the expected shape for a design offered on one blank.

A real foreign key with cascade delete on both child tables, unlike
`page_views.account_id`. The reasoning differs: a page view should outlive the
account that made it, whereas a variant or colour is owned by its product and is
meaningless without it.

`position` exists so the size ladder renders in size order rather than
alphabetically, where `2XL` would sort before `S`, and so colours render in
palette order rather than by name.

### Migration notes

Sequel migration syntax, one migration creating all three tables:

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

    create_table :product_colors do
      primary_key :id
      foreign_key :product_id, :products, null: false, on_delete: :cascade
      String    :name, null: false
      String    :hex, null: false
      TrueClass :available, null: false, default: true
      Integer   :position, null: false

      index [ :product_id, :name ], unique: true
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

  # The shop's stocked blanks. Order is display order.
  COLORS = {
    "Black"        => "#0d1114",
    "White"        => "#f7f7f5",
    "Heather Grey" => "#b5b8ba",
    "Navy"         => "#1b2a41",
    "Sand"         => "#d8cbb4",
    "Red"          => "#b3261e"
  }.freeze

  one_to_many :variants, class: :ProductVariant, order: :position
  one_to_many :colors,   class: :ProductColor,   order: :position
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

```ruby
class ProductColor < Sequel::Model
  many_to_one :product
  plugin :validation_helpers
  plugin :boolean_readers
end
```

Validations: `name` included in `Product::COLORS` keys; `hex` present;
`[product_id, name]` unique.

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

`create` and `update` write the product, its six variants and its selected
colours in a single transaction (`Product.db.transaction`), so a validation
failure anywhere cannot leave a half-updated ladder or a partial colour list
behind. Colour rows are reconciled against the submitted checkboxes: newly ticked
palette entries are inserted, unticked ones are deleted. On failure they re-render the form
with the submitted values and the model's errors.

Parameters are read explicitly by key rather than mass-assigned.

## Views

All pages follow the existing conventions: wrapped in `<div class="bg-white
text-ink">`, built from the `shared/` partial vocabulary, using the
`font-display` / `text-ink` / `brand-green` / `brand-orange` tokens.

**`admin/products/index`** — `shared/page_header` ("ALL / PRODUCTS."),
`admin/tabs`, then a `shared/data_table` with thumbnail, name, price range, count
of available sizes, a row of colour swatches, a `shared/status_badge` for active
or draft, and an edit link. `shared/empty_state` when there are no products.

**`admin/products/_form`** — shared by `new` and `edit`. Name, slug, description,
image filename with a live preview, base price, six fixed size rows, then the
colour palette as a checkbox per entry with its swatch shown beside the name.
Follows the app's form convention: `form_with ... data: { turbo: false }`.
Validation errors render inline above the form.

**`admin/products/new` / `edit`** — thin wrappers around the form partial. The
edit page also carries the delete button.

**`shop/index`** — page header, then a responsive grid of product cards: image,
name, price or price range, and a row of small colour swatches when the product
comes in more than one colour.

**`shop/show`** — large image, name, description, price, the size ladder, and a
colour selector. Unavailable sizes render struck through and greyed rather than
being hidden, so "2XL sold out" reads correctly instead of looking like 2XL was
never offered; unavailable colours get the same treatment.

The colour selector is swatches labelled with their names, not swatches alone —
colour is not a safe sole carrier of meaning for colourblind or screen reader
users, and two of the palette entries (Heather Grey and Sand) are close enough in
value to be hard to tell apart. A product with no colour rows omits the selector
entirely rather than rendering an empty control.

**Navigation** — a "Shop" link joins "Contact" in
`app/views/layouts/partials/_navigation.html.erb`. A fifth "Products" tab joins
the admin sub-nav in `app/views/admin/_tabs.html.erb`.

**`ApplicationHelper#price(cents)`** — formats integer cents for display. One
helper, used by every page that shows money.

## Sample data

`db/seeds.rb`, idempotent on slug so re-running changes nothing. Three shirts
built from artwork already in `app/assets/images/`:

| Name | Slug | Image | S–XL | 2XL–3XL | Colours | Notes |
|---|---|---|---|---|---|---|
| 3 Crow | `3-crow` | `3crow.png` | $12.00 | $14.00 | Black, White, Heather Grey | all sizes available |
| See That Shit | `see-that-shit` | `see_that_shit.png` | $12.00 | $14.00 | Black, Red | 3XL unavailable |
| Third Eye Smiley | `third-eye-smiley` | `3rd_eye_smiley.png` | $12.00 | $14.00 | Black | single colour, exercises the no-selector path |

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
`Product::SIZES`; `name` rejected when outside `Product::COLORS`; negative prices
rejected; cascade delete removes both variants and colours with their product;
`price_range` across mixed variant prices, including the no-available-variants
fallback.

**Admin authorization** — every product route (`index`, `new`, `create`, `edit`,
`update`, `destroy`) redirects when signed out and 404s for a signed-in
non-superuser. This matters more than usual because these are the first routes
that change state.

**Admin CRUD** — a real round trip: create a product and assert the row, its six
variants and its ticked colours exist; update it and assert the values changed,
including that unticking a colour removes that row and ticking a new one adds it;
delete it and assert the product, its variants and its colours are all gone.
Invalid input re-renders the form and writes nothing.

**Public catalog** — `/shop` lists active products and omits inactive ones;
`/shop/:slug` renders a product and 404s for an unknown or inactive slug;
unavailable sizes appear but are marked; a multi-colour product renders its
selector with colour names present, and a single-colour product omits the
selector.

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
operations. Multiple images per product — a design shown on a black tee still
uses one photo regardless of which colour the customer picks, which is a real
limitation worth revisiting once colours are in use. Per-colour pricing and
per-colour stock, which is what a full size-by-colour variant grid would buy;
colour is an option here, not a pricing axis.

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
