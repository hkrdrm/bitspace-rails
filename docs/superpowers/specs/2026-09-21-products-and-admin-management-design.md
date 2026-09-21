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

Five decisions were settled before design, and the rest of this document follows
from them.

**Scope is admin management plus a read-only public catalog.** No cart, no
add-to-cart, no checkout integration. The existing checkout page keeps its
hardcoded placeholder markup; wiring it to real products is separate work.

**A variant is a SKU: one row per size and colour combination.** This follows
directly from tracking inventory. Stock is a count of black 2XL shirts on the
shelf, and that quantity only has somewhere to live if a row means exactly one
(size, colour) pair. Six sizes across three colours is eighteen rows, each a real
countable thing.

An earlier draft of this spec treated colour as an option rather than an axis,
storing it as an array on the product. That cannot hold per-combination
inventory: it records which axes exist but not their intersection, and stock
lives in the intersection. The requirement changed; the model follows it.

**Images are a filename in a column, not uploads.** ActiveStorage is not
available here — it is built on ActiveRecord, and `config/application.rb`
deliberately omits `active_record/railtie` because Sequel owns `database.yml`.
Making it work would mean booting ActiveRecord alongside Sequel with its own
connection, which is a larger change than this feature justifies. Shrine is the
Sequel-native alternative and remains the right answer when uploads are actually
wanted. For now `products.image` holds a filename resolved against
`app/assets/images/`, which is enough to seed real-looking products today and
does not paint us into a corner.

**Sizes and colours both come from fixed sets.** Sizes are `S, M, L, XL, 2XL,
3XL`; colours come from a palette of the blanks the shop stocks. Both are
validated against code constants, and both are chosen in the admin with
checkboxes rather than free text. A print shop stocks a known set of garments, so
fixed vocabularies are honest about reality.

**Price is per size; stock is per SKU.** Colour does not change what a shirt
costs, so the admin enters six prices and they apply across every colour of that
size. Stock is the only genuinely per-SKU number, so it is the only thing entered
per cell. `price_cents` still lives on the variant row because that is what a
future order line item should read, but the form never asks for it twice.

Note that "colour" throughout means **garment** colour. The ink colour count the
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

There is no `colors` column. Which colours a design comes in is derivable from
its variants, and storing both invites drift where the list names a colour that
has no rows.

### `product_variants`

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `product_id` | foreign key → `products` | not null, `on_delete: :cascade` |
| `size` | String | not null, one of `Product::SIZES` |
| `color` | String | not null, one of `Product::COLORS` keys |
| `price_cents` | Integer | not null, >= 0 |
| `stock` | Integer | not null, >= 0, default `0` |
| `position` | Integer | not null |
| | | unique index on `[product_id, size, color]` |

**`color` is NOT NULL on purpose.** There is no such thing as a colourless
shirt — a design offered only on black is six rows with `color = 'Black'`. This
also avoids a real trap: PostgreSQL treats NULLs as distinct in unique indexes,
so a nullable `color` would silently fail to prevent duplicate rows for the
single-colour case.

**`stock` replaces an availability flag.** Zero means sold out. One concept
rather than two that can contradict each other.

`position` orders the size ladder, so it renders `S, M, L, XL, 2XL, 3XL` rather
than alphabetically, where `2XL` would sort before `S`. Colour ordering is
derived from palette order.

A real foreign key with cascade delete, unlike `page_views.account_id`. The
reasoning differs: a page view should outlive the account that made it, whereas a
variant is owned by its product and is meaningless without it.

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
      String  :size, null: false
      String  :color, null: false
      Integer :price_cents, null: false
      Integer :stock, null: false, default: 0
      Integer :position, null: false

      index [ :product_id, :size, :color ], unique: true
    end
  end
end
```

Run in both environments (`bin/rails db:migrate` and `RAILS_ENV=test bin/rails
db:migrate`) and commit the regenerated `db/schema.rb`.

No Sequel extensions are required. An earlier draft stored colours as a `jsonb`
array, which would have needed the `pg_json` extension loaded in an initializer;
dropping that column drops the prerequisite with it.

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

  one_to_many :variants, class: :ProductVariant, order: [ :position, :color ]
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

Validations: `size` included in `Product::SIZES`; `color` included in
`Product::COLORS` keys; `price_cents` and `stock` present and not negative;
`[product_id, size, color]` unique.

### Derived readers

These exist so views never do arithmetic or sorting:

- `Product.published` — a `dataset_module` scope: `where(active: true).order(:name)`.
  Named `published` rather than `active` so it cannot be misread as the `active`
  column, which `boolean_readers` already exposes on instances as `#active?`.
