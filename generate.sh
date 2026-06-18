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
)

echo "Fetching own repos for $USER ..."
gh api graphql -f query='
query($cursor: String, $login: String!) {
  user(login: $login) {
    repositories(first: 100, after: $cursor, privacy: PUBLIC, ownerAffiliations: OWNER, isFork: false, orderBy: {field: CREATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name description createdAt stargazerCount url homepageUrl isArchived
        primaryLanguage { name }
        defaultBranchRef { target { ... on Commit { history { totalCount } } } }
      }
    }
  }
}' -F login="$USER" --paginate --slurp \
| jq --argjson min "$MINCOMMITS" '[.[].data.user.repositories.nodes[]]
    | map({
        name, description,
        date: .createdAt[0:10],
        stars: .stargazerCount,
        commits: (.defaultBranchRef.target.history.totalCount // 0),
        lang: (.primaryLanguage.name // null),
        url,
        live: (
          if (.homepageUrl // "") != "" then .homepageUrl
          elif (.name=="bluesky-license" or .name=="nostr-license" or .name=="nostr-brainmaker") then ("https://kojira.github.io/" + .name + "/")
          else null end
        )
      })
    | map(select(.stars>0 or .live!=null or (.description // "")!="" or .commits>=15))
    | map(select(.commits > $min or .live != null))' \
> /tmp/_own.json
echo "  own (notable, commits>$MINCOMMITS): $(jq length /tmp/_own.json)"

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

jq -s '(.[0] + .[1]) | sort_by(.date) | reverse' /tmp/_own.json /tmp/_org.json > /tmp/_all.json
{ printf "window.REPOS = "; cat /tmp/_all.json; printf ";\n"; } > data.js
echo "Wrote data.js with $(jq length /tmp/_all.json) repos."
