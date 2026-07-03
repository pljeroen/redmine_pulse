# redmine_pulse — Specification (v1, rev 3)

**Status:** FROZEN (rev 3.1, 2026-06-20) — passed independent review (all conditions resolved).
Governs downstream implementation.
**Note:** this is the frozen v1 *design* specification, kept as a historical design record.
The shipped plugin has since evolved beyond it (e.g. English + Dutch locales, a Gantt
deep-link, effort-field suggestions). For current behaviour and configuration, see the
[README](../../../README.md) and [CHANGELOG](../../../CHANGELOG.md) — those are authoritative
for the released plugin; this document is not updated feature-by-feature.
**Post-freeze correction (rev 3.1, operator-approved revision):** §3.1 changeset visibility uses Redmine's
`:view_changesets` permission (not `browse-repository`) — a Redmine-6.1-reality correction surfaced while
building the metrics source. Behaviour change: which users' changeset activity feeds the staleness
reference date. The correction also renamed the permission from the placeholder used during
spec drafting to Redmine's canonical `:view_changesets`.
**Spec name:** redmine-pulse.
**Product:** an open-source Redmine 6.x plugin — a portfolio / project-health cockpit.
**License:** GPL-2.0-only. **Distribution:** public GitHub + redmine.org plugin listing.
**Revision note (rev 3):** rewritten to resolve independent review feedback — the scoring model is now
fully executable (formulas, normalization, edge cases, fixtures), the permission/visibility model
and cache are redesigned to Redmine idioms, `coverage_gap` is deferred to roadmap, and all
spec/schema/seed contradictions are removed. See `decisions.yaml` DEC-10..DEC-15.

---

## 1. Problem & intent

Redmine (through 6.1) has **no** native cross-project portfolio view, no project-health/RAG
rollup, and no "which project deserves attention next" signal. The plugins that provide this are
**commercial** (EasyRedmine, RedmineUP/RedmineX — proprietary, paywalled) or **dead** (the one
MIT-licensed portfolio plugin last supported Redmine 2.4, ~2016).

`redmine_pulse` fills that gap as the **free, open, maintained** option: a focused, well-tested,
well-documented plugin that does one thing excellently — surface project health and prioritization
from **real data already in Redmine** — and exposes that computation via a clean read API so
external tools can build on it.

**Scope governance:** this is a deliberate **community contribution**. The "minimal build" posture
is relaxed in favour of *maturity in service of real users* (the democratizing intent of
anti-extraction). The guardrail remains: no vanity features, no lock-in, no gold-plating. v1 does
one thing well with a mature roadmap for the rest.

**Ecosystem-alignment principle:** where Redmine has an established idiom (permissions via a
project module, visibility via `Project.visible` / `Issue.visible`, aggregates computed over the
viewer's visible subset, REST API-key auth), `redmine_pulse` follows it rather than inventing a
parallel mechanism. We extend Redmine; we do not work around it.

---

## 2. Product shape

**A plugin (system component) hosted inside a Redmine application** — not a standalone app. It runs
in-process within Redmine (Ruby on Rails), adds UI pages + a JSON API, and reads Redmine's own data.
Gantt/timeline *editing* is **out of scope** — the free `redmine_canvas_gantt` (GPL-2.0) plugin
already covers that; `redmine_pulse` is the missing **portfolio/health** layer and composes beside it.

---

## 3. Actors & access model

- **Portfolio owner / PMO** (primary) — opens the cockpit to decide what to work on next.
- **Project member** — views a project's health panel (subject to the permission, below).
- **External consumer** (machine) — a dashboard/service (Grafana, custom) reading the JSON API.
- **Plugin administrator** — configures signal mappings, weights, thresholds; assigns the permission.

### 3.1 Permission & visibility model (Redmine-idiomatic)

Two separate, standard Redmine mechanisms, used together (DEC-10):

1. **Access gate — a project module + permission.** The plugin declares a `pulse` **project module**
   containing a single read permission `:view_pulse`, assigned to roles through the standard
   Roles & Permissions admin UI, e.g.:
   ```ruby
   project_module :pulse do
     permission :view_pulse,
                { pulse: [:index, :show], pulse_api: [:portfolio, :project] },
                read: true
   end
   ```
   The cockpit (UI + API) renders **only** for users whose role grants `view_pulse` on a project that
   has the `pulse` module enabled. Controllers enforce this with Redmine's `before_action :authorize`.

2. **Data visibility — viewer-scoped aggregates.** Exactly like Redmine's own aggregate reports (the
   issue summary at `/projects/:id/issues/report`, the activity feed), **every** query the score is
   built from is scoped through Redmine's visibility primitives: `Project.visible(user)` and
   `Issue.visible(user)` / `Issue.visible_condition(user)` — which resolve, exactly as Redmine does,
   from: the `view_issues` permission (via the `issue_tracking` module + `Project.allowed_to_condition`,
   whose read preconditions include active/closed but **exclude archived** projects), role
   `issues_visibility` ∈ {`all`, `default`, `own`}, the issue's `is_private` flag with author/assignee
   identity (incl. the user's groups), and any per-tracker view restrictions. (There is **no**
   `view_private_issues` permission in Redmine 6.1 — private-issue access is governed by
   `issues_visibility` + author/assignee/group identity.) Changeset dates additionally require the
   repository module + :view_changesets permission. A score therefore reflects **only the issues the
   requesting user is allowed to see**. Two users with
   different visibility correctly see different scores for the same project — this is the existing
   Redmine norm (their native issue counts already differ), and the panel states it explicitly:
   *"computed from issues visible to you."*

