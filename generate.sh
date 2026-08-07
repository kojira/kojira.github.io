#!/usr/bin/env bash
# Regenerate portfolio data and history assets.
#  - data.js: GitHub API からプロジェクトタイムライン＋サマリー集計を生成。
#  - history.js / index.html: history.jsonl を正として、クライアント用データと
#    SEO向けの静的HISTORYタイムラインを生成。
#
# Project data:
#  - 自分(USER)の public・non-fork repo のうち「notable」なもの。
#  - 加えて、どこの org であっても INCLUDE_TOPIC トピックの付いた repo を取り込む
#    （org repo には「作成者」フィールドが無いため、出したいものは自分でトピックを付ける）。
# リポジトリ名・org 名はこのスクリプトに一切直書きしない。表示テキスト/リンク/表示可否は
# すべて GitHub 側のメタデータが正（description / homepage / topics）。
# Requires: gh (authenticated), jq, python3.
set -euo pipefail
USER="${1:-kojira}"
MINCOMMITS=2

# 自分の repo 以外で「ポートフォリオに出したい」org repo に付けるトピック（opt-in）。
# 例: gh repo edit <owner>/<repo> --add-topic kojira-portfolio
INCLUDE_TOPIC="kojira-portfolio"

# すべて GitHub 側のメタデータを正とする（スクリプトに直書きしない）:
#   - 説明文 … 各リポジトリの GitHub description（About）
#   - live リンク … 各リポジトリの GitHub homepage（About の🔗Website）
#   - 表示/非表示 … `no-portfolio` トピック
# よって表示テキストの直書きオーバーライドは持たない。

# タイムライン表示から隠したいリポジトリは、GitHub 側で下記トピックを付けるだけでよい
# （スクリプトを編集せず GitHub の Settings/Topics で管理できる）。
# 例: gh repo edit <owner>/<repo> --add-topic no-portfolio
# ※ 隠すのは「表示」だけ。ヘッダーの集計数(TOTALS)には全リポジトリとして含める。
HIDE_TOPIC="no-portfolio"

# 追加で名前指定でも除外できる手動オーバーライド（通常は空でよい。トピック運用を推奨）。
EXCLUDE='[]'

