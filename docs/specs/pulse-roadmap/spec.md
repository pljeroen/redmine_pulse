# redmine_pulse — Roadmap Specification (Portfolio Cockpit Extensions)

License: GPL-2.0-only.

Status: **FROZEN** (ready to govern implementation). Downstream build proceeds with no
unresolved questions.

## 1. Overview

This specification defines the next capability wave for **redmine_pulse**, the read-only
portfolio / project-health cockpit for Redmine 6.x. Seven build units (C1–C7) extend the
cockpit with a configurable signal model, a new planning-coverage signal, user-defined
ranking lenses, selectable per-audience scoring, saved views, scheduled recompute with
health alerting, and operator-configured outbound webhooks.

### 1.1 Existing baseline (unchanged foundations)

- Hexagonal architecture: a **pure-Ruby domain** (stdlib only, zero external dependencies),
  ports (Ruby `Protocol`-style duck-typed interfaces), and adapters.
- The cockpit **reads Redmine data read-only** and writes exactly **one reversible cache
  table** (`pulse_snapshots`) via a fingerprint + max-age model.
- Health scoring today uses **five signals** — `staleness`, `progress`, `momentum`,
  `risk_load`, `blocked_load` — with weights that must be exactly those five keys summing to
  1.0; `signal_completeness = active / 5.0`; a severity-first `dominant_signal`; and five
  fixed lens keys — `health`, `at_risk`, `stale`, `done`, `blocked`.
- Metrics are already **visibility-scoped per viewer**: the snapshot cache partitions on the
  viewer's permissions/role, so a viewer only ever sees health derived from data they may see.

### 1.2 Design spine (why C1 is first)

Five of the six product features bottom out on one generalization: the scoring model must
move from a hardcoded five-signal shape to an **N-signal registry** (per-signal enable flag +
weights that renormalize over the enabled set). Delivered backward-compatibly — the default
configuration reproduces today's five-signal output byte-for-byte — this is a safe, deliberate
extension of the frozen scoring model and the keystone every other unit composes on. This
ordering is deliberate: it removes the "big-bang" risk by making each later unit a small,
independently shippable increment.

### 1.3 Build units and dependency order

| Unit | Deliverable | Depends on |
|------|-------------|-----------|
| **C1** | N-signal registry generalization of the scoring engine (backward-compatible) | — (keystone) |
| **C2** | `coverage_gap` planning-coverage signal (additive-optional, default off) | C1 |
| **C3** | `WeightSet` + declarative custom ranking lenses | C1 |
| **C4** | Scoring profiles + per-viewer selection + cache-partition extension | C1 (shares VO with C3) |
| **C5** | `pulse_views` config table + saved views | C3, C4 |
| **C6** | Alert-event model + scheduled recompute/scan + mailer (email) delivery + subscriptions <!-- erratum 2026-07-06 (C6/GQ-C6-INAPP): email-only v1; in-app DEFERRED (Redmine 6.x has no in-app facility — GF-C6-01) --> | C1 |
| **C7** | Outbound webhook adapter (HMAC, SSRF guard, retry) | C6 |

Build order: **C1 → {C2, C3, C6} → C4 → C5 → C7**. After C1, C2/C3/C6 are parallelizable;
C4 follows C3; C5 follows C3+C4; C7 follows C6.

### 1.4 Global invariants (apply to every unit)

- **INV-PURE-DOMAIN** — all business logic (registry, weight sets, lenses, profiles, alert
  rules) lives in the pure-Ruby domain: stdlib only, zero external dependencies, no I/O.
- **INV-READ-ONLY** — the cockpit reads Redmine domain data read-only. The only writable
  tables introduced or used are the reversible cache (`pulse_snapshots`), the reversible
  **config** tables added here (`pulse_views`), and a reversible per-project alert-state
  table. Config and alert-state tables are a distinct category from the snapshot cache; the
  "one reversible cache table" trust narrative is preserved (cache-table count is unchanged).