- `Product#colors` — the distinct colours across this product's variants, in
  palette order. This is the single source of truth for which colours a design
  comes in.
- `Product#price_range` — `[min, max]` of `price_cents` across variants. When a
  product has no variants at all, falls back to
  `[base_price_cents, base_price_cents]` so the catalog shows a price rather than
  blank.
- `Product#stock_for(size:, color:)` — the count for one SKU, `0` when no such
  row exists.
- `Product#in_stock?` — whether any variant has `stock > 0`.
- `Product#swatch_for(color)` — the palette hex, or a neutral grey for a name no
  longer in the palette, so a retired colour cannot raise on an existing product.

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
`#index` lists published products with their variants; `#show` finds by slug and
raises `ActionController::RoutingError` when the product is missing or inactive,
so an unpublished product 404s rather than leaking its existence.

**`Admin::ProductsController < Admin::BaseController`** — inherits
`before_action :require_superuser`, so the superuser gate and its 404-not-403
behaviour apply with no extra code. Actions: `index`, `new`, `create`, `edit`,
`update`, `destroy`.

`create` and `update` write the product and reconcile its variant grid in a
single transaction (`Product.db.transaction`), so a failure anywhere cannot leave
a half-built grid behind. Reconciliation is explicit, because Sequel has no
`accepts_nested_attributes_for`:

1. The submitted colour checkboxes define the colour set.
2. For each selected colour and each of the six sizes, upsert a variant with the
   price for that size and the stock from that grid cell.
3. Delete variants whose colour is no longer selected.

**Unticking a colour deletes its rows, and their stock counts with them.**
Re-ticking recreates them at zero rather than restoring the old numbers. This is
worth saying out loud in the admin UI, next to the colour checkboxes, because it
is the one destructive thing an edit can do by accident.

Parameters are read explicitly by key rather than mass-assigned.

## Views

All pages follow the existing conventions: wrapped in `<div class="bg-white
text-ink">`, built from the `shared/` partial vocabulary, using the
`font-display` / `text-ink` / `brand-green` / `brand-orange` tokens.

**`admin/products/index`** — `shared/page_header` ("ALL / PRODUCTS."),
`admin/tabs`, then a `shared/data_table` with thumbnail, name, price range, a row
of colour swatches, total units in stock, a `shared/status_badge` for active or
draft, and an edit link. `shared/empty_state` when there are no products.

**`admin/products/_form`** — shared by `new` and `edit`. Follows the app's form
convention: `form_with ... data: { turbo: false }`. Validation errors render
inline above the form. Four groups:

1. Name, slug, description, image filename with a live preview, base price,
   active toggle.
2. Colour palette as a checkbox per entry, swatch beside the name, with the
   warning about unticking.
3. Price per size — six inputs, applied across every selected colour.
4. Stock grid — one row per size, one column per colour, a number input per cell.

The grid only needs cells for selected colours, but the page is server-rendered
and a checkbox can be toggled after load. A small Stimulus controller shows and
hides grid columns as colours are ticked; the app already eager-loads Stimulus
controllers from the importmap, so this adds one file and no registration. With
JavaScript unavailable the grid renders every palette colour and the unselected
columns are ignored on save, so the form still works — it is just noisier.

**`admin/products/new` / `edit`** — thin wrappers around the form partial. The
edit page also carries the delete button.

**`shop/index`** — page header, then a responsive grid of product cards: image,
name, price or price range, and a row of small colour swatches when the product
comes in more than one colour.

**`shop/show`** — large image, name, description, price, colour selector, and the
size ladder for the selected colour. Sizes with zero stock render struck through
and greyed rather than hidden, so "2XL sold out" reads correctly instead of
looking like 2XL was never offered. A product available in a single colour shows
that colour as a label rather than a selector with one option.

The colour selector labels swatches with their names, not swatches alone — colour
is not a safe sole carrier of meaning for colourblind or screen reader users, and
two palette entries (Heather Grey and Sand) are close enough in value to be hard
to tell apart.

Because the catalog is read-only in this round, the colour selector is
presentational: it switches which size ladder is shown, with no cart to add to.
Server-rendered, one section per colour, toggled by the same Stimulus controller
pattern.

