/* ===========================================================================
   maintenance · observability deck — client
   Vanilla JS, no build step, no external network calls.

   Layout is status-driven. One run-view container, two faces:
     - run.status === "running"  → LIVE FOCUS  (current work + activity on top)
     - otherwise                 → DEBRIEF     (stoplight + promoted followups)
   A tiny hash router adds a separate followups page:
     #/run/:id                   → the run (auto-face)
     #/run/:id/followups         → full followup detail
     #/run/:id/followup/:fid     → deep-link to one ticket
   =========================================================================== */
(function () {
  "use strict";

  // ---- constants ----------------------------------------------------------
  var STAGES = [
    { id: "starting",       label: "start",   },
    { id: "reading-config", label: "config",  },
    { id: "discovering",    label: "discover" },
    { id: "executing",      label: "execute"  },
    { id: "summarizing",    label: "summary"  },
    { id: "done",           label: "done"     }
  ];
  // Terminal = the stream can close. 'needs_followup' is deliberately NOT
  // terminal: the sweep is done but tickets remain, so we keep streaming to
  // reflect tickets resolving live until the run graduates to 'completed'.
  // 'awaiting_interactive' is likewise absent — a parked run is not over, and
  // this page is where the human clicks Start, so the stream must stay open for
  // as long as they take.
  var TERMINAL = { completed: 1, failed: 1, cancelled: 1 };
  var LEVEL_GLYPH = { info: "›", warn: "▲", error: "✕", success: "✓" };
  var CHIP_GLYPH = {
    success: "✓", skipped: "–", failure: "✕",
    followup: "…", running: "⟳", pending: "○",
    awaiting_interactive: "◆"
  };
  var TICKET_STATUS_LABEL = { open: "open", done: "done", wontdo: "won't do" };
  // GitHub triage: issue vs PR has to be readable at a glance, so it gets both
  // a glyph and a color (see .gt-row[data-kind] in the stylesheet).
  var KIND_GLYPH = { issue: "◉", pr: "⇄" };
  var ACTION_LABEL = { opened: "opened", update: "update", done: "done", nope: "won't do" };
  // status → queue sort priority (what's left surfaces first)
  var STATUS_PRIORITY = { running: 0, awaiting_interactive: 1, pending: 2, followup: 3, failure: 4, success: 5, skipped: 6 };

  // ---- state --------------------------------------------------------------
  var state = {
    runs: [],
    route: { view: "run", runId: null, fid: null },
    selectedId: null,
    detail: null,
    events: [],               // ordered, deduped event store for the selected run
    seenEventIds: {},
    maxEventId: 0,             // cached max event id (avoid rescanning events[])
    mountedEventsEl: null,     // which <ol> the live events are currently rendered into
    es: null,
    pollTimer: null,
    runsTimer: null,
    prevStatus: null,         // for the running -> done reveal
    ixPending: {},            // interactive task id -> Start POST in flight
    ixError: "",              // last Start failure, held until the next attempt
    expanded: {},             // result id -> summary expanded
    foldOpen: false,          // debrief: clean-projects fold
    logOpen: false,           // debrief: activity log
    scrolledFid: null,        // followups page: ticket we've already auto-scrolled to
    fpSig: null               // followups page: signature of last-rendered list
  };

  // ---- dom ----------------------------------------------------------------
  var el = {
    runList: byId("run-list"),
    runsCount: byId("runs-count"),
    runsEmpty: byId("runs-empty"),
    emptyState: byId("empty-state"),
    runView: byId("run-view"),
    followupsPage: byId("followups-page"),
    // header
    rvTag: byId("rv-tag"),
    rvStatus: byId("rv-status"),
    rvMeta: byId("rv-meta"),
    rvTime: byId("rv-time"),
    stageRail: byId("stage-rail"),
    // live face
    prFill: byId("pr-fill"),
    prStats: byId("pr-stats"),
    now: byId("now"),
    nowHint: byId("now-hint"),
    queue: byId("queue"),
    queueHint: byId("queue-hint"),
    events: byId("events"),
    eventsHint: byId("events-hint"),
    followupStrip: byId("followup-strip"),
    fsLabel: byId("fs-label"),
    // debrief face
    stoplight: byId("stoplight"),
    dbFollowups: byId("db-followups"),
    dbFollowupsLink: byId("db-followups-link"),
    dbFollowupsBody: byId("db-followups-body"),
    dbFollowupsFoot: byId("db-followups-foot"),
    dbTriage: byId("db-triage"),
    triageTitle: byId("triage-title"),
    gtNote: byId("gt-note"),
    gtNewBoard: byId("gt-new-board"),
    gtNew: byId("gt-new"),
    gtNewHint: byId("gt-new-hint"),
    gtTopBoard: byId("gt-top-board"),
    gtBy: byId("gt-by"),
    triageHint: byId("triage-hint"),
    gtTop: byId("gt-top"),
    gtGroups: byId("gt-groups"),
    gtGroupsHint: byId("gt-groups-hint"),
    summary: byId("summary"),
    results: byId("results"),
    resultsHint: byId("results-hint"),
    logToggle: byId("log-toggle"),
    logCount: byId("log-count"),
    eventsDebrief: byId("events-debrief"),
    // interactive queue
    ixBar: byId("ix-bar"),
    ixRows: byId("ix-rows"),
    ixHint: byId("ix-hint"),
    ixFoot: byId("ix-foot"),
    // followups page
    fpBack: byId("fp-back"),
    fpTitle: byId("fp-title"),
    fpSub: byId("fp-sub"),
    fpRunStatus: byId("fp-runstatus"),
    fpList: byId("fp-list"),
    fpHelp: byId("fp-help"),
    // chrome
    conn: byId("conn"),
    clock: byId("clock")
  };

  function byId(id) { return document.getElementById(id); }

  // =========================================================================
  // Boot
  // =========================================================================
  buildStageRail();
  startClock();
  wireStaticHandlers();
  window.addEventListener("hashchange", onRoute);
  refreshRuns(true);
  state.runsTimer = setInterval(refreshRuns, 4000);

  function wireStaticHandlers() {
    el.logToggle.addEventListener("click", function () {
      state.logOpen = !state.logOpen;
      el.logToggle.setAttribute("aria-expanded", state.logOpen ? "true" : "false");
      el.eventsDebrief.hidden = !state.logOpen;
      if (state.logOpen) mountEvents(el.eventsDebrief, false);
      else if (state.mountedEventsEl === el.eventsDebrief) state.mountedEventsEl = null;
    });
  }

  // =========================================================================
  // Router
  // =========================================================================
  function parseHash() {
    var h = (location.hash || "").replace(/^#\/?/, "");
    var parts = h.split("/").filter(Boolean);   // e.g. ["run","4","followups"]
    if (parts[0] === "run" && parts[1]) {
      var runId = parseInt(parts[1], 10);
      if (parts[2] === "followups") return { view: "followups", runId: runId, fid: null };
      if (parts[2] === "followup" && parts[3]) {
        return { view: "followups", runId: runId, fid: parseInt(parts[3], 10) };
      }
      return { view: "run", runId: runId, fid: null };
    }
    return { view: "run", runId: null, fid: null };
  }

  function onRoute() {
    var next = parseHash();
    var prev = state.route;
    state.route = next;

    if (next.runId == null) {
      // no run in the hash — pick the newest if we have one
      if (state.runs.length) { navigate(state.runs[0].id); return; }
      showEmpty();
      return;
    }
    // A new deep-linked ticket should re-scroll even if the run is unchanged.
    if (next.fid !== (prev && prev.fid)) state.scrolledFid = null;
    if (next.runId !== state.selectedId) {
      selectRun(next.runId);         // loads detail, connects live, then renders
    } else {
      renderCurrentView();           // same run, just switched view (run <-> followups)
    }
  }

  function navigate(runId, sub) {
    var h = "#/run/" + runId + (sub ? "/" + sub : "");
    if (location.hash === h) onRoute();     // same hash: re-run manually
    else location.hash = h;
  }

  // =========================================================================
  // Runs sidebar
  // =========================================================================
  function refreshRuns(initial) {
    fetchJSON("/api/runs").then(function (data) {
      var runs = (data && data.runs) || [];
      state.runs = runs;
      renderRunList();
      if (initial || state.selectedId == null) {
        // Honor a deep link on load; otherwise default to the newest run.
        var routed = parseHash();
        if (routed.runId != null && findRun(routed.runId)) {
          state.route = routed;
          if (routed.runId !== state.selectedId) selectRun(routed.runId);
        } else if (runs.length) {
          navigate(runs[0].id);
        } else {
          showEmpty();
        }
      } else if (state.selectedId != null && !findRun(state.selectedId) && runs.length) {
        navigate(runs[0].id);
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
      if (c.followup) mini.appendChild(miniStat("followup", c.followup));
      mini.appendChild(miniStat("fail", c.failure));
      if (c.running) mini.appendChild(miniStat("run", c.running));
      bottom.appendChild(when);
      bottom.appendChild(mini);

      li.appendChild(top);
      li.appendChild(bottom);
      li.addEventListener("click", function () { navigate(run.id); });
      li.addEventListener("keydown", function (e) {
        if (e.key === "Enter" || e.key === " ") { e.preventDefault(); navigate(run.id); }
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
    // Checked before 'running': a parked run has no running jobs but is very
    // much still open, and the sidebar should say whose turn it is.
    if (run.status === "awaiting_interactive" || c.awaiting_interactive) return "awaiting";
    if (run.status === "running" || c.running) return "running";
    if (run.status === "completed") return "ok";
    if (run.status === "failed" || c.failure) return "fail";
    if (run.status === "needs_followup" || c.followup) return "followup";
    if (run.status === "cancelled") return "idle";
    return c.success ? "ok" : "idle";
  }
  function healthLabel(health, run) {
    if (health === "running") return "live";
    if (health === "awaiting") return "your turn";
    if (health === "followup") return "followup";
    if (health === "fail") return "fail";
    if (health === "ok") return "ok";
    return run.status || "idle";
  }

  // =========================================================================
  // Selection + live connection
  // =========================================================================
  function selectRun(id) {
    state.selectedId = id;
    state.detail = null;
    state.events = [];
    state.seenEventIds = {};
    state.maxEventId = 0;
    state.mountedEventsEl = null;
    state.prevStatus = null;
    state.expanded = {};
    state.foldOpen = false;
    state.logOpen = false;
    state.scrolledFid = null;
    state.fpSig = null;
    el.events.innerHTML = "";
    el.eventsDebrief.innerHTML = "";
    renderRunList();

    teardownLive();
    Promise.all([
      fetchJSON("/api/runs/" + id),
      fetchJSON("/api/runs/" + id + "/events?after=0")
    ]).then(function (res) {
      if (state.selectedId !== id) return;
      ingestDetail(res[0]);
      ingestEvents((res[1] && res[1].events) || []);
      renderCurrentView();
      connectLive(id);
    }).catch(function () {
      connectLive(id);
      renderCurrentView();
    });
  }

  function connectLive(id) {
    if (!window.EventSource) { startPolling(id); return; }
    setConn("init", "connecting");
    var es;
    try {
      es = new EventSource("/api/stream/" + id + "?after=" + lastEventId());
    } catch (e) { startPolling(id); return; }
    state.es = es;

    es.onopen = function () {
      if (state.selectedId !== id) return;
      setConn("live", "live · sse");
    };
    es.onmessage = function (ev) {
      if (state.selectedId !== id) return;
      var payload;
      try { payload = JSON.parse(ev.data); } catch (e) { return; }
      var touched = false;
      if (payload.run) {
        ingestDetail({
          run: payload.run, jobs: payload.jobs, counts: payload.counts,
          followups: payload.followups, followup_counts: payload.followup_counts,
          interactive_tasks: payload.interactive_tasks,
          interactive_counts: payload.interactive_counts,
          project_issues: payload.project_issues, top_issues: payload.top_issues
        });
        touched = true;
      }
      if (payload.events && payload.events.length) { ingestEvents(payload.events); touched = true; }
      if (touched) renderCurrentView();
    };
    es.onerror = function () {
      if (state.selectedId !== id) return;
      es.close(); state.es = null;
      var run = state.detail && state.detail.run;
      if (run && TERMINAL[run.status]) setConn("down", "closed");
      else startPolling(id);
    };
  }

  function startPolling(id) {
    if (state.pollTimer) return;
    setConn("polling", "polling");
    var tick = function () {
      if (state.selectedId !== id) return;
      Promise.all([
        fetchJSON("/api/runs/" + id),
        fetchJSON("/api/runs/" + id + "/events?after=" + lastEventId())
      ]).then(function (res) {
        if (state.selectedId !== id) return;
        if (res[0]) ingestDetail(res[0]);
        ingestEvents((res[1] && res[1].events) || []);
        renderCurrentView();
        var run = state.detail && state.detail.run;
        if (run && TERMINAL[run.status]) { stopPolling(); setConn("down", "closed"); }
      }).catch(function () {});
    };
    state.pollTimer = setInterval(tick, 1500);
    tick();
  }

  function stopPolling() { if (state.pollTimer) { clearInterval(state.pollTimer); state.pollTimer = null; } }
  function teardownLive() {
    if (state.es) { try { state.es.close(); } catch (e) {} state.es = null; }
    stopPolling();
  }
  function setConn(s, label) {
    el.conn.dataset.state = s;
    el.conn.querySelector(".conn-label").textContent = label;
  }

  // =========================================================================
  // Ingest (update state, no DOM)
  // =========================================================================
  function ingestDetail(detail) {
    if (!detail || !detail.run) return;
    var prev = state.detail;
    // The SSE payload carries followups only when something changed; fall back
    // to the previous set so a jobs-only update doesn't blank them.
    if (detail.followups == null && prev) detail.followups = prev.followups;
    if (detail.followup_counts == null && prev) detail.followup_counts = prev.followup_counts;
    // Same for the triage snapshot — and doubly so here, since an older server
    // never sends these keys at all and the section must not blink out.
    if (detail.project_issues == null && prev) detail.project_issues = prev.project_issues;
    if (detail.top_issues == null && prev) detail.top_issues = prev.top_issues;
    // Same again for the interactive queue: an older server never sends these
    // keys, and the bar must not blink out on a jobs-only update.
    if (detail.interactive_tasks == null && prev) detail.interactive_tasks = prev.interactive_tasks;
    if (detail.interactive_counts == null && prev) detail.interactive_counts = prev.interactive_counts;
    state.detail = detail;

    // keep sidebar row fresh
    var sidebarRun = findRun(detail.run.id);
    if (sidebarRun) {
      sidebarRun.status = detail.run.status;
      sidebarRun.stage = detail.run.stage;
      sidebarRun.counts = detail.counts;
      sidebarRun.finished_at = detail.run.finished_at;
      renderRunList();
    }
  }

  function ingestEvents(events) {
    if (!events || !events.length) return;
    events.forEach(function (ev) {
      if (state.seenEventIds[ev.id]) return;
      state.seenEventIds[ev.id] = 1;
      state.events.push(ev);
      if (ev.id > state.maxEventId) state.maxEventId = ev.id;
    });
  }
  // Cached — updated as events are ingested — so the SSE-connect and polling
  // paths don't rescan the whole event array each tick.
  function lastEventId() { return state.maxEventId; }

  // =========================================================================
  // View dispatch
  // =========================================================================
  function showEmpty() {
    el.emptyState.hidden = false;
    el.runView.hidden = true;
    el.followupsPage.hidden = true;
  }

  function renderCurrentView() {
    if (!state.detail || !state.detail.run) { return; }
    el.emptyState.hidden = true;

    if (state.route.view === "followups") {
      el.runView.hidden = true;
      el.followupsPage.hidden = false;
      state.mountedEventsEl = null;
      renderFollowupsPage(state.detail, state.route.fid);
      return;
    }

    el.followupsPage.hidden = true;
    el.runView.hidden = false;
    renderRun(state.detail);
  }

  function renderRun(detail) {
    var run = detail.run;
    // A parked run stays on the live face. It is not over — it is waiting on a
    // human — and this is the page where they click Start and watch the rest.
    var live = run.status === "running" || run.status === "awaiting_interactive";
    var face = live ? "live" : "debrief";
    var faceChanged = el.runView.dataset.face !== face;
    el.runView.dataset.face = face;

    renderHeader(detail, face);
    renderInteractiveBar(detail);

    if (face === "live") {
      renderLiveFace(detail);
      mountEvents(el.events, faceChanged);       // (re)mount live log on the left column
    } else {
      renderDebriefFace(detail, faceChanged);
      // debrief log is lazy — only mounted when the user expands it
      if (state.logOpen) mountEvents(el.eventsDebrief, faceChanged);
      else state.mountedEventsEl = null;
    }

    // one-time reveal when the agent finishes (running -> terminal/needs_followup).
    // Parking is not finishing, so it must not trigger the reveal.
    if (state.prevStatus === "running" && !live) {
      playDebriefReveal();
    }
    state.prevStatus = run.status;
  }

  // -- interactive queue ----------------------------------------------------
  //
  // The human-paced half of the run. Everything here is deliberately free of
  // timers and elapsed-time nagging: someone pausing to think, walking away, or
  // stopping to file a bug is a normal condition, and this UI must not suggest
  // otherwise.
  function renderInteractiveBar(detail) {
    var tasks = detail.interactive_tasks || [];
    if (!tasks.length) { el.ixBar.hidden = true; return; }
    el.ixBar.hidden = false;

    var open = tasks.filter(isIxOpen).length;
    el.ixHint.textContent = open
      ? open + " of " + tasks.length + " " + plural(tasks.length, "task") + " outstanding"
      : (tasks.length === 1 ? "done" : "all " + tasks.length + " tasks done");

    el.ixRows.innerHTML = tasks.map(function (t) {
      return ixRow(t, detail.run.id);
    }).join("");

    Array.prototype.forEach.call(
      el.ixRows.querySelectorAll("button[data-task]"),
      function (btn) {
        btn.addEventListener("click", onStartInteractive);
        // A render triggered by the next SSE tick (~1s) would otherwise re-enable
        // a button whose POST is still in flight, inviting a second click.
        if (state.ixPending[btn.getAttribute("data-task")]) {
          btn.disabled = true;
          btn.textContent = "starting…";
        }
      }
    );

    // An error survives re-renders until the next successful click; otherwise the
    // message is wiped by the following SSE tick and the user never reads it.
    el.ixFoot.textContent = state.ixError ? state.ixError : (open
      ? "Start one when you're ready. It runs alongside the automated work, at your pace — nothing here is on a clock."
      : "");
    el.ixFoot.dataset.tone = state.ixError ? "error" : "";
  }

  function isIxOpen(t) {
    return t.status === "discovered" || t.status === "requested" || t.status === "started";
  }

  function ixRow(t, runId) {
    var label = {
      discovered: "ready when you are",
      requested: "queued — the sweep starts it at its next check",
      started: "running — take your time",
      done: "done",
      abandoned: "left for another day"
    }[t.status] || t.status;

    // "Queued" is the state people ask about, because the app cannot launch
    // anything itself — it records the click and the sweep dispatches it. Say
    // where the delay comes from, so a wait reads as expected rather than broken.
    var tip = {
      requested: "Your click is recorded. The app has no way to launch work " +
        "itself, so the sweep picks this up on its next check — within seconds " +
        "if it is between projects, otherwise when the project it is currently " +
        "running finishes.",
      started: "Dispatched. Work it at your pace; nothing here times out.",
      abandoned: "Closed without finishing. The sweep recorded it as left for another day."
    }[t.status] || "";

    var action = t.status === "discovered"
      ? '<button class="ix-start" type="button" data-task="' + esc(t.id) +
        '" data-run="' + esc(runId) + '">Start</button>'
      : '<span class="ix-state" data-status="' + esc(t.status) + '"' +
        (tip ? ' title="' + esc(tip) + '"' : "") + ">" + esc(label) + "</span>";

    return '<div class="ix-row" data-status="' + esc(t.status) + '">' +
      '<span class="ix-project">' + esc(t.project_name) + "</span>" +
      '<span class="ix-title">' + esc(t.title) + "</span>" +
      (t.status === "discovered"
        ? '<span class="ix-state" data-status="discovered">' + esc(label) + "</span>"
        : "") +
      action +
      "</div>";
  }

  function onStartInteractive(ev) {
    var btn = ev.currentTarget;
    var taskId = btn.getAttribute("data-task");
    var runId = btn.getAttribute("data-run");
    // Optimistic disable only. The authoritative state comes back over SSE when
    // the server has actually recorded the request.
    state.ixPending[taskId] = 1;
    state.ixError = "";
    btn.disabled = true;
    btn.textContent = "starting…";
    fetch("/api/runs/" + encodeURIComponent(runId) +
          "/interactive/" + encodeURIComponent(taskId) + "/start", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{}"
    }).then(function (res) {
      if (!res.ok) throw new Error("HTTP " + res.status);
      return res.json();
    }).then(function (data) {
      delete state.ixPending[taskId];
      // Fold the server's answer straight in so the row updates now rather than
      // on the next SSE tick.
      if (data && data.task && state.detail) {
        var list = state.detail.interactive_tasks || [];
        for (var i = 0; i < list.length; i++) {
          if (String(list[i].id) === String(data.task.id)) { list[i] = data.task; break; }
        }
        renderInteractiveBar(state.detail);
      }
    }).catch(function () {
      delete state.ixPending[taskId];
      state.ixError = "Could not record that — the sweep database may be busy. Try again.";
      if (state.detail) renderInteractiveBar(state.detail);
    });
  }

  // -- shared header --------------------------------------------------------
  function renderHeader(detail, face) {
    var run = detail.run;
    el.rvTag.textContent = run.tag;
    el.rvStatus.dataset.status = run.status;
    el.rvStatus.textContent = statusLabel(run.status);
    el.rvMeta.textContent = "run #" + run.id +
      (run.mode ? "  ·  " + run.mode : "") +
      (run.options ? "  ·  " + compactOptions(run.options) : "");
    el.rvTime.dataset.start = run.finished_at ? "" : (run.started_at || "");
    el.rvTime.textContent = timeRange(run.started_at, run.finished_at);
    if (face === "live") renderStageRail(run.stage, run.status);
  }

  function statusLabel(status) {
    if (status === "needs_followup") return "needs followup";
    // Not "stalled", not "waiting too long" — the run is simply the human's turn.
    if (status === "awaiting_interactive") return "awaiting you";
    return status || "";
  }
  function compactOptions(opts) {
    try {
      var o = JSON.parse(opts), flags = [];
      Object.keys(o).forEach(function (k) {
        if (o[k] === true) flags.push("--" + k);
        else if (o[k] !== false && o[k] != null) flags.push("--" + k + " " + o[k]);
      });
      return flags.join(" ");
    } catch (e) { return ""; }
  }

  // -- stage rail (live) ----------------------------------------------------
  function buildStageRail() {
    el.stageRail.innerHTML = "";
    STAGES.forEach(function (s) {
      var li = document.createElement("li");
      li.className = "sr-step";
      li.dataset.stage = s.id;
      li.innerHTML = '<span class="sr-dot"></span><span>' + s.label + '</span>';
      el.stageRail.appendChild(li);
    });
  }
  function renderStageRail(stage, status) {
    var idx = stageIndex(stage);
    var finished = TERMINAL[status] || stage === "done";
    var current = finished ? STAGES.length - 1 : idx;
    var steps = el.stageRail.children;
    for (var i = 0; i < steps.length; i++) {
      steps[i].classList.remove("done", "current");
      if (finished) steps[i].classList.add("done");
      else if (i < current) steps[i].classList.add("done");
      else if (i === current) steps[i].classList.add("current");
    }
  }
  function stageIndex(stage) {
    for (var i = 0; i < STAGES.length; i++) if (STAGES[i].id === stage) return i;
    return 0;
  }

  // =========================================================================
  // LIVE FACE
  // =========================================================================
  function renderLiveFace(detail) {
    var jobs = detail.jobs || [];
    var counts = detail.counts || {};
    renderProgressRail(counts);
    renderNow(jobs);
    renderQueue(jobs);
    renderFollowupStrip(detail);
  }

  function renderProgressRail(counts) {
    var total = counts.total || 0;
    var done = total - (counts.pending || 0) - (counts.running || 0);
    var pct = total ? Math.round((done / total) * 100) : 0;
    el.prFill.style.width = pct + "%";

    var stats = document.createElement("span");
    stats.className = "pr-frac";
    stats.textContent = done + " / " + total + " done";
    el.prStats.innerHTML = "";
    el.prStats.appendChild(stats);
    el.prStats.appendChild(prStat("ok", counts.success));
    if (counts.followup) el.prStats.appendChild(prStat("followup", counts.followup));
    if (counts.failure) el.prStats.appendChild(prStat("fail", counts.failure));
    if (counts.skipped) el.prStats.appendChild(prStat("skip", counts.skipped, "–"));
  }
  function prStat(kind, n, glyph) {
    var s = document.createElement("span");
    s.className = "pr-stat";
    var dot = document.createElement("span");
    dot.className = "ri-dot " + (kind === "skip" ? "" : kind);
    if (kind === "skip") dot.style.background = "var(--skip)";
    s.appendChild(dot);
    s.appendChild(document.createTextNode(String(n || 0)));
    return s;
  }

  function renderNow(jobs) {
    var running = jobs.filter(function (j) { return j.status === "running"; });
    el.nowHint.textContent = running.length ? running.length + " active" : "";
    if (!running.length) {
      el.now.innerHTML = '<div class="now-idle">Between projects — waiting for the next one to start…</div>';
      return;
    }
    el.now.innerHTML = "";
    running.forEach(function (job) {
      var latest = latestEventFor(job.id);
      var card = document.createElement("div");
      card.className = "now-card";
      var html =
        '<div class="now-top">' +
          '<span class="now-spin" aria-hidden="true"></span>' +
          '<span class="now-name">' + esc(job.project_name || job.project_path) + '</span>' +
          '<span class="now-elapsed" data-start="' + esc(job.started_at || "") + '">' +
            esc(elapsedLabel(job.started_at)) + '</span>' +
        '</div>';
      if (job.skill_name) html += '<div class="now-skill">' + esc(job.skill_name) + '</div>';
      if (latest) {
        html += '<div class="now-latest"><span class="nl-caret">›</span>' +
                '<span class="nl-msg"></span></div>';
      }
      card.innerHTML = html;
      if (latest) card.querySelector(".nl-msg").textContent = latest.message || "";
      el.now.appendChild(card);
    });
  }

  function latestEventFor(jobId) {
    for (var i = state.events.length - 1; i >= 0; i--) {
      if (state.events[i].job_id === jobId) return state.events[i];
    }
    return state.events.length ? state.events[state.events.length - 1] : null;
  }

  function renderQueue(jobs) {
    el.queueHint.textContent = jobs.length ? jobs.length + " projects" : "";
    var sorted = jobs.slice().sort(function (a, b) {
      var pa = STATUS_PRIORITY[a.status], pb = STATUS_PRIORITY[b.status];
      if (pa == null) pa = 9; if (pb == null) pb = 9;
      if (pa !== pb) return pa - pb;
      return a.id - b.id;
    });
    var html = "";
    sorted.forEach(function (j) {
      html += '<span class="chip" data-s="' + esc(j.status) + '" title="' +
        esc((j.project_name || "") + " — " + j.status) + '">' +
        '<span class="chip-glyph">' + (CHIP_GLYPH[j.status] || "○") + '</span>' +
        '<span class="chip-name">' + esc(j.project_name || j.project_path) + '</span>' +
        '</span>';
    });
    el.queue.innerHTML = html || '<span class="muted">No projects discovered yet.</span>';
  }

  function renderFollowupStrip(detail) {
    var fups = detail.followups || [];
    var open = countOpen(fups);
    if (!fups.length) { el.followupStrip.hidden = true; return; }
    el.followupStrip.hidden = false;
    el.followupStrip.href = "#/run/" + detail.run.id + "/followups";
    var n = open || fups.length;
    var word = (n === 1 ? "followup" : "followups");
    el.fsLabel.innerHTML = "<b>" + n + "</b> " + word +
      (open ? " queued for later" : " — all resolved");
  }

  // =========================================================================
  // DEBRIEF FACE
  // =========================================================================
  function renderDebriefFace(detail, faceChanged) {
    renderStoplight(detail.counts || {}, faceChanged);
    renderDebriefFollowups(detail, faceChanged);
    renderTriage(detail, faceChanged);
    renderSummary(detail.run.summary);
    renderResults(detail.jobs || []);
    renderLogToggle();
  }

  function renderStoplight(counts, reveal) {
    var lamps = [
      { k: "success",  n: counts.success  || 0, label: "success" },
      { k: "followup", n: counts.followup || 0, label: "followup" },
      { k: "failure",  n: counts.failure  || 0, label: "failure" },
      { k: "skipped",  n: counts.skipped  || 0, label: "skipped" }
    ];
    var html = "";
    lamps.forEach(function (l, i) {
      html += '<div class="lamp' + (l.n ? " lit" : "") + (reveal ? " reveal" : "") +
              '" data-k="' + l.k + '"' +
              (reveal ? ' style="animation-delay:' + (i * 90) + 'ms"' : "") + '>' +
        '<span class="lamp-orb" aria-hidden="true"></span>' +
        '<span class="lamp-text">' +
          '<span class="lamp-n">' + l.n + '</span>' +
          '<span class="lamp-label">' + l.label + '</span>' +
        '</span></div>';
    });
    el.stoplight.innerHTML = html;
  }

  function renderDebriefFollowups(detail, reveal) {
    var fups = detail.followups || [];
    if (!fups.length) { el.dbFollowups.hidden = true; return; }
    el.dbFollowups.hidden = false;
    if (reveal) { el.dbFollowups.classList.remove("reveal"); void el.dbFollowups.offsetWidth; el.dbFollowups.classList.add("reveal"); }
    el.dbFollowupsLink.href = "#/run/" + detail.run.id + "/followups";

    var open = 0, closed = 0, rows = "";
    fups.forEach(function (f) {
      var st = f.status || "open";
      if (st === "open") open++; else closed++;
      var lc = f.last_comment, latest = "";
      if (lc) {
        var verb = lc.action && lc.action !== "opened" ? lc.action + ": " : "";
        latest = esc(verb) + esc(lc.comment || "");
      }
      // One line per ticket. The detail text and the comment timeline stay on
      // the followups page — the # deep-links straight to the ticket there, and
      // the clamped cells keep their full text in a title tooltip.
      rows += '<tr class="tk-row' + (st !== "open" ? " is-closed" : "") + '">' +
        '<td class="tk-num"><a href="#/run/' + esc(detail.run.id) + '/followup/' + esc(f.id) +
          '" title="open ticket #' + esc(f.id) + ' with its full detail">#' + esc(f.id) + '</a></td>' +
        '<td class="tk-proj" title="' + esc(f.project_name || "") + '">' +
          esc(f.project_name || "—") + '</td>' +
        '<td class="tk-title" title="' + esc(f.title || "") +
          (f.detail ? esc(" — " + f.detail) : "") + '">' +
          '<span class="clamp2">' + esc(f.title || "") + '</span></td>' +
        '<td class="tk-stat"><span class="tk-status" data-s="' + esc(st) + '">' +
          esc(TICKET_STATUS_LABEL[st] || st) + '</span></td>' +
        '<td class="tk-latest"' + (lc ? ' title="' + esc(lc.comment || "") + '"' : "") + '>' +
          '<span class="clamp2">' + (latest || '<span class="muted">—</span>') + '</span></td>' +
        '</tr>';
    });
    el.dbFollowupsBody.innerHTML = rows;
    if (open) {
      el.dbFollowupsFoot.innerHTML =
        'Resolve a ticket with <code>/zed:maint-followup &lt;#&gt; done|nope|update [comment]</code>' +
        ' — when the last open ticket closes, this run flips to <strong>completed</strong>.';
    } else {
      el.dbFollowupsFoot.innerHTML = 'All followups resolved. This run is <strong>completed</strong>.';
    }
  }

  // -- GitHub work surfaced by the run --------------------------------------
  // Two populations share this section, told apart by `origin`:
  //   created — issues the run opened itself under the punt/issue/ticket
  //             disposition. Any tag can produce these; they get their own
  //             board at the top and a NEW badge everywhere they appear,
  //             because otherwise the only trace of them is a line of prose in
  //             a summary nobody re-reads.
  //   triage  — open work a weekly sweep noticed and did not touch.
  // Empty `project_issues` hides the whole section, so a run that neither
  // triaged nor filed anything shows nothing at all.
  function renderTriage(detail, reveal) {
    var items = detail.project_issues || [];
    if (!items.length) {
      el.dbTriage.hidden = true;
      el.gtNew.innerHTML = el.gtTop.innerHTML = el.gtGroups.innerHTML = "";
      return;
    }
    el.dbTriage.hidden = false;
    if (reveal) { el.dbTriage.classList.remove("reveal"); void el.dbTriage.offsetWidth; el.dbTriage.classList.add("reveal"); }

    var created = items.filter(isCreated);
    var triaged = items.filter(function (it) { return !isCreated(it); });

    el.triageTitle.textContent = triaged.length ? "GITHUB TRIAGE" : "GITHUB ISSUES FILED";
    el.triageHint.textContent =
      (created.length ? created.length + " new  ·  " : "") +
      items.length + plural(items.length, " item");
    el.gtNote.innerHTML = triageNote(created.length, triaged.length);

    // Board 1 — what the run filed. Ordinal-less (there are only ever a few)
    // but project-labelled, since it spans every project in the run.
    // Each board is emptied when hidden, not just hidden: selecting a run with
    // no triage after one that had it would otherwise leave the previous run's
    // rows parked in the DOM, ready to reappear on any later un-hide.
    el.gtNewBoard.hidden = !created.length;
    if (created.length) {
      el.gtNewHint.textContent = created.length + plural(created.length, " issue") + " opened by this run";
      el.gtNew.innerHTML = created.map(function (it) { return triageRow(it, 0, true); }).join("");
    } else {
      el.gtNew.innerHTML = "";
    }

    // Board 2 — the pre-existing backlog, ranked. Deliberately excludes the
    // created rows: they are already sitting in their own board directly above,
    // and listing them twice on one screen reads as noise rather than emphasis.
    // Derived from project_issues (the full set) rather than the server's
    // top_issues, which is capped at 10 *before* the split and would otherwise
    // yield fewer than 10 backlog rows.
    el.gtTopBoard.hidden = !triaged.length;
    if (triaged.length) {
      el.gtTop.innerHTML = triaged.slice(0, 10).map(function (it, i) {
        return triageRow(it, i + 1);
      }).join("");
    } else {
      el.gtTop.innerHTML = "";
    }

    // Board 3 — per project, everything, created rows included and badged.
    // Rows arrive already ordered, so grouping in arrival order puts the project
    // holding the most deserving item first. That is deliberately *not* the
    // PROJECT RESULTS order (which partitions attention-first by job status) —
    // the two sections are cross-referenced by project name, not by position.
    el.gtBy.hidden = !triaged.length;
    if (!triaged.length) { el.gtGroups.innerHTML = ""; return; }

    var order = [], byProject = {};
    items.forEach(function (it) {
      var name = it.project_name || "—";
      if (!byProject[name]) { byProject[name] = []; order.push(name); }
      byProject[name].push(it);
    });
    el.gtGroupsHint.textContent = order.length + plural(order.length, " project") + "  ·  up to 5 each";

    var groups = "";
    order.forEach(function (name) {
      var rows = byProject[name].slice(0, 5);
      var prs = 0, news = 0;
      rows.forEach(function (r) {
        if (r.kind === "pr") prs++;
        if (isCreated(r)) news++;
      });
      var meta = [];
      if (news) meta.push(news + " new");
      if (prs) meta.push(prs + plural(prs, " pr"));
      if (rows.length - prs) meta.push((rows.length - prs) + plural(rows.length - prs, " issue"));
      groups += '<div class="gt-group">' +
        '<div class="gt-group-head">' +
          '<span class="gt-group-name">' + esc(name) + '</span>' +
          '<span class="gt-group-meta">' + esc(meta.join("  ·  ")) + '</span>' +
        '</div>' +
        '<div class="gt-rows">';
      rows.forEach(function (it) { groups += triageRow(it, 0); });
      groups += '</div></div>';
    });
    el.gtGroups.innerHTML = groups;
  }

  function isCreated(it) { return it && it.origin === "created"; }

  // The section means different things depending on which populations are in
  // it, so the standfirst says which one the reader is looking at. When both are
  // present they get a line each — run together in one paragraph the second
  // sentence reads as if it were still describing the filed issues.
  function triageNote(nCreated, nTriaged) {
    var filed = "<b>" + nCreated + " issue" + (nCreated === 1 ? "" : "s") +
      "</b> filed by this maintenance run — work it <em>created</em> for you.";
    var noticed = "Open issues and pending PRs this weekly sweep noticed and did " +
      "<em>not</em> touch. Scan, pick what deserves your time, open it on GitHub.";
    var locate = " Grouped by project — find the same project by name in " +
      "<strong>PROJECT RESULTS</strong> below.";

    if (!nTriaged) {
      // Number-agnostic: this branch renders for a run that filed one issue and
      // for a run that filed six, so the copy must not presume either.
      return '<span class="gt-line is-new">' + filed +
        " Each row names the project it belongs to and opens on GitHub for the" +
        " full detail." + "</span>";
    }
    if (!nCreated) return '<span class="gt-line">' + noticed + locate + "</span>";
    return '<span class="gt-line is-new">' + filed + "</span>" +
           '<span class="gt-line">' + noticed + locate + "</span>";
  }

  // One triage row. `ordinal` > 0 renders the ranked top-10 variant (position +
  // project column); 0 renders the compact per-project variant. `withProject`
  // forces the project label on for a board that spans projects without being
  // ranked (FILED BY THIS RUN). The whole row is the link — these boards exist
  // to be jumped from, so the target is generous.
  function triageRow(it, ordinal, withProject) {
    var kind = it.kind === "pr" ? "pr" : "issue";
    var draft = String(it.state || "").toLowerCase() === "draft";
    var isNew = isCreated(it);
    var href = safeHref(it.url);
    var age = ageBand(it.age_days);
    var showProject = withProject || !!ordinal;
    var tip = (it.repo ? it.repo + " " : "") + "#" + it.number +
      (it.author ? "  ·  by " + it.author : "") +
      (it.labels ? "  ·  " + it.labels : "") +
      "\n" + (it.title || "") +
      (it.triage ? "\n" + it.triage : "") +
      (isNew ? "\nOpened by this maintenance run." : "") +
      (href ? "" : "\nno https url recorded — nothing to open");

    var inner = "";
    if (ordinal) inner += '<span class="gt-ord">' + pad(ordinal) + '</span>';
    inner +=
      '<span class="gt-kind">' +
        '<span class="gt-glyph" aria-hidden="true">' + KIND_GLYPH[kind] + '</span>' +
        '<span class="gt-num">#' + esc(it.number) + '</span>' +
      '</span>';
    if (showProject) inner += '<span class="gt-proj">' + esc(it.project_name || "—") + '</span>';
    inner +=
      '<span class="gt-body">' +
        '<span class="gt-title">' +
          // NEW before DRAFT: "this run made it" outranks "its author parked it".
          (isNew ? '<span class="gt-flag is-new">NEW</span>' : "") +
          (draft ? '<span class="gt-flag">draft</span>' : "") + esc(it.title || "") +
        '</span>' +
        '<span class="gt-triage">' + esc(it.triage || "") + '</span>' +
      '</span>' +
      '<span class="gt-age" data-age="' + age.band + '">' + esc(age.label) + '</span>' +
      // ↗ says "leaves the deck"; ⊘ says "the recorded url wasn't https, so
      // there is deliberately nothing to click here".
      '<span class="gt-open" aria-hidden="true">' + (href ? "↗" : "⊘") + '</span>';

    var attrs = ' data-kind="' + kind + '" data-tier="' + rankTier(it.rank) + '"' +
      (draft ? ' data-draft="1"' : "") + (isNew ? ' data-new="1"' : "") +
      ' title="' + esc(tip) + '"';
    if (!href) return '<div class="gt-row is-nolink"' + attrs + '>' + inner + '</div>';
    return '<a class="gt-row" href="' + href + '" target="_blank" rel="noopener noreferrer"' +
      attrs + ' aria-label="' + esc((isNew ? "newly filed " : "") +
      (kind === "pr" ? "pull request #" : "issue #") + it.number +
      " · " + (it.title || "") + " · opens on GitHub") + '">' + inner + '</a>';
  }

  // Only ever emit an https:// href. Anything else — a javascript: URL, a
  // relative path, junk from a bad triage run — loses the link and renders as
  // plain text. escHtml() so the value is safe inside href="…" as well.
  function safeHref(url) {
    var s = String(url == null ? "" : url);
    return /^https:\/\//i.test(s) ? escHtml(s) : null;
  }

  // rank is 0..100 with LOWER = more deserving; four bands drive the row rail.
  // A missing rank lands mid-pack rather than at the top — Number(null) is 0,
  // and an unranked row must not masquerade as the most urgent thing on screen.
  function rankTier(rank) {
    if (rank == null) return 2;
    var r = Number(rank);
    if (!isFinite(r)) return 2;
    if (r < 20) return 0;
    if (r < 50) return 1;
    if (r < 80) return 2;
    return 3;
  }

  // Age is the staleness signal — something open for four months should look
  // different from something opened on Tuesday.
  function ageBand(days) {
    if (days == null) return { label: "—", band: "fresh" };
    var d = Number(days);
    if (!isFinite(d) || d < 0) return { label: "—", band: "fresh" };
    return {
      label: d < 100 ? d + "d" : Math.round(d / 30) + "mo",
      band: d >= 90 ? "stale" : d >= 30 ? "aging" : "fresh"
    };
  }

  function plural(n, word) { return n === 1 ? word : word + "s"; }

  function renderSummary(md) {
    if (!md) { el.summary.innerHTML = '<p class="muted">No summary recorded for this run.</p>'; return; }
    el.summary.innerHTML = renderMarkdown(md);
  }

  function renderResults(jobs) {
    var attention = [], clean = [];
    jobs.forEach(function (j) {
      if (j.status === "failure" || j.status === "followup") attention.push(j);
      else clean.push(j);
    });
    attention.sort(function (a, b) {
      var pa = a.status === "failure" ? 0 : 1, pb = b.status === "failure" ? 0 : 1;
      if (pa !== pb) return pa - pb;
      return a.id - b.id;
    });

    var okN = clean.filter(function (j) { return j.status === "success"; }).length;
    var skN = clean.filter(function (j) { return j.status === "skipped"; }).length;
    el.resultsHint.textContent =
      (attention.length ? attention.length + " need attention · " : "") +
      clean.length + " clean";

    el.results.innerHTML = "";
    attention.forEach(function (j) { el.results.appendChild(resultCard(j, true)); });

    if (clean.length) {
      var fold = document.createElement("button");
      fold.className = "result-fold";
      fold.setAttribute("aria-expanded", state.foldOpen ? "true" : "false");
      fold.innerHTML =
        '<span class="rf-caret">' + (state.foldOpen ? "▾" : "▸") + '</span>' +
        '<span class="rf-dot"></span>' +
        '<span>' + clean.length + ' clean project' + (clean.length === 1 ? "" : "s") +
        '  ·  ' + okN + ' ok, ' + skN + ' skipped</span>';
      el.results.appendChild(fold);

      var wrap = document.createElement("div");
      wrap.className = "results";
      wrap.style.marginTop = "8px";
      wrap.hidden = !state.foldOpen;
      clean.slice().sort(function (a, b) { return a.id - b.id; })
        .forEach(function (j) { wrap.appendChild(resultCard(j, false)); });
      el.results.appendChild(wrap);

      fold.addEventListener("click", function () {
        state.foldOpen = !state.foldOpen;
        wrap.hidden = !state.foldOpen;
        fold.setAttribute("aria-expanded", state.foldOpen ? "true" : "false");
        fold.querySelector(".rf-caret").textContent = state.foldOpen ? "▾" : "▸";
      });
    }
  }

  function resultCard(job, expandByDefault) {
    var node = document.createElement("div");
    node.className = "result";
    node.dataset.status = job.status;
    var html =
      '<div class="result-top">' +
        '<span class="result-name">' + esc(job.project_name || job.project_path) + '</span>' +
        '<span class="result-state" data-s="' + esc(job.status) + '">' + esc(job.status) + '</span>' +
      '</div>';
    node.innerHTML = html;

    var hasError = job.status === "failure" && job.error;
    var hasSummary = !!job.summary;
    if (hasError || hasSummary) {
      var detail = document.createElement("div");
      detail.className = "result-detail";
      if (hasError) {
        var er = document.createElement("div");
        er.className = "result-error";
        er.textContent = job.error;
        detail.appendChild(er);
      }
      if (hasSummary) {
        var open = state.expanded[job.id] != null ? state.expanded[job.id] : expandByDefault;
        var sum = document.createElement("div");
        sum.className = "result-summary md";
        sum.innerHTML = renderMarkdown(job.summary);
        sum.style.display = open ? "" : "none";
        var toggle = document.createElement("button");
        toggle.className = "result-toggle";
        toggle.textContent = open ? "▾ hide summary" : "▸ show summary";
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
    return node;
  }

  function renderLogToggle() {
    el.logCount.textContent = state.events.length ? state.events.length + " events" : "";
    el.logToggle.setAttribute("aria-expanded", state.logOpen ? "true" : "false");
    el.eventsDebrief.hidden = !state.logOpen;
    el.logToggle.querySelector(".lt-caret").textContent = "▸";
  }

  // =========================================================================
  // FOLLOWUPS PAGE
  // =========================================================================
  function renderFollowupsPage(detail, fid) {
    var run = detail.run;
    var fups = detail.followups || [];

    // Only rebuild when something actually changed. Skipping no-op renders keeps
    // an SSE update (or the initial prime) from wiping the list and resetting the
    // reader's scroll position — including a just-applied deep-link scroll.
    var sig = run.status + "#" + fups.map(function (f) {
      return f.id + ":" + (f.status || "open") + ":" + (f.updated_at || "") +
        ":" + ((f.comments || []).length);
    }).join("|");
    if (sig !== state.fpSig) {
      state.fpSig = sig;
      el.fpBack.href = "#/run/" + run.id;
      el.fpRunStatus.dataset.status = run.status;
      el.fpRunStatus.textContent = statusLabel(run.status);
      el.fpTitle.textContent = run.tag + " — followups";

      var open = countOpen(fups), closed = fups.length - open;
      el.fpSub.textContent = fups.length
        ? (open + " open" + (closed ? "  ·  " + closed + " closed" : ""))
        : "none for this run";

      if (!fups.length) {
        el.fpList.innerHTML = '<p class="muted">This run surfaced no followups.</p>';
        el.fpHelp.textContent = "";
      } else {
        el.fpList.innerHTML = "";
        fups.forEach(function (f) { el.fpList.appendChild(ticketCard(f)); });
        if (open) {
          el.fpHelp.innerHTML = "Work a ticket from your shell: " +
            "<code>/zed:maint-followup &lt;#&gt; update|done|nope [comment]</code>. " +
            "When the last open ticket closes, this run graduates to completed.";
        } else {
          el.fpHelp.textContent = "All followups for this run are resolved.";
        }
      }
    }

    // Auto-scroll to a deep-linked ticket once per navigation.
    if (fid && state.scrolledFid !== fid) {
      state.scrolledFid = fid;
      scrollToTicket(fid);
    }
  }

  function ticketCard(f) {
    var st = f.status || "open";
    var node = document.createElement("div");
    node.className = "ticket" + (st !== "open" ? " is-closed" : "");
    node.id = "ticket-" + f.id;

    var html =
      '<div class="ticket-top">' +
        '<span class="ticket-num">#' + esc(f.id) + '</span>' +
        '<span class="ticket-proj">' + esc(f.project_name || "—") + '</span>' +
        '<span class="tk-status" data-s="' + esc(st) + '">' +
          esc(TICKET_STATUS_LABEL[st] || st) + '</span>' +
      '</div>' +
      '<h3 class="ticket-title">' + esc(f.title || "") + '</h3>';
    if (f.detail) html += '<p class="ticket-detail">' + esc(f.detail) + '</p>';
    node.innerHTML = html;

    var comments = f.comments || [];
    if (comments.length) {
      var tl = document.createElement("ol");
      tl.className = "ticket-timeline";
      comments.forEach(function (c) {
        var li = document.createElement("li");
        li.className = "tl-item";
        li.dataset.action = c.action || "update";
        li.innerHTML =
          '<span class="tl-ts">' + esc(clockTime(c.ts)) + '</span>' +
          '<span class="tl-action">' + esc(ACTION_LABEL[c.action] || c.action || "note") + '</span>' +
          '<span class="tl-comment"></span>';
        li.querySelector(".tl-comment").textContent = c.comment || "";
        tl.appendChild(li);
      });
      node.appendChild(tl);
    }
    if (st === "open") {
      var res = document.createElement("div");
      res.className = "ticket-resolve";
      res.innerHTML = "resolve: <code>/zed:maint-followup " + esc(f.id) + " done|nope|update [comment]</code>";
      node.appendChild(res);
    }
    return node;
  }

  function scrollToTicket(fid) {
    // Defer to the next frame so the freshly-rendered list is laid out and any
    // competing render from the same tick has settled before we scroll.
    requestAnimationFrame(function () {
      var node = byId("ticket-" + fid);
      if (!node || !node.scrollIntoView) return;
      // Honor prefers-reduced-motion: JS-driven smooth scroll isn't covered by
      // the CSS media guard, so jump instantly for those users. (The highlight's
      // transition is neutralized by the reduced-motion CSS rule.)
      var reduce = reducedMotion();
      node.scrollIntoView({ behavior: reduce ? "auto" : "smooth", block: "center" });
      if (!reduce) node.style.transition = "box-shadow 0.4s";
      node.style.boxShadow = "0 0 0 2px rgba(192,132,252,0.5)";
      setTimeout(function () { node.style.boxShadow = ""; }, 1400);
    });
  }

  function reducedMotion() {
    return !!(window.matchMedia &&
      window.matchMedia("(prefers-reduced-motion: reduce)").matches);
  }

  function countOpen(fups) {
    var n = 0;
    (fups || []).forEach(function (f) { if ((f.status || "open") === "open") n++; });
    return n;
  }

  // =========================================================================
  // Events rendering (shared between live log and debrief log)
  // =========================================================================
  // Mount the full event list into `target`. No-op if already mounted there
  // (so steady-state updates only append instead of re-rendering).
  function mountEvents(target, force) {
    if (state.mountedEventsEl === target && !force) return;
    state.mountedEventsEl = target;
    target.innerHTML = "";
    if (!state.events.length) {
      target.innerHTML = '<li class="events-empty">No activity yet.</li>';
      return;
    }
    var frag = document.createDocumentFragment();
    state.events.forEach(function (ev) { frag.appendChild(buildEvent(ev, false)); });
    target.appendChild(frag);
    target.scrollTop = target.scrollHeight;
  }

  // Called from ingest path via renderCurrentView; append only the new tail.
  function appendNewEvents(newlyAdded) {
    var target = state.mountedEventsEl;
    if (!target || !newlyAdded.length) return;
    var empty = target.querySelector(".events-empty");
    if (empty) empty.remove();
    var frag = document.createDocumentFragment();
    newlyAdded.forEach(function (ev) { frag.appendChild(buildEvent(ev, true)); });
    target.appendChild(frag);
    target.scrollTop = target.scrollHeight;
  }

  function buildEvent(ev, animate) {
    var li = document.createElement("li");
    li.className = "event" + (animate ? " enter" : "");
    li.dataset.level = ev.level || "info";
    var glyph = LEVEL_GLYPH[ev.level] || LEVEL_GLYPH.info;
    li.innerHTML =
      '<span class="ev-ts">' + esc(clockTime(ev.ts)) + '</span>' +
      '<span class="ev-glyph">' + esc(glyph) + '</span>' +
      '<span class="ev-msg"></span>';
    li.querySelector(".ev-msg").textContent = ev.message || "";
    return li;
  }

  // Wrap ingestEvents so the mounted list gets incremental appends. We diff by
  // tracking how many events existed before the ingest.
  var _ingestEvents = ingestEvents;
  ingestEvents = function (events) {
    var before = state.events.length;
    _ingestEvents(events);
    var added = state.events.slice(before);
    if (added.length && state.mountedEventsEl) appendNewEvents(added);
    if (el.eventsHint) el.eventsHint.textContent = state.events.length + " events";
  };

  // =========================================================================
  // Transition reveal
  // =========================================================================
  function playDebriefReveal() {
    // The stoplight + followups already render with the `reveal` class on the
    // first debrief paint after the switch; nothing else to orchestrate here.
    // (Kept as a hook so future run-complete effects have a home.)
  }

  // =========================================================================
  // Minimal Markdown renderer
  //   Supports: # / ## / ### headings, - and * and 1. lists, ``` code fences,
  //   `inline code`, **bold**, *em*/_em_, [text](url), --- rule, GFM tables.
  //   Everything is HTML-escaped first; only our own tags are injected.
  // =========================================================================
  function renderMarkdown(src) {
    if (!src) return "";
    var lines = String(src).replace(/\r\n?/g, "\n").split("\n");
    var out = [], i = 0, listType = null;
    function closeList() { if (listType) { out.push("</" + listType + ">"); listType = null; } }

    while (i < lines.length) {
      var line = lines[i];
      var fence = line.match(/^```\s*(\S*)\s*$/);
      if (fence) {
        closeList(); var buf = []; i++;
        while (i < lines.length && !/^```\s*$/.test(lines[i])) { buf.push(lines[i]); i++; }
        i++;
        out.push("<pre><code>" + escHtml(buf.join("\n")) + "</code></pre>");
        continue;
      }
      if (line.indexOf("|") !== -1 && i + 1 < lines.length &&
          /\|/.test(lines[i + 1]) &&
          /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$/.test(lines[i + 1])) {
        closeList();
        var header = splitRow(line);
        var aligns = splitRow(lines[i + 1]).map(function (c) {
          var l = /^:/.test(c), r = /:$/.test(c);
          return (l && r) ? "center" : r ? "right" : l ? "left" : "";
        });
        i += 2; var rows = [];
        while (i < lines.length && lines[i].indexOf("|") !== -1 && !/^\s*$/.test(lines[i])) {
          rows.push(splitRow(lines[i])); i++;
        }
        out.push(buildTable(header, aligns, rows));
        continue;
      }
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { closeList(); out.push("<hr>"); i++; continue; }
      var h = line.match(/^(#{1,3})\s+(.*)$/);
      if (h) { closeList(); out.push("<h" + h[1].length + ">" + inline(h[2]) + "</h" + h[1].length + ">"); i++; continue; }
      var ul = line.match(/^\s*[-*+]\s+(.*)$/);
      if (ul) { if (listType !== "ul") { closeList(); out.push("<ul>"); listType = "ul"; } out.push("<li>" + inline(ul[1]) + "</li>"); i++; continue; }
      var ol = line.match(/^\s*\d+[.)]\s+(.*)$/);
      if (ol) { if (listType !== "ol") { closeList(); out.push("<ol>"); listType = "ol"; } out.push("<li>" + inline(ol[1]) + "</li>"); i++; continue; }
      if (/^\s*$/.test(line)) { closeList(); i++; continue; }
      closeList();
      var para = [line]; i++;
      while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^```/.test(lines[i]) &&
             !/^(#{1,3})\s+/.test(lines[i]) && !/^\s*[-*+]\s+/.test(lines[i]) &&
             !/^\s*\d+[.)]\s+/.test(lines[i]) && !/^\s*([-*_])(\s*\1){2,}\s*$/.test(lines[i])) {
        para.push(lines[i]); i++;
      }
      out.push("<p>" + inline(para.join(" ")) + "</p>");
    }
    closeList();
    return out.join("");
  }

  function splitRow(row) {
    var s = row.trim().replace(/^\|/, "").replace(/\|$/, "");
    s = s.replace(/\\\|/g, "");
    return s.split("|").map(function (c) { return c.replace(//g, "|").trim(); });
  }
  function alignAttr(a) { return a ? ' style="text-align:' + a + '"' : ""; }
  function buildTable(header, aligns, rows) {
    var h = "<thead><tr>";
    header.forEach(function (c, idx) { h += "<th" + alignAttr(aligns[idx]) + ">" + inline(c) + "</th>"; });
    h += "</tr></thead><tbody>";
    rows.forEach(function (r) {
      h += "<tr>";
      for (var idx = 0; idx < header.length; idx++) h += "<td" + alignAttr(aligns[idx]) + ">" + inline(r[idx] != null ? r[idx] : "") + "</td>";
      h += "</tr>";
    });
    h += "</tbody>";
    return '<table class="md-table">' + h + "</table>";
  }
  function inline(text) {
    var s = escHtml(text), codes = [];
    // Protect inline code with a private-use sentinel (U+F8FF) that cannot occur
    // in normal text, so restoration can't be triggered by user content and no
    // stray whitespace is injected around the code span.
    s = s.replace(/`([^`]+)`/g, function (_, c) { codes.push(c); return "" + (codes.length - 1) + ""; });
    s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
    s = s.replace(/(^|[^*])\*([^*\n]+)\*/g, "$1<em>$2</em>");
    s = s.replace(/(^|[^_])_([^_\n]+)_/g, "$1<em>$2</em>");
    s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, function (_, txt, url) {
      if (!/^(https?:|mailto:|\/|#)/i.test(url)) return txt;
      var safeUrl = url.replace(/"/g, "%22").replace(/'/g, "%27");
      return '<a href="' + safeUrl + '" target="_blank" rel="noopener noreferrer">' + txt + '</a>';
    });
    s = s.replace(/(\d+)/g, function (_, n) { return "<code>" + codes[+n] + "</code>"; });
    return s;
  }
  // Escapes for both text and attribute contexts: quotes are encoded too, so
  // interpolating esc() inside `attr="..."` (chip titles, data-*, etc.) can't
  // break out of the attribute. Many call sites rely on this.
  function escHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
  }
  function esc(s) { return escHtml(s == null ? "" : s); }

  // =========================================================================
  // Time helpers
  // =========================================================================
  function startClock() {
    var tick = function () {
      var d = new Date();
      el.clock.textContent = pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
      updateElapsed();
    };
    tick(); setInterval(tick, 1000);
  }
  function pad(n) { return (n < 10 ? "0" : "") + n; }

  // Re-tick any live elapsed labels (header running time + NOW cards).
  function updateElapsed() {
    if (el.rvTime.dataset.start) el.rvTime.textContent = "started " + relTime(el.rvTime.dataset.start);
    var cards = el.now.querySelectorAll(".now-elapsed[data-start]");
    for (var i = 0; i < cards.length; i++) {
      if (cards[i].dataset.start) cards[i].textContent = elapsedLabel(cards[i].dataset.start);
    }
  }

  function parseTs(ts) {
    if (!ts) return null;
    var d = new Date(ts);
    return isNaN(d.getTime()) ? null : d;
  }
  function clockTime(ts) {
    var d = parseTs(ts);
    if (!d) return "--:--:--";
    return pad(d.getHours()) + ":" + pad(d.getMinutes()) + ":" + pad(d.getSeconds());
  }
  function elapsedLabel(start) {
    var d = parseTs(start);
    if (!d) return "";
    var sec = Math.max(0, Math.floor((Date.now() - d.getTime()) / 1000));
    var m = Math.floor(sec / 60), s = sec % 60;
    if (m < 60) return pad(m) + ":" + pad(s);
    var hh = Math.floor(m / 60); m = m % 60;
    return hh + "h " + pad(m) + "m";
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
    var end = parseTs(finish);
    if (end) {
      var dur = Math.max(0, Math.round((end.getTime() - s.getTime()) / 1000));
      return "ran " + fmtDur(dur);
    }
    return "started " + relTime(start);
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
      .then(function (r) { if (!r.ok) throw new Error("http " + r.status); return r.json(); });
  }
})();
