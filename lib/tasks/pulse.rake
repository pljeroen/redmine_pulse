# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Admin maintenance tasks for the pulse_snapshots cache.
#
# WHY THIS EXISTS — unbounded cache growth: the pulse_snapshots table is a content-
# addressed cache keyed on (project_id, visibility_context_id, snapshot_fingerprint).
# It has NO TTL and NO eviction policy; a row is created on every cold cache miss and
# removed only by the per-project `POST /pulse/refresh` (invalidate_project). On a long-
# lived instance with many distinct viewers or churning fingerprints the table grows
# without bound. `pulse:cache:clear` gives an admin a global flush / rebuild lever that
# the per-project refresh does not provide.
#
# Writes ONLY pulse_snapshots (INV-READ-ONLY / FC-CA-13) — it never touches a Redmine
# domain table. The cache rebuilds lazily on the next request (cold-miss warm).
#
#   bundle exec rake pulse:cache:clear RAILS_ENV=production
#   bundle exec rake 'pulse:cache:clear[42]' RAILS_ENV=production   # one project
#
# (Redmine auto-loads lib/tasks/*.rake; the task keeps its own `pulse:` namespace —
# it is NOT re-namespaced under redmine:plugins:. Quote the [id] form for zsh.)

# alerting contract (C6): the two scheduled-operation rake tasks live under the NEW
# redmine_pulse: namespace (PINNED, F-02). They are THIN shells over the composition-root
# task classes (Pulse::Tasks::Recompute / Pulse::Tasks::ScanAndAlert) — this .rake file is
# the ONLY production entry point for the alert pipeline (the additive no-coupling grep
# confirms the alert symbols never reach the request cycle). Scheduling is operator-side
# cron (DEC-08) — no worker/scheduler/Redis gem is introduced.
#
#   bundle exec rake redmine_pulse:recompute RAILS_ENV=production
#   bundle exec rake redmine_pulse:scan_and_alert RAILS_ENV=production
#
# The pre-existing pulse:cache:clear task (below) is OUT OF C6 SCOPE and NOT renamed — a
# mixed tree (pulse:cache:* + redmine_pulse:*) is accepted for C6.
namespace :redmine_pulse do
  desc 'Warm the pulse_snapshots cache for all projects (canonical profile). Idempotent; ' \
       'writes only pulse_snapshots; never touches pulse_alert_states. Operator-cron scheduled.'
  task recompute: :environment do
    warmed = Pulse::Tasks::Recompute.run
    puts "[redmine_pulse] recompute warmed #{warmed} project snapshot(s)."
  end

  desc 'Scan project health, compare to prior alert-state, and email watchers on a ' \
       'transition (permission re-checked at send). Advances state once per period.'
  task scan_and_alert: :environment do
    events = Pulse::Tasks::ScanAndAlert.run
    puts "[redmine_pulse] scan_and_alert emitted #{events.size} alert event(s)."
  end
end

namespace :pulse do
  namespace :cache do
    desc 'Clear the pulse_snapshots cache (all projects, or [project_id] for one). ' \
         'No TTL/eviction exists; this is the global flush + rebuild lever.'
    task :clear, [:project_id] => :environment do |_t, args|
      store = Pulse::Adapters::ActiveRecordSnapshotStore.new

      if args[:project_id].present?
        pid = Integer(args[:project_id])
        deleted = store.invalidate_project(pid)
        puts "[redmine_pulse] cleared #{deleted} cached snapshot(s) for project_id=#{pid}."
      else
        deleted = store.clear_all
        puts "[redmine_pulse] cleared #{deleted} cached snapshot(s) (all projects)."
      end
    end
  end
end
