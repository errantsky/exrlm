# Migration Plan: Umbrella → Single Phoenix App + Boundary

## Goal

Migrate from the current umbrella structure (`apps/rlm` + `apps/rlm_web`) to a single
Phoenix 1.8 app with the `boundary` library enforcing compile-time separation between
the core engine (`RLM`) and the web dashboard (`RLMWeb`).

---

## Current State

```
exrlm/                        (umbrella root)
├── apps/
│   ├── rlm/                  OTP app :rlm — core engine
│   │   ├── lib/rlm/          RLM.*, RLM.Worker, RLM.LLM, etc.
│   │   ├── test/
│   │   └── mix.exs           deps: req, jason, telemetry, phoenix_pubsub, mox, ex_doc
│   └── rlm_web/              OTP app :rlm_web — Phoenix 1.8 dashboard
│       ├── lib/rlm_web_web/  RlmWebWeb.* (Endpoint, Router, LiveViews, etc.)
│       ├── assets/
│       ├── test/
│       └── mix.exs           deps: phoenix, phoenix_live_view, bandit, heroicons, ...
├── config/                   shared config (config.exs, dev.exs, test.exs, runtime.exs, prod.exs)
├── examples/
└── mix.exs                   umbrella root mix.exs (deps: credo)
```

**Key facts about the current setup:**
- Two OTP apps: `:rlm` and `:rlm_web`
- Web app depends on core via `{:rlm, in_umbrella: true}`
- `RLM.PubSub` is started by `:rlm` and reused by `:rlm_web` (endpoint config: `pubsub_server: RLM.PubSub`)
- Web modules use the `RlmWebWeb` namespace (double-Web, an artifact of umbrella naming)
- Separate supervision trees in each app's `application.ex`

---

## Target State

```
exrlm/                        (single Phoenix 1.8 app, OTP app: :rlm)
├── lib/
│   ├── rlm/                  RLM.* — core engine (unchanged module names)
│   │   ├── application.ex    unified supervision tree
│   │   ├── worker.ex
│   │   ├── run.ex
│   │   ├── llm.ex
│   │   ├── ...
│   │   ├── telemetry/
│   │   └── tools/
│   ├── rlm_web/              RLMWeb.* — Phoenix web layer (renamed from RlmWebWeb)
│   │   ├── endpoint.ex
│   │   ├── router.ex
│   │   ├── telemetry.ex
│   │   ├── components/
│   │   ├── controllers/
│   │   └── live/
│   ├── rlm.ex                RLM public API (unchanged)
│   └── rlm_web.ex            RLMWeb macro module (renamed from RlmWebWeb)
├── assets/                   moved from apps/rlm_web/assets/
├── priv/
│   ├── static/               moved from apps/rlm_web/priv/static/
│   ├── gettext/              moved from apps/rlm_web/priv/gettext/
│   └── system_prompt.md      moved from apps/rlm/priv/system_prompt.md
├── test/
│   ├── rlm/                  core engine tests
│   ├── rlm_web/              web tests
│   ├── support/              merged test support
│   └── test_helper.exs       merged
├── config/                   consolidated config (all :rlm_web → :rlm)
├── examples/
└── mix.exs                   single mix.exs with all deps
```

---

## Phase 0: Pre-Migration Snapshot

Before touching anything, capture the current state so we have a rollback point
and a way to verify correctness.

### 0.1 — Create a clean baseline commit
```bash
git stash           # if any uncommitted work
git checkout -b migration/single-app
```

### 0.2 — Record current test output
```bash
mix test 2>&1 | tee /tmp/pre-migration-tests.txt
mix compile --warnings-as-errors 2>&1 | tee /tmp/pre-migration-compile.txt
```

### 0.3 — Inventory all module names
```bash
# From umbrella root
grep -rh "defmodule " apps/rlm/lib/ | sort > /tmp/core-modules.txt
grep -rh "defmodule " apps/rlm_web/lib/ | sort > /tmp/web-modules.txt
```

This gives us a checklist to verify every module survived the migration.

---

## Phase 1: Generate Fresh Phoenix 1.8 Scaffold (in a temp directory)

### 1.1 — Why generate fresh?

Restructuring the umbrella in-place risks missing generated boilerplate that Phoenix
expects (endpoint config, verified routes, static paths, formatter config, etc.).
Instead, generate a fresh app and use it as the **canonical reference** for:
- `mix.exs` structure (deps, aliases, compilers, project config)
- `config/` files (endpoint, esbuild, tailwind paths — they all change in a single app)
- `lib/rlm_web.ex` macro module (verified_routes endpoint reference, static_paths)
- `assets/js/app.js` (import paths)
- Root `.formatter.exs`
- `test/support/conn_case.ex`

