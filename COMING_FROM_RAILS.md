# Coming from Rails

Saci uses Rails vocabulary on purpose, so most concepts carry over. This
guide covers what is different: how a Saci app is put together, where
each Rails component lives, which gems are already built in, and what is
not supported.

## Mental model

| Rails | Saci |
|---|---|
| Ruby, interpreted, autoloaded | Crystal, compiled into one binary; files are `require`d (generated apps use globs) |
| `rails server` (Puma, Rack) | `saci serve` runs your entrypoint; `Saci::Application#listen` on stdlib `HTTP::Server` |
| Edit, then refresh | `saci serve --watch` rebuilds and restarts in a few seconds |
| `rails console` | `saci console` compiles each line; `saci runner` runs scripts in app context |
| `config/application.rb` | `src/<app>.cr`, `config/environments/*.cr`, `config/initializers/*.cr`, `Saci.configure` |
| `config/routes.rb` | `Saci::Router.new.draw { \|r\| ... }`, optionally `Saci::Routes.define` for compile-time helpers |
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

| Rails component | Saci |
|---|---|
| Action Dispatch routing | `Saci::Router`: `resources`, `resource`, `namespace`, `scope`, `member`/`collection`, `shallow`, `concern`, `direct`, `resolve`, `mount`, constraints, optional segments, redirects |
| Rack middleware | `config.middleware` with plain `HTTP::Handler`s. Built in: CORS, HostAuthorization, RemoteIp, Static, gzip, SSL, request body limit, `/up`, exceptions app |
| Action Controller | `Saci::Controller`: filters (including `around_action` and `prepend_*`), `rescue_from`, `respond_to`, `render`, `redirect_back`, strong params / `params.expect`, `rate_limit`, `allow_browser`, HTTP auth, conditional GET |
| Action View | ECR templates, layouts, partials, `content_for`, form builders, tag/text/number/date helpers, fragment caching |
| Asset pipeline (Propshaft) | `Saci::Assets` manifest with fingerprinted names and tag helpers |
| importmap-rails, Turbo, Stimulus | `Saci::Importmap`, `Saci::Turbo` (frames and streams), vendored Turbo Drive and Stimulus subsets |
| Active Record | `Saci::Record::Base`: associations, validations, callbacks, dirty tracking, enums, nested attributes, locking, bulk writes, batching, `explain`, multiple databases |
| Active Record migrations | `Saci::Record::Migration` (reversible `change`, `change_table`, `reversible`, `revert`, introspection, PostgreSQL native types) plus `db/schema.cr` |
| Active Job / Solid Queue | `Saci::Job` with the `:db` adapter (`SKIP LOCKED` claims, dead letters, priorities, uniqueness, batches, continuations) and `Saci::Recurring` |
| Action Mailer | `Saci::Mailer::Base` (SMTP, sendmail, SendGrid/Mailgun/Postmark/SES, DKIM, attachments, callbacks, previews) |
| Action Mailbox | `Saci::Mailbox` |
| Active Storage | `Saci::Storage` (disk, S3, mirror services, blobs, `has_one_attached`/`has_many_attached`, direct uploads) |
| Action Text | `Saci::RichText` (sanitized storage, attachments) |
| Action Cable / Solid Cable | `Saci::Cable` (in-process, Redis or database fan-out) |
| Rails.cache / Solid Cache | `Saci::Cache` (memory, Redis, database), `Saci::PageCache` |
| Active Support | durations, time zones, `Date`, inflections, core extensions, `CurrentAttributes`, notifications, I18n |
| Credentials | `config/credentials.yml.enc`, `saci credentials:*` |
| `rails new` / generators | `saci new`, `saci generate`, `saci destroy`, `saci app:update` |
| Minitest helpers | `saci/testing`: fixtures, factories, transactional tests, assertions, time travel, `assert_select`, `TestSession` |
| Kamal / Thruster | Kamal 2 config generated by `saci new`; `bin/thrust` documents the proxy setup (no bundled proxy) |

## Common gems and their Saci equivalents

| Gem | Saci |
|---|---|
| Devise, Sorcery, `has_secure_password` | Auth helpers (`login`, `current_user`, `require_login`), `has_secure_password`, `authenticate_by`, `generates_token_for`, `saci g authentication` |
| Pundit, CanCanCan, ActionPolicy | `Saci::Policy` (roles, `can`, scopes), `authorize!`, `policy_scope` |
| ActiveModel::Serializers, Jbuilder | `Saci::Serializer(T)` |
| Ransack | `Saci::Search` with `searchable_attributes` |
| PaperTrail, Audited | `Saci::Auditable` |
| Kaminari, Pagy | `Saci::Pagination` |
| Sidekiq, GoodJob | `:db` job adapter (there is no Redis queue adapter) |
| sidekiq-cron, whenever | `Saci::Recurring` |
| Rack::Attack | `Saci::Throttle` |
| rack-cors | `Saci::Middleware::CORS` |
| graphql-ruby | `Saci::GraphQL` |
| caxlsx, Prawn, csv | `Saci::Office` (XLSX, PDF, CSV) |
| jwt, rotp | `Saci::JWT`, `Saci::TOTP`, `has_two_factor` |
| FactoryBot, fixtures | `Saci::Testing::Factory`, `Saci::Testing::Fixtures` |
| Searchkick (basic search) | SQLite FTS5 through `Saci::Record::FTS` |
| ActiveAdmin, Administrate | `saci g admin` scaffold |
| Sentry hooks | `Saci.error_reporter = ->(ex : Exception) { ... }` |

## API differences worth knowing

- **Models**
  - Declare columns in the model: `column name : Type`, and `timestamps`.
  - Callbacks: `before_validation`, `before_save`, `after_save`,
    `after_create`, `after_commit` and `after_destroy`. There is no
    `before_create`, `before_update`, `before_destroy` or `around_*`.
  - There is no `scope` macro or `default_scope`. Define class methods
    that return a `Query`.
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
- **Routes**
  - Routes are values, not a global file. Draw them on a router and pass
    the router to `Saci::Application`.
  - Compile-time helpers need `Saci::Routes.define`. Otherwise use
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
- An image processing backend for storage variants and previews. The
  processor interface is pluggable, but none is bundled.
- A bundled HTTP/2 proxy in place of Thruster.
