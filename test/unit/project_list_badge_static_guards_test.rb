# frozen_string_literal: true

require 'minitest/autorun'

# project-list-badge STATIC source-scan guards (no Redmine env; path-based). Covers the
# static source-scan obligations:
#
#   open/no-external — GPL-2.0 header on every NEW .rb (lib/redmine_pulse/hooks.rb + the
#                          shared label module); no new gem; the JS asset carries a license
#                          header and references NO external/CDN URL and makes NO network
#                          call (zero fetch/XHR/ajax).
#   XSS              — the badge JS inserts blob-derived strings via
#                          textContent/createTextNode/setAttribute ONLY: no innerHTML /
#                          insertAdjacentHTML / outerHTML / document.write / .html().
#   inline-XSS       — the hook serializes the blob through ERB::Util.json_escape (no raw
#                          interpolation into the <script> body); the JS reads the blob via
#                          JSON.parse(textContent) and never eval()/new Function()/innerHTML
#                          over it.
#   renderer-purity  — the JS contains NO signal->label mapping table and NO i18n logic (it
#                          consumes the server-provided main_concern verbatim) and NO scoring
#                          threshold/weight/health arithmetic.
#   read-only        — no forbidden Redmine-domain write in the new .rb; no new db/migrate;
#                          no new write route.
#
# Where a target file is ABSENT the test FAILS (flunk) so the obligation is live, not
# silently skipped.
class ProjectListBadgeStaticGuardsTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)

  HOOKS_RB = 'lib/redmine_pulse/hooks.rb'
  SHARED_LABEL_RB = 'lib/pulse/adapters/main_concern_labels.rb'
  BADGE_JS = 'assets/javascripts/project_list_badge.js'

  # The NEW Ruby files this contract introduces (both MUST carry the GPL header).
  NEW_RUBY = [HOOKS_RB, SHARED_LABEL_RB].freeze

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
    flunk "expected file missing: #{rel}" unless File.exist?(p)
    File.read(p)
  end

  # ───────────── GPL-2.0 header on each new .rb ─────────────

  def test_new_ruby_files_carry_gpl_header
    NEW_RUBY.each do |rel|
      head = read_or_flunk(rel)[0, 600]
      assert_match(/GPL|GNU General Public License/i, head,
                   "#{rel}: every new .rb MUST carry a GPL-2.0 header")
    end
  end

  # ───────────── no new gem dependency ─────────────

  # The plugin Gemfile baseline: the ONLY permitted gem is the test-time json-schema
  # validator. The badge feature adds NO new runtime/test gem.
  GEMFILE_BASELINE_GEMS = %w[json-schema].freeze

  def test_no_new_gem_dependency
    # The plugin Gemfile pre-exists (test-only json-schema validator). The badge feature
    # introduces NO new gem dependency. Assert the set of declared gems is EXACTLY the
    # baseline — a new gem line (a CDN/runtime dep) FAILS this.
    gemfile = path('Gemfile')
    flunk 'plugin Gemfile missing (baseline expected)' unless File.exist?(gemfile)
    declared = File.read(gemfile).scan(/^\s*gem\s+['"]([^'"]+)['"]/).flatten.sort
    assert_equal GEMFILE_BASELINE_GEMS.sort, declared,
                 'the badge feature MUST add NO new gem ' \
                 "(Gemfile gems must stay exactly the baseline). got=#{declared.inspect}"
  end

  # ───────────── inline-XSS (Ruby side): json_escape on the blob ─────────────

  def test_hook_escapes_inline_blob_with_json_escape
    src = read_or_flunk(HOOKS_RB)
    assert_match(/json_escape/, src,
                 "#{HOOKS_RB}: inline-XSS — the inlined <script> blob MUST be escaped via " \
                 'ERB::Util.json_escape so a project name cannot break out of the <script> element')
    # The blob is built from the serialized portfolio (the shared label source) — it must
    # NOT raw-interpolate an un-escaped to_json directly into the script body. We assert the
    # json_escape token is present (the affirmative requirement); the live breakout test in
    # project_list_badge_hook_test.rb is the behavioural complement.
  end

  def test_hook_no_network_callout
    src = read_or_flunk(HOOKS_RB)
    refute_match(/Net::HTTP|open-uri|URI\.open|Faraday|HTTParty|RestClient/, src,
                 "#{HOOKS_RB}: no external network callout permitted in the hook")
  end

  # ───────────── read-only (static): no forbidden domain write ─────────────

  def test_new_ruby_files_contain_no_domain_write_calls
    NEW_RUBY.each do |rel|
      src = read_or_flunk(rel)
      DOMAIN_MODELS.each do |model|
        WRITE_METHODS.each do |m|
          pattern = /\b#{model}(\.[a-z_]+)*\.#{Regexp.escape(m)}\b/
          refute_match(pattern, src,
                       "#{rel}: forbidden write #{model}...#{m} on a Redmine domain receiver (must stay read-only)")
        end
      end
    end
  end

  def test_no_new_migration_introduced
    # The badge feature adds no write path -> no new db/migrate file. The plugin's existing
    # migrations (the pulse_snapshots cache table) predate it; assert the badge feature
    # introduces NONE referencing a badge/portfolio-data table.
    Dir[path('db/migrate/*.rb')].each do |f|
      src = File.read(f)
      refute_match(/portfolio_data|project_list_badge|pulse_badge/i, src,
                   "#{File.basename(f)}: the badge feature introduces no migration (must stay read-only)")
    end
  end

  # ───────────── XSS / inline-XSS (JS side) + renderer-purity ─────────────

  def test_badge_js_inserts_only_via_safe_dom_api
    src = read_or_flunk(BADGE_JS)
    # Conservative form: these markup-writing APIs MUST be ABSENT from the file entirely —
    # blob-derived strings go in via textContent / createTextNode / setAttribute only.
    %w[innerHTML insertAdjacentHTML outerHTML].each do |api|
      refute_match(/\.#{api}\b/, src,
                   "#{BADGE_JS}: XSS — #{api} MUST NOT appear (use textContent/setAttribute)")
    end
    refute_match(/document\.write\b/, src,
                 "#{BADGE_JS}: XSS — document.write MUST NOT appear")
    refute_match(/\.html\(/, src,
                 "#{BADGE_JS}: XSS — jQuery .html() MUST NOT appear")
    # Positive: the safe insertion APIs are actually used.
    assert_match(/textContent|createTextNode|setAttribute/, src,
                 "#{BADGE_JS}: blob-derived strings MUST be inserted via textContent/createTextNode/setAttribute")
  end

  def test_badge_js_reads_blob_via_json_parse_never_eval
    src = read_or_flunk(BADGE_JS)
    assert_match(/JSON\.parse/, src,
                 "#{BADGE_JS}: inline-XSS — the inline blob MUST be read via JSON.parse(textContent)")
    refute_match(/\beval\s*\(/, src,
                 "#{BADGE_JS}: inline-XSS — eval() MUST NOT appear (never execute the blob)")
    refute_match(/new\s+Function\s*\(/, src,
                 "#{BADGE_JS}: inline-XSS — new Function() MUST NOT appear")
  end

  def test_badge_js_makes_no_network_request
    src = read_or_flunk(BADGE_JS)
    # The data is same-document inline; the JS makes NO network call.
    refute_match(/\bfetch\s*\(/, src,
                 "#{BADGE_JS}: no external — fetch() MUST NOT appear (data is inline, no network request)")
    refute_match(/XMLHttpRequest/, src,
                 "#{BADGE_JS}: no external — XMLHttpRequest MUST NOT appear")
    refute_match(/\.ajax\s*\(/, src,
                 "#{BADGE_JS}: no external — .ajax() MUST NOT appear")
  end

  def test_badge_js_has_no_external_url_and_a_license_header
    src = read_or_flunk(BADGE_JS)
    refute_match(%r{https?://}, src,
                 "#{BADGE_JS}: no external — no absolute external/CDN URL permitted")
    # No credential handling (the auth is entirely server-side).
    refute_match(/api[_-]?key|Authorization|X-Redmine-API-Key|password|secret|token/i, src,
                 "#{BADGE_JS}: the JS MUST NOT handle any credential/token")
    # A GPL/license notice comment in the JS is the expected good practice (mirrors the CSS
    # header).
    assert_match(/GPL|GNU General Public License/i, src[0, 600],
                 "#{BADGE_JS}: the badge JS SHOULD carry a GPL-2.0 license header comment")
  end

  def test_badge_js_is_pure_renderer_no_label_table_or_scoring
    src = read_or_flunk(BADGE_JS)
    # renderer-purity: the JS consumes the SERVER-provided main_concern verbatim. It MUST
    # NOT carry its own signal->label mapping vocabulary or i18n logic.
    %w[Stale Losing\ momentum Behind\ schedule At\ risk Blocked].each do |label|
      refute_match(/#{Regexp.escape(label)}/, src,
                   "#{BADGE_JS}: renderer-purity — the JS MUST NOT hardcode the label #{label.inspect} " \
                   '(it consumes the server-provided main_concern verbatim)')
    end
    # No client-side i18n call.
    refute_match(/I18n\.|\bi18n\b/, src,
                 "#{BADGE_JS}: renderer-purity — the JS MUST NOT do its own i18n")
    # No scoring arithmetic: the dominant-signal vocabulary keys must not be re-derived
    # in the JS (it reads rag + main_concern, it never recomputes them).
    refute_match(/dominant_signal\s*=/, src,
                 "#{BADGE_JS}: renderer-purity — the JS MUST NOT recompute dominant_signal")
  end

  # ───────────── shared label module purity (domain must not import it) ─────────────

  def test_shared_label_module_lives_in_adapters_not_domain
    refute File.exist?(path('lib/pulse/domain/main_concern_labels.rb')),
           'the shared label module MUST NOT live in lib/pulse/domain (it uses Rails I18n, so it is not part of the standard-library-only domain layer)'
    src = read_or_flunk(SHARED_LABEL_RB)
    assert_match(/I18n|label_pulse/, src,
                 "#{SHARED_LABEL_RB}: the shared label module localizes via I18n")
  end

  def test_domain_does_not_import_shared_label_module
    Dir[path('lib/pulse/domain/**/*.rb')].each do |f|
      src = File.read(f)
      refute_match(%r{require\s+['"]pulse/adapters/main_concern_labels['"]}, src,
                   "#{File.basename(f)}: the pure domain MUST NOT depend on the (I18n-using) label adapter")
      refute_match(/MainConcernLabels/, src,
                   "#{File.basename(f)}: the pure domain MUST NOT reference MainConcernLabels (domain purity)")
    end
  end
end
