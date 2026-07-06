# frozen_string_literal: true

# redmine_pulse routes — EXACTLY the 5 named routes the controllers serve (CA-03 /
# FC-CA-31). No route targets a deferred/unimplemented feature (DEC-12).
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

# saved-views (C5) — 8 additive routes. HTML + .json share the :id routes (Rails format
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

# alerting (C6 / FR-C6-08) — 2 additive "Watch project health" opt-in routes. A
# logged-in user with :view_pulse on the project POSTs to toggle an explicit
# health-watch subscription (the RedmineSubscriptionStore#watch!/#unwatch! record the
# scan reads via subscribers_for). Both POST so button_to carries the CSRF token; the
# actions re-run the EXACT 404/403 visibility ladder before writing. NO scoring/alert
# SCAN runs in the request cycle (INV-ADDITIVE): the action only writes one Watcher row.
#   POST /projects/:id/pulse/watch    -> pulse#watch    (subscribe to health alerts)
#   POST /projects/:id/pulse/unwatch  -> pulse#unwatch  (unsubscribe)
post '/projects/:id/pulse/watch',   to: 'pulse#watch',   as: 'project_pulse_watch'
post '/projects/:id/pulse/unwatch', to: 'pulse#unwatch', as: 'project_pulse_unwatch'
