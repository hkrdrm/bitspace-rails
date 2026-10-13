# Flexible Product Options — Design

**Date:** 2026-10-13
**Status:** Draft, awaiting review
**Replaces:** the size × colour variant model in
`2026-09-21-products-and-admin-management-design.md`

## Goal

Let the shop sell anything, not only shirts in a fixed set of sizes and colours.
A product defines its own options (Size, Colour, Finish, anything else) with its
own values (S–3XL, Tie-Dye, Matte), and a variant is one combination of those
values. A product with no options is a simple item, like a sticker or a print,
with one price and one stock count.

Price lives on the product. Every variant sells at the product price unless it
has an explicit override.

## Why this replaces the September model

The September model hardcodes `Product::SIZES` and `Product::COLORS` in code and
makes every product a size × colour grid. Three requirements break it:

1. **Non-apparel items.** A sticker has neither a size nor a colour, but
   `product_variants.size` and `.color` are both NOT NULL and validated against
   the constants.
2. **One-offs and uneven ranges.** Ticking a colour always creates all six
   sizes. A one-of-a-kind shirt in L shows S, M, XL, 2XL and 3XL as "Sold out",
   which suggests they once existed.
3. **Customisable variants.** Adding a colour such as Tie-Dye means a code
   change and a deploy. Retiring one silently deletes its stock on the next save
   of any product that uses it.

Nothing references products yet (no cart, no orders), so changing the model now
is cheap. After orders exist it would not be.

## Decisions

**Options are defined per product, not globally.** Each product owns its option
names and values. "Black" on one product and "Black" on another are separate
rows. Not sharing them is what makes values customisable without side effects,
because retiring Tie-Dye on one product cannot touch another. To avoid retyping
S–3XL, the new-product form can copy the options from an existing product (see
Admin).

**A product has zero to three options.** Zero makes it a simple item. Three is
the same cap Shopify uses, and it keeps the variant table readable. A combined
cap of 100 variants per product stops a 10 × 10 × 10 explosion.

**Every product has at least one variant, always.** A simple product has exactly
one variant with no option values. Stock therefore always lives on a variant,
and a future order line item always references a variant. There is no separate
code path for "products without variants".

**Price is on the product; variants may override it.** `products.price_cents` is
the price. `product_variants.price_override_cents` is nullable, and NULL means
"use the product price". The admin leaves it blank almost always. When it is
filled in (2XL at $14 on a $12 shirt, or Tie-Dye at $18), that variant sells at
that price. One override per variant, with no rules engine and no upcharges:
anything more complex is a separate product.

**Images and swatches attach to option values.** A value can carry a swatch
(hex colour or image filename) and a product image filename. The swatch is what
the selector shows. The image replaces the main product photo when that value
is selected, which fixes the deferred "a design shown on black shows the same
photo when you pick White" limitation. Images are still filenames under
`app/assets/images/`, because uploads remain out of scope (see Risks).

**Variants are generated, not hand-built.** The admin edits options and values.
The server derives the full set of combinations and reconciles the variant rows
against it. The admin enters stock, an optional price override and an optional
SKU per row, but never adds or removes variant rows directly.

**Destructive edits need explicit confirmation.** Removing or renaming a value
deletes every variant that used it, along with its stock. When a save would
delete variants holding stock, the server refuses and re-renders the form with a
list of what would be lost and a confirmation checkbox. Deleting variants at
zero stock needs no confirmation.

## Data model

Money is integer cents everywhere, as before.

### `products` (changed)

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `name` | String | not null |
| `slug` | String | not null, unique |
| `description` | text | |
| `image` | String | nullable; filename under `app/assets/images/` |
| `price_cents` | Integer | not null, >= 0 (renamed from `base_price_cents`) |
| `active` | Boolean | not null, default true |
| `created_at`, `updated_at` | DateTime | not null |

### `product_options` (new)

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `product_id` | FK → `products` | not null, `on_delete: :cascade` |
| `name` | String | not null |
| `position` | Integer | not null |
| | | unique `[product_id, name]` |