**Navigation** — a "Shop" link joins "Contact" in
`app/views/layouts/partials/_navigation.html.erb`. A fifth "Products" tab joins
the admin sub-nav in `app/views/admin/_tabs.html.erb`.

**`ApplicationHelper#price(cents)`** — formats integer cents for display. One
helper, used by every page that shows money.

## Sample data

`db/seeds.rb`, idempotent on slug so re-running changes nothing. Three shirts
built from artwork already in `app/assets/images/`, priced $12 for S–XL and $14
for 2XL–3XL, following the homepage.

| Name | Slug | Image | Colours | Stock shape |
|---|---|---|---|---|
| 3 Crow | `3-crow` | `3crow.png` | Black, White, Heather Grey | full range, varied counts |
| See That Shit | `see-that-shit` | `see_that_shit.png` | Black, Red | 3XL at zero in both colours |
| Third Eye Smiley | `third-eye-smiley` | `3rd_eye_smiley.png` | Black | single colour, exercises the label-not-selector path |

Seed stock counts vary by cell rather than being uniform, so the admin grid and
the sold-out treatment are both visible on a fresh database without anyone having
to edit data first. All three seed as `active: true`; the inactive case is covered
by tests, so the catalog looks complete out of the box.

Loaded with `bin/rails db:seed`.

## Testing

Tests run serially against a real PostgreSQL database and must clean up after
themselves; there are no transactional tests. Every test that creates products
deletes them in teardown.

**Model tests** — slug uniqueness and format; `size` rejected outside
`Product::SIZES`; `color` rejected outside `Product::COLORS`; negative prices and
negative stock rejected; the `[product_id, size, color]` uniqueness constraint
actually rejects a duplicate SKU; cascade delete removes variants with their
product; `#colors` returns distinct colours in palette order; `#price_range`
across mixed prices including the no-variants fallback; `#stock_for` returning
zero for a combination that has no row.

**Admin authorization** — every product route (`index`, `new`, `create`, `edit`,
`update`, `destroy`) redirects when signed out and 404s for a signed-in
non-superuser. This matters more than usual because these are the first routes
that change state.

**Admin CRUD** — a real round trip. Create a product with two colours and assert
twelve variants exist with the right prices and stock. Update it: change a price
and assert it applied to both colours of that size; change one stock cell and
assert only that SKU moved. Add a third colour and assert six new rows at zero
stock. Remove a colour and assert its six rows are gone. Delete the product and
assert its variants went with it. Invalid input re-renders the form and writes
nothing.

**Public catalog** — `/shop` lists published products and omits inactive ones;
`/shop/:slug` renders a product and 404s for an unknown or inactive slug; a
multi-colour product renders its selector with colour names present; a
single-colour product shows a label instead; a zero-stock size renders as sold
out rather than disappearing.

## Risks and notes

**These are the first non-GET routes in the application.** Everything prior was a
read. CSRF protection is on outside the test environment, flash messages have not
been exercised, and validation error rendering is new. This is where the tests
should be most thorough.

**Stock is recorded, not enforced.** Nothing decrements it, because there are no
orders yet. It is a number a human maintains, and the catalog reads it to decide
what looks sold out. Treating it as authoritative inventory would be wrong until
an order flow exists to reserve and decrement it.

**Unticking a colour destroys its stock counts.** Called out above; the admin UI
should say so where the choice is made.

**Hard delete.** Nothing references products yet, so removing a row is safe today.
`active` is the normal unpublish mechanism; delete is for mistakes. Once order
line items reference variants, delete must become archive-only or it will orphan
order history. Worth revisiting then, not now.

**Variant counts multiply.** Six sizes across the full six-colour palette is
thirty-six rows for one product. That is nothing at this scale, but the admin
grid gets wide, which is why the form hides unselected colour columns.

**The page view collector records `/shop` traffic.** That is desirable — the
traffic page will start showing real product interest — but it is a reminder that
every public page render writes a row synchronously.

**Image filenames are unvalidated against the filesystem.** A typo yields a broken
image rather than an error. The admin form's live preview makes this visible at
entry time, which is the cheap mitigation.

## Out of scope

Cart and add-to-cart. Checkout integration. File uploads. Stock decrements,
reservations, or low-stock alerts — nothing consumes inventory yet. Categories,
tags, or collections. Product search and filtering, including filtering by colour.
Bulk operations. Per-colour product images: a design shown on a black tee will
show that same photo when a customer picks White, which is a real limitation
worth revisiting once colours are in use. Ink colour as a pricing input.

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