### 1.2 — Generation command

```bash
cd /tmp
mix phx.new rlm \
  --module RLM \
  --app rlm \
  --no-ecto \
  --no-mailer \
  --no-gettext \
  --no-install
```

This produces:
- App name: `:rlm`
- Root module: `RLM`
- Web module: `RLMWeb` (in `lib/rlm_web/`)
- No database, no mailer, no gettext
- Tailwind v4, esbuild, LiveView, LiveDashboard, Bandit all included

### 1.3 — Files to copy/reference from the scaffold

| Generated file | Purpose |
|---|---|
| `mix.exs` | **Reference** — merge deps from both umbrella apps + add boundary |
| `config/config.exs` | **Reference** — esbuild/tailwind paths, endpoint config, all under `:rlm` |
| `config/dev.exs` | **Reference** — watchers, live_reload patterns (paths differ from umbrella) |
| `config/test.exs` | **Reference** — endpoint port, secret_key_base |
| `config/runtime.exs` | **Reference** — PHX_SERVER, SECRET_KEY_BASE (single app key) |
| `config/prod.exs` | **Reference** — cache_static_manifest path |
| `lib/rlm_web.ex` | **Copy** — adapt verified_routes, static_paths, html_helpers |
| `lib/rlm/application.ex` | **Reference** — unified supervision children list |
| `.formatter.exs` | **Copy** — single-app formatter config |
| `test/support/conn_case.ex` | **Copy** — adapt endpoint reference |

---

## Phase 2: Build the Single-App `mix.exs`

### 2.1 — Merge dependencies

Current `:rlm` deps:
```elixir
{:req, "~> 0.5"},
{:jason, "~> 1.4"},
{:telemetry, "~> 1.2"},
{:phoenix_pubsub, "~> 2.1"},
{:mox, "~> 1.0", only: :test},
{:ex_doc, "~> 0.40.1", only: :dev, runtime: false}
```

Current `:rlm_web` deps (minus `{:rlm, in_umbrella: true}`):
```elixir
{:phoenix, "~> 1.8.3"},
{:phoenix_html, "~> 4.1"},
{:phoenix_live_reload, "~> 1.2", only: :dev},
{:phoenix_live_view, "~> 1.1.0"},
{:lazy_html, ">= 0.1.0", only: :test},
{:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
{:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
{:heroicons, tag: "v2.2.0", ...},
{:phoenix_live_dashboard, "~> 0.8.3"},
{:swoosh, "~> 1.16"},
{:req, "~> 0.5"},
{:telemetry_metrics, "~> 1.0"},
{:telemetry_poller, "~> 1.0"},
{:gettext, "~> 1.0"},
{:dns_cluster, "~> 0.2.0"},
{:bandit, "~> 1.5"},
{:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false}
```

Root umbrella deps:
```elixir
{:credo, "~> 1.7", only: [:dev, :test], runtime: false}
```

**Merged `mix.exs`** includes all of the above (deduplicated; `:req` appears once).

**Add boundary:**
```elixir
{:boundary, "~> 0.10", runtime: false}
```

**Decision: keep or drop Swoosh/Gettext?**

The current `rlm_web` has Swoosh and Gettext configured but the dashboard doesn't
send emails or use i18n. These were Phoenix generator leftovers. **Recommendation: drop
Swoosh entirely. Keep Gettext only if you want i18n later; otherwise drop it too.**

### 2.2 — Project config

```elixir
def project do
  [
    app: :rlm,
    version: "0.3.0",        # bump for migration
    elixir: "~> 1.19",
    elixirc_paths: elixirc_paths(Mix.env()),
    start_permanent: Mix.env() == :prod,
    compilers: [:boundary] ++ Mix.compilers(),
    aliases: aliases(),
    deps: deps(),
    listeners: [Phoenix.CodeReloader],
    # ExDoc config from current rlm app
    docs: [...]
  ]
end

defp elixirc_paths(:test), do: ["lib", "test/support"]
defp elixirc_paths(_), do: ["lib"]
```

### 2.3 — Aliases

Merge from both apps:
```elixir
defp aliases do
  [
    setup: ["deps.get", "assets.setup", "assets.build"],
    "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
    "assets.build": ["compile", "tailwind rlm", "esbuild rlm"],
    "assets.deploy": ["tailwind rlm --minify", "esbuild rlm --minify", "phx.digest"],
    precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
    test: ["test"]
  ]
end
```