**Consequence (resolves the cross-permission leak):** because aggregates are viewer-scoped, the
cockpit never exposes counts, "why", sparklines, or drill targets for issues the viewer cannot
already see. `INV-PERMISSION-SAFE` is satisfied **by construction**, not by post-hoc filtering.

**Access response codes (Redmine-accurate).** Per-project lookup goes through a single tested algorithm
keyed on `Project.visible(user)` (which, per `Project.allowed_to_condition`, includes active + closed
projects but **excludes archived** ones):
- **404** when the project is **not in `Project.visible(user)` or does not exist** — this covers
  nonexistent, private-and-invisible, **and archived** projects, all returning the same 404 so existence
  is never revealed. This is a thin lookup-via-visible-scope path, **not** bare `before_action
  :authorize` (which returns 403 for denied/module-disabled/archived and would leak existence here).
- **403** when the project **is** in `Project.visible(user)` (so the user already knows it exists) but
  the user's role lacks `view_pulse` or the `pulse` module is disabled — the standard Redmine 403.
- The portfolio simply omits any project not in the viewer's visible set or lacking the module.

---

## 4. The scoring model (the core IP) — executable specification

A **composite health score** per project plus **selectable lenses** that re-rank by one dimension.
Every input is **real, falsifiable data** already visible to the requester in Redmine (+ its linked
repository). All "days since" / window computations come from a single injected **Clock** so scoring
is deterministic for a fixed input + clock + config (`INV-DETERMINISTIC`).

v1 scores **five signals** (the rev-1 `coverage_gap` is deferred — §9, DEC-12). Each signal computes
a raw value and a **normalized health value `n ∈ [0,1]` where 1 = healthiest** (polarity folded in).

### 4.1 Signal definitions

Notation: `today = Clock.today`; all issue/changeset sets are **the requester-visible set** (§3.1);
`W = activity_window_days` (default 30); horizons `H_*` are settings with the defaults below.

| Signal | Active when | Raw value | Normalized health `n` |
|---|---|---|---|
| `staleness` | always | `days = today − reference_date` (whole days, floor), `reference_date = max(latest visible issue.updated_on, latest visible changeset.committed_on, project.created_on)` | `clamp(1 − days / H_stale, 0, 1)`, `H_stale=180` |
| `progress` | `effort_total > 0` | `progress_ratio = 1 − effort_open/effort_total` | `clamp(progress_ratio, 0, 1)` |
| `momentum` | always | `net = closed − opened` over `W` | `clamp(0.5 + (closed−opened) / (2·max(closed+opened, 1)), 0, 1)` |
| `risk_load` | ≥1 risk tracker mapped | `risk_raw = Σ priority.position` over visible **open** issues in mapped risk tracker(s) | `clamp(1 − risk_raw / H_risk, 0, 1)`, `H_risk=50` |
| `blocked_load` | always | `blocked_count` (definition below) | `clamp(1 − blocked_count / H_blocked, 0, 1)`, `H_blocked=20` |

