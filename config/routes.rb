# frozen_string_literal: true

# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation. See <https://www.gnu.org/licenses/> (GPL-2.0-only).

# redmine_pulse routes — EXACTLY the 5 named routes the controllers serve.
# No route targets a deferred/unimplemented feature.
#
#   GET  /pulse                    -> pulse#index    (portfolio overview, HTML)
#   GET  /projects/:id/pulse       -> pulse#show     (per-project health panel, HTML)
#   POST /pulse/refresh            -> pulse#refresh  (invalidate one project's cache)
#   GET  /pulse/portfolio.json     -> pulse_api#portfolio (ranked summaries, JSON)
#   GET  /pulse/projects/:id.json  -> pulse_api#project   (one project breakdown, JSON)

get  '/pulse', to: 'pulse#index'
post '/pulse/refresh', to: 'pulse#refresh'
get  '/projects/:id/pulse', to: 'pulse#show', as: 'project_pulse'
get  '/pulse/portfolio', to: 'pulse_api#portfolio', constraints: { format: 'json' }
get  '/pulse/projects/:id', to: 'pulse_api#project', constraints: { format: 'json' }

# saved-views — 8 additive routes. HTML + .json share the :id routes (Rails format
# routing); the show/edit/update/destroy/select actions re-check visibility server-side on
# EVERY format (existence-hiding 404 for a non-visible id).
#   GET    /pulse/views                -> pulse_views#index   (visible views)
#   GET    /pulse/views/new            -> pulse_views#new
#   POST   /pulse/views                -> pulse_views#create
#   GET    /pulse/views/:id            -> pulse_views#show     (also .json)
#   GET    /pulse/views/:id/edit       -> pulse_views#edit
#   PATCH  /pulse/views/:id            -> pulse_views#update   (also .json)
#   DELETE /pulse/views/:id            -> pulse_views#destroy  (also .json)
#   POST   /pulse/views/:id/select     -> pulse_views#select
get    '/pulse/views',          to: 'pulse_views#index',   as: 'pulse_views'
get    '/pulse/views/new',      to: 'pulse_views#new',     as: 'new_pulse_view'
post   '/pulse/views',          to: 'pulse_views#create'
get    '/pulse/views/:id/edit', to: 'pulse_views#edit',    as: 'edit_pulse_view'
post   '/pulse/views/:id/select', to: 'pulse_views#select', as: 'select_pulse_view'
get    '/pulse/views/:id',      to: 'pulse_views#show',    as: 'pulse_view'
patch  '/pulse/views/:id',      to: 'pulse_views#update'
delete '/pulse/views/:id',      to: 'pulse_views#destroy'

# alerting — 2 additive "Watch project health" opt-in routes. A
# logged-in user with :view_pulse on the project POSTs to toggle an explicit
# health-watch subscription (the RedmineSubscriptionStore#watch!/#unwatch! record the
# scan reads via subscribers_for). Both POST so button_to carries the CSRF token; the
# actions re-run the EXACT 404/403 visibility ladder before writing. NO scoring/alert
# SCAN runs in the request cycle (additive): the action only writes one Watcher row.
#   POST /projects/:id/pulse/watch    -> pulse#watch    (subscribe to health alerts)
#   POST /projects/:id/pulse/unwatch  -> pulse#unwatch  (unsubscribe)
post '/projects/:id/pulse/watch',   to: 'pulse#watch',   as: 'project_pulse_watch'
post '/projects/:id/pulse/unwatch', to: 'pulse#unwatch', as: 'project_pulse_unwatch'

# webhooks — 1 additive ADMIN-ONLY "send test event" route. An admin POSTs
# with params[:endpoint] (an index into the configured global endpoint list); the action
# delivers a SYNTHETIC AlertEvent to EXACTLY that ONE endpoint via the shared dispatcher
# pipeline (HTTPS -> SSRF -> serialize -> HMAC -> POST, ~5s timeout) and surfaces the HTTP
# status / error class to the operator. Gated on User.current.admin? (require_admin) —
# STRICTER than the :view_pulse ladder. It is the SOLE request-cycle webhook dispatch.
#   POST /pulse/webhook_test -> pulse#webhook_test
post '/pulse/webhook_test', to: 'pulse#webhook_test', as: 'pulse_webhook_test'