**Note:** The asset profile names change from `rlm_web` to `rlm` in the esbuild/tailwind config. This must also be updated in `config/config.exs`.

---

## Phase 3: Consolidate Config Files

Every occurrence of `config :rlm_web, ...` becomes `config :rlm, ...`.

### 3.1 — `config/config.exs`

Key changes:
```elixir
# BEFORE (umbrella)
config :rlm_web, RlmWebWeb.Endpoint,
  pubsub_server: RLM.PubSub, ...

config :esbuild,
  rlm_web: [
    cd: Path.expand("../apps/rlm_web/assets", __DIR__), ...
  ]

config :tailwind,
  rlm_web: [
    cd: Path.expand("../apps/rlm_web", __DIR__), ...
  ]

# AFTER (single app)
config :rlm, RLMWeb.Endpoint,
  pubsub_server: RLM.PubSub, ...

config :esbuild,
  version: "0.25.4",
  rlm: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js
             --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.1.12",
  rlm: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
    cd: Path.expand("..", __DIR__)
  ]
```

### 3.2 — `config/dev.exs`

Key changes:
- `config :rlm_web, RlmWebWeb.Endpoint` → `config :rlm, RLMWeb.Endpoint`
- Watcher esbuild/tailwind profile: `:rlm_web` → `:rlm`
- Live reload patterns: `~r"lib/rlm_web_web/..."` → `~r"lib/rlm_web/..."`

### 3.3 — `config/test.exs`

- `config :rlm_web, RlmWebWeb.Endpoint` → `config :rlm, RLMWeb.Endpoint`
- Drop `config :rlm_web, RlmWeb.Mailer, adapter: Swoosh.Adapters.Test` (dropping Swoosh)

### 3.4 — `config/runtime.exs`

- `config :rlm_web, RlmWebWeb.Endpoint` → `config :rlm, RLMWeb.Endpoint`
- All `:rlm_web` app env reads become `:rlm`

### 3.5 — `config/prod.exs`

- Same pattern as above
- Drop Swoosh config

---

## Phase 4: Module Renaming (RlmWebWeb → RLMWeb)

This is the highest-risk phase. Every module in the web layer gets renamed.

### 4.1 — Complete rename map

| Old module | New module |
|---|---|
| `RlmWebWeb` | `RLMWeb` |
| `RlmWebWeb.Endpoint` | `RLMWeb.Endpoint` |
| `RlmWebWeb.Router` | `RLMWeb.Router` |
| `RlmWebWeb.Telemetry` | `RLMWeb.Telemetry` |
| `RlmWebWeb.Gettext` | `RLMWeb.Gettext` (if keeping gettext) |
| `RlmWebWeb.CoreComponents` | `RLMWeb.CoreComponents` |
| `RlmWebWeb.TraceComponents` | `RLMWeb.TraceComponents` |
| `RlmWebWeb.Layouts` | `RLMWeb.Layouts` |
| `RlmWebWeb.RunListLive` | `RLMWeb.RunListLive` |
| `RlmWebWeb.RunDetailLive` | `RLMWeb.RunDetailLive` |
| `RlmWebWeb.TraceDebugController` | `RLMWeb.TraceDebugController` |
| `RlmWebWeb.ErrorHTML` | `RLMWeb.ErrorHTML` |
| `RlmWebWeb.ErrorJSON` | `RLMWeb.ErrorJSON` |
| `RlmWeb.Supervisor` | *(removed — merged into RLM.Application)* |
| `RlmWeb.Mailer` | *(removed — dropping Swoosh)* |
| `RlmWeb` | *(removed — was a placeholder module)* |

### 4.2 — Strategy: `sed` in a single pass

```bash
# From project root, after files are moved to lib/
find lib/ test/ config/ -type f \( -name "*.ex" -o -name "*.exs" -o -name "*.heex" \) \
  -exec sed -i 's/RlmWebWeb/RLMWeb/g' {} +

find lib/ test/ config/ -type f \( -name "*.ex" -o -name "*.exs" -o -name "*.heex" \) \
  -exec sed -i 's/RlmWeb\.Mailer/REMOVED_MAILER/g' {} +

# Clean up config references
find config/ -type f -name "*.exs" \
  -exec sed -i 's/config :rlm_web/config :rlm/g' {} +
```