- **INV-VISIBILITY** — every per-viewer payload counts only data the viewer may see. No new
  feature may widen data visibility.
- **INV-CACHE-PARTITION (security)** — any per-viewer cached payload's partition key (context
  id + fingerprint) must cover **every** permission or configuration dimension the payload
  depends on. A payload that varies by a dimension not in the key is a defect (this class of
  bug previously produced a stale-cache permission leak; it must not recur — see C4).
- **INV-NO-VENDOR-PHONE-HOME** — the plugin itself never contacts the author/vendor and ships
  no telemetry. Operator-configured outbound (C7 webhooks) is explicitly permitted and is the
  operator's own choice on their own install; it is delivered with safe defaults, not
  prohibitions.
- **INV-LOW-FOOTPRINT** — no new hard runtime dependency (no bundled background worker, no
  Redis). Scheduled work is a plain rake task the operator may schedule via cron.
- **INV-ADDITIVE** — every scheduled/optional capability is additive: if never enabled or
  scheduled, the plugin remains 100% functional in synchronous request-cycle mode with
  behavior identical to the prior release.
- **INV-BACKCOMPAT-THAW** — every change to the scoring model is a deliberate,
  backward-compatible extension: the shipped default configuration reproduces the prior
  release's output exactly for identical inputs.

### 1.5 Redmine 6.x platform rules (binding on adapters)

- Any `.json`/API entry point must **re-check the viewer's permission**; format-based routing
  does not inherit session authorization.
- Plugin `lib/` is eager-loaded in production (Zeitwerk): file path must match constant name.
- Gantt/feature gates use `User.current.allowed_to?(:permission, project)`; new capabilities
  introduce their own explicit permissions.
- Every translated locale ships **both** plural and singular unit keys; a completeness parity
  check guards this.

---

## 2. C1 — N-Signal Registry (keystone)

### 2.1 Purpose

Replace the hardcoded five-signal scoring shape with a **signal registry**: a canonical,
ordered catalog of known signals, each with an enable flag and a weight, where weights
renormalize over the currently **enabled** set. The default registry state reproduces today's
five-signal behavior exactly.

### 2.2 Requirements

- **FR-C1-01 (MUST, tier-1)** — A `SignalRegistry` enumerates every known signal with
  metadata: `key`, `always_active?` (whether the signal is active regardless of data),
  `default_weight`, and a fixed `canonical_order` index. The registry is the single source of
  truth for "which signals exist and in what order".
- **FR-C1-02 (MUST, tier-1)** — `ScoringConfig` accepts an **enabled signal set** and a
  weights map that covers exactly the enabled keys, each a finite real Numeric ≥ 0, summing to
  1.0 within 1e-9. Invalid input fails loud (`ArgumentError`).
- **FR-C1-03 (MUST, tier-1)** — The always-active subset **within the enabled set** must have
  weight-sum > 0 (generalization of the existing "non-empty active set" guarantee). Otherwise
  `ArgumentError`.
- **FR-C1-04 (MUST, tier-1)** — `signal_completeness = active_count / enabled_count` (replaces
  the hardcoded `/ 5.0`).
- **FR-C1-05 (MUST)** — `dominant_signal` iterates the **enabled** signals in canonical order;
  severity-first argmin over the active enabled set; the existing `on_track` threshold behavior
  is preserved.
- **FR-C1-06 (MUST)** — `breakdown` emits one `SignalResult` per **enabled** signal, ordered by
  canonical order restricted to the enabled set.
- **FR-C1-07 (MUST)** — The no-data trigger generalizes over enabled signals but remains
  equivalent to today for the default configuration.
- **FR-C1-08 (MUST, tier-1)** — **Backward compatibility:** the default registry state (the
  current five signals, current weights `staleness 0.25 / progress 0.25 / momentum 0.20 /
  risk_load 0.15 / blocked_load 0.15`, current horizons and shape constants) produces a
  `HealthResult` byte-identical to the prior release for identical `ProjectMetrics` inputs
  across a golden fixture set.
