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