**Important:** The `RlmWebWeb` → `RLMWeb` rename is safe as a global find-and-replace
because `RlmWebWeb` is unique and unambiguous. The `config :rlm_web` → `config :rlm` rename
must NOT affect `config :rlm,` lines that already exist (targeting the core engine config) —
but since those use `config :rlm,` (no `_web`) already, the `config :rlm_web` pattern won't
match them.

### 4.3 — References in non-Elixir files

Also rename in:
- `assets/js/app.js`: the `phoenix-colocated/rlm_web` import → `phoenix-colocated/rlm`
- `assets/css/app.css`: `@source "../../lib/rlm_web_web";` → `@source "../../lib/rlm_web";`
- `mix.exs`: endpoint/alias references
- `.formatter.exs`

### 4.4 — Endpoint `otp_app` change

In the endpoint module:
```elixir
# BEFORE
use Phoenix.Endpoint, otp_app: :rlm_web

# AFTER
use Phoenix.Endpoint, otp_app: :rlm
```

This is critical — Phoenix reads config from `Application.get_env(otp_app, __MODULE__)`,
so if the OTP app name doesn't match the config key, the endpoint won't start.

---

## Phase 5: File Movement

### 5.1 — Move core engine files

```bash
# Core engine: apps/rlm/lib/rlm/ → lib/rlm/
# But NOT application.ex — we'll write a new unified one
mkdir -p lib/rlm
cp -r apps/rlm/lib/rlm/* lib/rlm/
cp apps/rlm/lib/rlm.ex lib/rlm.ex

# Remove the old application.ex (will rewrite)
rm lib/rlm/application.ex

# Mix tasks
mkdir -p lib/mix/tasks
cp -r apps/rlm/lib/mix/tasks/* lib/mix/tasks/
```

### 5.2 — Move web files

```bash
# Web layer: apps/rlm_web/lib/rlm_web_web/ → lib/rlm_web/
mkdir -p lib/rlm_web
cp -r apps/rlm_web/lib/rlm_web_web/* lib/rlm_web/

# Web macro module: apps/rlm_web/lib/rlm_web_web.ex → lib/rlm_web.ex
cp apps/rlm_web/lib/rlm_web_web.ex lib/rlm_web.ex
```

### 5.3 — Move assets

```bash
# Assets from web app to project root
cp -r apps/rlm_web/assets/ assets/
```

### 5.4 — Move priv

```bash
mkdir -p priv
# Web static assets
cp -r apps/rlm_web/priv/static/ priv/static/
cp -r apps/rlm_web/priv/gettext/ priv/gettext/   # if keeping gettext

# Core engine priv files
cp apps/rlm/priv/system_prompt.md priv/system_prompt.md
```

**Important:** Any code that reads `priv/system_prompt.md` via `:code.priv_dir(:rlm)` will
still work because the OTP app name stays `:rlm`. The path resolution will now point to the
single app's `priv/` directory.

### 5.5 — Move tests

```bash
mkdir -p test/rlm test/rlm_web test/support

# Core tests
cp -r apps/rlm/test/rlm/* test/rlm/
cp -r apps/rlm/test/support/* test/support/

# Web tests
cp -r apps/rlm_web/test/rlm_web_web/* test/rlm_web/

# Web test support (conn_case.ex etc.)
cp apps/rlm_web/test/support/* test/support/  # merge, check for conflicts
```

### 5.6 — Move examples

```bash
# examples/ is already at the umbrella root — no move needed
```

### 5.7 — Remove umbrella structure

```bash
rm -rf apps/
```

---

## Phase 6: Unified Supervision Tree

### 6.1 — Write new `lib/rlm/application.ex`

```elixir
defmodule RLM.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ── Core Engine ──
      {Registry, keys: :unique, name: RLM.Registry},
      {Phoenix.PubSub, name: RLM.PubSub},
      {Task.Supervisor, name: RLM.TaskSupervisor},
      {DynamicSupervisor, name: RLM.RunSup, strategy: :one_for_one},
      {DynamicSupervisor, name: RLM.EventStore, strategy: :one_for_one},
      {RLM.Telemetry, []},
      {RLM.TraceStore, []},
      {RLM.EventLog.Sweeper, []},

      # ── Web Dashboard ──
      RLMWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:rlm, :dns_cluster_query) || :ignore},
      RLMWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: RLM.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    RLMWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
```

### 6.2 — Key considerations

