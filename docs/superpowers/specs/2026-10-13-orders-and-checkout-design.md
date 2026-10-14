# Orders and Checkout — Design

**Date:** 2026-10-13
**Status:** Draft, awaiting review
**Builds on:** `2026-10-13-flexible-product-options-design.md` (products,
variants, stock)

## Goal

Let people buy from the shop. A visitor fills a cart, chooses free pickup in
McComb or flat-rate shipping, and pays on Stripe's hosted Checkout page. Guests
can check out without an account. Paid orders decrement stock and appear in the
admin, where the owner moves each one through whatever processing steps it
needs. Signed-in customers see their orders in the dashboard. Sales tax is a
switch the owner can turn on once the business is set up to collect it.

This replaces the mockups at `app/views/admin/orders/index.html.erb`,
`app/views/dashboard/orders.html.erb`, the "Recent orders" panel on
`app/views/dashboard/index.html.erb`, and removes
`app/views/dashboard/checkout.html.erb`.

## Decisions

| Question | Decision |
|---|---|
| Payment | Stripe Checkout (hosted), card only (includes Apple Pay / Google Pay) |
| Accounts | Guest checkout allowed; signed-in orders carry `account_id` |
| Delivery | Free pickup in McComb, or one flat shipping rate per order set in the admin |
| Tax | Off by default. When on, one admin-set Mississippi rate applies to MS shipping addresses and to every pickup; nothing elsewhere |
| Statuses | Owner picks any post-payment status from a dropdown; no forced sequence |
| Refunds | Done in the Stripe dashboard; a webhook records them; stock is never restored automatically |
| Overselling | Re-check stock at checkout start; if two payments still land for the last unit, both succeed, stock floors at 0, and the later order is flagged `oversold` |
| Cart storage | The Rails session; no cart tables |
| Order creation | A `pending` order is saved when checkout starts; the webhook marks it paid |
| Receipts | Sent by Stripe (`receipt_email`); the app sends no email |

## Data model

One migration adds three tables.

### `orders`

| Column | Type | Notes |
|---|---|---|
| `id` | serial PK | |
| `number` | text, unique, not null | Public reference `BS-<id + 1000>`, set after insert |
| `token` | text, unique, not null | `SecureRandom.urlsafe_base64(24)`; the key to `/orders/:token` |
| `account_id` | bigint, nullable, FK accounts ON DELETE SET NULL | Set when the buyer was signed in at checkout |
| `email` | text, nullable | From Stripe after payment |
| `status` | text, not null, default `pending` | See statuses |
| `fulfillment` | text, not null | `pickup` or `shipping` |
| `subtotal_cents` | integer, not null | Sum of item lines |
| `shipping_cents` | integer, not null, default 0 | Flat rate at checkout time; 0 for pickup |
| `tax_cents` | integer, not null, default 0 | What Stripe actually charged |
| `total_cents` | integer, not null | Estimate at checkout; replaced with Stripe's `amount_total` when paid |
| `tax_rate_bps` | integer, nullable | Rate offered at checkout (700 = 7%); null when tax was off |
| `refunded_cents` | integer, not null, default 0 | From `charge.refunded` |
| `ship_name` | text, nullable | From Stripe, shipping orders only |
| `ship_address` | text, nullable | JSON of Stripe's address hash |
| `tracking_number` | text, nullable | Admin-entered |
| `oversold` | boolean, not null, default false | Set by the fulfiller |
| `stripe_session_id` | text, unique, nullable | Set right after the session is created |
| `stripe_payment_intent_id` | text, nullable, indexed | Used to match refunds |
| `paid_at` | timestamp, nullable | |
| `created_at`, `updated_at` | timestamp | |

**Statuses:** `pending`, `paid`, `printing`, `ready_for_pickup`, `shipped`,
`completed`, `cancelled`, `refunded`. Only the app sets `pending` and the
transition to `paid`. The admin dropdown offers every status except `pending`,
in that order, and accepts any of them at any time.

### `order_items`

