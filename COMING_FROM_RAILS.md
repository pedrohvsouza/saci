# Coming from Rails

Saci uses Rails vocabulary on purpose, so most concepts carry over. This
guide covers what is different: how a Saci app is put together, where
each Rails component lives, which gems are already built in, and what is
not supported.

## Mental model

| Rails | Saci |
|---|---|
| Ruby, interpreted, autoloaded | Crystal, compiled into one binary; files are `require`d (generated apps use globs) |
| `rails server` (Puma, Rack) | `saci serve` runs your entrypoint; `Application#listen` on stdlib `HTTP::Server` |
| Edit, then refresh | `saci serve --watch` rebuilds and restarts in a few seconds |
| `rails console` | `saci console` compiles each line; `saci runner` runs scripts in app context |
| `config/application.rb` | `src/<app>.cr`, `config/environments/*.cr`, `config/initializers/*.cr`, `Saci.configure` |
| `config/routes.rb` | `Router.new.draw { \|r\| ... }`, optionally `Routes.define` for compile-time helpers |
| `app/models`, `app/controllers`, `app/views` | `src/models`, `src/controllers`, `src/views` (ECR) |
| `db/schema.rb` | `db/schema.cr` (`saci db:schema:dump`) |
| Gems | Shards, compiled from source; many common gems have built-in equivalents |

## Language-level differences

- **No runtime reflection.** There is no `send`, `constantize`,
  `method_missing` or `eval`. Controller dispatch, job lookup, mailbox
  routing, polymorphic associations and named routes are generated at
  compile time by macros and `inherited` hooks. As a result:
  - Any public method on a controller that takes no arguments is an
    action. Make helpers private or give them parameters.
  - Avoid public zero-argument methods that take a block, and public
    zero-argument class methods, in controllers.
  - Dynamic finders are declared explicitly: `define_finders :email`.
- **Static types.** Model columns carry types
  (`column title : String`) and every attribute is nilable. Job
  payloads, mailer params and cache values cross a JSON or tagged-string
  boundary, so pass ids and scalars, not objects.
- **Symbols are compile-time.** Crystal cannot turn a string into a
  symbol at runtime. APIs that take symbols (locales, roles, params keys)
  also accept strings, and `Hash#symbolize_keys` returns an
  indifferent-access wrapper.
- **ECR, not ERB.** Templates are compiled into the binary, so you cannot
  edit them at runtime. `<%= %>` does **not** escape; use `h()`. Helpers
  that build HTML escape their own arguments.
- **Shared-heap concurrency.** Fibers, optionally across threads with
  `-Dexecution_context`. There are no worker processes, so request state
  must live in the request, a fiber-local slot, or the database. Saci's
  own state (transactions, locale, time zone, `Current`, auth context)
  is scoped per fiber.

## Component map

Rails namespaces its framework classes (`ActionController::Base`,
`ActiveRecord::Base`). Saci's live in the `Saci` module, which
`require "saci"` includes at the top level, so app code writes the short
names used below:

```crystal
class PostsController < Controller   # Saci::Controller
end

class Post < Record::Base            # Saci::Record::Base
end
```

Module methods keep the prefix, like `Rails.logger`: `Saci.config`,
`Saci.logger`, `Saci.env`. Top-level names your app defines win, so an app
`Session` model stays yours, and `Time` and `DB` are always the stdlib and
crystal-db ones. Compile with `-Dsaci_namespaced` to keep every framework
type behind `Saci::`.

| Rails component | Saci |
|---|---|
| Action Dispatch routing | `Router`: `resources`, `resource`, `namespace`, `scope`, `member`/`collection`, `shallow`, `concern`, `direct`, `resolve`, `mount`, constraints, optional segments, redirects |
| Rack middleware | `config.middleware` with plain `HTTP::Handler`s. Built in: CORS, HostAuthorization, RemoteIp, Static, gzip, SSL, request body limit, `/up`, exceptions app |
| Action Controller | `Controller`: filters (including `around_action` and `prepend_*`), `rescue_from`, `respond_to`, `render`, `redirect_back`, strong params / `params.expect`, `rate_limit`, `allow_browser`, HTTP auth, conditional GET |
| Action View | ECR templates, layouts, partials, `content_for`, form builders, tag/text/number/date helpers, fragment caching |
| Asset pipeline (Propshaft) | `Assets` manifest with fingerprinted names and tag helpers |
| importmap-rails, Turbo, Stimulus | `Importmap`, `Turbo` (frames and streams), vendored Turbo Drive and Stimulus subsets |
| Active Record | `Record::Base`: associations, validations, callbacks, dirty tracking, enums, nested attributes, locking, bulk writes, batching, `explain`, multiple databases |
| Active Record migrations | `Record::Migration` (reversible `change`, `change_table`, `reversible`, `revert`, introspection, PostgreSQL native types) plus `db/schema.cr` |
| Active Job / Solid Queue | `Job` with the `:db` adapter (`SKIP LOCKED` claims, dead letters, priorities, uniqueness, batches, continuations) and `Recurring` |
| Action Mailer | `Mailer::Base` (SMTP, sendmail, SendGrid/Mailgun/Postmark/SES, DKIM, attachments, callbacks, previews) |
| Action Mailbox | `Mailbox` |
| Active Storage | `Storage` (disk, S3, mirror services, blobs, `has_one_attached`/`has_many_attached`, direct uploads, vips/ImageMagick variants, PDF/video previews) |
| Action Text | `RichText` (sanitized storage, attachments) |
| Action Cable / Solid Cable | `Cable` (in-process, Redis or database fan-out) |
| Rails.cache / Solid Cache | `Cache` (memory, Redis, database), `PageCache` |
| Active Support | durations, time zones, `Date`, inflections, core extensions, `CurrentAttributes`, notifications, I18n |
| Credentials | `config/credentials.yml.enc`, `saci credentials:*` |
| `rails new` / generators | `saci new`, `saci generate`, `saci destroy`, `saci app:update` |
| Minitest helpers | `saci/testing`: fixtures, factories, transactional tests, assertions, time travel, `assert_select`, `TestSession` |
| Kamal / Thruster | Kamal 2 config generated by `saci new`; `bin/thrust` documents the proxy setup (no bundled proxy) |

