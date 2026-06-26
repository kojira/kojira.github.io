#!/usr/bin/env bash
# Regenerate data.js from the GitHub API.
#  - 自分(USER)の public・non-fork repo のうち「notable」なもの。
#  - 加えて、どこの org であっても INCLUDE_TOPIC トピックの付いた repo を取り込む
#    （org repo には「作成者」フィールドが無いため、出したいものは自分でトピックを付ける）。
# リポジトリ名・org 名はこのスクリプトに一切直書きしない。表示テキスト/リンク/表示可否は
# すべて GitHub 側のメタデータが正（description / homepage / topics）。
# Requires: gh (authenticated), jq.
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
