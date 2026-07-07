# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

require 'pulse/domain/scoring_config'
require 'pulse/domain/scoring_profile'
require 'pulse/domain/signal_registry'

module Pulse
  module Adapters
    # RedmineProfileProvider — the ProfileProvider implementation. It
    # publishes the admin-defined profiles + the synthetic system default, and resolves the
    # active profile for a viewer by precedence. It does I/O only through the injected
    # settings_provider duck (#scoring_config for the synthetic default; #pulse_profiles for
    # the admin-defined profiles + role bindings) and the viewer duck
    # (#roles_for_project(project) -> [role]; role#id) — so its resolution logic is testable
    # in the pure-adapter lane without a live Redmine.
    #
    # The system default (id "default") ALWAYS exists; its config is the CURRENT global
    # ScoringConfig (live-read, not a drifting copy). Precedence:
    #   1. explicit requested_id (transient viewer selection);
    #   2. viewer's role-default binding (MULTI-ROLE tie-break: FIRST match by role.id
    #      ASCENDING);
    #   3. system default.
    # A requested / bound id absent from the published set degrades to the system default AND
    # surfaces a warning via #last_warning — it NEVER raises.
    class RedmineProfileProvider
      RESERVED_DEFAULT_ID = 'default'

      attr_reader :last_warning

      def initialize(settings_provider:)
        @settings_provider = settings_provider
        @last_warning = nil
      end

      # -> Array<Pulse::Domain::ScoringProfile>, the synthetic default FIRST, then the
      # admin-defined profiles in their published (insertion) order. Rebuilt on each call so
      # the default mirrors the live global config and settings edits are reflected.
      def profiles
        [system_default] + admin_profiles
      end

      # -> Pulse::Domain::ScoringProfile — the active profile for `viewer` on `project`,
      # resolved by precedence. requested_id is the transient selection (may be nil). Sets
      # @last_warning (nil on a clean resolution; a human-readable String on a dangling
      # fallback). Never raises for a dangling reference.
      def resolve(viewer, project, requested_id = nil)
        @last_warning = nil
        published = profiles
        by_id = published.each_with_object({}) { |p, acc| acc[p.id] = p }

        # Level 1: an explicit transient selection.
        unless blank?(requested_id)
          selected = by_id[requested_id.to_s]
          return selected if selected

          @last_warning = warning_for(requested_id, :selected)
          return by_id[RESERVED_DEFAULT_ID]
        end

        # Level 2: the viewer's role-default binding (first match by role.id ascending).
        bound_id = bound_profile_id(viewer, project)
        unless bound_id.nil?
          bound = by_id[bound_id.to_s]
          return bound if bound

          @last_warning = warning_for(bound_id, :role_bound)
          return by_id[RESERVED_DEFAULT_ID]
        end

        # Level 3: the system default.
        by_id[RESERVED_DEFAULT_ID]
      end

      private

      # The role-binding profile_id for the FIRST (lowest) role.id the viewer holds on the
      # project that carries a binding — deterministic across viewer role-list order AND
      # settings insertion order. nil when the viewer holds no bound role.
      def bound_profile_id(viewer, project)
        bindings = normalized_role_bindings
        return nil if bindings.empty?

        role_ids = viewer_role_ids(viewer, project)
        role_ids.sort.each do |rid|
          return bindings[rid] if bindings.key?(rid)
        end
        nil
      end

      def viewer_role_ids(viewer, project)
        return [] unless viewer.respond_to?(:roles_for_project)

        Array(viewer.roles_for_project(project)).filter_map do |role|
          role.respond_to?(:id) ? role.id : nil
        end
      end

      # {role_id(Integer) => profile_id(String)} from the settings hash. String-or-integer
      # keyed input is normalized to Integer keys so the ascending-role.id sort is numeric.
      def normalized_role_bindings
        raw = pulse_profiles_hash['role_bindings'] || pulse_profiles_hash[:role_bindings] || {}
        raw.each_with_object({}) do |(rid, pid), acc|
          key = Integer(rid.to_s, exception: false)
          acc[key] = pid.to_s unless key.nil?
        end
      end

      # The synthetic system default: id "default", config == the CURRENT global config.
      def system_default
        Pulse::Domain::ScoringProfile.new(
          id: RESERVED_DEFAULT_ID, name: 'Default',
          config: @settings_provider.scoring_config
        )
      end

      # The admin-defined profiles as ScoringProfile VOs, in published order. A malformed
      # entry (missing name / invalid config) is skipped defensively (the sanitizer already
      # rejects such entries at the write path; this read path never raises on stale data).
      def admin_profiles
        raw = pulse_profiles_hash['profiles'] || pulse_profiles_hash[:profiles] || {}
        raw.filter_map do |id, entry|
          build_profile(id.to_s, entry)
        end
      end

      def build_profile(id, entry)
        return nil if id == RESERVED_DEFAULT_ID # reserved; the synthetic default owns it

        name = entry['name'] || entry[:name]
        config = config_from(entry)
        return nil if name.nil? || config.nil?

        Pulse::Domain::ScoringProfile.new(id: id, name: name.to_s, config: config)
      rescue ArgumentError
        nil
      end

      # A profile entry may carry either a ready ScoringConfig (the unit-test / in-memory
      # shape) or a persisted weights hash (the settings shape the sanitizer writes). Build
      # a ScoringConfig from whichever is present; a bad set fails to a nil (skipped).
      def config_from(entry)
        cfg = entry['config'] || entry[:config]
        return cfg if cfg.is_a?(Pulse::Domain::ScoringConfig)

        weights = entry['weights'] || entry[:weights]
        return nil if weights.nil?

        Pulse::Domain::ScoringConfig.new(weights: symbolize_weights(weights))
      rescue ArgumentError
        nil
      end

      def symbolize_weights(weights)
        weights.each_with_object({}) do |(k, v), acc|
          acc[k.to_sym] = v.is_a?(String) ? Float(v) : v
        end
      end

      def pulse_profiles_hash
        return {} unless @settings_provider.respond_to?(:pulse_profiles)

        raw = @settings_provider.pulse_profiles
        raw.is_a?(Hash) ? raw : {}
      end

      # The human-readable, LOCALIZED dangling-fallback warning. `kind`
      # is :selected (an explicit ?profile_id) or :role_bound (a role-default binding). Falls
      # back to the English default when I18n / the key is unavailable so a warning is ALWAYS
      # a plain readable String (the presenter renders it verbatim; it never crashes on nil).
      def warning_for(id, kind)
        subject = localized_subject(kind)
        if defined?(I18n) && I18n.respond_to?(:t)
          I18n.t(:pulse_profile_dangling_warning, subject: subject, id: id.inspect,
                                                   default: default_warning(subject, id))
        else
          default_warning(subject, id)
        end
      end

      def localized_subject(kind)
        key = kind == :role_bound ? :label_pulse_profile_subject_role_bound
                                  : :label_pulse_profile_subject_selected
        english = kind == :role_bound ? 'the role-bound profile' : 'the selected profile'
        if defined?(I18n) && I18n.respond_to?(:t)
          I18n.t(key, default: english)
        else
          english
        end
      end

      def default_warning(subject, id)
        "redmine_pulse: #{subject} #{id.inspect} is not a published profile — " \
          'falling back to the system default'
      end

      def blank?(value)
        value.nil? || (value.is_a?(String) && value.strip.empty?)
      end
    end
  end
end