- Order matters: `RLM.PubSub` must start before `RLMWeb.Endpoint` (Endpoint subscribes)
- `DNSCluster` was `:rlm_web` config → now reads from `:rlm` app env
- `config_change/3` callback was in the web app's application.ex → moved here

---

## Phase 7: Add Boundary Definitions

### 7.1 — Install boundary

In `mix.exs`:
```elixir
{:boundary, "~> 0.10", runtime: false}
```

And in `project/0`:
```elixir
compilers: [:boundary] ++ Mix.compilers()
```

### 7.2 — Define boundaries

**`lib/rlm.ex`** — Core engine boundary:
```elixir
defmodule RLM do
  use Boundary,
    deps: [],
    exports: [
      Config,
      Run,
      Worker,
      EventLog,
      TraceStore,
      Helpers,
      Span,
      IEx,
      Telemetry,
      Telemetry.PubSub,
      Tool,
      ToolRegistry
    ]

  # ... existing public API ...
end
```

**`lib/rlm_web.ex`** — Web layer boundary:
```elixir
defmodule RLMWeb do
  use Boundary,
    deps: [RLM],
    exports: [Endpoint]

  # ... existing macro module ...
end
```

**`lib/rlm/application.ex`** — Composition root (needs both):
```elixir
defmodule RLM.Application do
  use Boundary,
    top_level?: true,
    deps: [RLM, RLMWeb]

  # ... supervision tree ...
end
```

### 7.3 — Why `top_level?: true` on Application?

Without it, `RLM.Application` is part of the `RLM` boundary. But `RLM.Application` starts
`RLMWeb.Endpoint` — a module in the `RLMWeb` boundary. Since `RLM` declares `deps: []`
(no dependency on web), this would be a violation. Breaking `Application` out with
`top_level?: true` makes it an independent composition root that can wire both layers.

### 7.4 — What boundary enforces

After setup, the compiler will error if:
- Any module under `RLM.*` (except `RLM.Application`) calls anything in `RLMWeb.*`
- Any module under `RLMWeb.*` calls an `RLM.*` module that isn't in the exports list
- This prevents the core engine from depending on Phoenix/web concepts

### 7.5 — What boundary does NOT check

- PubSub messages (e.g., `Phoenix.PubSub.broadcast(RLM.PubSub, ...)` in web code — fine)
- Process name atoms (e.g., using `RLM.PubSub` as a name argument — not a function call)
- Telemetry events (decoupled by design)
- `send/2`, `GenServer.cast/2` messages across boundaries

---

## Phase 8: Fix Remaining References

### 8.1 — `priv/system_prompt.md` loading

Check how `RLM.Prompt` loads the system prompt:
```elixir
# If it uses :code.priv_dir(:rlm)
Application.app_dir(:rlm, "priv/system_prompt.md")
# This still works — OTP app is still :rlm
```

No change needed.

### 8.2 — TraceStore DETS path

Check `RLM.TraceStore` for DETS file path. If it uses `:code.priv_dir(:rlm)`, no change.
The `.gitignore` entry for `apps/rlm/priv/traces.dets` should be updated to `priv/traces.dets`.

### 8.3 — Test helpers

- `RLM.Test.MockLLM` — no rename needed (core module)
- `RLM.Test.Helpers` — no rename needed
- `ConnCase` — update `@endpoint` from `RlmWebWeb.Endpoint` to `RLMWeb.Endpoint`
- Web test files — rename from `test/rlm_web_web/` dir to `test/rlm_web/`

### 8.4 — `.formatter.exs`

Replace with single-app formatter:
```elixir
[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}"]
]
```

### 8.5 — `.gitignore`

Update umbrella-specific patterns:
```diff
- apps/rlm/priv/traces.dets
+ priv/traces.dets
```

### 8.6 — `mix.exs` `:mod` option

Ensure the application callback module is set:
```elixir
def application do
  [
    mod: {RLM.Application, []},
    extra_applications: [:logger, :runtime_tools]
  ]
end
```

---

## Phase 9: Verification

### 9.1 — Compile check
```bash
mix deps.get
mix compile --warnings-as-errors
```

Expected issues at this stage:
- Missing module references (incomplete rename)
- Boundary violations (good — fix them)
- Config key mismatches

### 9.2 — Boundary check
```bash
mix compile    # boundary compiler runs automatically
```