- **FR-C1-09 (MUST)** — The settings adapter **renormalizes** weights proportionally when a
  signal is enabled/disabled, so the operator-facing weights need not be manually re-summed;
  the domain value object nonetheless stays strict (rejects a non-summing map).
- **FR-C1-10 (SHOULD)** — Lens-key computation generalizes over the registry, but the default
  lens set (`health`, `at_risk`, `stale`, `done`, `blocked`) and the `at_risk` enrichment
  subset are unchanged for the default configuration.

### 2.3 Invariants
INV-PURE-DOMAIN, INV-BACKCOMPAT-THAW (FR-C1-08 is the falsifiable form), plus a strict
value-object guard (FR-C1-02/03 fail loud).

### 2.4 Acceptance criteria

- **AC-C1-01** — With the default registry, the golden fixture set yields a `HealthResult`
  (`health_score`, `rag`, `dominant_signal`, `signal_completeness`, `breakdown` order+values,
  `lens_keys`) equal to the prior release output exactly.
- **AC-C1-02** — Enabling a sixth signal → `breakdown` has six entries, `signal_completeness`
  denominator is 6, weights validated over six keys.
- **AC-C1-03** — Weights not summing to 1.0 → `ArgumentError`.
- **AC-C1-04** — Disabling a signal removes it from `breakdown`, the dominant-candidate set,
  and the completeness denominator.
- **AC-C1-05** — Enabled always-active subset weight-sum 0 → `ArgumentError`.
- **AC-C1-06** — Settings adapter: toggling a signal renormalizes remaining weights to sum 1.0
  by deterministic proportional scaling.

### 2.5 Dependencies
None (keystone). Consumed by C2, C3, C4, C6.

---

## 3. C2 — coverage_gap Signal (planning coverage)

### 3.1 Purpose

Add a sixth health signal that measures how well the **open** work of a project is *planned*.
In modern PM practice, unplanned open work (no estimate, no owner, no schedule) is the primary
hidden delivery risk. The signal is derivable from core Redmine fields, so it works in any
instance with zero configuration.

### 3.2 Requirements

- **FR-C2-01 (MUST)** — `coverage_gap` is registered as a known signal: **not** always-active,
  `default_weight = 0.15`, and **disabled by default**.
- **FR-C2-02 (MUST)** — The metrics source provides per-project, visibility-scoped planning
  inputs for **open** issues: `open_issue_count`, and per open issue the three booleans below.
  All read-only from Redmine.
- **FR-C2-03 (MUST)** — Per open issue, coverage fraction = mean of three dimensions:
  - `has_estimate` — `estimated_hours` present and > 0;
  - `has_assignee` — `assigned_to` present;
  - `has_schedule` — `due_date` present **OR** `fixed_version` present.
  Signal `n = clamp(mean coverage across open issues, 0, 1)` (higher = healthier).
  `raw_value = mean gap fraction = 1 − mean coverage` (informational).
- **FR-C2-04 (MUST)** — Active iff `open_issue_count > 0`; otherwise inactive (all numeric
  fields nil, consistent with `progress`/`risk_load`).
- **FR-C2-05 (MUST, tier-1)** — Default OFF: while disabled, the `HealthResult` is identical to
  the pre-C2 output for the same inputs (rides on C1 backward compatibility).
- **FR-C2-06 (MUST)** — When enabled, `coverage_gap` participates in scoring, dominant-signal
  selection, and completeness exactly like any other enabled signal.
- **FR-C2-07 (SHOULD)** — `raw_value` is surfaced in the UI as "planning coverage N%"
  (= `100 × mean coverage`), with correct singular/plural unit keys.
- **FR-C2-08 (MUST)** — The three dimensions are fixed in v1 (not admin-configurable);
  documented as such.

### 3.3 Invariants
INV-READ-ONLY, INV-VISIBILITY (only issues visible to the viewer count).

### 3.4 Acceptance criteria