Edge-case rules (resolve review findings F-002/003/004/007/008):

- **`staleness` no-activity:** an empty/new project still has `project.created_on` (a real Redmine
  timestamp), so `reference_date` is always defined; a brand-new empty project is *fresh*, not stale.
- **`progress` zero-denominator:** if `effort_total = 0` (no visible issues, or all-null mapped
  effort), `progress` is **inactive** (its weight is redistributed; §4.2). `effort_total` =
  `sum(mapped effort)` when an effort field is mapped, else `count(visible issues)` (the standard-field
  fallback). `effort_open` is the same measure over visible **open** issues.
- **`momentum`:** over visible issues, window half-open `[today−W, today)` evaluated in the instance's
  configured time zone (the `time_zone` is reported in the API `projection` block).
  - `opened` = count of visible issues with `created_on` in the window.
  - `closed` = count of **closing events** in the window. A *closing event* is precisely: a journal
    `detail` of property `status` whose **old** status had `is_closed = false` and whose **new** status
    has `is_closed = true`, timestamped at the journal's `created_on`; **plus** an issue *created
    directly in a closed status* counts as one closing event at its `created_on`. Open→open,
    closed→closed, and closed→open (re-open) transitions are **not** closing events; a
    reopen-then-reclose contributes one closing event per reclose that falls in-window. `is_closed` is
    read from the status definitions in force **for that scoring run** (a later status-definition edit
    changes future runs, not a deterministic replay of the same inputs).
  - No activity ⇒ `closed = opened = 0` ⇒ `n = 0.5` (neutral, still active). Golden fixtures cover
    created-closed, reopen/reclose, closed→closed, and boundary-instant cases.
- **`risk_load` priority weighting:** weight = `IssuePriority#position` (1-based enumeration order),
  so admin-defined priority sets work without hard-coding names. A change to the priority enumeration
  participates in the cache fingerprint (§6.4).
- **`blocked_load` definition:** a visible **open** issue `X` is *blocked* iff **(a)** there exists an
  `IssueRelation` of type `blocks` whose `issue_to = X`, whose blocking issue (`issue_from`) is **open
  AND visible to the requester** (`Issue.visible(user)`), i.e. *something visible blocks X* (direction
  matters; counting the other side would invert the signal) — **or (b)** (enrichment) `X.status_id`
  equals the configured **blocked status id** (configured by **id**, not localized name, so
  language/admin edits don't break it). **Visibility (resolves the leak):** a blocker the requester
  cannot see is **not** counted — matching Redmine's own `IssueRelation#visible?` (both endpoints must
  be visible) and preserving `INV-PERMISSION-SAFE`; we never expose the existence/open-state of a
  hidden blocker through `blocked_count`, `dominant_signal`, lens order, or drill context.

### 4.2 Composite health

Let `A` = the set of **active** signals for the project. Default weights over the full five-signal
set (sum to 1.0; tunable in settings, DEC-13):

```
staleness 0.25   progress 0.25   momentum 0.20   risk_load 0.15   blocked_load 0.15
```

Weight redistribution (resolves F-001/F-010 "graceful degradation has no algorithm"):
```
effective_weight w'_i = w_i / Σ_{j∈A} w_j          # renormalize over active signals only
contribution_i        = 100 · w'_i · n_i           # ∈ [0,100], always ≥ 0
score_raw             = Σ_{i∈A} contribution_i
health_score          = clamp(round_half_up(score_raw), 0, 100)   # integer 0..100
```

- **Explainability accounting (resolves F-011):** every contribution is **non-negative** and the
  contributions **sum to the score** — `round_half_up(Σ contribution_i) == health_score` by
  construction (no hidden base term, no negative contributions). The UI/API present `n_i`, `w'_i`,
  `raw_value`, and `contribution_i` for each active signal so the score is fully reconstructable.
- **RAG band:** `green` if `health_score ≥ 67`; `amber` if `34 ≤ health_score ≤ 66`; `red` if
  `health_score < 34` (defaults; tunable, DEC-13).
- **`dominant_signal` (the "why"):** the **active** signal with the **lowest normalized health**
  `n` (`argmin_{i∈A} n_i` — the most-broken signal), **weight-independent** (THAW-RA-001). Ties broken
  by the fixed order `[staleness, progress, momentum, risk_load, blocked_load]`. **Never nil** on a
  scoreable project (the always-active subset guarantees a non-empty active set); it is `null`
  **only** in the no-data state (§4.5).