### `option_values` (new)

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `product_option_id` | FK → `product_options` | not null, `on_delete: :cascade` |
| `name` | String | not null |
| `position` | Integer | not null |
| `swatch_hex` | String | nullable, `/\A#\h{6}\z/` |
| `swatch_image` | String | nullable; filename under `app/assets/images/` |
| `image` | String | nullable; filename under `app/assets/images/` |
| | | unique `[product_option_id, name]` |

`swatch_image` wins over `swatch_hex` when both are set. It exists for values
that a flat colour cannot represent, with tie-dye as the motivating case.

### `product_variants` (changed)

| Column | Type | Constraints |
|---|---|---|
| `id` | primary key | |
| `product_id` | FK → `products` | not null, `on_delete: :cascade` |
| `options_key` | String | not null; see below |
| `price_override_cents` | Integer | nullable, >= 0 |
| `stock` | Integer | not null, >= 0, default 0 |
| `sku` | String | nullable, unique when present |
| `position` | Integer | not null |
| | | unique `[product_id, options_key]` |

`size` and `color` are dropped. `price_cents` becomes `price_override_cents` and
nullable.

### `variant_option_values` (new join)

| Column | Type | Constraints |
|---|---|---|
| `product_variant_id` | FK → `product_variants` | not null, cascade |
| `option_value_id` | FK → `option_values` | not null, cascade |
| | | primary key on both |

### `options_key`

`options_key` is the variant's option value ids, sorted ascending and joined with
`-`, for example `"14-27"`. A simple product's only variant has `""`. It exists for
one reason: a unique index on `[product_id, options_key]` makes duplicate
combinations impossible at the database level, which a join table alone cannot
enforce. It is written only by the reconciler (below), never by a form.

`position` follows option order and then value order, so variants list as
`Black/S, Black/M, … White/S` according to how the admin ordered things.

### Cascade behaviour

Deleting a value cascades to `variant_option_values`, but **not** to the variant,
which would be left orphaned with a stale `options_key`. The reconciler therefore
always deletes affected variants explicitly, before it deletes values. The cascade
on the join table is a backstop, not the mechanism.

## Migration

One new migration. `20260921140000_create_products.rb` is not edited.

There is no real product data in any environment (confirmed 2026-10-13), so the
migration drops `products` and `product_variants` and recreates all five tables
in their new shape. There is no row conversion. Development gets its sample
products back from `bin/rails db:seed`.

Down migration: not supported. It raises, because recreating the September shape
would discard every option the new shape can express.

Run in both environments and commit the regenerated `db/schema.rb`.

## Models

```ruby
class Product < Sequel::Model
  MAX_OPTIONS  = 3
  MAX_VARIANTS = 100

  one_to_many :options,  class: :ProductOption,  order: :position
  one_to_many :variants, class: :ProductVariant, order: :position
end

class ProductOption < Sequel::Model
  many_to_one :product
  one_to_many :option_values, class: :OptionValue, order: :position
end

class OptionValue < Sequel::Model
  many_to_one :product_option
end

class ProductVariant < Sequel::Model
  many_to_one  :product
  many_to_many :option_values, join_table: :variant_option_values,
               left_key: :product_variant_id, right_key: :option_value_id
end
```

`Product::SIZES`, `Product::COLORS` and `NEUTRAL_SWATCH` are deleted.

The association is `option_values`, not `values`: `Sequel::Model#values` is the
built-in column hash, and an association by that name would replace it and
break every model method that depends on it.

### Readers

As before, these exist so views do no arithmetic or sorting.

- `Product.published`: unchanged.
- `Product#simple?`: no options.
- `Product#price_range`: `[min, max]` of effective variant prices. Equal when no
  variant has an override.
- `Product#in_stock?` and `#total_stock`: unchanged in meaning.
- `Product#swatch_option`: the first option whose values have a swatch, or nil.
  The catalog card shows this one.
