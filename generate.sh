#!/usr/bin/env bash
# Regenerate data.js from the GitHub API (own public, non-fork repos).
# Requires: gh (authenticated), jq.
set -euo pipefail
USER="${1:-kojira}"

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
| jq '[.[].data.user.repositories.nodes[]]
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
        ),
        _notable: (.stargazerCount > 0 or (.homepageUrl // "") != "" or (.description // "") != "")
      })
    | map(select(._notable)) | map(del(._notable))
    | sort_by(.date) | reverse' \
> /tmp/_repos.json

{ printf "window.REPOS = "; cat /tmp/_repos.json; printf ";\n"; } > data.js
echo "Wrote data.js with $(jq length /tmp/_repos.json) repos."