- **Determinism:** identical `ProjectMetrics` + `Clock` + `ScoringConfig` ⇒ identical `health_score`,
  RAG, `dominant_signal`, and lens keys (`round_half_up` is deterministic).

### 4.3 Lenses (re-ranking, not re-scoring)

Canonical lens enum (snake_case — the **single** source of truth used in spec, schema, seeds, tests,
and the `lens` URL/query param; UI labels are a separate display concern, resolves F-025):

`health` (default) · `at_risk` · `stale` · `done` · `blocked`.

Each lens defines a numeric **lens key** and a sort order; **ties always break by `project_id`
ascending** (determinism). Lenses re-rank the same scores; they never recompute the composite (DEC-02).

| Lens | Lens key | Order | "Needs attention" = |
|---|---|---|---|
| `health` | `health_score` | ascending | worst first |
| `at_risk` | `at_risk_index = Σ_{i∈A∩{risk_load,blocked_load,staleness}} w'_i·(1−n_i)` (×100) | descending | most at risk first |
| `stale` | `staleness` days | descending | most stale first |
| `done` | `progress_ratio` (×100); progress-inactive projects sort **last** | descending, then `effort_open` ascending | closest to done first |
| `blocked` | `blocked_count` | descending | most blocked first |

### 4.4 Timelines (retrospective + forward; no fabricated dates)

- **Retrospective** — a per-bucket activity/health trend (the sparkline) over the trailing window.
  Bucket boundaries are derived **deterministically from the injected Clock and `W`** (default: the
  last `ceil(W/7)` ISO weeks ending `today`); each bucket carries explicit `[start, end]` instants and
  aggregates the real events (issue closures/updates, changesets) that fall in that interval — a bucket
  with no events is a real zero, never an interpolation. Every bucket value traces to real visible
  timestamps (resolves F-013).
- **Forward** — milestone markers from **Versions whose `due_date` an operator actually set**. Redmine
  Version due dates are **date-valued** (`Version#due_date` aliases the date column `effective_date`),
  so they are rendered as **dates (no time-of-day, no timezone)** — provenance `version_due_date` — and
  the API encodes them with `format: date`, never as a midnight-UTC instant (which would invent a
  time). If none exist, the forward axis is empty — the plugin **never invents a date**.
- **Date provenance (resolves F-012):** every temporal value the plugin renders (UI or API) carries an
  explicit `provenance` tag from the closed set: `redmine_timestamp` (real issue/changeset time),
  `version_due_date` (operator-set), `computed` (an operational instant the plugin generated, e.g.
  `computed_at` — a real wall-clock value from the injected Clock, labelled as plugin-generated), or
  `derived_bucket` (a Clock-derived sparkline interval boundary). No value may carry a
  `projected`/`estimated` provenance — that class does not exist. `INV-NO-INVENTED-DATES` is updated to
  this provenance-tagged form (constraints.yaml; DEC-04 amended).

### 4.5 Graceful degradation (hard requirement)

The plugin produces a valid, **falsifiable** score on **any** visible Redmine project using
**standard fields only**. The minimum **standard-field active set** is
`{staleness, progress, momentum, blocked_load}` (progress active iff `effort_total > 0`). `risk_load`
is **enrichment** (active only when ≥1 risk tracker is mapped). Optional mappings (effort field, risk
tracker(s), blocked status) refine signals; when unmapped, the affected signal is marked
`active: false` with **null** `raw_value`/`contribution`, and its weight is redistributed over the
active set (§4.2) — **never faked** (`INV-DEGRADES-GRACEFULLY`).

**Representation (resolves the omitted-vs-`active:false` contradiction, F-023):** inactive signals are
**always present** in the breakdown with `active: false` and null values — they are **not omitted**.
The per-project panel lists them as "inactive — enable by mapping X." (Supersedes rev-1 §4.5 wording
"omitted and weight redistributed"; the redistribution still happens, the row is still shown.)

