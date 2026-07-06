# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # HtmlPresenter — the explicit view-model layer (COND-A4-001/002). It precomputes
    # ALL display state for the HTML surfaces so the ERB templates consume ONLY plain
    # precomputed fields and never call Scoring/Timeline/MetricsSource/SnapshotStore/
    # SnapshotFingerprint/VisibilityContext or any ActiveRecord query / score recompute.
    #
    # All user-facing strings are localized here via I18n (the views read the already-
    # localized strings); RAG chips carry a non-color cue + accessible label (WCAG
    # 1.4.1 / D-CA-OQ04). Pure presentation — it reads the already-computed domain
    # results off the Projection. The view-model structs are NESTED so the file name
    # matches its single primary constant (Zeitwerk autoload-naming).
    module HtmlPresenter
      # C2 (FC-C2-15): coverage_gap is appended LAST. A row is rendered ONLY for the keys
      # actually present in the breakdown (coverage_gap is absent on the default-OFF path, so
      # the panel stays byte-identical), in this canonical order.
      SIGNAL_KEYS = %w[staleness progress momentum risk_load blocked_load coverage_gap].freeze
      COVERAGE_GAP_KEY = 'coverage_gap'

      # One RAG chip's precomputed accessible state (non-color cue + aria label).
      RagChip = Struct.new(:state, :word, :aria_label, keyword_init: true)

      # One signal row for the panel (active or inactive-with-enable-hint). `label` is the
      # localized display name for the signal column (A10-C2-004): coverage_gap shows the
      # localized "Planning coverage" label; the 5 C1 signals keep their raw-key label text
      # (byte-identical default panel).
      SignalRow = Struct.new(:key, :label, :active, :raw_value, :n, :effective_weight,
                             :contribution, :enable_hint, :drill_url, keyword_init: true)

      # One project row for the portfolio overview. `main_concern` carries the
      # lens-vocabulary label for the severity-first dominant signal (R-A relabel);
      # `no_data` flags the 0-issue state (nil score, rag :no_data).
      PortfolioRow = Struct.new(:project_id, :identifier, :name, :url, :health_score,
                                :rag_chip, :dominant_signal, :main_concern, :computed_ago,
                                :sparkline, :no_data, keyword_init: true)

      # The whole portfolio overview view-model. `profile_warning` carries the human-readable
      # dangling-fallback warning (FC-C4-12 / FR-C4-09) when the viewer's ?profile_id selection
      # referenced an unpublished profile (scoring fell back to the system default); nil / blank
      # otherwise (no banner rendered).
      PortfolioView = Struct.new(:rows, :lens, :lenses, :default_lens, :visibility_note,
                                 :empty, :profile_warning, keyword_init: true)

      # The whole per-project panel view-model. `main_concern` is the lens-vocabulary
      # label for the severity-first dominant signal; `no_data` flags the 0-issue state
      # (nil score / rag :no_data) so the panel renders a "No data" indicator, not a
      # numeric score; `no_data_label` is the localized indicator text.
      PanelView = Struct.new(:project_id, :identifier, :name, :health_score, :rag_chip,
                             :dominant_signal, :main_concern, :signal_completeness,
                             :computed_ago, :signal_rows, :sparkline, :milestones,
                             :gantt_url, :visibility_note, :no_data, :no_data_label,
                             :active_profile_name, :profile_options, :profile_warning,
                             keyword_init: true)

      # C4 (FC-C4-17): one precomputed switcher option — plain presentation values (id/label/
      # selected), NEVER a domain ScoringProfile object, so the ERB reads only presenter
      # output (COND-A4-001). `value` == the profile id (the ?profile query param value).
      ProfileOption = Struct.new(:value, :label, :selected, keyword_init: true)

      module_function

      # Build the portfolio overview view-model from ranked projections.
      def portfolio_view(ranked_projections, lens:, now:)
        rows = ranked_projections.map { |p| portfolio_row(p, now) }
        PortfolioView.new(
          rows: rows,
          lens: lens.to_s,
          lenses: LensRanker::LENSES,
          default_lens: LensRanker::DEFAULT_LENS,
          visibility_note: I18n.t(:label_pulse_visibility_note),
          empty: rows.empty?,
          profile_warning: first_profile_warning(ranked_projections)
        )
      end

      def portfolio_row(projection, now)
        h = projection.health
        no_data = h.dominant_signal.nil? && h.health_score.nil?
        PortfolioRow.new(
          project_id: projection.project.id,
          identifier: projection.project.identifier,
          name: projection.project.name,
          url: "/projects/#{projection.project.identifier}/pulse",
          health_score: display_score(h.health_score),
          rag_chip: rag_chip(h.rag),
          dominant_signal: h.dominant_signal&.to_s,
          main_concern: main_concern_label(h.dominant_signal),
          computed_ago: computed_ago(projection.snapshot_computed_at, now),
          sparkline: sparkline_points(projection.timeline),
          no_data: no_data
        )
      end

      # Build the per-project panel view-model. `gantt_url` is a precomputed scalar (or
      # nil) supplied by the controller — the controller owns Redmine authorization
      # (User.current.allowed_to?(:view_gantt, project), which also covers the :gantt
      # module) and route generation, so the presenter stays free of Redmine auth/routing.
      def panel_view(projection, now:, gantt_url: nil)
        h = projection.health
        no_data = h.dominant_signal.nil? && h.health_score.nil?
        PanelView.new(
          project_id: projection.project.id,
          identifier: projection.project.identifier,
          name: projection.project.name,
          health_score: display_score(h.health_score),
          rag_chip: rag_chip(h.rag),
          dominant_signal: h.dominant_signal&.to_s,
          main_concern: main_concern_label(h.dominant_signal),
          signal_completeness: h.signal_completeness,
          computed_ago: computed_ago(projection.snapshot_computed_at, now),
          signal_rows: signal_rows(projection),
          sparkline: sparkline_points(projection.timeline),
          milestones: milestones(projection.timeline),
          gantt_url: gantt_url,
          visibility_note: I18n.t(:label_pulse_visibility_note),
          no_data: no_data,
          no_data_label: I18n.t(:label_pulse_no_data),
          active_profile_name: active_profile_name(projection),
          profile_options: profile_options(projection),
          profile_warning: profile_warning(projection)
        )
      end

      # C4 (FC-C4-12 / FR-C4-09): the human-readable dangling-fallback warning for the panel,
      # read off the precomputed projection.profile_warning (nil / blank => no banner). A
      # pre-C4-shaped projection that carries no such field degrades to nil (no crash).
      def profile_warning(projection)
        return nil unless projection.respond_to?(:profile_warning)

        w = projection.profile_warning
        w.nil? || (w.respond_to?(:strip) && w.strip.empty?) ? nil : w
      end

      # The first non-blank per-project dangling-fallback warning across the portfolio (the
      # ?profile_id override warning is identical for every project, so surfacing the first is
      # sufficient for the portfolio banner). nil when no project carried a warning.
      def first_profile_warning(projections)
        projections.each do |p|
          w = profile_warning(p)
          return w unless w.nil?
        end
        nil
      end

      # C4 (FC-C4-17 a): the ACTIVE profile's display name for the "scored under: <name>"
      # header. Reads the precomputed projection.active_profile_name (or the active_profile's
      # name); nil when no profile context is present (default-only / pre-C4-shaped projection).
      def active_profile_name(projection)
        if projection.respond_to?(:active_profile_name) && projection.active_profile_name
          return projection.active_profile_name
        end
        if projection.respond_to?(:active_profile) && projection.active_profile
          return projection.active_profile.name
        end

        nil
      end

      # C4 (FC-C4-17 b): the switcher options — one PLAIN precomputed value per published
      # profile (value == profile.id, label == profile.name, selected == it is the active
      # profile). NEVER a domain ScoringProfile (COND-A4-001). Empty when the projection
      # carries no published set (default-only / pre-C4-shaped projection).
      def profile_options(projection)
        return [] unless projection.respond_to?(:published_profiles)

        published = projection.published_profiles
        return [] if published.nil?

        active_id = active_profile_id(projection)
        published.map do |p|
          ProfileOption.new(value: p.id, label: p.name, selected: p.id == active_id)
        end
      end

      def active_profile_id(projection)
        return nil unless projection.respond_to?(:active_profile) && projection.active_profile

        projection.active_profile.id
      end

      # ── R-A "Main concern" lens-vocabulary mapping ──────────────────────────────
      # The dominant_signal -> localized lens label mapping is the SINGLE authoritative
      # source Pulse::Adapters::MainConcernLabels (FR-PLB-15 / DG-PLB-02). HtmlPresenter
      # (the cockpit) and JsonSerializer (the API + inline badge blob) BOTH delegate to
      # it, so the cockpit and the API can never drift. MAIN_CONCERN_KEYS is retained as
      # an alias of the shared mapping for backward compatibility with any reader.
      MAIN_CONCERN_KEYS = MainConcernLabels::KEYS

      def main_concern_label(dominant_signal)
        MainConcernLabels.label(dominant_signal)
      end

      # ── display rounding (finding 3, HTML side) ─────────────────────────────────
      # health_score is already an integer (or nil for no-data); pass through.
      def display_score(score)
        score
      end

      # Round a raw float for DISPLAY only (1-2 decimals). Never touches the JSON
      # explainability passthrough (json_serializer emits verbatim contribution /
      # effective_weight — FC-CA-23). nil passes through.
      def display_round(value, decimals = 2)
        return value if value.nil?
        return value unless value.is_a?(Numeric)

        value.round(decimals)
      end

      # A weight/contribution rendered as a percentage (1 decimal), for the panel.
      def display_percent(value)
        return value if value.nil?
        return value unless value.is_a?(Numeric)

        "#{(value.to_f * 100).round(1)}%"
      end

      # ── RAG accessibility (D-CA-OQ04): non-color localized word + aria label ────
      def rag_chip(rag)
        state = rag.to_s
        word = I18n.t("label_pulse_rag_#{state}")
        RagChip.new(
          state: state,
          word: word,
          aria_label: I18n.t(:label_pulse_rag_aria_label, state: word)
        )
      end

      # ── signal rows incl. inactive-with-enable-hint (CA-26 / FC-CA-26) ──────────
      def signal_rows(projection)
        by_key = projection.health.breakdown.to_h { |s| [s.key.to_s, s] }
        # Render ONLY the keys present in the breakdown, in canonical order. coverage_gap is
        # absent on the default-OFF path, so no coverage_gap row appears then (FC-C2-15) and
        # the 5-row panel is byte-identical.
        SIGNAL_KEYS.select { |key| by_key.key?(key) }.map do |key|
          s = by_key[key]
          SignalRow.new(
            key: key,
            label: signal_label(key),
            active: s.active,
            # finding 3 (HTML side): round value / effective_weight / contribution for
            # DISPLAY only. The JSON serializer keeps emitting these verbatim (FC-CA-23).
            # coverage_gap displays PLANNING COVERAGE = 100×(1−raw_value), NOT the raw gap
            # fraction (FC-C2-15) — the row shows how planned the open work is.
            raw_value: display_row_value(key, s),
            n: s.active ? display_round(s.n) : nil,
            effective_weight: s.active ? display_percent(s.effective_weight) : nil,
            contribution: s.active ? display_round(s.contribution) : nil,
            enable_hint: s.active ? nil : enable_hint(key),
            drill_url: s.active ? JsonSerializer.drill_url(projection, key, s) : nil
          )
        end
      end

      # A10-C2-004: the localized signal-column display name. coverage_gap resolves the
      # dedicated localized "Planning coverage" label (label_pulse_planning_coverage, defined
      # in en.yml + nl.yml); the 5 C1 signals keep their raw-key text (default panel unchanged).
      def signal_label(key)
        return I18n.t(:label_pulse_planning_coverage) if key == COVERAGE_GAP_KEY

        key
      end

      # The DISPLAYED value for a signal row. coverage_gap renders the planning-coverage
      # percentage 100×(1−raw_value) (FC-C2-15); every other signal renders its rounded
      # raw_value. Inactive => nil.
      def display_row_value(key, signal)
        return nil unless signal.active

        if key == COVERAGE_GAP_KEY
          display_round(100.0 * (1.0 - signal.raw_value))
        else
          display_round(signal.raw_value)
        end
      end

      # An inactive signal carries an enable-hint (never silently omitted).
      def enable_hint(key)
        I18n.t("pulse.enable_hint_#{key}", default: I18n.t(:pulse_enable_hint_generic,
                                                           default: 'inactive — map an enrichment field to enable'))
      end

      # ── sparkline + milestones for the panel/overview ───────────────────────────
      def sparkline_points(timeline_result)
        timeline_result.retrospective.map do |b|
          { start: b.start[:at], end: b.end[:at], value: b.event_count }
        end
      end

      def milestones(timeline_result)
        timeline_result.forward.map do |mk|
          { version_id: mk.version_id, name: mk.name, due_date: mk.due_date[:date] }
        end
      end

      # ── "computed N <unit> ago" (CA-10e / FC-CA-10b) ────────────────────────────
      def computed_ago(at, now)
        seconds = (now - at).to_i
        seconds = 0 if seconds.negative?
        n, unit = humanize_span(seconds)
        I18n.t(:'pulse.computed_ago',
               default: "computed %{n} %{unit} ago",
               n: n, unit: unit)
      end

      def humanize_span(seconds)
        n, plural_key = if seconds < 60
                          [seconds, 'seconds']
                        elsif seconds < 3600
                          [seconds / 60, 'minutes']
                        elsif seconds < 86_400
                          [seconds / 3600, 'hours']
                        else
                          [seconds / 86_400, 'days']
                        end
        # Singularise at n == 1 ("1 minute ago", not "1 minutes ago"). English and Dutch
        # both use one/other, so n == 1 -> singular is correct for the shipped locales. A
        # translated locale must provide BOTH pulse.unit_*s (plural) and pulse.unit_*
        # (singular) keys; a locale with different plural rules can override the unit words
        # via I18n. A missing key falls back to the English word (default:).
        unit_key = n == 1 ? SINGULAR_UNIT.fetch(plural_key) : plural_key
        # Resolve the unit word through I18n (pulse.unit_*) so a translated locale emits a
        # translated unit. English default preserves the prior rendered text exactly.
        [n, I18n.t("pulse.unit_#{unit_key}", default: unit_key)]
      end

      # Plural -> singular unit key for the n == 1 case (used by humanize_span).
      SINGULAR_UNIT = {
        'seconds' => 'second', 'minutes' => 'minute',
        'hours' => 'hour', 'days' => 'day'
      }.freeze
    end
  end
end
