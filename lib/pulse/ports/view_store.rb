# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Ports
    # ViewStore is a duck-typed port: any object responding to the methods below satisfies
    # the port. It is stdlib-only — the port surface carries NO
    # framework/persistence types; the production adapter
    # (Pulse::Adapters::ActiveRecordViewStore) owns ALL pulse_views database I/O.
    #
    # The controller (PulseViewsController) depends on THIS port only — it calls @view_store
    # and NEVER calls PulseView AR methods directly. The AR scope PulseView.visible_to stays
    # inside the adapter implementation. This keeps the controller boundary decoupled from
    # raw ActiveRecord and confines pulse_views persistence to the single adapter (the
    # snapshot cache — pulse_snapshots — is a distinct store from saved-view config).
    #
    # Protocol:
    #   visible_to(user)      -> a relation of the views the user may SEE (the read gate).
    #                            The returned object responds to #find(id) — raising
    #                            RecordNotFound (existence hiding) for a view outside the
    #                            visible set — and #to_a for listing.
    #   find_visible(id, user) -> PulseView | raises RecordNotFound (the scoped find helper).
    #   create(attrs)         -> PulseView (persisted, or an unsaved record carrying errors).
    #   update(view, attrs)   -> Boolean (true on success, false on a validation failure).
    #   destroy(view)         -> void (removes the pulse_views row).
    #
    # The domain layer NEVER depends on this module. No ABC/inheritance is required.
    module ViewStore
    end
  end
end