"Valid score" is defined falsifiably (resolves F-010): `health_score` is an integer in `[0,100]`; at
least the four standard-field signals are active for a non-empty project; the breakdown is present and
reconstructs the score per §4.2; and a `signal_completeness = |active| / 5` field communicates the
evidential basis so a standard-only score does not masquerade as a fully-enriched one.

**No-data state (THAW-RA-001):** a project with **zero scoreable data** must render a **distinct
no-data state**, not a spurious freshness-floor score. The pure-domain trigger is, conjunctively,
on **per-project DATA only**: `effort_total == 0` (no issues / no mapped effort) **and** the event
series is empty (no created/closed activity) **and** `blocked_count == 0` (no blockers) **and**
`risk_raw == 0` (no risk issues on this project). The risk conjunct keys on per-project `risk_raw`,
**not** the global `risk_mapped` flag (whether a risk tracker is *configured* instance-wide), because
in any instance with a risk tracker configured `risk_mapped` is true for every project and would never
let a genuinely empty project reach the no-data state. The no-data result carries `rag: no_data`,
`health_score: null`, `dominant_signal: null`, `signal_completeness: 0.0`, a breakdown of all five
signals `active: false` with null values (canonical order), and the lens-key set present with
all-null values (the key set is preserved per §4.3). **Boundary:** any single scoreable fact —
`effort_total ≥ 1` (one issue), one created/closed event, one blocker, or one risk issue
(`risk_raw ≥ 1`) — takes the project off the no-data path and scores it normally.

---

## 5. UX (v1)

### 5.1 Portfolio overview page (`/pulse`)
- A ranked table/cards of the projects **visible to the user with `view_pulse`**: name, RAG chip,
  `health_score`, `dominant_signal` ("why"), sparkline (retrospective trend), last-activity age.
- **Lens selector** (`health` / `at_risk` / `stale` / `done` / `blocked`) — re-ranks instantly.
- Click a row → per-project panel. Defined empty state (no visible projects) and a permission/visibility
  banner ("computed from issues visible to you").
- Served from cache (§6.4) with a visible `computed_at` ("computed N minutes ago", provenance
  `computed`) + a manual refresh action.

### 5.2 Per-project health panel (`/projects/:id/pulse`, + a project-menu tab)
- The composite score + **full signal breakdown**: each signal's `active` flag, `raw_value`, `n`,
  `w'`, and `contribution` (active rows reconstruct the score; inactive rows show how to enable them).
