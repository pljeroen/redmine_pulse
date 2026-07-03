# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'
require 'shellwords'

# ─────────────────────────────────────────────────────────────────────────────
# ci-compat — RED smoke/safety suite (CT-12 CONFIG).
#
# STANDALONE static-assertion suite (no Redmine env). Runs via:
#   ruby -Itest -Ilib test/unit/ci_workflow_safety_test.rb
#
# It STATICALLY enforces the safe-CI security properties (CI-01..CI-04), the
# compatibility matrix (CI-05), the host-neutral CI-script shape (CI-08/CI-09),
# the README matrix + CI badge (CI-11), the CHANGELOG entry (CI-12), and the
# committed-harness expectation (OSI-CI-01). It reads the deliverable files and
# asserts; nothing is mocked, nothing is skipped.
#
# RED BY CONSTRUCTION: the deliverables `.github/workflows/ci.yml` and
# `scripts/ci/run.sh` do NOT exist yet (A9 authors them). Where a target file is
# ABSENT the test FAILS (flunk) so the obligation stays live, not silently
# skipped — exactly the static_source_guards_test idiom. Each assertion must
# FAIL NOW for the RIGHT reason (file absent), and FAIL LATER if A9 ships an
# unsafe workflow/script. FAIL CLOSED is the rule throughout.
# ─────────────────────────────────────────────────────────────────────────────
class CiWorkflowSafetyTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)

  WORKFLOW = '.github/workflows/ci.yml'
  CI_SCRIPT = 'scripts/ci/run.sh'
  HARNESS_SCRIPT = 'scripts/test-redmine/run-tests.sh'
  README = 'README.md'
  CHANGELOG = 'CHANGELOG.md'

  def path(rel)
    File.join(ROOT, rel)
  end

  # Read raw file bytes, or FAIL (RED) if the deliverable is absent. The right
  # RED reason while A9 has not yet authored the file.
  def read_or_flunk(rel)
    p = path(rel)
    flunk "expected file missing (RED until A9 authors it): #{rel}" unless File.exist?(p)
    File.read(p)
  end

  # Parse a workflow file as YAML, or FAIL if absent / unparseable. The `on:`
  # key is a YAML truthy token (`on` -> true) under the YAML 1.1 booleans Psych
  # uses, so we read triggers off the raw text too where exactness matters; the
  # parsed tree is used for structural assertions (permissions, strategy.matrix).
  def workflow_yaml
    src = read_or_flunk(WORKFLOW)
    YAML.safe_load(src, aliases: true)
  rescue Psych::SyntaxError => e
    flunk "#{WORKFLOW}: workflow YAML is not parseable (CI-06): #{e.message}"
  end

  # ─────────── CI-01: triggers — maintainer-only, never fork-triggerable ───────

  # No EXTERNAL actor may trigger any workflow. The `on:` triggers MUST be a
  # subset of the maintainer-only set {push, workflow_dispatch}: pull_request AND
  # pull_request_target are forbidden, so a public fork PR triggers nothing at all
  # (the strongest defence against fork-PR CI hijack — there is no path for
  # untrusted fork code to run in our Actions). push MUST be present so CI still
  # validates every commit to master. FAIL CLOSED on any fork-triggerable event.
  SAFE_TRIGGERS = %w[push workflow_dispatch].freeze

  def test_ci01_triggers_are_maintainer_only_never_fork_triggerable
    src = read_or_flunk(WORKFLOW)

    # (a) The fork-PR secret-exfiltration exploit trigger must be NOWHERE in the
    #     file — not in on:, not in a comment, not anywhere. Literal scan.
    refute_match(/pull_request_target/, src,
                 "#{WORKFLOW}: pull_request_target MUST NOT appear anywhere — it is the " \
                 'documented fork-PR secret-exfiltration exploit vector (CI-01)')

    # (b) The parsed trigger set must be a SUBSET of {push, workflow_dispatch} and
    #     MUST include push. YAML maps the bare `on:` key to the boolean `true`
    #     under Psych's YAML 1.1 booleans, so resolve under either 'on' or true.
    wf = workflow_yaml
    on_block = wf['on'] || wf[true]
    refute_nil on_block,
               "#{WORKFLOW}: an `on:` trigger block must be present (CI-01)"

    triggers =
      case on_block
      when Hash  then on_block.keys.map(&:to_s)
      when Array then on_block.map(&:to_s)
      when String then [on_block]
      else flunk("#{WORKFLOW}: unrecognized `on:` shape #{on_block.inspect} (CI-01)")
      end

    assert_includes triggers, 'push',
                    "#{WORKFLOW}: push MUST be a trigger so CI validates every commit (CI-01)"
    fork_triggerable = triggers - SAFE_TRIGGERS
    assert_empty fork_triggerable,
                 "#{WORKFLOW}: triggers MUST be a subset of {push, workflow_dispatch} — a " \
                 "fork-triggerable event (e.g. pull_request) lets external code run in our " \
                 "Actions. FAIL CLOSED. offending=#{fork_triggerable.inspect} (CI-01)"
  end

  # ───────────────────── CI-02: zero secrets in the workflow ──────────────────

  # No repository secret may be referenced. Fork-PR builds must run with only
  # the default read-only GITHUB_TOKEN; no secret access is possible because
  # none are configured. Literal scan for both `secrets.` and `${{ secrets`.
  def test_ci02_workflow_references_zero_secrets
    src = read_or_flunk(WORKFLOW)
    refute_match(/secrets\./, src,
                 "#{WORKFLOW}: no `secrets.` reference permitted — zero-secrets posture is the " \
                 'key fork-PR safety property (CI-02)')
    refute_match(/\$\{\{\s*secrets/, src,
                 "#{WORKFLOW}: no `${{ secrets ... }}` expression permitted anywhere (CI-02)")
  end

  # ───────────────────── CI-03: least-privilege permissions ───────────────────

  # A TOP-LEVEL permissions block granting contents: read, and NO write-scoped
  # permission anywhere in the file. Default token scope must be restricted.
  def test_ci03_top_level_permissions_contents_read_no_write_scope
    wf = workflow_yaml
    perms = wf['permissions']
    refute_nil perms,
               "#{WORKFLOW}: a TOP-LEVEL `permissions:` block must be declared (CI-03)"
    assert_kind_of Hash, perms,
                   "#{WORKFLOW}: top-level permissions must be a mapping with contents: read (CI-03)"
    assert_equal 'read', perms['contents'].to_s,
                 "#{WORKFLOW}: top-level permissions MUST grant `contents: read` " \
                 "(got #{perms['contents'].inspect}) (CI-03)"

    # No permission key anywhere in the file may be granted `write`. FAIL CLOSED
    # on any write-scope escalation (top-level or per-job).
    src = read_or_flunk(WORKFLOW)
    write_grants = src.scan(/^\s*[a-z-]+:\s*write\b/)
    assert_empty write_grants,
                 "#{WORKFLOW}: no permission may be granted `write` scope — least privilege " \
                 "(CI-03). offending lines: #{write_grants.inspect}"
  end

  # ───────────────────── CI-04: all actions pinned to a 40-hex SHA ────────────

  # Every `uses:` value MUST be pinned to a full 40-char commit SHA, not a
  # floating tag/branch. A compromised tag must not be able to inject code.
  def test_ci04_every_uses_action_pinned_to_full_commit_sha
    src = read_or_flunk(WORKFLOW)

    uses_lines = src.lines.map(&:rstrip).select { |l| l =~ /^\s*(-\s*)?uses:/ }
    refute_empty uses_lines,
                 "#{WORKFLOW}: the workflow must use at least one action (checkout, setup-ruby) " \
                 'so the SHA-pin guard has something to verify (CI-04)'

    # Extract the ref of each `uses:` value (everything after the LAST '@',
    # before any trailing `# tag` comment) and require a full 40-hex SHA.
    uses_lines.each do |line|
      value = line.sub(/^\s*(-\s*)?uses:\s*/, '')
      # Strip an inline tag comment (e.g. `  # v4.2.2`) before checking the ref.
      ref_part = value.split('#', 2).first.to_s.strip
      assert_match(/@[0-9a-f]{40}\z/, ref_part,
                   "#{WORKFLOW}: every `uses:` action MUST be pinned to a full 40-hex commit SHA, " \
                   "not a floating tag/branch — supply-chain pinning (CI-04). offending: #{line.strip.inspect}")
    end
  end

  # ───────────────────── CI-05: matrix — Ruby {3.2,3.4} × DB {pg,mysql} ───────

  # The strategy matrix must include Ruby 3.2 AND 3.4 AND DB postgres AND mysql,
  # against Redmine 6.1.x. The 4-combo compatibility set.
  def test_ci05_matrix_covers_ruby_3_2_and_3_4_and_postgres_and_mysql_on_redmine_6_1
    wf = workflow_yaml
    jobs = wf['jobs']
    refute_nil jobs, "#{WORKFLOW}: a `jobs:` block must be present (CI-05)"

    matrices = jobs.values.filter_map do |job|
      next unless job.is_a?(Hash)
      strat = job['strategy']
      strat.is_a?(Hash) ? strat['matrix'] : nil
    end
    refute_empty matrices,
                 "#{WORKFLOW}: a job `strategy.matrix:` block must be present — the compat matrix (CI-05)"

    # Gather every scalar value mentioned anywhere in any matrix block (axis
    # values + matrix.include rows), downcased, for membership checks.
    matrix_tokens = matrices.flat_map { |m| flatten_scalars(m) }.map { |v| v.to_s.downcase }

    %w[3.2 3.4].each do |rb|
      assert_includes matrix_tokens, rb,
                      "#{WORKFLOW}: CI matrix MUST include Ruby #{rb} (CI-05). got=#{matrix_tokens.inspect}"
    end
    assert(matrix_tokens.any? { |t| t.include?('postgres') || t == 'pg' },
           "#{WORKFLOW}: CI matrix MUST include a PostgreSQL DB leg (CI-05). got=#{matrix_tokens.inspect}")
    assert(matrix_tokens.any? { |t| t.include?('mysql') },
           "#{WORKFLOW}: CI matrix MUST include a MySQL DB leg (CI-05). got=#{matrix_tokens.inspect}")

    # Redmine 6.1.x must be the pinned target somewhere in the workflow (the
    # checkout step pins the tag, e.g. v6.1.2 per CI-CD-03).
    src = read_or_flunk(WORKFLOW)
    assert_match(/6\.1\.\d+|6\.1\.x|v6\.1/, src,
                 "#{WORKFLOW}: the workflow MUST pin Redmine 6.1.x as the test target (CI-05/CI-CD-03)")
  end

  # ───────────────────── CI-08/CI-09: host-neutral run.sh ─────────────────────

  # scripts/ci/run.sh exists, is `bash -n` clean, contains NONE of the
  # host-specific tokens (no container leakage, no GitHub-template leakage), and
  # DOES run the rake plugins:test + the standalone domain lane.
  def test_ci08_run_sh_exists_is_executable_and_bash_n_clean
    p = path(CI_SCRIPT)
    flunk "expected file missing (RED until A9 authors it): #{CI_SCRIPT}" unless File.exist?(p)
    assert File.executable?(p),
           "#{CI_SCRIPT}: the CI script MUST be executable (chmod +x) (CI-08)"

    # `bash -n` is a built-in syntax check (no install). Shell out to it.
    out = `bash -n #{p.shellescape} 2>&1`
    assert_equal 0, $?.exitstatus,
                 "#{CI_SCRIPT}: must pass `bash -n` syntax check (CI-08). output: #{out}"
  end

  def test_ci08_run_sh_is_host_neutral_no_container_or_template_leakage
    src = read_or_flunk(CI_SCRIPT)
    # Forbidden host-specific tokens: container runtimes, the local harness's
    # container names, hardcoded Redmine path, and GitHub Actions template syntax.
    {
      'podman'           => /podman/,
      'docker'           => /docker/,
      'pulse_test_'      => /pulse_test_/,
      '/usr/src/redmine' => %r{/usr/src/redmine},
      '${{ (GH template)' => /\$\{\{/
    }.each do |label, pat|
      refute_match(pat, src,
                   "#{CI_SCRIPT}: host-specific token #{label} must NOT leak into the portable " \
                   'script (CI-08 host-neutrality)')
    end
  end

  def test_ci09_run_sh_runs_plugins_test_and_standalone_domain_lane
    src = read_or_flunk(CI_SCRIPT)
    # It DOES run the Redmine rake plugins:test lane.
    assert_match(/redmine:plugins:test/, src,
                 "#{CI_SCRIPT}: must run `rake redmine:plugins:test` (CI-08/CI-09)")
    # It DOES run the standalone domain lane (ruby -Itest ... on the domain tests).
    assert_match(/ruby\s+-Itest/, src,
                 "#{CI_SCRIPT}: must run the standalone domain lane via `ruby -Itest ...` (CI-08)")
    assert_match(%r{test/unit/domain}, src,
                 "#{CI_SCRIPT}: the standalone lane must target the domain tests under " \
                 'test/unit/domain (CI-08)')
  end

  # ───────────────────── CI-A10-001: full standalone unit-suite coverage ──────

  # COVERAGE PARITY (A10 fix-cycle, finding CI-A10-001, HIGH).
  #
  # The local reference harness runs `rake redmine:plugins:test`, which discovers
  # EVERY unit test. The CI script splits that into a Redmine functional+integration
  # lane plus a standalone lane — but the standalone lane must not silently DROP the
  # top-level (non-domain) unit guards. `test/unit/static_source_guards_test.rb`,
  # `test/unit/i18n_coverage_test.rb` and `test/unit/ci_workflow_safety_test.rb`
  # (this very file) are bare-Ruby guards that the Redmine lane does NOT run, so the
  # standalone lane is their ONLY home in CI. A `test/unit/domain/*` glob excludes
  # them — they then run NOWHERE, and CI cannot regress-detect a broken guard.
  #
  # FAIL CLOSED: the standalone lane MUST provably include every top-level unit
  # guard — either by a recursive `test/unit/**` glob, or by explicitly naming the
  # guards alongside the domain glob. RED on the current `test/unit/domain/*`-only
  # run.sh.
  def test_a10_001_run_sh_standalone_lane_runs_full_unit_suite_not_only_domain
    src = read_or_flunk(CI_SCRIPT)

    # The non-domain top-level unit guards that the Redmine functional+integration
    # lane does NOT discover — they are bare-Ruby and live only in the standalone
    # lane. Each MUST be provably executed by run.sh.
    top_level_guards = %w[
      test/unit/static_source_guards_test.rb
      test/unit/i18n_coverage_test.rb
      test/unit/ci_workflow_safety_test.rb
    ]

    # Acceptance A: a RECURSIVE glob over the whole standalone unit tree. A
    # `test/unit/**/*_test.rb` (or `test/unit/**/**`) Dir glob provably includes
    # the top-level guards AND the domain tests. A `test/unit/*_test.rb`
    # (single-level) glob would also pick up the three guards but NOT the domain
    # subdir — so we require the recursive `**` form, which covers both.
    recursive_glob =
      src =~ %r{Dir\[[^\]]*test/unit/\*\*}  # test/unit/** ... inside a Dir[...]

    # Acceptance B: the three top-level guards are each EXPLICITLY named in run.sh
    # (in addition to whatever domain glob exists), so they are provably run.
    explicitly_named = top_level_guards.all? { |g| src.include?(g) }

    assert(recursive_glob || explicitly_named,
           "#{CI_SCRIPT}: the standalone lane MUST run the FULL unit suite, not only " \
           "test/unit/domain/* — the top-level guards (static_source_guards, " \
           "i18n_coverage, ci_workflow_safety) are bare-Ruby and run NOWHERE ELSE in " \
           "CI. Use a recursive `test/unit/**/*_test.rb` glob OR explicitly name all " \
           "three guards alongside the domain glob (coverage parity, CI-A10-001). " \
           "found recursive_glob=#{!recursive_glob.nil?} explicitly_named=#{explicitly_named}")

    # Belt-and-braces: a NARROW domain-only glob with NO recursive sweep and NO
    # explicit naming of the guards is the exact defect — assert it is NOT the shape
    # of the script. (Redundant with the assertion above, but pins the RED reason to
    # the specific `test/unit/domain/*`-only pattern from the audit.)
    domain_only = src =~ %r{Dir\[[^\]]*test/unit/domain/\*_test\.rb}
    refute(domain_only && !recursive_glob && !explicitly_named,
           "#{CI_SCRIPT}: the standalone lane uses a domain-ONLY glob " \
           "(test/unit/domain/*_test.rb) that excludes the top-level unit guards — " \
           "they run nowhere in CI (CI-A10-001). Broaden to test/unit/**/*_test.rb " \
           "or name the guards explicitly.")
  end

  # ───────────────────── CI-A10-002: immutable Redmine checkout ref ────────────

  # REPRODUCIBILITY (A10 fix-cycle, finding CI-A10-002, MEDIUM).
  #
  # The label + CANON_REQ_PKG pin Redmine 6.1.2, but the checkout clones the MOVING
  # `6.1-stable` branch — a moving ref can change the tested substrate with no repo
  # change, defeating reproducibility. The Redmine checkout MUST target an IMMUTABLE
  # ref: the `v6.1.2` tag, or a 40-hex commit SHA. The moving `6.1-stable` branch
  # ref MUST NOT be used. RED on the current `-b 6.1-stable` clone.
  def test_a10_002_workflow_checks_out_immutable_redmine_ref_not_moving_branch
    src = read_or_flunk(WORKFLOW)

    # Find the Redmine-checkout command line(s): a git clone of the redmine repo.
    redmine_clone_lines =
      src.lines.map(&:strip).select { |l| l =~ %r{git\s+clone} && l =~ /redmine\/redmine/ }
    refute_empty redmine_clone_lines,
                 "#{WORKFLOW}: a Redmine `git clone` step must be present so the immutable-ref " \
                 "guard has something to check (CI-A10-002)"

    redmine_clone_lines.each do |line|
      # (a) FAIL CLOSED on the known moving-branch ref. `6.1-stable` is a branch that
      #     advances over time — explicitly forbidden as the checkout target.
      refute_match(/-b\s+6\.1-stable\b/, line,
                   "#{WORKFLOW}: the Redmine checkout MUST NOT clone the MOVING `6.1-stable` " \
                   "branch — it can change the tested substrate without a repo change. Pin the " \
                   "immutable v6.1.2 tag or a 40-hex commit SHA (CI-A10-002). offending: " \
                   "#{line.inspect}")

      # (b) More generally: a `-b <ref>` / `--branch <ref>` checkout target on the
      #     redmine clone MUST be an immutable ref — the v6.1.2 tag or a 40-hex SHA.
      #     Any other named ref (a moving branch) FAILS CLOSED.
      if (m = line.match(/(?:-b|--branch)[=\s]+(\S+)/))
        ref = m[1].delete('"\'')
        immutable = ref =~ /\Av?6\.1\.2\z/ || ref =~ /\A[0-9a-f]{40}\z/
        assert(immutable,
               "#{WORKFLOW}: the Redmine checkout ref `#{ref}` is not an immutable target — it " \
               "MUST be the v6.1.2 tag or a full 40-hex commit SHA, never a moving branch " \
               "(CI-A10-002). offending: #{line.inspect}")
      end
    end

    # (c) Positive corroboration: the immutable v6.1.2 tag (or a 40-hex SHA) must
    #     appear AS the checkout ref somewhere in the clone step — not merely as a
    #     comment/label. A `-b v6.1.2` / `--branch v6.1.2` / `checkout <sha>` token.
    has_immutable_ref =
      src =~ /(?:-b|--branch)[=\s]+v?6\.1\.2\b/ ||
      src =~ /\bgit\s+(?:checkout|reset[^\n]*)\s+[0-9a-f]{40}\b/ ||
      src =~ /(?:-b|--branch)[=\s]+[0-9a-f]{40}\b/
    assert(has_immutable_ref,
           "#{WORKFLOW}: the Redmine checkout MUST pin an IMMUTABLE ref — clone/checkout the " \
           "`v6.1.2` tag or a 40-hex commit SHA — so the tested substrate is reproducible " \
           "(CI-A10-002). No immutable checkout ref found.")
  end

  # ───────────────────── CI-11: README compatibility matrix + CI badge ────────

  def test_ci11_readme_has_compatibility_matrix_and_ci_badge
    src = read_or_flunk(README)

    # A compatibility matrix mentioning Redmine 6.1 + both Ruby versions + both DBs.
    assert_match(/6\.1/, src, "#{README}: compatibility matrix must mention Redmine 6.1 (CI-11)")
    assert_match(/3\.2/, src, "#{README}: compatibility matrix must mention Ruby 3.2 (CI-11)")
    assert_match(/3\.4/, src, "#{README}: compatibility matrix must mention Ruby 3.4 (CI-11)")
    assert_match(/PostgreSQL/i, src, "#{README}: compatibility matrix must mention PostgreSQL (CI-11)")
    assert_match(/MySQL/i, src, "#{README}: compatibility matrix must mention MySQL (CI-11)")

    # A Markdown table (a header separator row of pipes-and-dashes).
    assert_match(/\|[\s:-]*-{2,}[\s:|-]*\|/, src,
                 "#{README}: the compatibility matrix must be a Markdown table (CI-11)")

    # A CI status badge: a GitHub-Actions workflow badge or a shields.io CI badge
    # that links to the project's own Actions run.
    has_actions_badge = src =~ %r{actions/workflows/ci\.yml/badge\.svg}
    has_shields_ci_badge = src =~ %r{img\.shields\.io/.*\b(?:ci|github/actions/workflow)\b}i
    assert(has_actions_badge || has_shields_ci_badge,
           "#{README}: must carry a CI status badge (GitHub-Actions workflow badge or shields.io CI " \
           'badge) linking to the project Actions run (CI-11)')
  end

  # ───────────────────── CI-12: CHANGELOG entry references CI ─────────────────

  def test_ci12_changelog_has_ci_entry
    src = read_or_flunk(CHANGELOG)
    assert_match(/\bCI\b|continuous integration/i, src,
                 "#{CHANGELOG}: must have an entry referencing CI / continuous integration (CI-12)")
    # The entry must mention GitHub Actions (the host) so the CI addition is concrete.
    assert_match(/GitHub Actions/i, src,
                 "#{CHANGELOG}: the CI entry should name GitHub Actions, the chosen CI host (CI-12)")
  end

  # ───────────────────── OSI-CI-01: harness committed + referenced ────────────

  # The local harness script exists on disk (it does today). The impl step will
  # `git add` it; this test documents the file-presence expectation and that the
  # harness is referenced from README or scripts/ci (NOT git state).
  def test_osi_ci01_harness_present_and_referenced
    assert File.exist?(path(HARNESS_SCRIPT)),
           "#{HARNESS_SCRIPT}: the local harness script must be present on disk (OSI-CI-01)"

    # It must be referenced from README or from the CI script, so the local-dev
    # parity entry point is discoverable, not orphaned.
    referenced =
      (File.exist?(path(README)) && File.read(path(README)).include?('scripts/test-redmine')) ||
      (File.exist?(path(CI_SCRIPT)) && File.read(path(CI_SCRIPT)).include?('scripts/test-redmine'))
    assert referenced,
           'the committed harness (scripts/test-redmine/) must be referenced from README.md or ' \
           'scripts/ci/run.sh so local-dev parity is discoverable (OSI-CI-01)'
  end

  private

  # Recursively collect every scalar leaf from a nested Hash/Array structure.
  def flatten_scalars(obj)
    case obj
    when Hash  then obj.values.flat_map { |v| flatten_scalars(v) }
    when Array then obj.flat_map { |v| flatten_scalars(v) }
    else [obj]
    end
  end
end
