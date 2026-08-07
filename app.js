// kojira — history & projects timeline

const LANG_COLORS = {
  JavaScript: "#f1e05a", TypeScript: "#3178c6", Python: "#3572A5",
  Rust: "#dea584", Dart: "#00B4AB", Ruby: "#701516", Java: "#b07219",
  Go: "#00ADD8", "C++": "#f34b7d", C: "#555555", Shell: "#89e051",
  HTML: "#e34c26", CSS: "#563d7c", Svelte: "#ff3e00", Vue: "#41b883",
};

const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function fmtDate(iso) {
  const [y, m, d] = iso.split("-");
  if (!m) return y;
  if (!d || d === "01") return `${y}.${m}`;
  return `${y}.${m}.${d}`;
}

function observe() {
  const els = document.querySelectorAll(".reveal");
  if (!("IntersectionObserver" in window)) {
    els.forEach((el) => el.classList.add("in"));
    return;
  }
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) {
      if (e.isIntersecting) {
        e.target.classList.add("in");
        io.unobserve(e.target);
      }
    }
  }, { rootMargin: "0px 0px -12% 0px", threshold: 0.15 });
  els.forEach((el) => io.observe(el));
}

function addYear(tl, year) {
  const yd = document.createElement("div");
  yd.className = "year reveal";
  yd.innerHTML = `<span>${year}</span>`;
  tl.appendChild(yd);
}

function historyMeta(item) {
  const tags = (item.tags || []).map((tag) => `<span class="tag">${esc(tag)}</span>`).join("");
  const links = (item.links || []).map((link) =>
    `<a class="source-link" href="${esc(link.url)}" target="_blank" rel="noopener">${esc(link.label)} ↗</a>`
  ).join("");
  return `${tags}${links}`;
}

function renderHistory() {
  const tl = document.getElementById("timeline");
  tl.innerHTML = "";
  const items = (window.HISTORY || []).slice().sort((a, b) => b.date.localeCompare(a.date));
  let lastYear = null;
  let idx = 0;

  for (const h of items) {
    const year = h.date.slice(0, 4);
    if (year !== lastYear) {
      addYear(tl, year);
      lastYear = year;
    }

    const side = idx % 2 === 0 ? "left" : "right";
    const alt = idx % 2 === 1 ? " alt" : "";
    const item = document.createElement("div");
    item.className = `item ${side} reveal${alt}`;
    item.innerHTML = `
      <article class="card history-card">
        <div class="date">${fmtDate(h.date)}</div>
        <h3>${esc(h.title)}</h3>
        ${h.description ? `<p class="desc">${esc(h.description)}</p>` : ""}
        <div class="meta history-meta">${historyMeta(h)}</div>
      </article>`;
    tl.appendChild(item);
    idx++;
  }

  const firstYear = items.length ? Math.min(...items.map((x) => Number(x.date.slice(0, 4)))) : "";
  const tagSet = new Set(items.flatMap((x) => x.tags || []));
  document.getElementById("summary").innerHTML = `
    <span class="stat"><b>${items.length}</b><span>milestones</span></span>
    <span class="stat"><b>${firstYear}</b><span>since</span></span>
    <span class="stat"><b>${tagSet.size}</b><span>themes</span></span>`;
  document.getElementById("tagline").textContent = "Things I've built, communities I've joined, and technologies I've explored.";
  observe();
}

function projectMeta(r) {
  const parts = [];
  if (r.lang) {
    const col = LANG_COLORS[r.lang] || "#8a97a9";
    parts.push(`<span class="lang"><i class="dot" style="background:${col}"></i>${esc(r.lang)}</span>`);
  }
  if (r.stars > 0) parts.push(`<span class="star">★ ${r.stars}</span>`);
  parts.push(`<span class="commits">⎇ ${r.commits.toLocaleString("en-US")} commit${r.commits === 1 ? "" : "s"}</span>`);
  if (r.live) parts.push(`<a class="live" href="${esc(r.live)}" target="_blank" rel="noopener">Live ↗</a>`);
  return parts.join("");
}

function renderProjects() {
  const tl = document.getElementById("timeline");
  tl.innerHTML = "";
  const repos = (window.REPOS || []).slice();
  let lastYear = null;
  let idx = 0;

  for (const r of repos) {
    const year = r.date.slice(0, 4);
    if (year !== lastYear) {
      addYear(tl, year);
      lastYear = year;
    }

    const side = idx % 2 === 0 ? "left" : "right";
    const alt = idx % 2 === 1 ? " alt" : "";
    const slash = r.name.indexOf("/");
    const org = slash > -1 ? r.name.slice(0, slash) : null;
    const repoName = slash > -1 ? r.name.slice(slash + 1) : r.name;
    const item = document.createElement("div");
    item.className = `item ${side} reveal${alt}`;
    item.innerHTML = `
      <article class="card">
        <div class="date">${fmtDate(r.date)}</div>
        <h3>${org ? `<span class="org">${esc(org)}</span>` : ""}<a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(repoName)}</a></h3>
        ${r.description ? `<p class="desc">${esc(r.description)}</p>` : ""}
        <div class="meta">${projectMeta(r)}</div>
      </article>`;
    tl.appendChild(item);
    idx++;
  }

  const T = window.TOTALS || null;
  const nProjects = T ? T.projects : repos.length;
  const totalStars = T ? T.stars : repos.reduce((a, r) => a + (r.stars || 0), 0);
  const totalCommits = T ? T.commits : repos.reduce((a, r) => a + (r.commits || 0), 0);
  const since = T ? T.since : (repos.length ? Math.min(...repos.map((r) => +r.date.slice(0, 4))) : "");
  document.getElementById("summary").innerHTML = `
    <span class="stat"><b>${nProjects}</b><span>projects</span></span>
    <span class="stat"><b>${totalStars}</b><span>stars</span></span>
    <span class="stat"><b>${totalCommits.toLocaleString("en-US")}</b><span>commits</span></span>
    <span class="stat"><b>${since}</b><span>since</span></span>`;
  document.getElementById("tagline").textContent = "Public repositories — a timeline of things I've built.";
  observe();
}

function setView(view, updateHash = true) {
  const chosen = view === "projects" ? "projects" : "history";
  document.querySelectorAll(".view-button").forEach((btn) => {
    btn.classList.toggle("active", btn.dataset.view === chosen);
    btn.setAttribute("aria-pressed", btn.dataset.view === chosen ? "true" : "false");
  });
  if (chosen === "projects") renderProjects();
  else renderHistory();
  if (updateHash) history.replaceState(null, "", chosen === "history" ? "#history" : "#projects");
}

document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".view-button").forEach((btn) => {
    btn.addEventListener("click", () => setView(btn.dataset.view));
  });
  setView(location.hash === "#projects" ? "projects" : "history", false);
});