echo "Fetching own repos for $USER ..."
gh api graphql -f query='
query($cursor: String, $login: String!) {
  user(login: $login) {
    repositories(first: 100, after: $cursor, privacy: PUBLIC, ownerAffiliations: OWNER, isFork: false, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name description createdAt stargazerCount url homepageUrl isArchived
        primaryLanguage { name }
        repositoryTopics(first: 30) { nodes { topic { name } } }
        defaultBranchRef { target { ... on Commit { history { totalCount } } } }
      }
    }
  }
}' -F login="$USER" --paginate --slurp \
| jq '[.[].data.user.repositories.nodes[]]
    | map({
        name, description,
        date: .createdAt[0:10],
        stars: .stargazerCount,
        commits: (.defaultBranchRef.target.history.totalCount // 0),
        lang: (.primaryLanguage.name // null),
        url,
        topics: [.repositoryTopics.nodes[].topic.name],
        live: (if (.homepageUrl // "") != "" then .homepageUrl else null end)
      })' \
> /tmp/_own_all.json
echo "  own (all public, non-fork): $(jq length /tmp/_own_all.json)"

# 表示用は「notable」だけに絞り込む（タイムラインのカード）。
# さらに HIDE_TOPIC トピックの付いたリポジトリは表示から除外する（集計には残る）。
jq --argjson min "$MINCOMMITS" --arg hide "$HIDE_TOPIC" '
    map(select((.topics // []) | index($hide) | not))
  | map(select(.stars>0 or .live!=null or (.description // "")!="" or .commits>=15))
  | map(select(.commits > $min or .live != null))' \
  /tmp/_own_all.json > /tmp/_own.json
echo "  own (notable & not hidden, commits>$MINCOMMITS): $(jq length /tmp/_own.json)"

echo "Searching repos tagged topic:$INCLUDE_TOPIC ..."
# 自分の repo は上で取得済み。ここでは「INCLUDE_TOPIC が付いた repo（org 含む）」を
# トピック検索で取り込む。owner が自分なら repo 名のみ、他 owner なら "owner/name" 表記。
gh api graphql -f query='
query($q: String!) {
  search(query: $q, type: REPOSITORY, first: 100) {
    nodes { ... on Repository {
      name nameWithOwner description createdAt stargazerCount url homepageUrl isFork
      owner { login }
      primaryLanguage { name }
      repositoryTopics(first: 30) { nodes { topic { name } } }
      defaultBranchRef { target { ... on Commit { history { totalCount } } } }
    } }
  }
}' -F q="topic:$INCLUDE_TOPIC fork:false" \
| jq --arg login "$USER" '[.data.search.nodes[]]
    | map(select(.isFork | not))
    | map({
        name: (if .owner.login == $login then .name else .nameWithOwner end),
        description,
        date: .createdAt[0:10],
        stars: .stargazerCount,
        commits: (.defaultBranchRef.target.history.totalCount // 0),
        lang: (.primaryLanguage.name // null),
        url,
        topics: [.repositoryTopics.nodes[].topic.name],
        live: (if (.homepageUrl // "") != "" then .homepageUrl else null end)
      })' \
> /tmp/_inc_all.json
echo "  included (topic:$INCLUDE_TOPIC): $(jq length /tmp/_inc_all.json)"

# 取り込み repo の表示分（明示タグなので notable 判定はしない。no-portfolio が付いていれば隠す）。
jq --arg hide "$HIDE_TOPIC" 'map(select((.topics // []) | index($hide) | not))' \
  /tmp/_inc_all.json > /tmp/_inc.json

# 表示セット = own(notable・非hidden) ＋ included、url で重複排除（own 優先）、整列。
jq -s --argjson exclude "$EXCLUDE" '(.[0] + .[1])
    | unique_by(.url)
    | map(select(.name as $n | ($exclude | index($n)) | not))
    | map(del(.topics))
    | sort_by(.date) | reverse' /tmp/_own.json /tmp/_inc.json > /tmp/_all.json

# ヘッダーのサマリー数字は【全リポジトリ対象】＝自分の全公開 non-fork repo ＋ 取り込み
# (INCLUDE_TOPIC) repo、fork 除く。表示は厳選だが数字は全体を集計（hidden も含める）。
jq -s '(.[0] + .[1]) | unique_by(.url) | {
    projects: length,
    stars: ([.[].stars] | add),
    commits: ([.[].commits] | add),
    since: ([.[].date[0:4] | tonumber] | min)
  }' /tmp/_own_all.json /tmp/_inc_all.json > /tmp/_totals.json

{ printf "window.REPOS = "; cat /tmp/_all.json; printf ";\nwindow.TOTALS = "; cat /tmp/_totals.json; printf ";\n"; } > data.js
echo "Wrote data.js with $(jq length /tmp/_all.json) repos (display) / totals: $(jq -c . /tmp/_totals.json)"

# ---- Personal history -------------------------------------------------------
# history.jsonl が唯一の編集元。1行1イベントのJSONとして管理し、
# 1) history.js（ブラウザでHISTORYへ戻る際の再描画用）
# 2) index.html 内のHISTORY:START/END区間（検索エンジンがJSなしで読める静的HTML）
# を同時に生成する。
if [[ ! -f history.jsonl ]]; then
  echo "history.jsonl not found" >&2
  exit 1
fi

# JSONL全行を検証し、日付の新しい順に正規化。
jq -s 'sort_by(.date) | reverse' history.jsonl > /tmp/_history.json
{ printf "window.HISTORY = "; cat /tmp/_history.json; printf ";\n"; } > history.js

python3 <<'PY'
import html
import json
import re
from pathlib import Path

history_path = Path("history.jsonl")
index_path = Path("index.html")

items = [json.loads(line) for line in history_path.read_text(encoding="utf-8").splitlines() if line.strip()]
items.sort(key=lambda item: item.get("date", ""), reverse=True)

def fmt_date(value: str) -> str:
    parts = value.split("-")
    if len(parts) == 1:
        return parts[0]
    if len(parts) == 2 or (len(parts) >= 3 and parts[2] == "01"):
        return f"{parts[0]}.{parts[1]}"
    return f"{parts[0]}.{parts[1]}.{parts[2]}"

lines = []
last_year = None
for idx, item in enumerate(items):
    date = str(item.get("date", ""))
    year = date[:4]
    if year != last_year:
        lines.append(f'      <div class="year reveal"><span>{html.escape(year)}</span></div>')
        last_year = year

    side = "left" if idx % 2 == 0 else "right"
    alt = " alt" if idx % 2 else ""
    tags = "".join(
        f'<span class="tag">{html.escape(str(tag))}</span>'
        for tag in item.get("tags", [])
    )
    links = "".join(
        f'<a class="source-link" href="{html.escape(str(link.get("url", "")), quote=True)}" '
        f'target="_blank" rel="noopener">{html.escape(str(link.get("label", "Source")))} ↗</a>'
        for link in item.get("links", [])
        if link.get("url")
    )
    description = item.get("description")
    desc_html = f'<p class="desc">{html.escape(str(description))}</p>' if description else ""

    lines.extend([
        f'      <div class="item {side} reveal{alt}">',
        '        <article class="card history-card">',
        f'          <div class="date">{html.escape(fmt_date(date))}</div>',
        f'          <h3>{html.escape(str(item.get("title", "")))}</h3>',
        f'          {desc_html}' if desc_html else '',
        f'          <div class="meta history-meta">{tags}{links}</div>',
        '        </article>',
        '      </div>',
    ])

block = "\n".join(line for line in lines if line != "")
text = index_path.read_text(encoding="utf-8")
start = "<!-- HISTORY:START -->"
end = "<!-- HISTORY:END -->"
if start not in text or end not in text:
    raise SystemExit("index.html is missing HISTORY generation markers")

pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
replacement = f"{start}\n{block}\n      {end}"
text, count = pattern.subn(lambda _: replacement, text, count=1)
if count != 1:
    raise SystemExit("could not replace HISTORY block exactly once")
index_path.write_text(text, encoding="utf-8")

print(f"Wrote history.js and static history HTML with {len(items)} milestones")
PY