- **AC-C2-01** — A project whose open issues are all fully planned → `n = 1.0`.
- **AC-C2-02** — A project with no open issues → `coverage_gap` inactive.
- **AC-C2-03** — Mixed coverage → `n` equals the mean fraction (worked example: two open
  issues, one 3/3-covered and one 0/3-covered → `n = 0.5`).
- **AC-C2-04** — `has_schedule` is true when `due_date` is present **or** `fixed_version` is
  present (either alone suffices).
- **AC-C2-05** — Disabled (default) → `HealthResult` identical to pre-C2 for identical inputs.
- **AC-C2-06** — Coverage inputs respect issue visibility (issues invisible to the viewer are
  excluded from the counts).

### 3.5 Dependencies
C1.

---

## 4. C3 — Custom Ranking Lenses

### 4.1 Purpose

Let users define named **ranking lenses**: a weighted subset of signals used to rank/sort the
portfolio by a chosen emphasis (e.g. "Delivery risk" = risk-heavy). Lenses are declarative and
fully validated — no formula language.

### 4.2 Requirements

- **FR-C3-01 (MUST)** — `WeightSet` value object: a frozen map of signal-key → weight over a
  subset of registered signals. Validates that keys are registered, weights are finite real
  Numerics ≥ 0, and at least one weight > 0. Fails loud otherwise. **This VO is shared with
  C4 scoring profiles.**
- **FR-C3-02 (MUST)** — `CustomLens` value object = `{ name (non-empty String), weight_set
  (WeightSet), sort_direction (:asc | :desc), threshold (Numeric or nil) }`. Frozen; fails loud
  on invalid input.
- **FR-C3-03 (MUST)** — A lens's ranking score for a project = **normalized weighted mean** of
  the chosen signals' normalized `n`: `Σ(wᵢ·nᵢ) / Σ(wᵢ)` over the lens's signals that are
  enabled and active. When the denominator is 0 (all chosen signals inactive) the project is
  **unrankable** by that lens (ranking score nil).
- **FR-C3-04 (MUST)** — No formula/expression DSL. Only declarative weighted subsets.
- **FR-C3-05 (MUST)** — A lens references only registered signal keys; a chosen signal that is
  currently disabled or inactive is excluded from both numerator and denominator.
- **FR-C3-06 (MUST)** — A built-in lens **catalog** is defined in code. User-authored lenses
  are of the weighted-signal-score family (as FR-C3-03). The existing raw-metric lenses
  (`stale`, `done`, `blocked` — direct metric passthroughs) remain built-in and are **not**
  user-authorable in v1. Persistence of user-authored/private lenses rides on the C5 config
  store; C3 delivers the pure VO, validation, ranking, and built-in catalog so a lens from any
  source is computable.
- **FR-C3-07 (SHOULD)** — The five existing lens keys remain available and unchanged in default
  output (consistent with FR-C1-10).

### 4.3 Invariants
INV-PURE-DOMAIN; strict VO (fails loud). Ranking is a pure function of `HealthResult`/signal
data.

### 4.4 Acceptance criteria

- **AC-C3-01** — `CustomLens` / `WeightSet` referencing an unknown signal key → `ArgumentError`.
- **AC-C3-02** — Negative or non-finite weight → `ArgumentError`.
- **AC-C3-03** — Ranking score equals the normalized weighted mean of active chosen signals'
  `n` (worked example verified numerically).
- **AC-C3-04** — A lens whose chosen signals are all inactive → ranking score nil (unrankable);
  a partially-inactive lens excludes inactive signals from the denominator.
- **AC-C3-05** — `CustomLens` is frozen; mutation raises `FrozenError`.
- **AC-C3-06** — Empty name → `ArgumentError`; `sort_direction` outside `{:asc, :desc}` →
  `ArgumentError`.

### 4.5 Dependencies
C1. Shares `WeightSet` with C4. User-lens persistence lands with C5.

---

## 5. C4 — Scoring Profiles & Per-Viewer Scoring

### 5.1 Purpose

