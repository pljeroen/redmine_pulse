# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

module Pulse
  module Adapters
    # ActiveRecordViewStore — the production ViewStore adapter. It owns ALL pulse_views
    # database I/O; the ViewStore PORT stays stdlib-only. It is backed EXCLUSIVELY by the
    # PulseView AR model (the pulse_views table) — it NEVER reads or writes pulse_snapshots
    # (saved-view config and the snapshot cache are distinct stores; the cache is owned by
    # ActiveRecordSnapshotStore). Config is written only in response to explicit user
    # create/update/destroy/select actions.
    #
    # The controller (PulseViewsController) calls THIS adapter through the @view_store
    # instance injected at the composition root, and never touches PulseView directly, so
    # the AR scope PulseView.visible_to (the authoritative read gate) lives here.
    class ActiveRecordViewStore
      # visible_to(user) -> the ActiveRecord::Relation of the views the user may SEE. It
      # responds to #find(id) (RecordNotFound / 404 existence-hiding for a non-visible id)
      # and #to_a for listing. This is the single read gate the controller resolves every
      # target through, on EVERY format.
      def visible_to(user)
        PulseView.visible_to(user)
      end

      # find_visible(id, user) -> PulseView, resolved THROUGH the visibility scope so a view
      # outside the caller's visible set raises ActiveRecord::RecordNotFound (the controller
      # maps that to 404 — existence hiding, not 403).
      def find_visible(id, user)
        visible_to(user).find(id)
      end

      # create(attrs) -> PulseView (persisted when valid; an unsaved record carrying
      # validation errors otherwise — the caller inspects #persisted? / #errors).
      def create(attrs)
        view = PulseView.new(attrs)
        view.save
        view
      end

      # update(view, attrs) -> Boolean (true on success; false leaves #errors populated).
      def update(view, attrs)
        view.update(attrs)
      end

      # destroy(view) -> void.
      def destroy(view)
        view.destroy
        nil
      end
    end
  end
end