| Column | Type | Notes |
|---|---|---|
| `id` | serial PK | |
| `order_id` | FK orders ON DELETE CASCADE, not null | |
| `variant_id` | FK product_variants ON DELETE SET NULL, nullable | |
| `product_name` | text, not null | Snapshot |
| `variant_label` | text, not null | Snapshot of `ProductVariant#label` |
| `sku` | text, nullable | Snapshot |
| `unit_price_cents` | integer, not null | Snapshot of `ProductVariant#price_cents` |
| `quantity` | integer, not null, > 0 | |

Because items keep their own snapshot, products and variants stay deletable;
past orders still show exactly what was bought.

### `store_settings`

A single row, loaded with `StoreSetting.current` (creates the row with defaults
if missing).

| Column | Type | Default |
|---|---|---|
| `id` | serial PK | |
| `shipping_cents` | integer, not null | 800 ($8.00, a placeholder to change in the admin) |
| `pickup_instructions` | text, not null | `"Pickup in McComb, MS. We'll reach out when it's ready."` |
| `tax_enabled` | boolean, not null | false |
| `tax_rate_bps` | integer, nullable | null |
| `stripe_tax_rate_id` | text, nullable | null |
| `updated_at` | timestamp | |

## Cart

- Stored as `session[:cart]`, a hash of `variant_id (string) => quantity`.
- A `Cart` PORO wraps it: `add(variant_id, qty)`, `update(variant_id, qty)`,
  `remove(variant_id)`, `lines` (loads variants with products, eager),
  `subtotal_cents`, `count`, `clear`.
- `lines` silently drops entries whose variant no longer exists or whose
  quantity is not a positive integer, and writes the cleaned hash back.
- Each line reports `available?`: false when the product is unpublished or the
  variant has 0 stock. Unavailable lines show a note and are excluded from
  checkout and from the subtotal.
- Quantities are capped at the variant's current stock on add and update.
- Adding an unknown, unpublished, or sold-out variant is refused with a flash
  message.

### Routes and pages

- `POST /cart/items` (`variant_id`, `quantity`) — from the product page's
  **Add to cart** button, which posts the variant the picker selected.
- `PATCH /cart/items/:variant_id` (`quantity`), `DELETE /cart/items/:variant_id`.
- `GET /cart` — lines (image, product name, variant label, unit price,
  quantity form, remove), subtotal, and the delivery choice:
  - **Pickup in McComb — Free**, with the pickup instructions.
  - **Ship it — $X flat**.
  - When tax is on: "Mississippi sales tax is added at checkout for MS addresses
    and pickups."
  - Empty cart: an empty state linking to the shop.
- The navigation shows a cart link with the item count.

## Checkout

`POST /checkout` (`fulfillment` = `pickup` | `shipping`):

1. Reject an empty cart or an unknown fulfillment value (back to `/cart` with a
   message).
2. Re-check stock for every available line inside a transaction. If any
   quantity exceeds stock, cap or drop the line in the cart, redirect to `/cart`
   with a message naming what changed, and create nothing.
3. Save a `pending` order with item snapshots, `subtotal_cents`,
   `shipping_cents` (flat rate or 0), `tax_rate_bps` (when tax is on),
   `account_id` (when signed in), and an estimated `total_cents` (subtotal +
   shipping).
4. Create the Checkout Session through `StripeGateway`:
   - `mode: "payment"`, `payment_method_types: ["card"]`
   - `line_items`: one per item, `price_data` with `currency: "usd"`,
     `unit_amount` from the snapshot, `product_data.name` = "Product — Variant
     label" (just the product name for a simple product)
   - Shipping orders: `shipping_address_collection: { allowed_countries: ["US"] }`
     and one `shipping_options` entry with `fixed_amount` = the flat rate,
     display name "Flat rate shipping"
   - Tax on: shipping orders put the stored tax rate in each line's
     `dynamic_tax_rates`; pickup orders put it in each line's `tax_rates`. Tax
     applies to items only, not shipping (manual tax rates can't be attached to
     a shipping option).
   - `customer_email` when signed in. Receipts go to the email entered on
     Stripe's page, sent by Stripe once "Email customers about successful
     payments" is on in the Stripe dashboard
   - `metadata: { order_id: }`, `client_reference_id: order.number`
   - `expires_at`: 30 minutes from now
   - `success_url`: `/orders/:token`, `cancel_url`: `/cart`
