/* redmine_pulse — portfolio / project-health cockpit for Redmine 6.x.
 * Copyright (C) 2026 Jeroen
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License (GPL-2.0) as published by the Free
 * Software Foundation, either version 2 of the License, or (at your option) any
 * later version. See the GNU General Public License for more details.
 *
 * project-list-badge (B2 server-inline, D-PLB-C04). This is a PURE RENDERER
 * (INV-RENDERER-PURITY): it reads the server-inlined viewer-scoped portfolio blob and
 * decorates each /projects row with the RAG chip + the server-provided "main concern"
 * label. It computes NO health, holds NO signal->label vocabulary, and makes NO network
 * request — the data is same-document inline (INV-NO-EXTERNAL). All blob-derived strings
 * go into the DOM via textContent / setAttribute ONLY (INV-XSS); the blob is read via
 * JSON.parse and is NEVER executed (INV-INLINE-XSS). Any fault is silent (INV-FAILSILENT).
 *
 * Row selector grounded against the live Redmine 6.1.2 /projects DOM (DG-PLB-01): the
 * project listing is a <ul class="projects"> tree; each <li> wraps an inner <div> whose
 * first child is <a class="project" href="/projects/:identifier">. The same DOM serves
 * the board display_type, so one selector covers both list and board (DG-PLB-01).
 */
(function () {
  'use strict';

  var BLOB_ID = 'pulse-portfolio-data';
  var DECORATED_FLAG = 'data-pulse-decorated';
  var IDENTIFIER_RE = /\/projects\/([^/?#]+)/;

  // Read + parse the inline blob. Fail-silent: any absence / empty / malformed JSON
  // returns null (no decoration), never throws (INV-FAILSILENT / INV-INLINE-XSS).
  function readPortfolio() {
    try {
      var el = document.getElementById(BLOB_ID);
      if (!el) { return null; }
      var text = el.textContent;
      if (!text || text.trim() === '') { return null; }
      var data = JSON.parse(text);
      var projects = data && data.projects ? data.projects : data;
      if (!Array.isArray(projects)) { return null; }
      // The server passes a `labels` object alongside `projects` (I18N-F1..F5): the
      // localized RAG words + an aria FORMAT string. The renderer holds NO vocabulary of
      // its own; it reads these (with an English fallback) so the chips are server-localized.
      var labels = (data && data.labels) || {};
      return { projects: projects, labels: labels };
    } catch (e) {
      return null;
    }
  }

  // Build an identifier -> {rag, main_concern} index once (O(N)); look up O(1) per row.
  function buildIndex(projects) {
    var index = {};
    for (var i = 0; i < projects.length; i++) {
      var entry = projects[i];
      if (entry && typeof entry.identifier === 'string') {
        index[entry.identifier] = entry;
      }
    }
    return index;
  }

  // The RAG chip: a span carrying the existing cockpit CSS classes (rag -> css-class by
  // concatenation only), a non-empty RAG word + aria-label/title (non-color a11y cue,
  // WCAG 1.4.1). All text via textContent; class/aria via setAttribute (INV-XSS).
  function buildChip(entry, labels) {
    var rag = String(entry.rag || '');
    var chip = document.createElement('span');
    chip.setAttribute('class', 'pulse-rag pulse-rag-' + rag);
    var word = ragWord(rag, labels);
    var aria = ariaLabel(word, labels);
    chip.setAttribute('aria-label', aria);
    chip.setAttribute('title', aria);
    chip.textContent = word;
    return chip;
  }

  // RAG state -> a human-readable word. NOT a health computation and NOT a localized
  // concern-label table: the word is the SERVER-localized label off the blob `labels`
  // object, with a short English fallback (INV-FAILSILENT) so a missing labels object
  // still renders. This only names the colour channel for the non-color cue.
  var RAG_FALLBACK = { green: 'Green', amber: 'Amber', red: 'Red', no_data: 'No data' };

  function ragWord(rag, labels) {
    var key = rag === 'green' || rag === 'amber' || rag === 'red' ? rag : 'no_data';
    return (labels && labels['rag_' + key]) || RAG_FALLBACK[key];
  }

  // Build the accessible label from the SERVER-provided aria FORMAT string (a
  // "...%{state}..." / "...%s..." template, so translators control word order), with an
  // English fallback. Pure substitution — the renderer holds no aria vocabulary of its own.
  function ariaLabel(word, labels) {
    var fmt = (labels && labels.rag_aria_format) || 'Health: %{state}';
    if (fmt.indexOf('%{state}') !== -1) { return fmt.replace('%{state}', word); }
    if (fmt.indexOf('%s') !== -1) { return fmt.replace('%s', word); }
    return fmt + word;
  }

  // The server-provided main-concern label, consumed VERBATIM (INV-RENDERER-PURITY):
  // textContent only, no vocabulary of our own. null/empty -> no label node.
  function buildConcern(entry) {
    var concern = entry.main_concern;
    if (concern === null || concern === undefined || concern === '') { return null; }
    var span = document.createElement('span');
    span.setAttribute('class', 'pulse-concern');
    span.textContent = String(concern);
    return span;
  }

  function decorateRow(anchor, entry, labels) {
    // Idempotent per-row guard: skip if this row already carries a chip (INV-IDEMPOTENT).
    if (anchor.parentNode && anchor.parentNode.querySelector('.pulse-rag')) { return; }

    var chip = buildChip(entry, labels);
    var concern = buildConcern(entry);

    // Additive placement: insert the chip (and label) right AFTER the project <a>, within
    // its inner <div>, without removing/obscuring the existing link/icon/description
    // (INV-UNOBTRUSIVE). insertBefore(node, anchor.nextSibling) appends after the anchor.
    var parent = anchor.parentNode;
    if (!parent) { return; }
    parent.insertBefore(chip, anchor.nextSibling);
    if (concern) { parent.insertBefore(concern, chip.nextSibling); }
    anchor.setAttribute(DECORATED_FLAG, '1');
  }

  function decorate() {
    var portfolio = readPortfolio();
    if (!portfolio) { return; }
    var projects = portfolio.projects;
    var labels = portfolio.labels;
    if (!projects || projects.length === 0) { return; }
    var index = buildIndex(projects);

    var rows = document.querySelectorAll('ul.projects li');
    for (var i = 0; i < rows.length; i++) {
      try {
        // The inner-div project anchor (DG-PLB-01). :scope > div guards against matching a
        // descendant subproject's anchor (each <li> is visited once by the NodeList).
        var anchor = rows[i].querySelector(':scope > div a.project[href^="/projects/"]');
        if (!anchor) { continue; }
        var href = anchor.getAttribute('href') || '';
        var m = IDENTIFIER_RE.exec(href);
        if (!m) { continue; }
        var entry = index[m[1]];
        if (!entry) { continue; } // not in portfolio (Pulse disabled) -> unchanged
        decorateRow(anchor, entry, labels);
      } catch (e) {
        // Per-row containment: one row's failure must not abort the rest (INV-FAILSILENT).
      }
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', decorate);
  } else {
    decorate();
  }
})();