Deliver "fine-grained per-viewer scoring" as selectable **scoring profiles**: named
configurations (which signals are enabled, their weights, RAG thresholds and shape) that
different audiences can score under. An admin publishes presets; a viewer may switch; an admin
may bind a default profile to a role/group.

### 5.2 Requirements

- **FR-C4-01 (MUST)** — `ScoringProfile` value object = `{ id, name, config (a ScoringConfig:
  enabled signals + weights via WeightSet + RAG thresholds + horizons + momentum shape) }`.
  Immutable.
- **FR-C4-02 (MUST)** — The admin publishes named preset profiles via settings. A **system
  default profile** always exists (id `default`) equal to the current global configuration.
- **FR-C4-03 (MUST)** — A viewer may select an active profile from the published set. Active
  profile resolves in precedence order: **explicit viewer selection** (persisted via a saved
  view, C5) > **role-default binding** (FR-C4-04) > **system default**.
- **FR-C4-04 (MUST)** — An admin MAY bind a default profile id to a Redmine role/group;
  resolution uses the viewer's roles.
- **FR-C4-05 (MUST, tier-1, security)** — The **active profile id is a component of the
  snapshot cache partition** (folded into the context id / `SnapshotFingerprint`). A snapshot
  computed under profile A must never be served for profile B. Rationale: the payload varies by
  profile, so per INV-CACHE-PARTITION the key must cover profile; omitting it reintroduces the
  prior stale-cache leak class.
- **FR-C4-06 (MUST)** — Scoring under a profile uses that profile's config; `health_score`,
  `rag`, and `dominant_signal` reflect it.
- **FR-C4-07 (MUST)** — Each profile carries its own enabled signal set (a profile may enable
  `coverage_gap` while another does not).
- **FR-C4-08 (SHOULD)** — The UI shows the active profile name ("scored under: <name>") and a
  switcher.
- **FR-C4-09 (MUST)** — A saved view or role-binding referencing a removed/renamed profile
  degrades gracefully to the system default with a surfaced warning; no error/crash.

### 5.3 Invariants
- **INV-C4-CACHE-PARTITION** — profile id ∈ cache key (FR-C4-05 is its falsifiable form).
- **INV-C4-PERM-UNCHANGED** — profiles change **weighting only**, never widen visibility; the
  visible issue set is still gated by the viewer's permissions.

### 5.4 Acceptance criteria

- **AC-C4-01** — Same project + viewer, two profiles with different weights → two distinct
  cached snapshots and distinct scores; no cross-serve.
- **AC-C4-02** — Profile resolution precedence (viewer selection > role binding > default) holds.
- **AC-C4-03** — A profile that disables a signal → that project's breakdown under the profile
  omits it.
- **AC-C4-04** — INV-C4-PERM-UNCHANGED: a profile cannot cause an issue invisible to the viewer
  to be counted.
- **AC-C4-05** — A dangling profile reference → falls back to default with a warning, no error.
- **AC-C4-06** — The system default profile reproduces the global-config output (compat).

### 5.5 Dependencies
C1; shares `WeightSet` with C3. Viewer-selection persistence completes with C5.

---

## 6. C5 — Saved Views

### 6.1 Purpose

Persist named cockpit configurations, modeled directly on Redmine's own custom-queries
(`IssueQuery`) pattern that users already understand: private "My views" plus shareable public
and role-scoped views.

### 6.2 Requirements

- **FR-C5-01 (MUST)** — A new **reversible** migration creates a `pulse_views` **config** table
  (explicitly not the snapshot cache). Columns: `id`, `name`, `user_id` (owner; nil for
  system/built-in), `visibility` (`private | public | roles`), `role_ids` (for role-scoped),
  `project_scope` (`all | selected | status_filter`) + scope params, `lens_ref`, `profile_ref`,
  `sort`, `prefs` (serialized threshold/column preferences), timestamps.
