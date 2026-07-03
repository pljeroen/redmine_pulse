# Redmine Pulse

A **portfolio / project-health cockpit** for Redmine 6.x (plugin id
`redmine_pulse`) — it answers *"which project deserves attention next, and why?"*
with real-data-grounded health scoring, multi-lens prioritisation, and a clean
read API. Ships in **English and Dutch**.

[![CI](https://github.com/pljeroen/redmine_pulse/actions/workflows/ci.yml/badge.svg)](https://github.com/pljeroen/redmine_pulse/actions/workflows/ci.yml)
[![License: GPL-2.0-only](https://img.shields.io/badge/license-GPL--2.0--only-green)](LICENSE)
[![Ruby](https://img.shields.io/badge/Ruby-3.2%20%7C%203.4-orange)](https://www.ruby-lang.org/)
[![Redmine](https://img.shields.io/badge/Redmine-6.1%2B-purple)](https://www.redmine.org/)
[![Architecture](https://img.shields.io/badge/architecture-hexagonal-purple)](#how-it-works)
[![Status](https://img.shields.io/badge/status-v0.1.0-green)](CHANGELOG.md)

## What it is

Redmine is excellent at tracking individual issues, but it has no native
**portfolio view** — no single place that tells a programme owner which of their
many projects needs attention right now, and why. There is no cross-project
"what's slipping" signal and no RAG (red/amber/green) rollup. The plugins that
offer this are commercial (EasyRedmine, RedmineUP) or long dead.

`redmine_pulse` fills that gap as a **free, open, maintained** option. It scores
every project you can see on five health signals, ranks them, colours them
red/amber/green, and tells you — transparently — the single biggest concern for
each. It **reads your Redmine data without modifying it**, is **permission-safe**
(you only ever see what your Redmine account is allowed to see), and **never
invents data**: a forward timeline is drawn only from milestone dates someone
actually set.

What Pulse *does* touch is small and honest: it adds **one additive, fully
reversible cache table of its own** (`pulse_snapshots`) and a fail-silent
page-head listener that only activates on the project list. See
[What Pulse touches](#what-pulse-touches) for the complete footprint.

## Screenshots

| Portfolio overview | Per-project health panel |
| --- | --- |
| ![Portfolio overview — every visible project ranked by composite health, with RAG chips and lens selector](doc/screenshots/portfolio.png) | ![Per-project panel — signal breakdown, main concern, retrospective sparkline and forward milestones](doc/screenshots/project-panel.png) |

| Settings | No-data state |
| --- | --- |
| ![Admin settings — signal mappings, weights, RAG thresholds, momentum shape, and activity/freshness windows, each with inline help and shipped defaults](doc/screenshots/settings.png) | ![Distinct no-data state when there is nothing to score yet](doc/screenshots/no-data.png) |

## What Pulse touches

"Read-only" deserves an honest breakdown. These are the *only* ways Pulse
touches your instance:

- **Your Redmine data: read-only.** Pulse reads issues, versions, and changesets
  to compute health. It never creates, updates, or deletes a Redmine record.
- **One additive cache table it owns.** The install migration creates a single
  plugin-prefixed table, `pulse_snapshots`, where Pulse caches the expensive part
  of each score. It is the *only* table Pulse writes to (besides its own
  plugin-settings row), it collides with no Redmine core table, and **the table
  is fully reversible** — uninstalling drops it cleanly. The one thing that
  outlives an uninstall is a single row in Redmine's core `settings` table
  (holding your saved configuration); [Uninstall](#uninstall) shows the optional
  step to clear it too.
- **A fail-silent page-head listener.** Pulse registers a
  `view_layouts_base_html_head` hook so it can decorate the project list with RAG
  badges. The listener is invoked on every page but short-circuits immediately on
  anything other than the project index — it does no database work elsewhere — and
  is wrapped fail-silent, so a problem inside Pulse can never break a page.
- **Portfolio computation on the project list.** For users with the Pulse
  permission, the `/projects` page computes the portfolio rollup, served from the
  snapshot cache. On very large instances this is the one cost worth knowing about.

That is the complete blast radius: read-only against your data, one reversible
table, one fail-silent hook.

## Installation

### Install

From your Redmine root:

```sh
cd plugins
git clone https://github.com/pljeroen/redmine_pulse.git redmine_pulse
cd ..
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
bundle exec rails assets:precompile RAILS_ENV=production
```

Then restart your application server (Passenger, Puma, etc.).

> **The `assets:precompile` step is required, not optional.** Redmine 6.x serves
> plugin CSS/JS as fingerprinted [Propshaft](https://github.com/rails/propshaft)
> assets. Skip it and Pulse's stylesheet and the project-list badge script are
> never served — the cockpit renders unstyled and the RAG badges silently never
> appear, so the plugin looks broken when it is merely missing its assets. Re-run
> it after every upgrade.

### Upgrade

From your Redmine root:

```sh
cd plugins/redmine_pulse
git pull
cd ../..
bundle install
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
bundle exec rails assets:precompile RAILS_ENV=production
```

Then restart your application server. Check [`CHANGELOG.md`](CHANGELOG.md) for
anything version-specific.

### Uninstall

Pulse's own table comes out cleanly; one small settings row is the only thing
that lingers, and step 3 deletes it. From your Redmine root:

```sh
# 1. Reverse Pulse's migration — drops the pulse_snapshots cache table + index.
bundle exec rake redmine:plugins:migrate NAME=redmine_pulse VERSION=0 RAILS_ENV=production
# 2. Remove the plugin.
rm -rf plugins/redmine_pulse
# 3. (Optional) Delete Pulse's plugin-settings row for a fully clean removal.
RAILS_ENV=production bundle exec rails runner "Setting.where(name: 'plugin_redmine_pulse').delete_all"
```

Then restart your application server. Step 1 runs the migration's reverse
(`drop_table :pulse_snapshots`), which drops the `pulse_snapshots` table and its
index cleanly with no orphaned schema. Step 2 removes the plugin directory.
Neither of those touches the one row Pulse writes to Redmine's core `settings`
table (`name = 'plugin_redmine_pulse'`, holding your saved configuration), so it
persists until you remove it — step 3 deletes that `settings` row (the one where
`name = 'plugin_redmine_pulse'`) if you want nothing left behind. It's core
ActiveRecord against the `settings` table, so it works whether or not the plugin
directory is still present — safe to run before or after step 2.
Your Redmine data is untouched throughout — Pulse never wrote to it.

## Getting started

Pulse is a per-project module, so you enable it where you want it and grant the
read permission to the roles that should see it:

1. **Enable the module per project.** Go to a project's *Settings → Modules* and
   tick **Pulse**. (Enable it on every project you want to appear in the
   portfolio.)
2. **Grant the permission.** As an administrator, go to *Administration → Roles
   and permissions*, and for each role that should use the cockpit, grant
   **View pulse** (`view_pulse`) under the *Pulse* group.
3. Visit **`/pulse`** for the portfolio overview, or open the **Pulse** tab on
   any Pulse-enabled project for its health panel. The panel deep-links to
   Redmine's built-in **Gantt** for that project when you have permission to see
   it (`view_gantt`).

**A fresh install shows nothing — that is expected, not a fault.** Until you
enable the **Pulse** module on at least one project, `/pulse` renders an empty
portfolio and the project list carries no badges. Pulse only surfaces projects
whose module is on *and* that you have permission to see, so the first thing to
do after installing is step 1 above.

Users only ever see projects and issues their Redmine account already has
visibility into — Pulse adds a lens, never a leak.

## Configuration

Pulse ships with sane defaults and works out of the box. Tune it under
*Administration → Plugins → Redmine Pulse → Configure*:

| Setting | What it does | Default |
| --- | --- | --- |
| **Effort field** | Optional custom field mapping used to weight progress by effort instead of issue count. Unset → progress uses issue counts. | _(unset)_ |
| **Risk trackers** | Trackers that count toward the **risk load** signal. Unset → the risk signal is omitted and its weight is redistributed. | _(none)_ |
| **Blocked status** | Optional status that marks an issue as blocked (in addition to `blocks` relations). | _(unset)_ |
| **Weights** | The relative weight of each of the five signals (staleness, progress, momentum, risk load, blocked load). They renormalise over the active signals. | balanced |
| **RAG green / amber thresholds** | Score at/above green → green; at/above amber → amber; below → red. | 67 / 34 |
| **Horizons** (`h_stale`, `h_risk`, `h_blocked`) | The day/count horizons that normalise the staleness, risk, and blocked signals to 0–1. | 180 / 50 / 20 |
| **Activity window (days)** | The trailing window used for the momentum signal and the sparkline. | 30 |
| **Momentum shape** (`momentum_activity_half`, `momentum_direction_bias`) | Tunes the momentum signal: the activity level that reads as neutral (0.5), and how much net issue completion nudges it up or down. | 8 · 0.15 |
| **On-track threshold** | When a project's worst signal is at or above this (0–1), its main concern reads *"On track"* instead of naming a signal. | 0.5 |
| **Freshness cap (minutes)** | Auto-refreshes a cached snapshot older than this on the next view, so *"computed X ago"* never exceeds it. `0` = only recompute when the underlying data changes. | 60 |

Mappings that depend on your custom fields or trackers (effort field, risk
trackers, blocked status) are **optional enrichment** — leave them blank and the
affected signal is gracefully omitted, never faked. Out-of-range values are
rejected and reported, not silently saved. When the **effort field** is left
blank, the settings page *suggests* the numeric custom fields whose name looks
like effort or story points — it only suggests; nothing is applied until you
enter an id, so scoring never changes on you silently.

## The scoring model

Each visible project is scored on **five signals**, each normalised to 0–1:

- **Staleness** — how long since meaningful activity.
- **Progress** — how much of the work is done (by issue count, or by effort if
  an effort field is mapped).
- **Momentum** — the trend of activity over the activity window.
- **Risk load** — open issues in the configured risk trackers.
- **Blocked load** — issues blocked by visible blockers.

The signals combine into a **composite health score (0–100)** using the
configured weights, which renormalise over whichever signals are active. The
score maps to a **RAG status** via the thresholds. The same scores feed **five
lenses** that re-rank (not re-score) the portfolio: *health*, *at-risk*,
*stale*, *done*, and *blocked*.

The model is built to be trustworthy:

- **Explainable** — each project shows its per-signal contributions, which
  reconstruct the score exactly. The **"main concern"** is its single worst
  signal (severity-first), with a distinct **no-data** state when there is
  nothing to score.
- **No invented dates** — the retrospective sparkline is drawn from real
  activity; the forward timeline shows only milestone dates a user actually set.
- **Read-only and permission-safe** — Pulse reads your Redmine data without ever
  modifying it (its only write is its own reversible `pulse_snapshots` cache) and
  never shows you anything your account can't already see.

## API

Pulse exposes the computed metrics as read-only JSON so external dashboards
(Grafana, etc.) can consume them — visualisation is a consumer, not a
competitor.

- `GET /pulse/portfolio.json` — a ranked array of per-project health summaries.
  Supports `?lens=<health|at_risk|stale|done|blocked>` and pagination
  (`?offset=&limit=`, default limit 100).
- `GET /pulse/projects/:id.json` — one project's full breakdown plus its history
  series and forward milestones.

The exact response shapes are published as JSON Schemas —
[`portfolio.json`](docs/specs/redmine-pulse/contracts/schemas/portfolio.json) and
[`project.json`](docs/specs/redmine-pulse/contracts/schemas/project.json) — with
validated example payloads under
[`contracts/seeds/`](docs/specs/redmine-pulse/contracts/seeds/). Write your consumer
against these.

Authentication uses the standard Redmine REST mechanism: the admin **Enable REST
web service** setting must be on, and the request carries an API key
(`X-Redmine-API-Key` header, `key` param, or HTTP Basic). Both endpoints are
authorised by `view_pulse` and scoped to the caller's visibility exactly like
the UI.

Each payload carries a `schema_version`, two distinct timestamps
(`snapshot_computed_at` and `projected_at`), and a `projection` block
(`clock_today`, `time_zone`, `activity_window_days`, the horizons) so a client
can fully reconstruct the time-derived values. Response codes: **404** when the
project is not in your visible set or does not exist; **403** when it is visible
but you lack permission or the module is disabled; REST-disabled requests get
Redmine's standard 401/403.

**API compatibility.** New fields are introduced additively within a
`schema_version`: a release may add a field to a payload without bumping the
version. Write your consumer as a **tolerant reader** — read the fields you need
and ignore any you don't recognise — rather than validating each response
against a closed/strict schema that rejects unknown fields. The `schema_version`
is bumped only for breaking changes (a removed or renamed field, or a changed
meaning).

## Compatibility

The [GitHub Actions CI workflow](.github/workflows/ci.yml) defines and exercises
this matrix on every push to `master` (and on manual dispatch):

| Redmine   | Ruby 3.2          | Ruby 3.4          |
| --------- | ----------------- | ----------------- |
| **6.1.x** | PostgreSQL 16 · MySQL 8 | PostgreSQL 16 · MySQL 8 |

Four combinations (Redmine 6.1.x × Ruby 3.2/3.4 × PostgreSQL 16 / MySQL 8) plus a
fast standalone pure-domain lane. CI is **maintainer-only** — it runs on pushes to
`master` and manual dispatch, never on pull requests, so a public fork PR triggers
nothing by design.

**Tested on.** Development verifies the full functional/integration suite against
**Redmine 6.1.2** on **Ruby 3.4 + PostgreSQL 16** (primary), the pure-domain lane
on **Ruby 3.2 and 3.4**, and at least one full run against **MySQL 8**. Other
Redmine 6.x point releases are expected to work but are not yet part of the
verified envelope — the DOM and asset assumptions are kept defensive and
fail-silent.

**Localisation.** The interface ships in **English and Dutch** (`nl`) — Redmine
renders Pulse in each viewer's own language, falling back to English for anything a
locale doesn't translate.

## How it works

Pulse uses a **hexagonal (ports & adapters)** architecture. The scoring engine
under `lib/pulse/domain/` is pure Ruby with **zero framework dependencies** — no
Rails, no ActiveRecord — so the core logic is deterministic and testable in
isolation. All Redmine integration (reading issues, versions, changesets;
caching; rendering) lives in adapters under `lib/pulse/adapters/` and `app/`,
behind the ports in `lib/pulse/ports/`. Expensive aggregates are cached in a
content-addressed snapshot, while the time-dependent part of the score is
projected cheaply per request.

## Running tests locally

Two lanes, mirroring CI:

- **Pure-domain suite** (no database, no Rails) — the fast inner loop:

  ```sh
  ruby -Itest -Ilib -e 'Dir["test/unit/domain/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
  ```

- **Full Redmine-integrated suite** — use the committed isolated harness under
  [`scripts/test-redmine/`](scripts/test-redmine/README.md) (an ephemeral
  Redmine 6.1.x + PostgreSQL container pair): `./scripts/test-redmine/up.sh`
  then `./scripts/test-redmine/run-tests.sh`.

The host-neutral runner [`scripts/ci/run.sh`](scripts/ci/run.sh) is what CI
invokes; it runs both lanes against any prepared Redmine checkout (set
`REDMINE_ROOT` or pass the root as `$1`).

## Roadmap

Not yet shipped, tracked for later: a `coverage_gap` signal, background snapshot
recompute, per-viewer fine-grained scoring, custom lenses, more locales, saved
views, webhooks, and alerting. See [`CHANGELOG.md`](CHANGELOG.md).

## Contributing

This is a personal project and I'm not taking outside contributions at this stage —
issues and pull requests won't be reviewed or merged for now (that may change later).
In the meantime you're very welcome to **fork** it under the GPL and adapt it to your
own needs. Thanks for understanding! 🙂

## License

GPL-2.0-only, to match Redmine. See [`LICENSE`](LICENSE).
