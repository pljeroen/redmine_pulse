# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# Creates the plugin-owned pulse_views CONFIG table (FC-C5-01/02/03). This is a
# CONFIG table, NOT the snapshot cache — it is written ONLY in response to explicit
# user actions (create / update / select / destroy) through the ActiveRecordViewStore
# adapter (INV-C5-CONFIG-NOT-CACHE). The migration references pulse_views ONLY; it
# never touches the cache table, so the "one reversible cache table" trust narrative
# holds (cache-table count 1 -> 1).
#
# The migration seeds EXACTLY three system-owned (user_id nil) built-in views idempotently
# via PulseView.seed_builtins! (find_or_create_by!), so they are present after
# `rake redmine:plugins:migrate` with no manual step (FC-C5-11).
#
# Reversible: `down` drops the table (drop_table drops its indexes too, so no separate
# remove_index — matching the established reversible-create idiom). NOTE: rolling C5 back
# drops ALL saved views (user-created AND built-in) — the reversible contract by design.
class CreatePulseViews < ActiveRecord::Migration[6.1]
  def up
    create_table :pulse_views do |t|
      t.string   :name,          null: false
      t.integer  :user_id,       null: true                        # nil = system/built-in
      t.string   :visibility,    null: false, default: 'private'   # private | public | roles
      t.text     :role_ids,      null: true                        # serialized Array<Integer>
      t.string   :project_scope, null: false, default: 'all'       # all | selected | status_filter
      t.text     :scope_params,  null: true                        # serialized scope parameters
      t.string   :lens_ref,      null: true                        # CustomLens name / built-in lens key
      t.string   :profile_ref,   null: true                        # ScoringProfile id
      t.string   :sort,          null: true                        # serialized sort spec
      t.text     :prefs,         null: true                        # serialized threshold/column prefs
      t.datetime :created_at,    null: false
      t.datetime :updated_at,    null: false
    end

    add_index :pulse_views, :user_id,    name: 'index_pulse_views_on_user_id'
    add_index :pulse_views, :visibility, name: 'index_pulse_views_on_visibility'

    # Idempotent seed of the three built-in system views (find_or_create_by!).
    PulseView.reset_column_information
    PulseView.seed_builtins! if defined?(PulseView) && PulseView.respond_to?(:seed_builtins!)
  end

  # drop_table also drops the table's indexes, so no separate remove_index is needed;
  # this keeps the down path robust even against a dirty/partial DB state.
  def down
    drop_table :pulse_views
  end
end