## Common gems and their Saci equivalents

| Gem | Saci |
|---|---|
| Devise, Sorcery, `has_secure_password` | Auth helpers (`login`, `current_user`, `require_login`), `has_secure_password`, `authenticate_by`, `generates_token_for`, `saci g authentication` |
| Pundit, CanCanCan, ActionPolicy | `Policy` (roles, `can`, scopes), `authorize!`, `policy_scope` |
| ActiveModel::Serializers, Jbuilder | `Serializer(T)` |
| Ransack | `Search` with `searchable_attributes` |
| PaperTrail, Audited | `Auditable` |
| Kaminari, Pagy | `Pagination` |
| Sidekiq, GoodJob | `:db` job adapter (there is no Redis queue adapter) |
| sidekiq-cron, whenever | `Recurring` |
| Rack::Attack | `Throttle` |
| rack-cors | `Middleware::CORS` |
| graphql-ruby | `GraphQL` |
| caxlsx, Prawn, csv | `Office` (XLSX, PDF, CSV) |
| jwt, rotp | `JWT`, `TOTP`, `has_two_factor` |
| FactoryBot, fixtures | `Testing::Factory`, `Testing::Fixtures` |
| Searchkick (basic search) | SQLite FTS5 through `Record::FTS` |
| ActiveAdmin, Administrate | `saci g admin` scaffold |
| Sentry hooks | `Saci.error_reporter = ->(ex : Exception) { ... }` |

## API differences worth knowing

- **Models**
  - Declare columns in the model: `column name : Type`, and `timestamps`.
  - Callbacks: `before_validation`, `before_/after_save`,
    `before_/after_create`, `before_/after_update`,
    `before_/after_destroy`, `around_save/create/update/destroy` and
    `after_commit` (`on: :create | :update | :destroy`). Halt a save or
    destroy with `throw_abort` instead of `throw :abort`. There is no
    `after_validation`, `after_initialize`, `after_find`, `prepend:` or
    `if:`/`unless:` on callbacks.
  - `scope :published, -> { where(published: true) }` works and chains
    (`Post.published.recent`, `author.posts.published`). Lambda arguments
    need types: `scope :by, ->(id : Int64) { where(author_id: id) }`.
    There is no `default_scope`.
  - Use `model_enum` instead of `enum` (`enum` is a reserved word in
    Crystal).
  - `t.references` does not add a foreign key unless you pass
    `foreign_key: true`.
  - SQLite cannot add a foreign key or check constraint to an existing
    table. Declare them inside `create_table`.
- **Controllers**
  - `params["id"]?` returns a nilable `String`. Nested data comes from
    `params.require(...).permit(...)`, `params.expect(...)` and
    `params.dig(...)`.
  - The empty-array form of `permit` needs a type annotation:
    `tags: [] of String`.
- **Rendering**
  - `render_template :show` replaces implicit rendering. An action that
    never renders returns a 500 that tells you so.
  - `render_partial("comments/comment", collection: list)` renders a
    collection.
  - Partial files have no leading underscore: `render_partial("shared/header")`
    reads `src/views/shared/header.ecr`, not `_header.ecr`.
  - `<% content_for(:head) do %>...<% end %>` and `capture` work with ECR
    blocks as in ERB. Print the slot with `<%= content_for(:head) %>`.
  - Assets live in `src/assets` (served directly in development).
    `saci assets:precompile` replaces `rails assets:precompile`.
- **Routes**
  - Routes are values, not a global file. Draw them on a router and pass
    the router to `Application`.
  - Compile-time helpers need `Routes.define`. Otherwise use
    `path_for(:post, id)`.
- **Mailers**
  - Actions are class methods (`def self.welcome`). Use `with(...)` for
    parameterized mailers.
- **Jobs**
  - `perform(payload : JSON::Any)` takes a single JSON payload.
    `perform_later` accepts named tuples and hashes, and records are
    encoded as GlobalID references.
- **Drivers**
  - Saci never requires a database driver. Add `pg` or `mysql` to your
    app's `shard.yml` and require it yourself (`saci new --db=...` does
    this).

## Not supported

- Autoloading, in-process code reloading, a real REPL, and breakpoints or
  step debugging. These depend on runtime evaluation, which Crystal does
  not have.
- Engines and Rack middleware gems.
- Single-table inheritance, `delegated_type`, composite primary keys,
  Active Record encryption, async queries, `strict_loading`,
  `store_accessor` and `normalizes`.
- Browser-driven system tests. `saci g system_test` generates an HTTP
  integration test.
- GIS / PostGIS types.
- A bundled HTTP/2 proxy in place of Thruster.
