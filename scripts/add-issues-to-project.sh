#!/usr/bin/env bash
set -euo pipefail

export GH_PAGER=""

# Required environment variables:
#   GH_TOKEN - GitHub PAT with project and repo access
#   ORG      - GitHub organization (default: caido-community)
#   PROJECT_NUMBER - GitHub Project number (default: 2)
#   SINCE_MINUTES  - Look back window in minutes (default: 30)

ORG="${ORG:-caido-community}"
PROJECT_NUMBER="${PROJECT_NUMBER:-2}"
SINCE_MINUTES="${SINCE_MINUTES:-30}"

# Get the project node ID
PROJECT_ID=$(gh api graphql -f query='
  query($org: String!, $number: Int!) {
    organization(login: $org) {
      projectV2(number: $number) {
        id
      }
    }
  }' -f org="$ORG" -F number="$PROJECT_NUMBER" -q '.data.organization.projectV2.id')

echo "Project ID: $PROJECT_ID"

# Calculate the "since" timestamp
if date --version >/dev/null 2>&1; then
  SINCE=$(date -u -d "${SINCE_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
else
  SINCE=$(date -u -v-"${SINCE_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)
fi

echo "Looking for issues since: $SINCE"

# Fetch all existing project item content IDs for deduplication
echo "Fetching existing project items..."
EXISTING_IDS=""
END_CURSOR=""
HAS_NEXT="true"

while [ "$HAS_NEXT" = "true" ]; do
  AFTER_ARG=""
  if [ -n "$END_CURSOR" ]; then
    AFTER_ARG="-f after=$END_CURSOR"
  fi

  RESULT=$(gh api graphql -f query='
    query($projectId: ID!, $after: String) {
      node(id: $projectId) {
        ... on ProjectV2 {
          items(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes { content { ... on Issue { id } ... on PullRequest { id } } }
          }
        }
      }
    }' -f projectId="$PROJECT_ID" $AFTER_ARG)

  PAGE_IDS=$(echo "$RESULT" | jq -r '.data.node.items.nodes[].content.id // empty')
  EXISTING_IDS="${EXISTING_IDS}${PAGE_IDS}"$'\n'
  HAS_NEXT=$(echo "$RESULT" | jq -r '.data.node.items.pageInfo.hasNextPage')
  END_CURSOR=$(echo "$RESULT" | jq -r '.data.node.items.pageInfo.endCursor')
done

echo "Found $(echo "$EXISTING_IDS" | grep -c '.') existing items in project"

# Get all repos in the org
REPOS=$(gh api --paginate "/orgs/$ORG/repos" -q '.[].full_name')

for REPO in $REPOS; do
  # Get open issues (not PRs) updated since the lookback window
  ISSUES=$(gh api --paginate "/repos/$REPO/issues?state=open&since=$SINCE&sort=created&direction=desc" \
    -q '.[] | select(.pull_request == null) | .node_id')

  for ISSUE_ID in $ISSUES; do
    if echo "$EXISTING_IDS" | grep -q "^${ISSUE_ID}$"; then
      echo "Skipping issue $ISSUE_ID from $REPO (already in project)"
      continue
    fi

    echo "Adding issue $ISSUE_ID from $REPO to project"
    gh api graphql -f query='
      mutation($projectId: ID!, $contentId: ID!) {
        addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
          item { id }
        }
      }' -f projectId="$PROJECT_ID" -f contentId="$ISSUE_ID" 2>/dev/null || true
  done
done

echo "Done."
