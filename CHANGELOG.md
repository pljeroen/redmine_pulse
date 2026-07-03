# Changelog

All notable changes to **redmine_pulse** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-03

First public release. A feature-complete portfolio / project-health cockpit
for Redmine 6.x: scoring engine, HTML cockpit, read JSON API, and CI.

_Roadmap (not yet shipped): a `coverage_gap` signal, background snapshot
recompute, per-viewer fine-grained (non-cached) scoring, custom lenses,
additional locales, saved views, webhooks, and alerting._

### Added

- **Dutch (`nl`) locale.** A full Dutch translation of every user-facing string.
  Redmine renders Pulse in Dutch for users whose language is Dutch, with English
  as the fallback for any untranslated key.
- **Gantt deep-link.** The per-project health panel links to Redmine's built-in
  project Gantt — shown only when the viewer is allowed to see it.
- **Effort-field suggestions.** When the effort field is left blank, the settings
  page suggests numeric custom fields whose name looks like effort or story points.
  Suggestion only: nothing is auto-applied, so scoring never changes silently.

- **Scoring engine (pure-domain, stdlib-only).** Five signals — staleness,
  progress, momentum, risk load, blocked load — combine into a composite
  health score (0–100) with deterministic, explainable per-signal
  contributions that reconstruct the score. Weights renormalise over the
  active signals so a missing enrichment signal degrades gracefully rather
  than being faked.
- **Prioritisation lenses.** Five lenses re-rank the portfolio without
  re-scoring: health, at-risk, stale, done, and blocked. The "main concern"
  for a project is its single worst signal (severity-first), with a distinct
  no-data state when there is nothing to score.
- **RAG status** with tunable green/amber/red thresholds.
- **Timeline.** A retrospective sparkline from real activity plus forward
  milestone markers derived only from milestone dates a user actually set —
  never fabricated dates.
- **Redmine metrics source (read-only, permission-safe).** Viewer-scoped
  aggregation via `Project.visible` / `Issue.visible(user)`; blocked load
  counts only visible blockers.
- **HTML cockpit.** A portfolio overview page, a per-project health panel, and
  a project-menu tab — rendering precomputed presenter view-models only (no
  scoring or ActiveRecord access in the views), with RAG-coloured chips and a
  styled sparkline.
- **Read JSON API.** `GET /pulse/portfolio.json` and
  `GET /pulse/projects/:id.json`, authenticated with a standard Redmine API
  key, carrying a `schema_version` and the computed projection fields, with
  lens selection and pagination.
- **Snapshot + clock-split cache.** A content-addressed aggregate snapshot
  (fingerprinted over the visible data and settings) combined with a
  per-request clock projection, plus a cache-clear rake task.
- **Settings (admin).** Tunable signal mappings (effort field, risk trackers,
  blocked status), per-signal weights, RAG thresholds, horizons, and the
  activity window — with out-of-range values rejected and surfaced as a
  localized error rather than silently saved.
- **`view_pulse` permission** gated behind a per-project `pulse` module.
- **Continuous integration.** A safe-by-design GitHub Actions workflow
  (read-only token, no secrets, SHA-pinned actions) exercising a compatibility
  matrix of Redmine 6.1.x × Ruby 3.2/3.4 × PostgreSQL 16 / MySQL 8, plus a
  fast standalone pure-domain lane.

[Unreleased]: https://github.com/pljeroen/redmine_pulse/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/pljeroen/redmine_pulse/releases/tag/v0.1.0
