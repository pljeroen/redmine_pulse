# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

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