5. Save `stripe_session_id`, redirect (303) to the session URL.

If the Stripe call raises, delete the pending order and redirect to `/cart`
with "Checkout is unavailable right now, try again shortly."

### Tax rate object

Stripe tax rates are immutable. When the admin saves settings with tax on and a
rate that differs from the one behind `stripe_tax_rate_id` (or no id yet), the
app creates a new Stripe tax rate (`display_name: "Sales tax"`,
`jurisdiction: "MS"`, `country: "US"`, `state: "MS"`, `percentage`,
`inclusive: false`) and stores its id. Turning tax off keeps the id for reuse.
If creating the rate fails, the settings are not saved and the form shows an
error.

Owner note: Mississippi generally taxes shipping charges too; confirm with
whoever handles the tax filing.

## Fulfilment and webhooks

### `OrderFulfiller`

`OrderFulfiller.new(order, session).call`, where `session` is a Stripe Checkout
Session object (or the fake's equivalent):

1. In a transaction, reload the order `FOR UPDATE`. If it is not `pending`, or
   `session.payment_status != "paid"`, return without changes.
2. Set `email` (`session.customer_details.email`), `ship_name` and
   `ship_address` (from `session.shipping_details` / collected shipping, when
   present), `tax_cents` (`session.total_details.amount_tax`), `total_cents`
   (`session.amount_total`), `shipping_cents`
   (`session.total_details.amount_shipping`), `stripe_payment_intent_id`,
   `paid_at = now`, `status = "paid"`.
3. For each item: lock the variant row; if the variant is gone or its stock is
   below the quantity, set `oversold = true`; set stock to
   `max(stock - quantity, 0)`.

It is safe to call any number of times; only the first call changes anything.

### Two triggers

- **Webhook `checkout.session.completed`** — find the order by
  `metadata.order_id` and confirm `stripe_session_id` matches; run the
  fulfiller.
- **Success page** — if the order is still `pending` and has a
  `stripe_session_id`, retrieve the session from Stripe and run the fulfiller.
  If Stripe errors or the session is unpaid, show "Payment received,
  confirming your order…" and refresh the page every 3 seconds (meta refresh,
  at most 10 times via a `tries` query param, then show "We're still confirming
  your payment. Check back in a minute.").

On the success page the cart is cleared once the order is `paid`.

### Webhook endpoint

`POST /stripe/webhooks`, no CSRF, no authentication. Verifies the signature with
`StripeGateway#construct_event(payload, signature_header)` using
`STRIPE_WEBHOOK_SECRET`; a bad or missing signature returns 400. Handled events:

- `checkout.session.completed` — as above.
- `checkout.session.expired` — delete the matching order if it is still
  `pending`.
- `charge.refunded` — find the order by `stripe_payment_intent_id`; set
  `refunded_cents = charge.amount_refunded`; if `amount_refunded >= amount`,
  set `status = "refunded"`. Stock is untouched.

Unknown events and events for orders that don't exist return 200. Any exception
while handling returns 500 so Stripe retries.

### `StripeGateway`

The only class that calls the Stripe API:

- `create_checkout_session(params) → session` (responds to `id`, `url`)
- `retrieve_session(id) → session`
- `create_tax_rate(bps) → id`
- `construct_event(payload, signature) → event`

`Rails.application.config.x.stripe_gateway` holds the instance; tests replace
it with `FakeStripeGateway`, which records the params it was given and returns
canned sessions. Keys: `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` from ENV
(`.env` in development via dotenv, `.kamal/secrets` in production). New gem:
`stripe`.

## Admin

### Orders (`/admin/orders`)

- Excludes `pending` orders. Newest first, limit 100 with a "Showing the newest
  N of M" note.
- Columns: Number, Date, Email, Items (count), Delivery (Pickup / Ship), Total,
  Status badge, plus an **Oversold** badge when set and "Partially refunded $X"
  when `0 < refunded_cents < total_cents`.
- Search (`q`) on order number or email, case-insensitive, `%` matched
  literally.
- Filter links: All · Needs action (`paid`, `printing`, `ready_for_pickup`) ·
  Pickup · Shipping · Oversold · Refunded. Unknown filters show All.

### Order page (`/admin/orders/:number`)

- Items (product, variant label, SKU, quantity, unit price, line total).
- Totals: subtotal, shipping, tax, total, refunded (when > 0).
- Customer email; shipping name and formatted address, or "Pickup in McComb".
- Link to the payment in the Stripe dashboard
  (`https://dashboard.stripe.com/payments/<payment_intent_id>`).
- One form: status dropdown (all statuses except `pending`) and tracking number.
  Saving redirects back with "Order updated." An invalid status re-renders with
  an error. Pending orders return 404 here.

### Settings (`/admin/settings`)

New admin tab. Fields: flat shipping rate (dollars), pickup instructions, tax
switch, Mississippi rate (percent, up to two decimals). Validation:

- Shipping rate: required, $0.00–$100.00.
- Pickup instructions: required, at most 500 characters.
- Tax rate: required when tax is on; 0.01%–15.00%.

When tax is off the page notes "No sales tax is being collected."

### Overview

- Two new tiles: **Orders** (paid-or-later orders in the last 7 days) and
  **Revenue** (sum of `total_cents - refunded_cents` for those orders), both
  labelled "Last 7 days".
- Recent activity gains "Order BS-1042 paid — $38.00" items at `paid_at`.

## Customer pages

### Order page (`/orders/:token`)

Anyone with the link can view it. Unknown tokens return 404. Shows the number,
date, items, totals, and status in words:

| Status | Shown as |
|---|---|
| pending | Payment received, confirming your order… (see success page) |
| paid | Paid — we're getting it ready |
| printing | Printing |
| ready_for_pickup | Ready for pickup in McComb |
| shipped | Shipped (plus "Tracking: …" when present) |
| completed | Completed |
| cancelled | Cancelled |
| refunded | Refunded |

For pickup orders it shows the pickup instructions; for shipping orders the
address. A note says "Bookmark this page to check on your order."

### Dashboard

- `/dashboard/orders` lists the signed-in account's non-pending orders (number,
  date, status, total), each linking to `/orders/:token`. Empty state links to
  the shop.