- **FR-C5-02 (MUST, tier-1)** — Visibility mirrors `IssueQuery`: **private** (owner only),
  **public** (any user who may view the cockpit), **role-scoped** (members holding a listed
  role). Publishing public or role-scoped is gated by a new plugin permission
  `:manage_public_pulse_views`.
- **FR-C5-03 (MUST)** — A `PulseView` captures `{ project scope, active lens (C3), active
  scoring profile (C4), sort, threshold/column prefs }`.
- **FR-C5-04 (MUST)** — Private by default.
- **FR-C5-05 (MUST)** — Built-in default views ship: **Portfolio health**, **At risk**,
  **Stalled** (system-owned, public).
- **FR-C5-06 (MUST)** — Selecting a view sets the active lens and active profile; this selection
  is the persistence that satisfies the per-viewer profile selection in FR-C4-03.
- **FR-C5-07 (MUST)** — User-authored/private custom lenses (C3) persist via this config store
  (a named private lens, or embedded in a view).
- **FR-C5-08 (MUST, tier-1)** — Access control: a user sees a view iff it is their private view,
  or public, or role-scoped to a role they hold; editing is gated by ownership or
  `:manage_public_pulse_views`. Enforced server-side; `.json` access re-checks permission.
- **FR-C5-09 (MUST)** — Migration is reversible (down drops the config table); no impact on the
  snapshot cache.

### 6.3 Invariants
- **INV-C5-CONFIG-NOT-CACHE** — `pulse_views` is config, never the snapshot cache; the "one
  reversible cache table" narrative holds.
- **INV-C5-PERM** — view visibility enforced server-side; `.json` re-checks permission.

### 6.4 Acceptance criteria

- **AC-C5-01** — Migration up creates `pulse_views`; down drops it cleanly (reversible).
- **AC-C5-02** — Private view invisible to non-owner; public visible to any cockpit viewer;
  role-scoped visible only to holders of a listed role.
- **AC-C5-03** — Publishing without `:manage_public_pulse_views` is denied.
- **AC-C5-04** — Built-in default views present after install.
- **AC-C5-05** — Selecting a view applies its lens + profile + scope.
- **AC-C5-06** — `.json` access to a view re-checks permission (no session-auth bypass).

### 6.5 Dependencies
C3, C4.

---

## 7. C6 — Scheduled Recompute & Health Alerting

### 7.1 Purpose

Proactively warm snapshots and notify the right people when a project's health **changes** —
without a bundled background worker. Both capabilities are additive: if never scheduled, the
cockpit behaves exactly as today.

### 7.2 Mechanism decision

A plain **rake task the operator schedules via cron**, not a bundled worker (Sidekiq/
delayed_job). Rationale: zero new runtime dependency, low footprint, self-host friendly, and
additive. Redmine itself ships rake+cron for recurring work (`redmine:send_reminders`), so this
is idiomatic. Two tasks: `redmine_pulse:recompute` (warm snapshots) and
`redmine_pulse:scan_and_alert` (detect transitions and dispatch).

### 7.3 Requirements

- **FR-C6-01 (MUST)** — `redmine_pulse:recompute` warms snapshots (recomputes under the
  canonical/global profile) for all projects or a filtered subset; idempotent and safe to
  re-run; honors the existing max-age/fingerprint mechanics.
- **FR-C6-02 (MUST)** — `redmine_pulse:scan_and_alert` computes current health per project
  (canonical profile), compares to persisted prior state, and emits `AlertEvent`s on
  transitions.
- **FR-C6-03 (MUST, tier-1)** — Additive: if neither task is ever scheduled, the plugin remains
  fully functional in synchronous mode with behavior identical to the prior release, and no
  scheduler/worker dependency exists.
- **FR-C6-04 (MUST)** — A new **reversible** migration creates a per-**project** alert-state
  store: last RAG band, last dominant signal, last no-data flag, last score, `updated_at`.
  Recorded under the canonical/global profile only (not per-viewer).
