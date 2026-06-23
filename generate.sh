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

# Portfolio-only overrides (repo settings are left untouched). Fill in
# descriptions / live URLs for repos whose GitHub "About" is empty.
OVERRIDES='{
  "omoikane": {
    "description": "Knowledge-base server that lets AI coding agents (Claude Code, Cursor, Cline…) store and reverse-index past traps, decisions, design notes, lessons and incidents — toward a self-running librarian-agent community."
  },
  "428lab/events": {
    "description": "All-in-one event-ops platform — announce, recruit, run, score and award hackathons and any event, with real-time presentation and scoring.",
    "live": "https://events.kojira.io"
  },
  "428lab/debug-shrine": {
    "description": "Shrine-themed web app that tracks members GitHub activity (Firebase auth + Firestore) and grants titles/achievements. A Yotsuya-lab project.",
    "live": "https://d-shrine.jp"
  },
  "nosplay": { "live": "https://kojira.github.io/nosplay" },
  "aozoraquest": { "live": "https://aozoraquest.app" },
  "noscha-io": { "live": "https://noscha.io" },
  "NostrDraw": { "live": "https://kojira.github.io/NostrDraw/" },
  "NostrYears": { "live": "https://kojira.github.io/NostrYears/" },
  "NostrShrine": { "live": "https://kojira.github.io/NostrShrine/" },
  "NostrAnalytics": { "live": "https://kojira.github.io/NostrAnalytics/" },
  "nostr-haijin-checker": { "live": "https://kojira.github.io/nostr-haijin-checker/" },
  "bluesky-chan": { "live": "https://bsky.app/profile/bskychan.bsky.social" }
}'

# Repos to exclude from the portfolio entirely (by name), even if notable.
EXCLUDE='["FindSenryu4Discord"]'

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

jq -s --argjson ov "$OVERRIDES" --argjson exclude "$EXCLUDE" '(.[0] + .[1])
    | map(select(.name as $n | ($exclude | index($n)) | not))
    | map(. as $r | ($ov[$r.name] // {}) as $o
          | $r + {
              description: (if ($o.description // "") != "" then $o.description else $r.description end),
              live: ($o.live // $r.live)
            })
    | sort_by(.date) | reverse' /tmp/_own.json /tmp/_org.json > /tmp/_all.json
{ printf "window.REPOS = "; cat /tmp/_all.json; printf ";\n"; } > data.js
echo "Wrote data.js with $(jq length /tmp/_all.json) repos."
