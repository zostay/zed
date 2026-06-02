/* ===========================================================================
   maintenance · observability deck — client
   Vanilla JS, no build step, no external network calls.
   - Polls /api/runs for the sidebar.
   - Streams the selected run via SSE (/api/stream/<id>) with a polling
     fallback (/api/runs/<id> + /events) when SSE drops or errors.
   - Renders a tiny inline Markdown subset for run + job summaries.
   =========================================================================== */
(function () {
  "use strict";

  // ---- constants ----------------------------------------------------------
  var STAGES = [
    { id: "starting",       label: "starting",       tag: "01" },
    { id: "reading-config", label: "reading config", tag: "02" },
    { id: "discovering",    label: "discovering",    tag: "03" },
    { id: "executing",      label: "executing",      tag: "04" },
    { id: "summarizing",    label: "summarizing",    tag: "05" },
    { id: "done",           label: "done",           tag: "06" }
  ];
  var COUNT_KEYS = ["total", "pending", "running", "success", "failure", "skipped"];
  var TERMINAL = { completed: 1, failed: 1, cancelled: 1 };
  var LEVEL_GLYPH = { info: "›", warn: "▲", error: "✕", success: "✓" };

  // ---- state --------------------------------------------------------------
  var state = {
    runs: [],
    selectedId: null,
    detail: null,             // { run, jobs, counts }
    jobsById: {},             // id -> last rendered job
    lastEventId: 0,
    seenEventIds: {},
    es: null,                 // EventSource
    pollTimer: null,
    runsTimer: null,
    expanded: {}              // job id -> bool (summary expanded)
  };

  // ---- dom ----------------------------------------------------------------
  var el = {
    runList: byId("run-list"),
    runsCount: byId("runs-count"),
    runsEmpty: byId("runs-empty"),
    emptyState: byId("empty-state"),
    runView: byId("run-view"),
    rvTag: byId("rv-tag"),
    rvMeta: byId("rv-meta"),
    rvStatus: byId("rv-status"),
    rvTime: byId("rv-time"),
    stepper: byId("stepper"),
    counts: byId("counts"),
    jobs: byId("jobs"),
    jobsHint: byId("jobs-hint"),
    summary: byId("summary"),
    events: byId("events"),
    eventsHint: byId("events-hint"),
    conn: byId("conn"),
    clock: byId("clock")
  };

  function byId(id) { return document.getElementById(id); }

  // =========================================================================
  // Boot
  // =========================================================================
  buildStepper();
  buildCounts();
  startClock();
  refreshRuns(true);
  state.runsTimer = setInterval(refreshRuns, 4000);

  // =========================================================================
  // Runs sidebar
  // =========================================================================
  function refreshRuns(initial) {
    fetchJSON("/api/runs").then(function (data) {
      var runs = (data && data.runs) || [];
      state.runs = runs;
      renderRunList();
      if (initial && runs.length && state.selectedId == null) {
        selectRun(runs[0].id);   // newest first → select default
      } else if (state.selectedId != null && !findRun(state.selectedId) && runs.length) {
        selectRun(runs[0].id);
      }
    }).catch(function () { /* server may be momentarily unreachable */ });
  }

  function findRun(id) {
    for (var i = 0; i < state.runs.length; i++) {
      if (state.runs[i].id === id) return state.runs[i];
    }
    return null;
  }

  function renderRunList() {
    var runs = state.runs;
    el.runsCount.textContent = runs.length;
    el.runsEmpty.hidden = runs.length > 0;
    el.runList.innerHTML = "";

    runs.forEach(function (run) {
      var health = runHealth(run);
      var li = document.createElement("li");
      li.className = "run-item" + (run.id === state.selectedId ? " is-active" : "");
      li.dataset.health = health;
      li.tabIndex = 0;

      var top = document.createElement("div");
      top.className = "ri-top";
      var tag = document.createElement("span");
      tag.className = "ri-tag";
      tag.textContent = run.tag;
      var pill = document.createElement("span");
      pill.className = "health-pill";
      pill.dataset.h = health;
      pill.textContent = healthLabel(health, run);
      top.appendChild(tag);
      top.appendChild(pill);

      var bottom = document.createElement("div");
      bottom.className = "ri-bottom";
      var when = document.createElement("span");
      when.textContent = relTime(run.started_at);
      var mini = document.createElement("span");
      mini.className = "ri-mini";
      var c = run.counts || {};
      mini.appendChild(miniStat("ok", c.success));
      mini.appendChild(miniStat("fail", c.failure));
      if (c.running) mini.appendChild(miniStat("run", c.running));
      bottom.appendChild(when);
      bottom.appendChild(mini);

      li.appendChild(top);
      li.appendChild(bottom);
      li.addEventListener("click", function () { selectRun(run.id); });
      li.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); selectRun(run.id); }
      });
      el.runList.appendChild(li);
    });
  }

  function miniStat(kind, n) {
    var s = document.createElement("span");
    var dot = document.createElement("span");
    dot.className = "ri-dot " + kind;
    s.appendChild(dot);
    s.appendChild(document.createTextNode(String(n || 0)));
    return s;
  }

  function runHealth(run) {
    var c = run.counts || {};
    if (run.status === "running" || c.running) return "running";
    if (run.status === "failed" || c.failure) return "fail";
    if (run.status === "completed") return "ok";
    if (run.status === "cancelled") return "idle";
    return c.success ? "ok" : "idle";
  }
  function healthLabel(health, run) {
    if (health === "running") return "live";
    if (health === "fail") return "fail";
    if (health === "ok") return "ok";
    return run.status || "idle";
  }

  // =========================================================================
  // Selection + live connection
  // =========================================================================
  function selectRun(id) {
    if (state.selectedId === id && state.detail) {
      // already showing; just ensure connection
    }
    state.selectedId = id;
    state.detail = null;
    state.jobsById = {};
    state.lastEventId = 0;
    state.seenEventIds = {};
    el.events.innerHTML = "";
    renderRunList();
    el.emptyState.hidden = true;
    el.runView.hidden = false;

    teardownLive();
    // Initial full load via REST, then connect SSE for live updates.
    Promise.all([
      fetchJSON("/api/runs/" + id),
      fetchJSON("/api/runs/" + id + "/events?after=0")
    ]).then(function (res) {
      if (state.selectedId !== id) return;
      applyDetail(res[0]);
      applyEvents((res[1] && res[1].events) || []);
      connectLive(id);
    }).catch(function () {
      // server hiccup: still try to stream
      connectLive(id);
    });
  }

  function connectLive(id) {
    if (!window.EventSource) { startPolling(id); return; }
    setConn("init", "connecting");
    var es;
    try {
      es = new EventSource("/api/stream/" + id + "?after=" + state.lastEventId);
    } catch (e) {
      startPolling(id);
      return;
    }
    state.es = es;

    es.onopen = function () {
      if (state.selectedId !== id) return;
      setConn("live", "live · sse");
    };
    es.onmessage = function (ev) {
      if (state.selectedId !== id) return;
      var payload;
      try { payload = JSON.parse(ev.data); } catch (e) { return; }
      if (payload.run) applyDetail({ run: payload.run, jobs: payload.jobs, counts: payload.counts });
      if (payload.events && payload.events.length) applyEvents(payload.events);
    };
    es.onerror = function () {
      if (state.selectedId !== id) return;
      // SSE dropped — the server closes terminal streams intentionally.
      // If the run is finished we don't need to fall back; otherwise poll.
      es.close();
      state.es = null;
      var run = state.detail && state.detail.run;
      if (run && TERMINAL[run.status]) {
        setConn("down", "closed");
      } else {
        startPolling(id);
      }
    };
  }

  function startPolling(id) {
    if (state.pollTimer) return;
    setConn("polling", "polling");
    var tick = function () {
      if (state.selectedId !== id) return;
      Promise.all([
        fetchJSON("/api/runs/" + id),
        fetchJSON("/api/runs/" + id + "/events?after=" + state.lastEventId)
      ]).then(function (res) {
        if (state.selectedId !== id) return;
        if (res[0]) applyDetail(res[0]);
        applyEvents((res[1] && res[1].events) || []);
        var run = state.detail && state.detail.run;
        if (run && TERMINAL[run.status]) {
          stopPolling();
          setConn("down", "closed");
        }
      }).catch(function () { /* keep trying */ });
    };
    state.pollTimer = setInterval(tick, 1500);
    tick();
  }

  function stopPolling() {
    if (state.pollTimer) { clearInterval(state.pollTimer); state.pollTimer = null; }
  }

  function teardownLive() {
    if (state.es) { try { state.es.close(); } catch (e) {} state.es = null; }
    stopPolling();
  }

  function setConn(stateName, label) {
    el.conn.dataset.state = stateName;
    el.conn.querySelector(".conn-label").textContent = label;
  }

  // =========================================================================
  // Render detail
  // =========================================================================
  function applyDetail(detail) {
    if (!detail || !detail.run) return;
    var prev = state.detail;
    state.detail = detail;
    var run = detail.run;

    el.rvTag.textContent = run.tag;
    el.rvMeta.textContent = "run #" + run.id +
      (run.mode ? "  ·  " + run.mode : "") +
      (run.options ? "  ·  " + compactOptions(run.options) : "");
    el.rvStatus.dataset.status = run.status;
    el.rvStatus.textContent = run.status;
    el.rvTime.textContent = timeRange(run.started_at, run.finished_at);

    renderStepper(run.stage, run.status);
    renderCounts(detail.counts || {}, prev && prev.counts);
    renderJobs(detail.jobs || []);
    renderSummary(run.summary);

    // keep sidebar pill fresh for this run
    var sidebarRun = findRun(run.id);
    if (sidebarRun) {
      sidebarRun.status = run.status;
      sidebarRun.stage = run.stage;
      sidebarRun.counts = detail.counts;
      sidebarRun.finished_at = run.finished_at;
      renderRunList();
    }
  }

  function compactOptions(opts) {
    try {
      var o = JSON.parse(opts);
      var flags = [];
      Object.keys(o).forEach(function (k) {
        if (o[k] === true) flags.push("--" + k);
        else if (o[k] !== false && o[k] != null) flags.push("--" + k + " " + o[k]);
      });
      return flags.join(" ");
    } catch (e) { return ""; }
  }

  // -- stepper --------------------------------------------------------------
  function buildStepper() {
    el.stepper.innerHTML = "";
    STAGES.forEach(function (s) {
      var d = document.createElement("div");
      d.className = "step";
      d.dataset.stage = s.id;
      d.innerHTML =
        '<span class="step-index"></span>' +
        '<span class="step-name">' + s.label + '</span>' +
        '<span class="step-tag">' + s.tag + '</span>';
      el.stepper.appendChild(d);
    });
  }
  function renderStepper(stage, status) {
    var idx = stageIndex(stage);
    // A finished run lights all stages as done.
    var finished = TERMINAL[status];
    var current = finished ? STAGES.length - 1 : idx;
    var steps = el.stepper.children;
    for (var i = 0; i < steps.length; i++) {
      var step = steps[i];
      step.classList.remove("done", "current");
      if (finished || status === "completed") {
        step.classList.add("done");
      } else if (i < current) {
        step.classList.add("done");
      } else if (i === current) {
        step.classList.add("current");
      }
    }
    // For a still-running last stage, mark current not just done.
    if (!finished && current >= 0 && current < steps.length) {
      steps[current].classList.remove("done");
      steps[current].classList.add("current");
    }
  }
  function stageIndex(stage) {
    for (var i = 0; i < STAGES.length; i++) if (STAGES[i].id === stage) return i;
    return 0;
  }

  // -- counts ---------------------------------------------------------------
  function buildCounts() {
    el.counts.innerHTML = "";
    COUNT_KEYS.forEach(function (k) {
      var d = document.createElement("div");
      d.className = "count";
      d.dataset.k = k;
      d.innerHTML = '<span class="count-n">0</span><span class="count-label">' + k + '</span>';
      el.counts.appendChild(d);
    });
  }
  function renderCounts(counts, prev) {
    var nodes = el.counts.children;
    for (var i = 0; i < nodes.length; i++) {
      var k = nodes[i].dataset.k;
      var v = counts[k] != null ? counts[k] : 0;
      var nEl = nodes[i].querySelector(".count-n");
      if (prev && prev[k] !== v) {
        nodes[i].classList.remove("hot");
        void nodes[i].offsetWidth;
        nodes[i].classList.add("hot");
      }
      nEl.textContent = v;
    }
  }

  // -- jobs -----------------------------------------------------------------
  function renderJobs(jobs) {
    el.jobsHint.textContent = jobs.length ? jobs.length + " discovered" : "";
    if (!jobs.length) {
      el.jobs.innerHTML = '<div class="muted" style="padding:14px">No projects discovered yet.</div>';
      return;
    }
    // Reconcile in place so we can animate only what changed.
    var existing = {};
    Array.prototype.forEach.call(el.jobs.children, function (node) {
      if (node.dataset.jobId) existing[node.dataset.jobId] = node;
    });

    jobs.forEach(function (job) {
      var prior = state.jobsById[job.id];
      var node = existing[job.id];
      var changed = !prior || prior.status !== job.status ||
        (prior.summary || "") !== (job.summary || "") ||
        (prior.error || "") !== (job.error || "");
      if (!node) {
        node = document.createElement("div");
        node.dataset.jobId = job.id;
        el.jobs.appendChild(node);
      }
      if (changed || !node.innerHTML) {
        renderJobNode(node, job);
        if (prior && prior.status !== job.status) {
          node.classList.remove("flash"); void node.offsetWidth; node.classList.add("flash");
        }
      }
      delete existing[job.id];
      state.jobsById[job.id] = { status: job.status, summary: job.summary, error: job.error };
    });
    // Remove stale nodes
    Object.keys(existing).forEach(function (id) {
      if (existing[id].parentNode) existing[id].parentNode.removeChild(existing[id]);
    });
  }

  function renderJobNode(node, job) {
    node.className = "job";
    node.dataset.status = job.status;
    node.dataset.jobId = job.id;

    var html = "";
    html += '<div class="job-top">';
    html += '<span class="job-icon"><span class="ind ' + esc(job.status) + '"></span></span>';
    html += '<span class="job-name">' + esc(job.project_name || job.project_path) + '</span>';
    html += '<span class="job-state" data-s="' + esc(job.status) + '">' + esc(job.status) + '</span>';
    html += '</div>';
    if (job.project_path && job.project_path !== job.project_name) {
      html += '<div class="job-path">' + esc(job.project_path) + '</div>';
    }
    node.innerHTML = html;

    var hasError = job.status === "failure" && job.error;
    var hasSummary = !!job.summary;
    if (hasError || hasSummary) {
      var detail = document.createElement("div");
      detail.className = "job-detail";
      if (hasError) {
        var er = document.createElement("div");
        er.className = "job-error";
        er.textContent = job.error;
        detail.appendChild(er);
      }
      if (hasSummary) {
        var expanded = state.expanded[job.id] || job.status === "failure";
        var sum = document.createElement("div");
        sum.className = "job-summary md";
        sum.innerHTML = renderMarkdown(job.summary);
        sum.style.display = expanded ? "" : "none";

        var toggle = document.createElement("button");
        toggle.className = "job-toggle";
        toggle.textContent = expanded ? "▾ hide summary" : "▸ show summary";
        toggle.addEventListener("click", function () {
          var now = sum.style.display === "none";
          sum.style.display = now ? "" : "none";
          state.expanded[job.id] = now;
          toggle.textContent = now ? "▾ hide summary" : "▸ show summary";
        });
        detail.appendChild(toggle);
        detail.appendChild(sum);
      }
      node.appendChild(detail);
    }
  }

  // -- run summary ----------------------------------------------------------
  function renderSummary(md) {
    if (!md) {
      el.summary.innerHTML = '<p class="muted">No summary yet — it appears when the run finishes.</p>';
      return;
    }
    el.summary.innerHTML = renderMarkdown(md);
  }

  // =========================================================================
  // Events
  // =========================================================================
  function applyEvents(events) {
    if (!events || !events.length) return;
    var frag = document.createDocumentFragment();
    var added = 0;
    events.forEach(function (ev) {
      if (state.seenEventIds[ev.id]) return;
      state.seenEventIds[ev.id] = 1;
      if (ev.id > state.lastEventId) state.lastEventId = ev.id;
      frag.appendChild(buildEvent(ev));
      added++;
    });
    if (!added) return;
    // clear empty placeholder
    var empty = el.events.querySelector(".events-empty");
    if (empty) empty.remove();
    el.events.appendChild(frag);
    el.eventsHint.textContent = el.events.children.length + " events";
    // autoscroll to newest
    el.events.scrollTop = el.events.scrollHeight;
  }

  function buildEvent(ev) {
    var li = document.createElement("li");
    li.className = "event enter";
    li.dataset.level = ev.level || "info";
    var glyph = LEVEL_GLYPH[ev.level] || LEVEL_GLYPH.info;
    li.innerHTML =
      '<span class="ev-ts">' + esc(clockTime(ev.ts)) + '</span>' +
      '<span class="ev-glyph">' + esc(glyph) + '</span>' +
      '<span class="ev-msg"></span>';
    li.querySelector(".ev-msg").textContent = ev.message || "";
    return li;
  }

  // =========================================================================
  // Minimal Markdown renderer
  //   Supports: # / ## / ### headings, - and * and 1. lists, ``` code fences,
  //   `inline code`, **bold**, *em*/_em_, [text](url), --- rule, paragraphs.
  //   Everything is HTML-escaped first; only our own tags are injected.
  // =========================================================================
  function renderMarkdown(src) {
    if (!src) return "";
    var lines = String(src).replace(/\r\n?/g, "\n").split("\n");
    var out = [];
    var i = 0;
    var listType = null;   // 'ul' | 'ol' | null

    function closeList() {
      if (listType) { out.push("</" + listType + ">"); listType = null; }
    }

    while (i < lines.length) {
      var line = lines[i];

      // fenced code block
      var fence = line.match(/^```\s*(\S*)\s*$/);
      if (fence) {
        closeList();
        var buf = [];
        i++;
        while (i < lines.length && !/^```\s*$/.test(lines[i])) {
          buf.push(lines[i]); i++;
        }
        i++; // skip closing fence
        out.push("<pre><code>" + escHtml(buf.join("\n")) + "</code></pre>");
        continue;
      }

      // horizontal rule
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) {
        closeList(); out.push("<hr>"); i++; continue;
      }

      // headings
      var h = line.match(/^(#{1,3})\s+(.*)$/);
      if (h) {
        closeList();
        var lvl = h[1].length;
        out.push("<h" + lvl + ">" + inline(h[2]) + "</h" + lvl + ">");
        i++; continue;
      }

      // unordered list
      var ul = line.match(/^\s*[-*+]\s+(.*)$/);
      if (ul) {
        if (listType !== "ul") { closeList(); out.push("<ul>"); listType = "ul"; }
        out.push("<li>" + inline(ul[1]) + "</li>");
        i++; continue;
      }

      // ordered list
      var ol = line.match(/^\s*\d+[.)]\s+(.*)$/);
      if (ol) {
        if (listType !== "ol") { closeList(); out.push("<ol>"); listType = "ol"; }
        out.push("<li>" + inline(ol[1]) + "</li>");
        i++; continue;
      }

      // blank line
      if (/^\s*$/.test(line)) { closeList(); i++; continue; }

      // paragraph (gather consecutive non-structural lines)
      closeList();
      var para = [line];
      i++;
      while (i < lines.length &&
             !/^\s*$/.test(lines[i]) &&
             !/^```/.test(lines[i]) &&
             !/^(#{1,3})\s+/.test(lines[i]) &&
             !/^\s*[-*+]\s+/.test(lines[i]) &&
             !/^\s*\d+[.)]\s+/.test(lines[i]) &&
             !/^\s*([-*_])(\s*\1){2,}\s*$/.test(lines[i])) {
        para.push(lines[i]); i++;
      }
      out.push("<p>" + inline(para.join(" ")) + "</p>");
    }
    closeList();
    return out.join("");
  }

  // inline formatting on already-structural text
  function inline(text) {
    // escape first, then re-introduce our markup via placeholder-safe regex
    var s = escHtml(text);
    // inline code (protect contents from further formatting)
    var codes = [];
    s = s.replace(/`([^`]+)`/g, function (_, c) {
      codes.push(c);
      return " CODE" + (codes.length - 1) + " ";
    });
    // bold then italic
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
    s = s.replace(/(^|[^_])_([^_\n]+)_/g, "$1<em>$2</em>");
    // links [text](url) — only http(s)/mailto/relative, escaped url
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_, txt, url) {
      if (!/^(https?:|mailto:|\/|#)/i.test(url)) return txt;
      return '<a href="' + url + '" target="_blank" rel="noopener noreferrer">' + txt + '</a>';
    });
    // restore code spans
    s = s.replace(/ CODE(\d+) /g, function (_, n) {
      return "<code>" + codes[+n] + "</code>";
    });
    return s;
  }

  function escHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function esc(s) { return escHtml(s == null ? "" : s); }

  // =========================================================================
  // Time helpers
  // =========================================================================
  function startClock() {
    var tick = function () {
      var d = new Date();
      el.clock.textContent = pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
    };
    tick(); setInterval(tick, 1000);
  }
  function pad(n) { return (n < 10 ? "0" : "") + n; }

  function parseTs(ts) {
    if (!ts) return null;
    // stored as ISO-8601 UTC like 2026-06-01T17:04:05Z
    var d = new Date(ts);
    return isNaN(d.getTime()) ? null : d;
  }
  function clockTime(ts) {
    var d = parseTs(ts);
    if (!d) return "--:--:--";
    return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
  }
  function relTime(ts) {
    var d = parseTs(ts);
    if (!d) return "—";
    var sec = Math.floor((Date.now() - d.getTime()) / 1000);
    if (sec < 0) sec = 0;
    if (sec < 60) return sec + "s ago";
    if (sec < 3600) return Math.floor(sec / 60) + "m ago";
    if (sec < 86400) return Math.floor(sec / 3600) + "h ago";
    return Math.floor(sec / 86400) + "d ago";
  }
  function timeRange(start, finish) {
    var s = parseTs(start);
    if (!s) return "";
    var label = "started " + clockTime(start);
    var end = parseTs(finish);
    if (end) {
      var dur = Math.max(0, Math.round((end.getTime() - s.getTime()) / 1000));
      label += "  ·  " + fmtDur(dur);
    } else {
      label = "started " + relTime(start);
    }
    return label;
  }
  function fmtDur(sec) {
    if (sec < 60) return sec + "s";
    var m = Math.floor(sec / 60), s = sec % 60;
    if (m < 60) return m + "m " + s + "s";
    var h = Math.floor(m / 60); m = m % 60;
    return h + "h " + m + "m";
  }

  // =========================================================================
  // fetch helper
  // =========================================================================
  function fetchJSON(url) {
    return fetch(url, { headers: { "Accept": "application/json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("http " + r.status);
        return r.json();
      });
  }
})();