- **FR-C6-05 (MUST)** — `AlertEvent` domain value object = `{ project_id, event_type
  (:rag_transition | :dominant_change | :no_data_appeared | :score_delta), from, to, score,
  previous_score, delta, occurred_at }`. Pure domain; frozen.
- **FR-C6-06 (MUST)** — Triggers: `rag_transition` (band change, primary), `dominant_change`,
  `no_data_appeared`, and an optional `score_delta` when `|delta| ≥ N` for an admin-configured
  threshold `N` (default: disabled).
- **FR-C6-07 (MUST, tier-1, security)** — Recipient resolution for project P: users who
  **currently hold the plugin view permission on P** AND are **subscribed** (see FR-C6-08).
  Permission is **re-checked at send time**, not only at subscribe time.
- **FR-C6-08 (MUST)** — Subscription model: explicit opt-in **"Watch project health"** per user
  per project (mirrors Redmine watchers), PLUS an admin setting to **auto-subscribe** members of
  a configured role (e.g. project managers).
- **FR-C6-09 (MUST)** — Delivery via the Redmine mailer (ActionMailer/existing SMTP). In-app
  notification DEFERRED (Redmine 6.x has no in-app facility — GF-C6-01; GQ-C6-INAPP resolved
  email-only v1, 2026-07-06). <!-- erratum 2026-07-06 (C6/GQ-C6-INAPP): operator-approved R-A email-only v1; in-app is a Rule-41 declared deferral, platform-blocked per GF-C6-01; AlertDelivery port retained for a future in-app adapter -->
- **FR-C6-10 (MUST)** — `scan_and_alert` updates the alert-state **after** successful
  evaluation so each transition fires exactly once (a re-run with no change emits nothing).
- **FR-C6-11 (SHOULD)** — `recompute` reuses the existing fingerprint/max-age cache mechanics.
- **FR-C6-12 (MUST)** — Alerting operates on the canonical profile only; per-viewer alerting is
  explicitly out of scope.

### 7.4 Invariants
INV-ADDITIVE, INV-LOW-FOOTPRINT, INV-READ-ONLY (recompute writes only the cache + alert-state,
both reversible), plus **INV-C6-PERM-AT-SEND** (FR-C6-07) and **INV-C6-ONCE** (FR-C6-10).

### 7.5 Acceptance criteria

- **AC-C6-01** — Never scheduling either task → synchronous request-path behavior unchanged
  vs. the prior release.
- **AC-C6-02** — A green→amber transition emits one `rag_transition`; a second run without
  change emits nothing.
- **AC-C6-03** — A dominant-signal change emits `dominant_change`.
- **AC-C6-04** — A project becoming genuinely empty emits `no_data_appeared`.
- **AC-C6-05** — A recipient is a subscribed **and** view-permitted user; a subscribed user who
  lost view permission receives nothing (re-checked at send).
- **AC-C6-06** — Admin auto-subscribe role → members of that role receive without an explicit
  watch.
- **AC-C6-07** — Alert-state migration up/down is reversible.
- **AC-C6-08** — `score_delta` fires only when `|delta| ≥ N` and `N` is configured.
- **AC-C6-09** — `recompute` is idempotent (a repeat run leaves the same cache state, no
  duplicate work observable).

### 7.6 Dependencies
C1. Produces the `AlertEvent` stream consumed by C7.

---

## 8. C7 — Outbound Webhooks

### 8.1 Purpose

Let an operator forward health `AlertEvent`s to their own HTTP endpoints. This is the
operator's sovereign choice on their own install (INV-NO-VENDOR-PHONE-HOME constrains only the
*plugin* contacting the vendor, never the operator's own integrations). Delivered with safe
defaults, not prohibitions.

### 8.2 Requirements

- **FR-C7-01 (MUST)** — An outbound webhook **port** (`WebhookDispatcher`) with an HTTP
  **adapter**. The domain emits `AlertEvent` value objects; the adapter serializes and
  delivers. No outbound HTTP in the domain.