- `ProductVariant#price_cents`: `price_override_cents || product.price_cents`.
  The single reader every view and every future line item should use.
- `ProductVariant#sold_out?`: `stock.zero?`. Retires the inline computation that
  the September review deferred.
- `ProductVariant#label`: the value names in option order, such as
  `"Black / L"`, or the product name for a simple product.
- `ProductVariant#value_for(option)`: the variant's value for a given option.
- `OptionValue#swatch?`: true when `swatch_hex` or `swatch_image` is present.

### Validations

- **Product:** as before (`price_cents` replaces `base_price_cents`), plus no
  more than `MAX_OPTIONS` options.
- **ProductOption:** name present and unique per product.
- **OptionValue:** name present and unique per option. `swatch_hex` format.
  `swatch_image` and `image` must resolve through the asset load path, like
  `Product#image`.
- **ProductVariant:** `stock` >= 0. `price_override_cents` >= 0 when present.
  `sku` unique when present. `options_key` unique per product, and not nil.
  This is not `validates_presence`, which treats a simple variant's `""` as
  missing.

## Reconciliation: `ProductEditor`

The September controller grew a large private section (parsing money, guards,
`rebuild_variants`), and the review flagged its duplication between `create` and
`update`. Options make this logic larger, so it moves out of the controller into a
plain Ruby object at `app/models/product_editor.rb`:

```ruby
editor = ProductEditor.new(product, params)
if editor.save   # true or false, never raises
  ...
else
  editor.errors        # field-keyed, for the form
  editor.pending_loss  # variants with stock that the save would delete
end
```

`save` does the following inside one `Product.db.transaction`:

1. Parse and validate product fields. Money parsing keeps the September rule:
   malformed input is an error, never zero.
2. Parse options, a list of `{ name, values }` where values is a list of
   `{ name, swatch_hex, swatch_image, image }`. Blank options and blank values are
   dropped. Values are matched to existing rows **by name, ignoring case**. Name
   is the identity, so a rename is a delete plus an add.
3. Compute the target combinations (the Cartesian product of the values, or a
   single empty combination for a simple product). Fail if there are more than
   `MAX_VARIANTS`.
4. Diff against existing variants by `options_key`. When the delete set holds any
   stock and `params[:confirm_loss]` is absent, populate `pending_loss`, roll
   back, and return false.
5. Delete variants no longer wanted, then delete values and options no longer
   wanted, in that order.
6. Upsert options and values with their positions and swatch and image fields.
7. Create new variants at stock 0 and update positions.
8. Apply the submitted per-variant fields (stock, price override, SKU) to
   variants that existed **before** this save, keyed by variant id. New variants
   stay at stock 0, because the admin had no cell to type into for them.
9. `product.refresh`. Still load-bearing, for the reason the September plan gives.

The controller becomes thin: build an editor, call `save`, then redirect or
re-render.

## Routes

Unchanged. `/shop`, `/shop/:slug`, and `resources :products, except: [:show]`
under `/admin`.

## Admin

### Product list (`admin/products/index`)

The columns become thumbnail, name, price (single or range), options summary
(`Size · Colour`, or `Simple item`), variant count, total stock, status and edit.
The swatch column shows the `swatch_option` values when there is one.

### Form (`admin/products/_form`)

The form works without JavaScript. JavaScript only adds conveniences.

1. **Details.** Name, slug, description, image with its live preview (unchanged),
   price, and visible-in-shop.
2. **Options.** Up to three option blocks. Each has a name field and a value
   list, where each value row has name, swatch hex, swatch image and image
   fields. Without JavaScript, the form renders the existing values plus three
   blank value rows per option and one blank option block, if fewer than three
   exist. Saving with more blanks filled grows the lists. With JavaScript, a
   small Stimulus controller adds "Add value" and "Add option" buttons and
   removes the padding rows. Value order is row order. Moving a value is done by
   editing its position field, with drag-to-reorder out of scope.