- The **timeline** (retrospective sparkline with bucket provenance + forward Version milestones).
- **Drill links** into the underlying visible Redmine issues/versions that drive each signal. (Safe by
  construction: links only ever target issues in the viewer's visible set; clicking still passes through
  Redmine's own `Issue.visible` check.)
- States: healthy, no-data (new/empty project), enrichment-unmapped (which signals are inactive + how
  to enable), permission/visibility banner.

### 5.3 Settings (admin)
- Signal mappings (effort field, risk tracker(s), blocked status **id**); weights; RAG thresholds;
  activity-window length; horizons (`H_stale`, `H_risk`, `H_blocked`); momentum shape
  (`momentum_activity_half`, `momentum_direction_bias`); the on-track threshold; and the snapshot
  freshness cap (`snapshot_max_age_minutes`). All validated; defaults ship
  working (DEC-13). A settings change bumps the **settings-version hash** (§6.4) so caches recompute.

Visual encodings (RAG colors, sparklines) are driven by the **real thresholds/data**, never decorative.

---

## 6. Architecture

### 6.1 Style: hexagonal (ports & adapters)
The **scoring engine is pure Ruby domain logic** — no Rails, no ActiveRecord, no `Time.now` — so it
is unit-testable without a Redmine instance.

- **Domain** (pure Ruby, stdlib only): the signal computations and the composite/lens scoring as pure
  functions over plain value objects (`ProjectMetrics` + `Clock` + `ScoringConfig` in → `HealthResult`
  out). This is the testable IP. The domain operates only on already-fetched, already-visibility-scoped
  values — it has no concept of Redmine, permissions, or I/O.
- **Ports** (interfaces; no I/O): `MetricsSource` (supplies visibility-scoped `ProjectMetrics` for a
  given user + project set), `Clock` (current time, injected), `SettingsProvider` (weights/mappings/
  thresholds → `ScoringConfig`), `SnapshotStore` (read/write the cache).
- **Adapters** (Rails/Redmine; own all I/O): `RedmineMetricsSource` (implements `MetricsSource` via
  `Project.visible` / `Issue.visible(user)` / Journal / Changeset / Version / IssueRelation queries —
  read-only), `SystemClock`, `RedmineSettingsProvider`, `ActiveRecordSnapshotStore` (the cache table),
  the Rails **controllers + views** (overview, panel), and the **API controller**.

`MetricsSource` contract is explicit (resolves F-020/F-021): it returns a `ProjectMetrics` whose
fields are already **visibility-scoped** for the requesting user and carry **date provenance**;
nullability and the "visible subset" semantics are part of the port contract and are covered by
**adapter contract tests** against real Redmine models (not only pure-domain unit tests).

### 6.2 Read-only & permission-safe
The plugin **never writes** Redmine domain data (issues, projects, journals, relations, versions).
It owns only its own **settings** + **cache (snapshot) table**. All reads are scoped through Redmine
visibility (§3.1). The only server-side write on a `GET` is an idempotent upsert into the
**plugin-owned** snapshot table on a cache miss (§6.4) — documented and bounded (resolves F-019);
manual refresh is a separate `POST` that invalidates a project's snapshots. A scheduled background
recompute is roadmap.

### 6.3 API surface (read-only JSON)
Authenticated via Redmine API key (the standard REST mechanism: requires the admin "Enable REST web
service" setting; accepts `X-Redmine-API-Key` header, `key` param, or HTTP Basic per Redmine
convention; `accept_api_auth` on the actions), then `authorize`d via `view_pulse` and visibility-scoped
exactly like the UI (resolves F-016):
- `GET /pulse/portfolio.json` → ranked array of per-project health summaries
  (schema: `contracts/schemas/portfolio.json`). Supports `?lens=` and pagination (`?offset=&limit=`,
  default limit 100) for large instances.
- `GET /pulse/projects/:id.json` → one project's full breakdown + history series + forward milestones
  (schema: `contracts/schemas/project.json`).
- Both payloads carry a `schema_version` and **two distinct timestamps** — `snapshot_computed_at`
  (when the static aggregate was cached) and `projected_at` (when the per-request time projection ran)
  — plus a `projection` block (`clock_today` as a date, `time_zone`, `activity_window_days`, the
  horizons) so a client can fully reconstruct the time-derived values (resolves the
  reconstructability gap). Response codes follow §3.1: **404** when the project is not in the viewer's
  visible set or doesn't exist; **403** when visible-but-unpermitted/module-disabled; REST disabled
  yields Redmine's standard 401/403.

### 6.4 Performance & caching (snapshot + clock split)
The rollup is expensive, but the score is **time-dependent** (`staleness`, `momentum`, sparkline
change as the clock advances even with no data change). So caching is split (resolves F-017/F-018,
DEC-11):

- **Static aggregate snapshot** (cached, content-addressed): the expensive, **non-time-dependent**
  visibility-scoped aggregates per `(project_id, visibility_context_id)` — `reference_date`,
  `effort_open`/`effort_total`, `risk_raw`, `blocked_count`, the `{version_id: due_date}` set, and a
  compact **event series** (issue create timestamps + close-event timestamps over a bounded retention
  horizon `≥ 2·W`) needed to project momentum/sparkline at read time. The cache key is a
  `snapshot_fingerprint` over **every** input:
  `max(updated_on) + visible_issue_count + latest_changeset_id + blocker_fingerprint + sorted{version_id:due_date} + priority_enum_version + settings_version_hash + visibility_context_id`.
  Including `visible_issue_count` catches **issue deletion** (max `updated_on` may not move). The
  **`blocker_fingerprint`** is not a mere count+max-id of `blocks` relations — that would miss a
  **visible cross-project blocker changing open/closed state** (its `updated_on` is on another project,
  outside this project's `max(updated_on)`). It is instead, over the set of `blocks` relations targeting
  this project's visible open issues, the sorted tuple-hash of
  `(relation_id, issue_from_id, issue_from.is_closed, issue_from.updated_on)` for each blocker the
  requester can see — so a blocker's status flip invalidates the snapshot. The clock is **not** in this
  key.
- **`visibility_context_id`** = a fingerprint of the **full resolved visibility predicate** for the
  requester on the project — not a coarse role label. It includes everything Redmine's
  `Issue.visible_condition` (via `Project.allowed_to_condition`) actually depends on: the `view_issues`
  permission state (the `issue_tracking` module enabled + the active/closed project-status precondition),
  the per-project effective roles and their `issues_visibility` level (`all`/`default`/`own`), any
  per-tracker view restrictions, the repository module + :view_changesets permission (for changeset
  dates), the `pulse` module state, the admin flag, and the non-member/anonymous builtin-role overrides
  — **plus the user id and group ids whenever any applicable role's `issues_visibility` is
  identity-dependent** (`own`/`default`, where the predicate resolves to
  `author_id = user.id OR assigned_to_id ∈ {user + groups}` over `is_private`/authored/assigned issues).
  (No `view_private_issues` permission exists in Redmine 6.1 — that dimension is the `issues_visibility`
  + identity resolution above, not a separate permission.) The consequence is exact:
  for identity-dependent roles the context **collapses to per-user** (correct, no leak); only for fully
  identity-independent predicates (e.g. role `issues_visibility = all`, no private restriction) do
  distinct users **share** a snapshot. A change to a user's roles/groups/memberships/tracker
  permissions/module state moves them to a different `visibility_context_id` (and a settings/role
  change bumps the fingerprint), so a shared snapshot is never stale or over-broad.
- **Time-derived final score** (computed per request, cheap): `staleness`, `momentum`, the sparkline,
  and therefore `health_score`/RAG/lenses are computed from the snapshot + the current `Clock` on every
  request. `computed_at` reflects the **snapshot** computation instant (provenance `computed`).
- **Invalidation:** a snapshot is recomputed when its `snapshot_fingerprint` changes (content-addressed,
  no TTL guessing). Concurrency: the snapshot table has a unique constraint on
  `(project_id, visibility_context_id, snapshot_fingerprint)`; concurrent read-miss recomputes are
  idempotent (insert-or-ignore), so a stampede converges to one row.

### 6.5 Plugin packaging & compatibility
Standard Redmine plugin layout (`init.rb`, `app/`, `lib/`, `config/locales/`, `db/migrate/`, `assets/`,
`test/`). Declares Redmine `>= 6.1`. A documented compatibility matrix + CI against the targeted Redmine
version on a Redmine-supported Ruby. i18n via `config/locales` (English and Dutch shipped; structure
ready for more). Prefers public Redmine APIs over private internals where one exists (`SOFT-COMPAT-FORWARD`).

---

## 7. Constraints (hard)

- Free, open-source, **GPL-2.0-only**; self-hosted; **no telemetry / SaaS / vendor lock-in**
  (`INV-OPEN`).
- **No invented calendar dates** (`INV-NO-INVENTED-DATES`, provenance-tagged form — §4.4).
- **Read-only** over Redmine domain data (`INV-READ-ONLY`); owns only settings + cache.
- **Permission-safe** — access gated by `view_pulse`; data scoped through Redmine visibility; never
  widens what a user can see (`INV-PERMISSION-SAFE`).
- **Works on standard Redmine fields**; enrichment optional, inactive signals shown not faked
  (`INV-DEGRADES-GRACEFULLY`).
- **Deterministic scoring** — same inputs + clock + config ⇒ same output (`INV-DETERMINISTIC`).
- **Score transparency** — every score reconstructs from its non-negative per-signal contributions
  (`INV-EXPLAINABLE`).
- Domain layer has **zero framework deps** (`INV-DOMAIN-PURITY`).

---

## 8. Acceptance criteria (v1)

See `verification-plan.yaml` for the full mechanism/evidence mapping. Summary:

1. **AC-SCORE-DETERMINISM** — fixed `ProjectMetrics` + `Clock` + `ScoringConfig` ⇒ identical
   `health_score`, RAG, `dominant_signal`, lens keys across runs (pure-domain unit test, no Redmine).
2. **AC-SCORE-FORMULA** — the §4 formulas (per-signal `n`, redistribution, composite, `dominant_signal`,
   lens keys) produce the **expected fixture outputs** for a set of golden `ProjectMetrics` fixtures
   incl. all edge cases (zero-issue, effort_total=0, no-activity, all-closed momentum, all-inactive-but-
   standard, full-enrichment).
3. **AC-DEGRADES** — a standard-fields-only project yields a valid score with `risk_load` `active:false`
   + null values, weight redistributed, and `signal_completeness` reported; the panel shows inactive rows.
4. **AC-EXPLAINABLE** — every score's breakdown is present and `round_half_up(Σ contribution_i) ==
   health_score`; all contributions ≥ 0.
5. **AC-NO-DATES** — every rendered date/interval carries a `provenance` ∈
   {`redmine_timestamp`,`version_due_date`,`computed`,`derived_bucket`}; no `projected`/`estimated`
   provenance exists; a project with zero Version due dates renders an empty forward axis.
6. **AC-PERMISSION-ACCESS** — UI + API render only for users with `view_pulse` on a module-enabled,
   visible project; others get 404 (per-project) / absence (portfolio); REST-disabled → 401/403.
7. **AC-PERMISSION-VISIBILITY** — scores reflect only the requester's visible issue set: with Redmine
   permission fixtures (private issues, role `issues_visibility: own`, hidden trackers, cross-project
   relations, repository-disabled), counts/score/why/drill targets exclude non-visible issues.
8. **AC-READ-ONLY** — no code path writes Redmine domain tables; only plugin settings/cache tables are
   written (integration test with a DB write-guard on domain tables + static scan for
   save/update/destroy/touch outside plugin-owned models + review).
9. **AC-API-SCHEMA** — `portfolio.json` and `projects/:id.json` responses validate against the published
   schemas; the seed examples validate (schema-validation test per emitted schema).
10. **AC-CACHE-INVALIDATION** — a **matrix**: each input class (issue update, issue **deletion**,
    relation add/remove, Version due-date edit, settings change, priority-enum change) invalidates only
    affected snapshots; an unrelated project is not recomputed; **clock advance with zero data change**
    re-projects staleness/momentum **without** a snapshot recompute (the split holds).
11. **AC-LENSES** — each canonical lens (`health`/`at_risk`/`stale`/`done`/`blocked`) produces the
    defined ranking (incl. tie-break by `project_id`) on a fixture portfolio.
12. **AC-DOMAIN-PURITY** — the domain layer imports no Rails/AR/IO and is loadable + testable without
    Redmine (static import scan + the pure-domain suite runs standalone).
13. **AC-OPEN** — repository contains GPL-2.0 text; static check finds no telemetry/network-callout in
    domain or adapters beyond Redmine-internal reads; no SaaS dependency.
14. **AC-COMPAT** — the plugin installs and its tests pass against Redmine 6.1.x on a supported Ruby (CI).
15. **AC-PERF** — portfolio overview renders from cache within the `SOFT-PERF` budget for a fixture of
    low-hundreds of projects (benchmark; advisory threshold).
16. **AC-I18N** — all user-facing strings resolve through `config/locales`; a lint finds no hard-coded
    user-facing English in views/controllers.

---

## 9. v1 / roadmap boundary

**v1:** the executable scoring model (composite + 5 lenses + **5 signals** with graceful degradation),
the portfolio overview page, the per-project panel with retrospective+forward timeline, the read API
(both endpoints), settings, the snapshot/clock-split cache with content-addressed invalidation, the
`view_pulse` permission/module + viewer-scoped visibility.

**Roadmap (not v1):** `coverage_gap` signal (deferred — needs a concrete Redmine-native
deliverables mapping before it is specifiable, F-009); **per-viewer non-cached fine-grained scoring**
beyond the visibility-context cache; background scheduled recompute; effort-field auto-detect (OQ-2);
configurable custom lenses; more i18n locales; per-user saved views/filters; webhooks/push to external
sinks; richer trend analytics; redmine_canvas_gantt deep-link integration; alerting thresholds.

---

## 10. Open questions (logged)

- **OQ-1 (distribution account):** which GitHub org/account hosts the public repo, and the redmine.org
  listing owner. *(operator decision — needed before publish, not before build.)*
- **OQ-2 (effort-field auto-detect):** convenience auto-detection of a `story_points`-style field before
  requiring explicit mapping. *(roadmap; v1 requires explicit mapping — not blocking.)*

*(Resolved since rev 1: **OQ-3** activity window → **30 days**; **OQ-4** RAG thresholds → **67/34**;
both frozen defaults, tunable in settings — DEC-13.)*