Fix any violations. Common ones:
- `RLM.Application` referencing both `RLM` and `RLMWeb` (expected — that's why it has `top_level?`)
- Core modules accidentally importing web helpers

### 9.3 — Test suite
```bash
mix test
```

Compare output against `/tmp/pre-migration-tests.txt`. Same number of tests should pass.

### 9.4 — Format check
```bash
mix format --check-formatted
```

### 9.5 — Manual smoke test
```bash
iex -S mix phx.server
# Visit http://localhost:4000 — dashboard should load
# Run: RLM.run("What is 2+2?", "answer", model_large: "...")
```

### 9.6 — Module inventory check
```bash
grep -rh "defmodule " lib/ | sort > /tmp/post-migration-modules.txt
# Compare against pre-migration lists — every module should be accounted for
```

---

## Phase 10: Cleanup and Documentation

### 10.1 — Update CLAUDE.md

- Update project structure diagram
- Update module map (remove umbrella references)
- Update build commands (no more `apps/` paths)
- Update config fields if any keys changed
- Update OTP supervision tree diagram

### 10.2 — Update README.md

- Remove umbrella references
- Update setup instructions

### 10.3 — Update CHANGELOG.md

```markdown
## [0.3.0] — 2026-XX-XX

### Changed
- Migrated from umbrella project to single Phoenix 1.8 app
- Renamed web modules from `RlmWebWeb.*` to `RLMWeb.*`
- Added `boundary` library for compile-time module dependency enforcement
- Unified supervision tree into single `RLM.Application`

### Removed
- Swoosh email dependency (unused)
- Umbrella project structure
```

### 10.4 — Update examples/

Check that example files don't reference old module names or paths.

---

## Risk Register

| Risk | Impact | Mitigation |
|---|---|---|
| Missed `RlmWebWeb` → `RLMWeb` rename | Compile error | Global search-replace + compile check |
| `config :rlm_web` → `config :rlm` overlap with existing `:rlm` config | Runtime misconfiguration | Careful manual merge of config files; use generated scaffold as reference |
| `otp_app: :rlm_web` left in endpoint | Endpoint won't start (reads wrong config) | Explicit check in Phase 4.4 |
| DETS/priv paths break | TraceStore fails to open | Verify `:code.priv_dir(:rlm)` resolves correctly |
| `mix.lock` conflicts | Deps won't resolve | Run `mix deps.get` early; resolve manually |
| Asset paths in esbuild/tailwind config | CSS/JS won't build | Use generated scaffold config as canonical reference |
| `phoenix-colocated/rlm_web` import in app.js | JS build fails | Rename to `phoenix-colocated/rlm` |
| Boundary `compilers` deprecation warning | Noise | Acceptable; boundary v0.10 still requires it |
| Test support file conflicts | Test failures | Merge carefully; `ConnCase` and `MockLLM` go in same `test/support/` |

---

## Execution Order Summary

```
Phase 0:  Snapshot (baseline commit, test output, module inventory)
Phase 1:  Generate fresh Phoenix scaffold in /tmp (reference only)
Phase 2:  Write new mix.exs (merge deps, add boundary)
Phase 3:  Consolidate config/ (all :rlm_web → :rlm, fix paths)
Phase 4:  Rename modules (RlmWebWeb → RLMWeb, global search-replace)
Phase 5:  Move files (apps/ → lib/, assets/, priv/, test/)
Phase 6:  Write unified Application (merge supervision trees)
Phase 7:  Add boundary definitions (RLM, RLMWeb, RLM.Application)
Phase 8:  Fix remaining references (priv paths, .gitignore, formatter, tests)
Phase 9:  Verify (compile, boundary, tests, format, smoke test)
Phase 10: Update docs (CLAUDE.md, README.md, CHANGELOG.md)
```

**Estimated phases of high risk:** Phase 3 (config consolidation) and Phase 4 (module rename).
Everything else is mechanical file movement.

---

## Open Questions

1. **Keep or drop Gettext?** The dashboard doesn't use i18n currently. Dropping it simplifies
   the migration but makes it harder to add later. Recommendation: drop for now.

2. **Keep or drop Swoosh?** The dashboard doesn't send emails. Recommendation: drop.

3. ~~**Keep or drop Phoenix.LiveDashboard?**~~ **Resolved: keep.** Useful for dev debugging,
   minimal overhead (one dep + one route), and easy to include from generation.

4. **App version bump?** Recommendation: bump to 0.3.0 to mark the structural change.

5. **Single commit or incremental?** Recommendation: do it in one commit on a feature branch.
   The intermediate states (half-moved files) won't compile, so incremental commits would all
   be broken. One atomic commit is cleaner for bisect/revert.