- **FR-C7-02 (MUST, tier-1)** — Endpoints configured admin-side: **global endpoints + per-
  project overrides**, each `{ url, secret, enabled, event filter, ssrf_override, redaction }`.
  **Off by default** — with no endpoints configured, zero outbound traffic.
- **FR-C7-03 (MUST)** — Payload is versioned JSON per `contracts/schemas/webhook-payload.json`,
  carrying read-only snapshot data only.
- **FR-C7-04 (MUST)** — Fires on the same `AlertEvent` stream as C6, emitted from the background
  path — never blocking a web request.
- **FR-C7-05 (MUST)** — Delivery is at-least-once with bounded retry (3 attempts, backoff) then
  dead-letter/log. No unbounded retry.
- **FR-C7-06 (MUST, tier-1, security)** — Safe defaults: HTTPS-only default (overridable per
  endpoint); ~5s connect/read timeout; **SSRF guard default-ON** blocking loopback / RFC1918 /
  `169.254.169.254` (cloud metadata), **overridable per endpoint**; HMAC-SHA256 signature with a
  per-endpoint secret; redaction option; a manual "send test event" action.
- **FR-C7-07 (MUST)** — The signature is HMAC-SHA256 over the exact raw body using the endpoint
  secret, carried in a header (e.g. `X-Pulse-Signature`).
- **FR-C7-08 (SHOULD)** — Delivery attempts and outcomes are logged for observability without
  leaking secrets.
- **FR-C7-09 (MUST)** — The "send test event" action delivers a synthetic `AlertEvent` to one
  endpoint and surfaces the HTTP result.

### 8.3 Invariants
- **INV-C7-DOMAIN-PURE** — no outbound HTTP in the domain; adapter only.
- **INV-C7-NO-BLOCK** — webhook delivery never blocks the request cycle.
- **INV-C7-DEFAULT-OFF** — no endpoints ⇒ no outbound traffic (only operator-configured
  destinations are ever contacted).
- **INV-C7-SSRF-DEFAULT** — guard on by default, overridable per endpoint.

### 8.4 Acceptance criteria

- **AC-C7-01** — The seed payload validates against `webhook-payload.json`.
- **AC-C7-02** — With no endpoints configured, zero outbound requests are made.
- **AC-C7-03** — The HMAC signature verifies against the endpoint secret over the exact body.
- **AC-C7-04** — The SSRF guard blocks a loopback/RFC1918/metadata URL by default; a per-
  endpoint override permits it.
- **AC-C7-05** — Delivery retries up to 3 times with backoff then dead-letters; retry is
  bounded.
- **AC-C7-06** — HTTPS-only default rejects an `http://` endpoint unless overridden.
- **AC-C7-07** — The test-event action delivers a synthetic event and reports the HTTP status.
- **AC-C7-08** — The ~5s timeout is enforced; a slow endpoint does not hang the scan.

### 8.5 Dependencies
C6 (consumes its `AlertEvent` stream and background path).

---

## 9. Cross-cutting notes

- **Frozen-model thaw (C1):** C1 modifies the previously-frozen scoring model. FR-C1-08 /
  AC-C1-01 (golden byte-identical default output) is the gate that must pass before C2/C4 layer
  further scoring behavior on top.
- **Cache partition (C4):** adding the profile dimension to the payload requires extending the
  cache partition (FR-C4-05); failing to do so reintroduces a known permission-leak class.
- **Shared value object (C3/C4):** `WeightSet` is authored once in C3 and reused by C4.
- **Shared alert stream (C6/C7):** C6 produces `AlertEvent`s; C7 consumes them. Build C6 first.
- **Saved views are UI-heavy (C5):** keep domain logic thin; push richness to the view layer.
- **Residual operator decisions:** all four product forks were resolved with the operator on
  2026-07-06 (coverage_gap rollout = additive default-off; per-viewer = presets + viewer
  override + role-default binding; alert subscription = opt-in watch + optional PM-role
  auto-subscribe; webhook SSRF = guard-on-overridable). No open questions remain.
