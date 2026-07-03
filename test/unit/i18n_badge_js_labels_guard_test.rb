# frozen_string_literal: true

# redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
# Copyright (C) 2026 Jeroen
#
# This program is free software: you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation, either version 2 of the License, or (at your option) any later
# version. See <https://www.gnu.org/licenses/> (GPL-2.0).

require 'minitest/autorun'

# H1 I18n sweep — STATIC source guard (no Redmine env) for F1–F5 (badge JS i18n wiring).
#
# Complements the server-side blob test (i18n_badge_labels_blob_test.rb). Where that test
# asserts the SERVER emits a labels object, THIS one asserts the JS is wired to CONSUME it:
#   - project_list_badge.js reads a `labels` object from the parsed blob (data.labels),
#   - it does NOT hardcode the RAG words 'Green'/'Amber'/'Red'/'No data' as the chip text,
#   - the aria label is built from a server format string, not a hardcoded 'Health: ' prefix,
#   - an English fallback is retained (the JS still renders if labels is absent — fail-safe).
#
# RED NOW: ragWord() hardcodes the four words and buildChip() builds `'Health: ' + word`,
# and the JS never references data.labels. PASSES once A9 wires the JS to the blob labels.
class I18nBadgeJsLabelsGuardTest < Minitest::Test
  ROOT = File.expand_path('../../..', __FILE__)
  BADGE_JS = File.join(ROOT, 'assets/javascripts/project_list_badge.js')

  def js
    flunk "badge JS missing: #{BADGE_JS}" unless File.exist?(BADGE_JS)
    File.read(BADGE_JS)
  end

  # ── F1..F4 : the JS reads localized RAG words from the blob labels object ──

  def test_js_reads_labels_object_from_blob
    src = js
    # The pure renderer must consume server-provided labels (the blob is the seam). It must
    # reference a `labels` field off the parsed blob/entry, e.g. data.labels / labels[...].
    assert_match(/\blabels\b/, src,
                 'I18N-F1..F5: project_list_badge.js MUST consume a `labels` object from the ' \
                 'inline blob (it currently holds its own hardcoded vocabulary) -> RED')
    assert_match(/(?:data|portfolio|blob)\s*(?:\.|\[['"])labels|\.labels\b/, src,
                 'I18N-F1..F5: the JS MUST read `labels` off the parsed blob (e.g. data.labels) ' \
                 'so the RAG words are server-localized, not hardcoded in the renderer')
  end

  def test_js_does_not_hardcode_rag_words_as_chip_text
    src = js
    # ragWord() today returns 'Green'/'Amber'/'Red'/'No data'. After the fix the chip text
    # comes from the server labels; the JS must NOT carry these English words as literal
    # return values. (A short English FALLBACK constant is acceptable, but the four words
    # returned verbatim from a switch is the defect we guard — so require they are gone as
    # the *primary* source. We assert the literal return-statement form is absent.)
    %w[Green Amber Red].each do |word|
      refute_match(/return\s+['"]#{word}['"]/, src,
                   "I18N-F1..F4: the badge JS MUST NOT `return '#{word}'` as hardcoded RAG " \
                   'chip text — the localized word comes from the server blob labels -> RED')
    end
    refute_match(/return\s+['"]No data['"]/, src,
                 'I18N-F4: the badge JS MUST NOT `return \'No data\'` as hardcoded chip text ' \
                 '(it comes from label_pulse_rag_no_data via the blob) -> RED')
  end

  # ── F5 : the aria label is built from a server format string, not a JS-side prefix ──

  def test_js_does_not_hardcode_health_aria_prefix
    src = js
    # buildChip() today does `'Health: ' + word`. The aria text must instead come from the
    # server aria FORMAT string (so translators can invert word order). Guard the hardcoded
    # English prefix concatenation specifically.
    refute_match(/['"]Health:\s*['"]\s*\+/, src,
                 "I18N-F5: the badge JS MUST NOT build the aria label as the hardcoded " \
                 "'Health: ' + word prefix — use the server-provided aria format string -> RED")
  end

  # ── fail-safe : an English fallback is retained (renderer still works if labels absent) ──

  def test_js_retains_english_fallback_when_labels_absent
    src = js
    # The pure renderer must remain fail-safe (INV-FAILSILENT): if the blob carries no
    # labels, it falls back to an English default rather than rendering an empty/undefined
    # chip. After the fix the JS reads labels WITH a `||`/`&&` fallback on the SAME line.
    # We require the fallback construct to co-occur with a `labels` reference (so the pre-
    # existing `default:` switch case does NOT satisfy it) — RED now (no labels read at all).
    fallback_with_labels = src.lines.any? do |line|
      line.include?('labels') && (line =~ /\|\||&&/)
    end
    assert fallback_with_labels,
           'I18N-F1..F5: the JS MUST read the blob labels WITH an English fallback on the ' \
           'same expression (e.g. `(labels && labels.rag_green) || \'Green\'`) so it stays ' \
           'fail-safe -> RED (no labels read at all today)'
  end
end
