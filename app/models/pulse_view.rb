# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseView — the saved-view CONFIG record. Top-level constant (Zeitwerk
# path match app/models/pulse_view.rb, consistent with the PulseSnapshot naming), so the
# plugin boots without a Zeitwerk::NameError.
#
# A saved view captures a cockpit configuration: project scope, active lens (a CustomLens
# name or a built-in lens key), active profile (a ScoringProfile id), sort, and column/
# threshold preferences. Visibility mirrors IssueQuery:
#   * private -> visible ONLY to its owner (user_id == viewer.id)
#   * public  -> visible to any cockpit viewer (holds :view_pulse)
#   * roles   -> visible ONLY to members holding a listed role (role_ids)
#
# visible_to(user) is the SINGLE authoritative read visibility gate — every controller
# read/mutate/select path resolves the target THROUGH the ViewStore port, which uses this
# scope, so a visibility defect propagates to all paths at once (one point of falsification).
#
# user_id nil == a system-owned built-in view (system_view?). Built-ins are immutable at the
# controller layer for every user (the controller's system_view? guard renders 403).
#
# CONFIG, not CACHE: rows are written ONLY on explicit user actions through
# Pulse::Adapters::ActiveRecordViewStore. The snapshot cache (pulse_snapshots) is untouched.
class PulseView < ActiveRecord::Base
  VISIBILITIES  = %w[private public roles].freeze
  PROJECT_SCOPES = %w[all selected status_filter].freeze

  # The exactly-three built-in system views. Pinned name -> built-in lens key;
  # user_id nil (system-owned), visibility public, project_scope all, profile_ref nil.
  BUILTINS = [
    { name: 'Portfolio health', lens_ref: 'health' },
    { name: 'At risk',          lens_ref: 'at_risk' },
    { name: 'Stalled',          lens_ref: 'stale' }
  ].freeze

  # nil = system-owned; no dependent: :destroy — a user deletion leaves the (private) view
  # orphaned rather than cascade-deleting; the controller defends with owner?/visible_to.
  belongs_to :user, optional: true

  # JSON serialization for the structured columns (Array<Integer> / Hash). role_ids and
  # scope_params/sort/prefs round-trip losslessly through JSON text.
  serialize :role_ids,     coder: JSON
  serialize :scope_params, coder: JSON
  serialize :sort,         coder: JSON
  serialize :prefs,        coder: JSON

  # visibility defaults to 'private' at the DB level (column default). Guarantee the default
  # on an in-memory PulseView.new(...) too, before validation reads it.
  after_initialize do
    self.visibility = 'private' if visibility.nil? && new_record?
  end

  validates :name, presence: true, length: { minimum: 1 }
  validates :visibility, inclusion: { in: VISIBILITIES }
  validates :project_scope, inclusion: { in: PROJECT_SCOPES }
  validate :role_ids_present_when_roles

  # ── scopes ─────────────────────────────────────────────────────────────────

  scope :system_owned, -> { where(user_id: nil) }
  scope :user_owned,   ->(user_id) { where(user_id: user_id) }

  # visible_to(user) — the single authoritative READ visibility gate. Returns
  # EXACTLY the union of:
  #   (private AND user_id = user.id) ∪ public ∪ (roles AND user holds a listed role_id)
  # No other record is ever returned.
  #
  # The roles branch is matched in Ruby against the deserialized role_ids Array (role_ids is
  # a serialized text column, not a queryable scalar), intersected with the set of role ids
  # the user holds across their memberships. Private/public are matched in SQL; the roles
  # subset is unioned by id so the returned relation stays a real ActiveRecord::Relation
  # (composable with .to_a / .pluck as the suites use it).
  scope :visible_to, lambda { |user|
    base_ids = where(visibility: 'public')
               .or(where(visibility: 'private', user_id: user&.id))
               .pluck(:id)

    held = held_role_ids(user)
    role_ids = if held.empty?
                 []
               else
                 where(visibility: 'roles').select do |v|
                   (v.role_ids_array & held).any?
                 end.map(&:id)
               end

    where(id: (base_ids + role_ids).uniq)
  }

  # ── built-in seeding (idempotent) ───────────────────────────────────────────

  # Seed EXACTLY the three built-in system views idempotently. find_or_create_by!
  # keyed on (user_id: nil, name:) so a re-run never duplicates — the count stays == 3.
  def self.seed_builtins!
    BUILTINS.each do |b|
      find_or_create_by!(user_id: nil, name: b[:name]) do |v|
        v.visibility    = 'public'
        v.project_scope = 'all'
        v.lens_ref      = b[:lens_ref]
        v.profile_ref   = nil
      end
    end
  end

  # ── instance predicates ─────────────────────────────────────────────────────

  def owner?(user)
    !user_id.nil? && user_id == user&.id
  end

  def system_view?
    user_id.nil?
  end

  # role_ids as a plain Array (deserialized); [] when the column is nil / blank.
  def role_ids_array
    Array(role_ids).map(&:to_i)
  end

  # The set of role ids the user holds across ALL their project memberships. Used by the
  # visible_to roles branch. Empty for a nil user / a user with no role memberships.
  def self.held_role_ids(user)
    return [] if user.nil? || user.id.nil?

    MemberRole
      .joins(:member)
      .where(members: { user_id: user.id })
      .pluck(:role_id)
      .uniq
  end

  private

  # role_ids must deserialize to a NON-EMPTY Array iff visibility == 'roles'; irrelevant
  # (not required) for private/public.
  def role_ids_present_when_roles
    return unless visibility == 'roles'

    errors.add(:role_ids, :blank) if role_ids_array.empty?
  end
end