3. **Copy options from.** On `new` only, a select of existing products. Choosing
   one (a GET to `new?copy_from=<id>`) prefills the options section. This
   replaces a preset table and covers the "every tee is S–3XL" case.
4. **Variants.** Edit page only. One row per variant: label, stock, price
   override (placeholder shows the product price, blank means use it) and SKU.
   A simple product shows one row without a label column. With more than 30
   rows, the table gets a filter box via JavaScript and remains a plain table
   without it.
5. **Pending loss.** When `save` returned false because of `pending_loss`, a
   panel at the top lists each variant to be deleted with its stock ("Black / 2XL
   — 3 in stock"), and adds a required "Delete these variants and their stock"
   checkbox (`confirm_loss`).

A warning beside the options section says that removing or renaming a value
deletes its variants and their stock.

### Flow

- **Create** saves the product, options and generated variants (all at stock 0),
  then redirects to **edit**, with a notice such as "Created with 18 variants. Set
  stock below." Stock cannot be entered on `new`, because the rows do not exist
  until the combinations are known. This is what removes the client-side grid
  entirely: `variant_grid_controller.js` is deleted.
- **A simple product** is created with no options. `new` shows a single "Stock"
  field that applies only when no options were entered, so a simple product is
  complete after one save and create redirects to the index instead.
- **Update** redirects back to **edit** whenever the set of variants changed, so
  new rows are visible to fill in, and to the index otherwise.

Errors render inline as now. The September cosmetic issue ("Price s") goes away,
because errors now come from `ProductEditor` with written-out messages.

## Shop

### Catalog card (`shop/index`)

Price shows `From $12` when `price_range` spans values, otherwise `$12`. The
September `$12 – $14` form reads as a range but tells a customer less than
"from". Swatches show when `swatch_option` exists and has more than one value.
The card is otherwise unchanged.

### Product page (`shop/show`)

**Without JavaScript**, the page renders the image, name, description and a
**variant list**: one line per variant with its label, its effective price, and
"In stock" or a struck-through "Sold out". This is always correct, if long.

**With JavaScript**, a generalised `variant_picker` Stimulus controller (replacing
`color_switcher`) hides the list and shows:

- One button group per option, in option order. Values with a swatch render
  swatch and name. Others render the name alone. Names are always visible: the
  September accessibility rule (colour is never the sole carrier of meaning)
  carries over.
- An option with a single value renders as a label, not a one-button group (the
  generalised Third Eye Smiley case).
- Selecting values narrows the result. A value is struck through when no in-stock
  variant matches it together with the current selections in the other options.
- When every option is selected, the price shows that variant's effective price
  and an "In stock" or "Sold out" line. Before then, it shows the product price
  or "From $X".
- When the selected value of any option has an `image`, the main photo swaps to
  it. Otherwise the product image stays.

The controller reads variant data from a JSON value attribute rendered by the
server (id, option value ids, price, stock, image URL), so it never computes
prices or reads the DOM to learn availability.

**A simple product** shows price and stock state with no selectors and no
controller.

There is still no add-to-cart. The picker is presentational until a cart exists,
as in September.

## Sample data

`db/seeds.rb`, idempotent on slug. Re-running converges the three shirts to the
new shape and adds one simple item.

| Name | Options | Notes |
|---|---|---|
| 3 Crow | Size S–3XL, Colour Black/White/Heather Grey | 2XL and 3XL carry a $14 override on a $12 product. Shows the override in use. |
| See That Shit | Size S–3XL, Colour Black/Red | 3XL at zero in both colours |
| Third Eye Smiley | Size S–3XL, Colour Black | single-value option renders as a label |
| 3 Crow Sticker | none | simple item, $4, stock 50, reuses `3crow.png` |

No tie-dye seed, because there is no tie-dye artwork in the repo. Tests cover the
swatch-image path instead.

The deferred seeds clean-ups from September (`[].tap`, the `.then` chain and the
`puts` noise in test output) are done while the file is being rewritten anyway.

## Testing

Tests run serially against the shared remote database and clean up in teardown.
Never run two test processes at once.

**Model tests.** Option and value uniqueness. The `MAX_OPTIONS` cap. Swatch hex
format. Image filenames rejected when they do not resolve. `options_key`
uniqueness rejects a duplicate combination at the database. Cascade from product
deletes options, values, variants and join rows. `ProductVariant#price_cents`
with and without an override. `price_range` with mixed overrides. `label`
ordering. `swatch_option` choosing the first option with swatches.

**`ProductEditor` tests**, the bulk of the coverage and run without HTTP:

- Creating a simple product yields one variant with `options_key = ""`.
- Two options of 6 and 3 values yield 18 variants in the right order.
- Adding a value creates only the new combinations, at stock 0, and leaves
  existing stock untouched.
- Removing a value at zero stock deletes its variants without confirmation.
- Removing a value with stock returns false, sets `pending_loss`, and writes
  nothing (the whole transaction rolls back, product fields included).
- The same save with `confirm_loss` succeeds.
- Renaming a value counts as delete plus add, and the loss check applies.
- Value matching ignores case ("black" matches "Black").
- Adding a third option multiplies variants, and stock on the old variants is
  dropped through the loss check, because the old combinations no longer exist.
  This is surprising enough to be worth a test that pins it.
- Removing every option collapses to one simple variant, again through the loss
  check.
- Over `MAX_VARIANTS` is rejected and writes nothing.
- Malformed price or override is rejected, never coerced to zero.
- Per-variant stock, override and SKU apply by variant id, and ids belonging to
  another product are ignored.

**Admin integration.** Authorisation for all six routes, signed out and as
non-superuser (carried over). Create redirects to edit. The pending-loss panel
renders and the confirm checkbox completes the save. Copy-from prefills options.
The simple-product stock field on `new` works.

**Shop integration.** The no-JS variant list renders labels, effective prices and
sold-out state. A single-value option renders as a label. A simple product shows
price and stock with no selectors. Inactive products 404 (carried over). The
override price appears for the overridden variants.

## Risks and notes

**The migration drops the product tables.** That is safe only because there is
no real product data yet. If anyone adds real products before this deploys, the
migration must be rewritten to convert them instead.

**Options reshape stock.** Adding or removing a whole option changes every
combination, so every existing variant is replaced. With stock on hand, the loss
check stops this and asks for confirmation, which is correct, but the admin will
need to re-enter stock afterwards. The confirmation panel should state that
plainly.

**Images as filenames are now a real constraint.** Per-value images and swatch
images mean every new colour photo or tie-dye swatch needs a commit and a deploy
to land in `app/assets/images/`. That was tolerable for one image per product.
It is not tolerable for a shop that adds variants often. Uploads (Shrine, which
is Sequel-native) should be the next piece of work after this one, and the
filename columns are shaped so that Shrine's `*_data` columns can replace them.

**Stock is still recorded, not enforced.** Unchanged from September.

**Hard delete.** Unchanged. It must become archive-only once orders reference
variants.

**Per-product values do not aggregate.** "How many Black shirts do we have
across all designs" is a query over value names, not ids. That is acceptable at
this scale, and the reason values are per product is listed under Decisions.

## Out of scope

Cart, checkout and stock decrements. File uploads (the next piece of work, see
Risks). Global option presets or a shared colour library, where copy-from covers
the need. Drag-to-reorder. Pricing rules, upcharges or more than one override
level: a variant either uses the product price or names its own. Per-variant
weight or shipping data. Bulk stock import. Search and filtering.

## Inherited constraints

- **Sequel, not ActiveRecord.**
- **Run the suite as `bin/rails test test/`**, never bare `bin/rails test`. The
  suite takes about 400s against the remote database, so run it in the
  background, and only one test process at a time.
- **Do not remove the `setup_fixtures` / `teardown_fixtures` overrides** in
  `test/test_helper.rb`.
- **Do not run `bin/rails tailwindcss:build`.**
- **`bin/rubocop` and `bin/brakeman --no-pager` must exit 0.**
