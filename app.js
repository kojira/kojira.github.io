// kojira — projects timeline. Data is baked into data.js (window.REPOS),
// regenerated from the GitHub API via generate.sh.

const LANG_COLORS = {
  JavaScript: "#f1e05a", TypeScript: "#3178c6", Python: "#3572A5",
  Rust: "#dea584", Dart: "#00B4AB", Ruby: "#701516", Java: "#b07219",
  Go: "#00ADD8", "C++": "#f34b7d", C: "#555555", Shell: "#89e051",
  HTML: "#e34c26", CSS: "#563d7c", Svelte: "#ff3e00", Vue: "#41b883",
};

const esc = (s) => String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
  ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function fmtDate(iso) {
  // iso = YYYY-MM-DD -> "YYYY.MM"
  const [y, m] = iso.split("-");
  return `${y}.${m}`;
}

function metaRow(r) {
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

function render() {
  const tl = document.getElementById("timeline");
  const repos = (window.REPOS || []).slice(); // already newest-first
  let lastYear = null;
  let idx = 0;

  for (const r of repos) {
    const year = r.date.slice(0, 4);
    if (year !== lastYear) {
      const yd = document.createElement("div");
      yd.className = "year reveal";
      yd.innerHTML = `<span>${year}</span>`;
      tl.appendChild(yd);
      lastYear = year;
    }

    const side = idx % 2 === 0 ? "left" : "right";
    const alt = idx % 2 === 1 ? " alt" : "";
    // org repos are stored as "owner/name" — show an org badge + the repo name
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
        <div class="meta">${metaRow(r)}</div>
      </article>`;
    tl.appendChild(item);
    idx++;
  }

  // summary stats — 全リポジトリ集計(window.TOTALS)を優先。タイムラインは厳選表示だが、
  // この数字は全リポジトリ(own 全公開 + 428lab、fork 除く)を対象にする。
  // TOTALS が無い場合は従来どおり表示中 REPOS から算出。
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

  observe();
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

document.addEventListener("DOMContentLoaded", render);
