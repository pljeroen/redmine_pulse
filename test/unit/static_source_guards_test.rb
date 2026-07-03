# frozen_string_literal: true

require 'minitest/autorun'

# STATIC source-scan guards (no Redmine env; path-based). Covers the AGENT_CHECK /
# static-mechanism tier-1 obligations + the binding T1 static conditions:
#   FC-CA-13 / COND-A8-003(b) — forbidden Redmine-domain write methods in
#       controllers/adapter/views (the static complement to the runtime write-guard).
#   COND-A4-002 — view purity: no business/scoring logic or AR access in ERB.
#   COND-CA-02 — settings partial exposes ONLY the CA-23 field set; no
#       deliverables_field / coverage_gap control.
#   D-CA-OQ02 — risk_trackers multi-select; select2 asset vendored LOCAL (no CDN).
#   FC-CA-29 / CA-29-OPEN — GPL-2.0 header on every new .rb; no network callout.
#   FC-CA-04 / FC-CA-25 — SnapshotStore port is stdlib-only; domain never requires it.
#
# RED until A9 writes the files. Where a target file is ABSENT, the test FAILS
# (flunk) so the obligation is live, not silently skipped.
class StaticSourceGuardsTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)

  NEW_CONTROLLERS = %w[
    app/controllers/pulse_controller.rb
    app/controllers/pulse_api_controller.rb
  ].freeze

  NEW_ADAPTER = 'lib/pulse/adapters/active_record_snapshot_store.rb'
  NEW_PORT = 'lib/pulse/ports/snapshot_store.rb'
  SETTINGS_PARTIAL = 'app/views/settings/_pulse_settings.html.erb'
  VIEW_GLOB = 'app/views/**/*.erb'

  # CA-A10-004: the COMPLETE set of new production Ruby files introduced by this
  # contract — the six new adapters + the snapshot-store port + both controllers.
  # The read-only forbidden-write scan and the no-network scan apply to ALL of them,
  # not just the two controllers + active_record_snapshot_store. (The prior-contract
  # adapters redmine_metrics_source/redmine_settings_provider/snapshot_fingerprint/
  # visibility_context/system_clock are out of THIS contract's scope.)
  NEW_ADAPTERS = %w[
    lib/pulse/adapters/active_record_snapshot_store.rb
    lib/pulse/adapters/html_presenter.rb
    lib/pulse/adapters/json_serializer.rb
    lib/pulse/adapters/pulse_projection.rb
    lib/pulse/adapters/settings_sanitizer.rb
    lib/pulse/adapters/lens_ranker.rb
  ].freeze

  # Every new production Ruby file in this contract (controllers + adapters + port).
  ALL_NEW_RUBY = (NEW_CONTROLLERS + NEW_ADAPTERS + [NEW_PORT]).freeze

  # Redmine domain model receivers that must never be written to.
  DOMAIN_MODELS = %w[
    Issue Project Journal JournalDetail IssueRelation Version Changeset
    Repository IssuePriority IssueStatus User Role Member Tracker CustomField
    CustomValue EnabledModule Enumeration Setting Group
  ].freeze

  WRITE_METHODS = %w[
    save save! update update! update_all update_attribute update_column update_columns
    touch increment! decrement! toggle! create create! insert insert_all upsert upsert_all
    destroy destroy_all delete delete_all
  ].freeze

  def path(rel)
    File.join(ROOT, rel)
  end

  def read_or_flunk(rel)
    p = path(rel)
    flunk "expected file missing (RED until A9): #{rel}" unless File.exist?(p)
    File.read(p)
  end

  # ───────────── FC-CA-13 / COND-A8-003(b): forbidden write scan ─────────────

  # CA-A10-004: apply the forbidden-Redmine-domain-write scan to the COMPLETE set of
  # new production Ruby files (controllers + all six adapters + port), not just the two
  # controllers + active_record_snapshot_store. A future forbidden write/callout in any
  # new adapter must be caught.
  def test_controllers_and_all_new_adapters_contain_no_domain_write_calls
    ALL_NEW_RUBY.each do |rel|
      src = read_or_flunk(rel)
      DOMAIN_MODELS.each do |model|
        WRITE_METHODS.each do |m|
          # Match e.g. `Issue.update_all` / `project.save!` / `Version.create`.
          pattern = /\b#{model}(\.[a-z_]+)*\.#{Regexp.escape(m)}\b/
          refute_match(pattern, src,
                       "#{rel}: forbidden write #{model}...#{m} on a Redmine domain receiver (FC-CA-13)")
        end
      end
    end
  end

  def test_adapter_only_writes_its_own_pulse_snapshot_model
    src = read_or_flunk(NEW_ADAPTER)
    # The adapter MAY write its own PulseSnapshot model; assert it does NOT write any
    # Redmine domain model (covered above) and that its write surface is the plugin table.
    assert_match(/pulse_snapshots|PulseSnapshot/, src,
                 'the adapter persists to its own pulse_snapshots table only')
  end

  # ───────────────────── COND-A4-002: view purity ───────────────────────────

  # CA-A10-002: COND-A4-002 / Rule 18 — NO direct Redmine ActiveRecord access or domain
  # recomputation in ANY ERB view, INCLUDING the settings partial. The prior guard checked
  # only a handful of query-method tokens and MISSED `Tracker.sorted.each` (a direct
  # Redmine model-constant AR query in ERB). This strengthened guard scans every
  # app/views/**/*.erb and FAILS on:
  #   (1) any Redmine domain model CONSTANT followed by a method call (e.g. `Tracker.`,
  #       `Issue.`, `Project.`, `Version.`, `IssueStatus.`, ...) — direct AR access,
  #   (2) AR query/finder methods (`.where(`, `.pluck(`, `.find_by(`, `.sorted`, `.all`,
  #       `.order(`, `.select(`, `.includes(`, `.joins(`, `.visible`),
  #   (3) domain recomputation in the view (Scoring./Timeline./SnapshotFingerprint./
  #       VisibilityContext./MetricsSource).
  # The view must consume PREPARED form/presenter state (plain option data) only.
  def test_views_contain_no_business_logic_or_ar_access
    # Redmine domain model constants that must NEVER appear as a bare receiver in a view.
    # `\b#{model}\.` matches `Tracker.sorted`, `Issue.visible`, `Project.where`, etc.,
    # while NOT matching e.g. `t(:label_pulse_tracker)` or instance vars / locals.
    model_consts = DOMAIN_MODELS - %w[User] # User.current is read-only ambient context in views
    model_const_pats = model_consts.map { |m| /\b#{m}\.[a-z]/ }

    forbidden = model_const_pats + [
      /Pulse::Domain::Scoring|Scoring\.score|\bScoring\./,
      /Pulse::Domain::Timeline|Timeline\.build|\bTimeline\./,
      /MetricsSource|RedmineMetricsSource/,
      /SnapshotStore|SnapshotFingerprint|VisibilityContext/,
      /\.visible\b/,
      /\.where\(|\.pluck\(|\.find_by\(|\.sorted\b|\.order\(|\.includes\(|\.joins\(/,
      /\.all\b|\.find\(|\.find_each\b/
    ]

    erbs = Dir[path(VIEW_GLOB)]
    flunk 'no ERB views yet (RED until A9)' if erbs.empty?
    # The settings partial MUST be among the scanned views (it is the CA-A10-002 target).
    assert(erbs.any? { |f| f.end_with?('_pulse_settings.html.erb') },
           'the settings partial MUST be scanned by the ERB-purity guard (CA-A10-002)')
    erbs.each do |f|
      src = File.read(f)
      forbidden.each do |pat|
        refute_match(pat, src,
                     "#{File.basename(f)}: view must render prepared presenter/form state only, " \
                     "no direct Redmine model/AR access or domain recomputation (COND-A4-002 / Rule 18) " \
                     "[pattern #{pat.inspect}]")
      end
    end
  end

  # ──────────────── COND-CA-02: settings field set is exactly CA-23 ──────────

  # The EXACT CA-23 settings field set (read off CANON CA-23 + init.rb defaults +
  # ScoringConfig). These are the ONLY input/select `name` keys the settings partial may
  # carry. The five weights live under settings[weights][<sig>]; the rest are top-level
  # settings[<key>] scalars. risk_trackers is an array param (settings[risk_trackers][]).
  CA23_TOP_LEVEL_FIELDS = %w[
    effort_field risk_trackers blocked_status
    rag_green_min rag_amber_min
    h_stale h_risk h_blocked activity_window_days
    momentum_activity_half momentum_direction_bias on_track_threshold
    snapshot_max_age_minutes
  ].freeze
  CA23_WEIGHT_KEYS = %w[staleness progress momentum risk_load blocked_load].freeze

  def test_settings_partial_exposes_only_ca23_fields_no_deliverables
    src = read_or_flunk(SETTINGS_PARTIAL)
    refute_match(/deliverables_field/, src,
                 'settings partial must NOT render deliverables_field (DEC-12 / COND-CA-02)')
    refute_match(/coverage_gap/, src,
                 'settings partial must NOT render a coverage_gap control')

    # ── CA-A10-005: EXACT field-set, not just presence. Parse every form-control
    # `name="settings[...]"` attribute out of the rendered partial source and assert the
    # set is EXACTLY the CA-23 allowed set — no extras (no deliverables_field/coverage_gap
    # or ANY other speculative control). ──────────────────────────────────────────────
    #
    # Top-level keys: name="settings[<key>]" or name="settings[<key>][]" (array params).
    top_level = src.scan(/name="settings\[([a-z_]+)\](?:\[\])?"/).flatten.uniq
    # Weight keys: name="settings[weights][<sig>]". The partial generates these in an ERB
    # loop, so the literal `name` carries `<%= sig %>`; the concrete signal set is the loop
    # driver array. Collect BOTH the literal weight-name presence and the driver signals.
    weight_name_present = src.match?(/name="settings\[weights\]\[(?:<%=\s*sig\s*%>|[a-z_]+)\]"/)
    loop_signals = src.scan(/\[:([a-z_]+),\s*t\(/).flatten.uniq # [[:staleness, t(...)], ...]

    expected_top = CA23_TOP_LEVEL_FIELDS.sort
    assert_equal expected_top, top_level.sort,
                 "settings partial must expose EXACTLY the CA-23 top-level fields and NOTHING " \
                 "else (CA-A10-005). got=#{top_level.sort.inspect} expected=#{expected_top.inspect}"

    assert weight_name_present,
           'settings partial must render the per-signal weight inputs settings[weights][<sig>] (CA-23)'
    assert_equal CA23_WEIGHT_KEYS.sort, loop_signals.sort,
                 "settings partial weight inputs must cover EXACTLY the 5 ScoringConfig signals " \
                 "and NOTHING else (CA-A10-005). got=#{loop_signals.sort.inspect}"
  end

  # ───────────── D-CA-OQ02: risk_trackers multi-select, local select2 ─────────

  # CA-A10-003: the operator chose a select2-style multi-select (D-CA-OQ02), but the
  # FUNCTIONAL requirement is a WORKING multi-select that degrades to a native control.
  # Assert a GENUINE multi-select for risk_trackers, decoupled from the JS-enhancement:
  #   (a) a `<select ... multiple ...>` element exists whose `name` targets risk_trackers
  #       (settings[risk_trackers][] — an array param), AND
  #   (b) it carries `<option ...>` entries (the project trackers), so it is a real
  #       populated control, not an empty placeholder.
  def test_settings_partial_uses_multiselect_for_risk_trackers
    src = read_or_flunk(SETTINGS_PARTIAL)

    # A <select> element that is BOTH `multiple` AND named for risk_trackers. The attrs
    # may appear in any order, so match the opening <select ...> tag span and require both.
    select_tag = src[/<select\b[^>]*name="settings\[risk_trackers\]\[\]"[^>]*>/m] ||
                 src[/<select\b[^>]*name="settings\[risk_trackers\]\[\]"[^>]*\bmultiple/m]
    refute_nil select_tag,
               'risk_trackers must be a <select> whose name targets settings[risk_trackers][] (D-CA-OQ02)'
    assert_match(/\bmultiple\b/, select_tag,
                 'the risk_trackers <select> must be a genuine multi-select (multiple) (D-CA-OQ02)')

    # The select must be POPULATED with <option> entries (the trackers) — a real control,
    # not an empty/placeholder shell. Check there is at least one <option within the
    # risk_trackers select block.
    select_block = src[/<select\b[^>]*name="settings\[risk_trackers\]\[\]"[\s\S]*?<\/select>/m]
    refute_nil select_block, 'the risk_trackers <select> block must be present'
    assert_match(/<option\b/, select_block,
                 'the risk_trackers multi-select must render <option> entries for the trackers ' \
                 '(a working, populated control — not an empty placeholder) (CA-A10-003)')
  end

  # CA-A10-003 + CA-A10-006: asset integrity. The vendored select2 asset must be a
  # GENUINE local asset, NOT a no-op placeholder/shim, and never a CDN URL. Decoupled
  # from the JS-enhancement choice: A9 may EITHER vendor a real local select2 asset OR
  # drop the asset entirely in favour of the native <select multiple> — but it may NOT
  # ship a nominal-but-fake shim file that lets the locality test pass vacuously.
  SHIM_MARKERS = [
    /replace\s+(its\s+body\s+with|with\s+the\s+upstream)/i,
    /\bno-?op\b/i,
    /\bplaceholder\b/i,
    /vendor\s+drop-?in\s+slot/i,
    /drop-?in\s+slot/i,
    /graceful\s+(no-?js-?regression\s+)?fallback/i
  ].freeze

  # A genuine minified select2 distribution is tens of KB. A shim is ~1KB. Require a
  # real-asset floor so the no-op placeholder fails. (If A9 instead removes the asset and
  # uses a native control, the "no select2 reference" branch below makes the floor moot.)
  SELECT2_MIN_BYTES = 10_000

  def test_select2_asset_is_local_and_not_a_placeholder_shim
    # No ERB/asset may reference an external select2 URL (FC-CA-29 INV-OPEN).
    Dir[path(VIEW_GLOB)].each do |f|
      src = File.read(f)
      refute_match(%r{https?://[^"'\s]*select2}i, src,
                   "#{File.basename(f)}: select2 must be local, no CDN (FC-CA-29)")
    end

    partial_src = File.exist?(path(SETTINGS_PARTIAL)) ? File.read(path(SETTINGS_PARTIAL)) : ''
    references_select2 = partial_src =~ /select2/i

    # If the partial references a select2 asset, it MUST resolve to a genuine local file:
    # present, NOT a shim, and at least the real-asset size floor. If A9 instead ships a
    # native <select multiple> with NO select2 asset reference, this whole block is skipped
    # (the multi-select test above already proves the working control).
    return unless references_select2

    select2_assets = Dir[path('assets/**/*select2*')]
    refute_empty select2_assets,
                 'a referenced select2 asset must be vendored locally under assets/ (D-CA-OQ02)'

    js_assets = select2_assets.select { |p| p.end_with?('.js') }
    refute_empty js_assets,
                 'a referenced select2 JS enhancement must resolve to a local .js asset (CA-A10-003)'

    js_assets.each do |asset|
      bytes = File.read(asset)
      SHIM_MARKERS.each do |marker|
        refute_match(marker, bytes,
                     "#{File.basename(asset)}: vendored select2 asset must be the real library, " \
                     "NOT a no-op/placeholder shim (CA-A10-003 / CA-A10-006) [marker #{marker.inspect}]")
      end
      # A real no-op shim defines select2 as an identity function; the real library does not
      # ship that exact one-liner. Forbid the tell-tale identity stub.
      refute_match(/\$\.fn\.select2\s*=\s*function\s*\(\s*\)\s*\{\s*return\s+this;?\s*\}/, bytes,
                   "#{File.basename(asset)}: select2 asset must not be a no-op identity stub (CA-A10-003)")
      assert_operator bytes.bytesize, :>=, SELECT2_MIN_BYTES,
                      "#{File.basename(asset)}: vendored select2 asset is #{bytes.bytesize} bytes — " \
                      "below the real-asset floor (#{SELECT2_MIN_BYTES}); it is a placeholder, " \
                      "not the genuine minified distribution (CA-A10-006)"
    end
  end

  # ───────────── FC-CA-29 / CA-29-OPEN: GPL header + no callout ──────────────

  def test_new_ruby_files_carry_gpl_header
    rubies = (NEW_CONTROLLERS + [NEW_ADAPTER, NEW_PORT]).select { |r| File.exist?(path(r)) }
    flunk 'no new .rb files yet (RED until A9)' if rubies.empty?
    rubies.each do |rel|
      head = File.read(path(rel))[0, 600]
      assert_match(/GPL|GNU General Public License/i, head,
                   "#{rel}: every new .rb must carry a GPL-2.0 header (CA-29)")
    end
  end

  # CA-A10-004: apply the no-network-callout scan to EVERY new production Ruby file
  # (controllers + all six adapters + port), not just controllers + store + port.
  def test_no_network_callout_in_new_sources
    rubies = ALL_NEW_RUBY.select { |r| File.exist?(path(r)) }
    flunk 'no new .rb files yet (RED until A9)' if rubies.empty?
    rubies.each do |rel|
      src = File.read(path(rel))
      refute_match(/Net::HTTP|open-uri|URI\.open|Faraday|HTTParty|RestClient/, src,
                   "#{rel}: no network callout permitted (FC-CA-29 INV-OPEN)")
    end
  end

  # ───────────── FC-CA-04 / FC-CA-25: port + domain purity ───────────────────

  def test_snapshot_store_port_is_stdlib_only
    src = read_or_flunk(NEW_PORT)
    refute_match(/ActiveRecord|ApplicationRecord|Rails|require ['"]active_record/, src,
                 'SnapshotStore port must be stdlib-only (FC-CA-04/25)')
    assert_match(/fetch/, src)
    assert_match(/store/, src)
    assert_match(/invalidate_project/, src)
  end

  def test_domain_does_not_require_snapshot_store
    Dir[path('lib/pulse/domain/**/*.rb')].each do |f|
      src = File.read(f)
      refute_match(%r{require\s+['"]pulse/ports/snapshot_store['"]}, src,
                   "#{File.basename(f)}: domain MUST NOT depend on the SnapshotStore port (CA-25)")
    end
  end

  # ───────────── R-B UI completion (THAW-RB-001): cockpit styling asset ───────
  #
  # VIEW-PURITY DECISION (R-B / settings-500 fix mechanism): the settings-500
  # (NameError on `pulse_tracker_options` when Redmine renders the plugin settings
  # partial) is fixed by the HELPER-SCOPE route — A9 makes PulseSettingsHelper#
  # pulse_tracker_options reachable in the settings-partial's VIEW scope (e.g. via
  # `helper_method`/helper inclusion into the view chain), NOT by letting the ERB query
  # `Tracker.sorted` directly. Therefore the cockpit ERB-purity rule above stays
  # UNCHANGED and continues to scan the settings partial too: NO `Tracker.`/AR access
  # may appear in ANY ERB, settings partial included (COND-A4-002 / Rule 18 preserved
  # uniformly). The settings render test (test/functional/settings_render_test.rb)
  # proves the helper is in scope at render time — that is the functional complement to
  # this static rule. (The alternative — exempting the admin settings partial — was
  # REJECTED: it would weaken the uniform invariant for no correctness gain, since the
  # helper boundary already keeps the AR query out of the view.)

  STYLESHEET_DIR = 'assets/stylesheets'

  # RAG has no color today because assets/stylesheets/ is empty (only .keep). The
  # cockpit needs a plugin stylesheet that colors the RAG chips (pulse-rag-{red,amber,
  # green,no_data}) and styles the sparkline. Assert a GENUINE stylesheet asset exists
  # under assets/stylesheets/ — a real .css file (not just the .keep placeholder) that
  # carries the RAG chip rules. RED now (the dir holds only .keep).
  def test_plugin_stylesheet_asset_exists_with_rag_chip_rules
    css_files = Dir[path("#{STYLESHEET_DIR}/*.css")]
    refute_empty css_files,
                 "a plugin cockpit stylesheet (assets/stylesheets/*.css) must exist so the " \
                 "RAG chips render with color — the dir is empty today (THAW-RB-001 finding 2)"

    combined = css_files.map { |f| File.read(f) }.join("\n")
    # The stylesheet must define the four RAG chip states (color is the whole point).
    %w[pulse-rag-red pulse-rag-amber pulse-rag-green pulse-rag-no_data].each do |klass|
      assert_match(/\.#{Regexp.escape(klass)}\b/, combined,
                   "the cockpit stylesheet must style the .#{klass} RAG chip (THAW-RB-001 finding 2 + " \
                   "R-A no_data state)")
    end
  end

  # The cockpit ERB must LINK the plugin stylesheet (a stylesheet that is never included
  # has no effect). At least one pulse view (index/show) must reference the plugin's
  # stylesheet via stylesheet_link_tag '...redmine_pulse...' (Redmine's plugin_assets
  # convention) or content_for(:header_tags). RED now (no view links any stylesheet).
  def test_cockpit_view_links_plugin_stylesheet
    pulse_views = Dir[path('app/views/pulse/*.erb')]
    flunk 'no pulse cockpit views yet (RED until A9)' if pulse_views.empty?
    combined = pulse_views.map { |f| File.read(f) }.join("\n")
    assert_match(/stylesheet_link_tag\s*\(?\s*['"][^'"]*redmine_pulse|content_for\s*\(?\s*:header_tags/,
                 combined,
                 "a cockpit view (app/views/pulse/*) must include the plugin stylesheet " \
                 "(stylesheet_link_tag '...redmine_pulse' or content_for(:header_tags)) so the RAG " \
                 "colors/sparkline styling actually load (THAW-RB-001 finding 2)")
  end
end
