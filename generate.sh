#!/usr/bin/env bash
# Regenerate data.js from the GitHub API.
#  - Own public, non-fork repos that are "notable" (stars / live / description)
#    and have more than MINCOMMITS commits (drops empty/trivial repos).
#  - Plus an explicit list of org repos kojira created (INCLUDE).
# Requires: gh (authenticated), jq.
set -euo pipefail
USER="${1:-kojira}"
MINCOMMITS=2

# Org repos kojira created (owner/name). Edit this list to curate.
INCLUDE=(
  "428lab/events"
  "428lab/debug-shrine"
)

# すべて GitHub 側のメタデータを正とする（スクリプトに直書きしない）:
#   - 説明文 … 各リポジトリの GitHub description（About）
#   - live リンク … 各リポジトリの GitHub homepage（About の🔗Website）
#   - 表示/非表示 … `no-portfolio` トピック
# よって表示テキストの直書きオーバーライドは持たない。

# タイムライン表示から隠したいリポジトリは、GitHub 側で下記トピックを付けるだけでよい
# （スクリプトを編集せず GitHub の Settings/Topics で管理できる）。
# 例: gh repo edit kojira/FindSenryu4Discord --add-topic no-portfolio
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

echo "Fetching ${#INCLUDE[@]} included org repos ..."
rm -f /tmp/_org_lines.json
for full in ${INCLUDE[@]+"${INCLUDE[@]}"}; do
  owner="${full%%/*}"; name="${full##*/}"
  gh api graphql -F owner="$owner" -F name="$name" -f query='
  query($owner:String!, $name:String!){
    repository(owner:$owner, name:$name){
      name description createdAt stargazerCount url homepageUrl
      primaryLanguage{name}
      defaultBranchRef{ target{ ... on Commit{ history{ totalCount } } } }
    }
  }' \
  | jq --arg full "$full" '.data.repository | {
        name: $full,
        description,
        date: .createdAt[0:10],
        stars: .stargazerCount,
        commits: (.defaultBranchRef.target.history.totalCount // 0),
        lang: (.primaryLanguage.name // null),
        url,
        live: (if (.homepageUrl // "") != "" then .homepageUrl else null end)
      }' >> /tmp/_org_lines.json
done
if [ -f /tmp/_org_lines.json ]; then jq -s '.' /tmp/_org_lines.json > /tmp/_org.json; else echo '[]' > /tmp/_org.json; fi

jq -s --argjson exclude "$EXCLUDE" '(.[0] + .[1])
    | map(select(.name as $n | ($exclude | index($n)) | not))
    | map(del(.topics))
    | sort_by(.date) | reverse' /tmp/_own.json /tmp/_org.json > /tmp/_all.json

# ヘッダーのサマリー数字は【全リポジトリ対象】(own 全公開 non-fork + 428lab、fork 除く)。
# 表示は厳選 REPOS のままだが、数字は全体を集計する（EXCLUDE は表示専用なので含める）。
jq -s '(.[0] + .[1]) | {
    projects: length,
    stars: ([.[].stars] | add),
    commits: ([.[].commits] | add),
    since: ([.[].date[0:4] | tonumber] | min)
  }' /tmp/_own_all.json /tmp/_org.json > /tmp/_totals.json

{ printf "window.REPOS = "; cat /tmp/_all.json; printf ";\nwindow.TOTALS = "; cat /tmp/_totals.json; printf ";\n"; } > data.js
echo "Wrote data.js with $(jq length /tmp/_all.json) repos (display) / totals: $(jq -c . /tmp/_totals.json)"