- The dashboard home "Recent orders" panel shows the latest 3 the same way.
- `/dashboard/checkout` and its view are removed, along with any links to it.

## Testing

Minitest, following the existing integration-test style. No test calls Stripe.

- **Cart:** add, update, remove; quantity capped at stock; unknown, unpublished,
  and sold-out variants refused; junk session entries cleaned without errors.
- **Checkout:** empty cart and bad fulfillment rejected; stock re-check failure
  creates no order and explains; success creates a pending order with correct
  snapshots and totals and redirects to the fake session URL; the params sent to
  the fake are correct for pickup vs shipping and tax on vs off; a gateway error
  deletes the pending order.
- **OrderFulfiller:** marks paid and copies Stripe fields; decrements stock; a
  second call changes nothing; short stock sets oversold and floors at 0; a
  deleted variant sets oversold; an unpaid session changes nothing.
- **Webhooks:** signed with the real `Stripe::Webhook::Signature` helper and a
  test secret: completed, expired, full refund, partial refund, bad signature →
  400, unknown event → 200.
- **Success page:** a late webhook is covered by the pull path; an unpaid
  session shows the confirming message; the cart is cleared once paid.
- **Admin:** orders list, search, filters, pending hidden; order page; status
  and tracking update; invalid status; settings validation; tax rate created
  only when the rate changes; overview tiles and activity; non-superusers get
  404.
- **Customer:** `/orders/:token` shows the order and 404s for unknown tokens;
  dashboard orders shows only the signed-in account's orders; recent orders
  panel; mockup placeholders gone; `/dashboard/checkout` gone.
- **Manual, before merge:** one test-mode checkout in the browser with card
  `4242 4242 4242 4242` and `stripe listen --forward-to
  localhost:3000/stripe/webhooks`, for both pickup and shipping.

## Out of scope

Emailing order links or status updates (needs SMTP), saved addresses, linking
guest orders to accounts, discount codes, Stripe Tax, multiple shipping rates,
holding stock during checkout, restoring stock on refund.
