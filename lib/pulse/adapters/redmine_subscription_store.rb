# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # RedmineSubscriptionStore — the SubscriptionStore port over Redmine (C6 / FC-C6-07 /
    # FC-C6-06). Resolves the recipient set for a project's alert and applies the
    # PERMISSION-AT-SEND gate.
    #
    # Subscription is the UNION of two sources:
    #   (1) explicit "Watch project health" watchers — a Redmine Watcher record with the
    #       pulse-health discriminator (watchable_type = WATCHABLE_TYPE, watchable_id =
    #       project.id). This is a plugin-private discriminator: it never collides with a
    #       real Redmine watchable, and the polymorphic #watchable is never dereferenced.
    #   (2) members of the admin-configured pulse_alert_auto_subscribe_role_id on the
    #       project (nil => auto-subscribe OFF, the DEFAULT — role members are NOT candidates).
    #
    # The PERMISSION-AT-SEND gate (INV-C6-PERM-AT-SEND / FC-C6-06) is applied HERE, at
    # resolution time, to EVERY candidate from BOTH sources: a user is a recipient IFF
    # user.allowed_to?(:view_pulse, project) is TRUE against LIVE permission state. Because
    # :view_pulse is a PROJECT_MODULE permission (init.rb project_module :pulse), this is
    # FALSE both when the user's :view_pulse was revoked AND when the :pulse module is
    # disabled on the project — so a revoked user OR a module-disabled project yields zero
    # recipients (the two load-bearing falsifiers). The gate MUST NOT live downstream in
    # delivery (RISK-C6-01) — delivery receives only the already-filtered set.
    #
    # Reachable ONLY from the scan_and_alert composition root + the Watch-toggle controller
    # action (which calls watch!/unwatch! and touches no scoring/alert symbol) — NEVER from
    # the scoring request cycle (INV-ADDITIVE).
    class RedmineSubscriptionStore
      # Plugin-private polymorphic discriminator for the "Watch project health" opt-in. It
      # is NOT a real AR model — Watcher stores it as a bare string and we never call
      # #watchable, so no PulseHealth constant needs to exist.
      WATCHABLE_TYPE = 'PulseHealth'

      # -> Array<User> — the permitted recipient set for the project's alert.
      def subscribers_for(project_id)
        project = Project.find_by(id: project_id)
        return [] if project.nil?

        candidates = (watcher_users(project) + auto_subscribe_role_users(project)).uniq
        candidates.select { |user| user.allowed_to?(:view_pulse, project) }
      end

      # Subscribe `user` to `project`'s health alerts (idempotent — the Watcher unique index
      # on [user_id, watchable_type, watchable_id] makes a repeat a no-op).
      def watch!(user, project)
        Watcher.find_or_create_by!(
          watchable_type: WATCHABLE_TYPE, watchable_id: project.id, user_id: user.id
        )
        nil
      end

      # Unsubscribe `user` from `project`'s health alerts (idempotent).
      def unwatch!(user, project)
        Watcher.where(watchable_type: WATCHABLE_TYPE, watchable_id: project.id,
                      user_id: user.id).delete_all
        nil
      end

      private

      # The explicit "Watch project health" watchers for the project (active real Users).
      def watcher_users(project)
        user_ids = Watcher.where(watchable_type: WATCHABLE_TYPE, watchable_id: project.id)
                          .pluck(:user_id)
        return [] if user_ids.empty?

        User.where(id: user_ids).to_a
      end

      # Members of the admin auto-subscribe role on the project (empty when the setting is
      # nil/blank — the DEFAULT OFF state).
      def auto_subscribe_role_users(project)
        role_id = auto_subscribe_role_id
        return [] if role_id.nil?

        role = Role.find_by(id: role_id)
        return [] if role.nil?

        # Members of the project whose member_roles include this role -> their principals
        # that are Users (exclude groups; the permission gate re-checks each user anyway).
        Member.where(project_id: project.id)
              .joins(:member_roles)
              .where(member_roles: { role_id: role.id })
              .map(&:principal)
              .select { |p| p.is_a?(User) }
              .uniq
      end

      # The configured auto-subscribe role id (Integer) or nil (disabled / DEFAULT). Read
      # LIVE from the plugin settings so a mid-run admin change is honored on the next scan.
      def auto_subscribe_role_id
        raw = plugin_settings['pulse_alert_auto_subscribe_role_id']
        return nil if raw.nil? || (raw.is_a?(String) && raw.strip.empty?)

        Integer(raw, exception: false)
      end

      def plugin_settings
        s = Setting.plugin_redmine_pulse
        s.is_a?(Hash) ? s : {}
      end
    end
  end
end
