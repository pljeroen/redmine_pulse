# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# PulseApiController — the JSON adapter surface + composition root.
# It relies ENTIRELY on Redmine's built-in REST authentication (accept_api_auth + the
# header/param/HTTP-Basic credential mechanism Redmine's ApplicationController already
# implements) — it parses NO credentials of its own.
#
# accept_api_auth is exposed as a class method on Redmine 6.1.2's ApplicationController
# (app/controllers/application_controller.rb line 646), so the controller inherits it
# by subclassing ApplicationController (verified against the deployed source).
#
# Ordering: the REST-auth gate (require_login -> Redmine 401/403 when REST disabled or
# no/invalid credentials) runs BEFORE the per-project 404/403 ladder.
# Errors render via Redmine's conventional REST envelope ({"errors":[...]}) — no custom
# pulse envelope. Read-only: GET writes no Redmine domain table.
class PulseApiController < PulseBaseController
  accept_api_auth :portfolio, :project

  before_action :require_login

  DEFAULT_LIMIT = 100

  # DoS guard: hard upper-bound on the requested page size. Without a cap
  # a caller can request an unbounded slice (limit far above any sane maximum), forcing the
  # composition root to rank + serialize the whole portfolio — an amplification / memory-DoS
  # lever. A limit above this maximum is a validation error -> 422 (same envelope as the
  # lower bound), exactly like limit<1. The default-limit path is unaffected.
  MAX_PORTFOLIO_LIMIT = 250

  # GET /pulse/portfolio.json — ranked per-project health summaries.
  def portfolio
    offset, limit = validated_pagination
    return if performed? # 422 already rendered

    lens = Pulse::Adapters::LensRanker.normalize_lens(params[:lens])
    # ?profile_id is the transient GLOBAL override applying to every project;
    # absent, each project resolves its own per-project role-default binding.
    all = Pulse::Adapters::LensRanker.rank(
      engine.portfolio_projections(User.current, selected_profile_id), lens
    )
    page = all.slice(offset, limit) || []

    payload = Pulse::Adapters::JsonSerializer.portfolio(
      page,
      lens: lens,
      default_lens: Pulse::Adapters::LensRanker::DEFAULT_LENS,
      pagination: { 'offset' => offset, 'limit' => limit, 'total' => all.size },
      snapshot_at: page.first ? page.first.snapshot_computed_at : Time.now.utc,
      projected_at: Time.now.utc,
      config: settings_provider.scoring_config,
      clock: clock
    )
    render json: payload
  end

  # GET /pulse/projects/:id.json — one project's full breakdown.
  def project
    proj = visible_project(params[:id])
    return if proj.nil? # 404

    return unless authorize_pulse(proj) # 403

    # the transient profile selection (?profile_id=<id>) overrides the role binding for
    # this request; a dangling id degrades to the default in the provider.
    projection = engine.project_projection(User.current, proj, selected_profile_id)
    render json: Pulse::Adapters::JsonSerializer.project(projection)
  end

  private

  # ── pagination validation ───────────────────────────────────────────────────
  # offset default 0 (must be >= 0); limit default 100 (must be an integer >= 1).
  # Any violation -> 422 with the Redmine-conventional {"errors":[...]} envelope.
  def validated_pagination
    offset = 0
    limit = DEFAULT_LIMIT

    if params[:offset].present?
      offset = strict_int(params[:offset])
      return pagination_error('offset must be an integer >= 0') if offset.nil? || offset.negative?
    end

    if params[:limit].present?
      limit = strict_int(params[:limit])
      return pagination_error('limit must be an integer >= 1') if limit.nil? || limit < 1
      # reject an over-cap page size with the SAME 422 envelope (availability guard).
      if limit > MAX_PORTFOLIO_LIMIT
        return pagination_error("limit must be an integer <= #{MAX_PORTFOLIO_LIMIT}")
      end
    end

    [offset, limit]
  end

  def strict_int(raw)
    s = raw.to_s.strip
    return nil unless s.match?(/\A-?\d+\z/)

    s.to_i
  end

  def pagination_error(message)
    render_api_errors(message)
    [nil, nil]
  end

  # ── 404/403 visibility ladder ───────────────────────────────────────────────
  # JSON-specific: does NOT assign @project (no Redmine project layout on the API
  # surface). authorize_pulse + the adapter-factory composition root live in
  # PulseBaseController (shared, identical across both surfaces).
  def visible_project(identifier)
    proj = Project.visible(User.current).find_by(identifier: identifier)
    render_404 if proj.nil?
    proj
  end
end
