#!/usr/bin/env bash
set -o errexit

[ -n "${GITHUB_REPOSITORY}" ] || fail "No GITHUB_REPOSITORY was supplied."
[ -n "${PULL_REQUEST}" ] || fail "No PULL_REQUEST was supplied."
[ -n "${PULL_REQUEST_LABEL}" ] || fail "No PULL_REQUEST_LABEL was supplied."
[ -n "${PULL_REQUEST_LABEL_CONFLICT}" ] || fail "No PULL_REQUEST_LABEL_CONFLICT was supplied."
[ -n "${GITHUB_TOKEN}" ] || fail "No GITHUB_TOKEN was supplied."

# Determine https://github.com/OWNER/REPO from GITHUB_REPOSITORY.
REPO="${GITHUB_REPOSITORY##*/}"
OWNER="${GITHUB_REPOSITORY%/*}"

git config user.name "${GIT_AUTHOR_NAME}"
git config user.email "${GIT_AUTHOR_EMAIL}"

[ -n "${OWNER}" ] || fail "Could not determine GitHub owner from GITHUB_REPOSITORY."
[ -n "${REPO}" ] || fail "Could not determine GitHub repo from GITHUB_REPOSITORY."

# Fetch the SHAs & Numbers from the pull requests that are marked with $PULL_REQUEST_LABEL.
readarray -t pulls < <(
  jq -cn '
    {
      query: $query,
      variables: {
        owner: $owner,
        repo: $repo,
        pull_request_label: $pull_request_label
      }
    }' \
    --arg query '
      query($owner: String!, $repo: String!, $pull_request_label: String!) {
        repository(owner: $owner, name: $repo) {
          pullRequests(states: OPEN, labels: [$pull_request_label], first: 100) {
            nodes {
              headRefOid
              title
              author {
                login
              }
              number
              mergeable
              reviews {
                totalCount
              }
            }
          }
        }
      }' \
    --arg owner "$OWNER" \
    --arg repo "$REPO" \
    --arg pull_request_label "$PULL_REQUEST_LABEL" \
  | curl \
    --fail \
    --show-error \
    --silent \
    --header "Authorization: token $GITHUB_TOKEN" \
    --header "Content-Type: application/json" \
    --data @- \
    https://api.github.com/graphql \
  | jq -r '.data.repository.pullRequests.nodes'
)

echo ""

# Do not attempt to merge if there are no pull requests to be merged.
if [ ${#pulls[@]} -eq 0 ]
then
  echo "No pull requests with label $PULL_REQUEST_LABEL"
  exit 0
fi

for j in "${!pulls[@]}"; do
if [[ $j -le $i ]]
then
    continue
fi

echo "CHECKING CONFLICTS BETWEEN $i AND $j"
echo "------------------------------------"
git merge --no-commit ${pulls[$i]} ${pulls[$j]} > /dev/null 2>&1
git --no-pager diff --name-status --diff-filter=U | cut -c3-
git reset --hard HEAD~1 > /dev/null 2>&1
git clean -xxdf > /dev/null 2>&1
echo "------------------------------------"
done




















# Check Conflicts and exit if exists
conflicts=$( echo ${pulls[@]} | jq -r '[ .[] | select( .mergeable == "CONFLICTING" ) ]' )
if [ $( echo ${conflicts[@]} | jq -r '. | length' ) -ne 0 ]
then
  echo "Conflicting PR found - further merging is impossible"
  echo "-------------------------------------------------------------------"
  echo ${conflicts[@]} | jq -r '.[] | [.headRefOid, .number, .mergeable, .title+" ("+.author.login+")"] | @tsv'
  echo "-------------------------------------------------------------------"
  echo ""

  for num in $( echo ${conflicts[@]} | jq -r '.[].number' )
  do
    curl \
      -X POST \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: token $GITHUB_TOKEN" \
      https://api.github.com/repos/$OWNER/$REPO/issues/$num/labels \
      -d "{\"labels\":[\"${PULL_REQUEST_LABEL_CONFLICT}\"]}"
  done
fi

forMerge=$( echo ${pulls[@]} | jq -c '[ .[] | select( .mergeable != "CONFLICTING" ) ]' )

# Show all pulls for detect conflicts
echo "Pull requests for cross-merge conflicts detect"
echo "-------------------------------------------------------------------"
echo ${forMerge[@]} | jq -r '.[] | [.headRefOid, .number, .title+" ("+.author.login+")"] | @tsv'
echo "-------------------------------------------------------------------"
echo ""












# Save information
echo "master +" > head.txt
echo ${forMerge[@]} | jq -r '.[] | [.headRefOid, .number, .title+" ("+.author.login+")"] | @tsv' >> head.txt

# Split SHAs and Numbers to two arrays
shas=( $( echo ${forMerge[@]} | jq -r '.[].headRefOid' ) )
numbers=( $( echo ${forMerge[@]} | jq -r '.[].number' ) )

# Merge all shas together into one commit.
git fetch origin "${shas[@]}" &>/dev/null
echo ""
git merge --no-ff --no-commit "${shas[@]}"
echo ""
git commit --message "Merged Pull Requests (${numbers[*]})"
echo ""
echo "Merged ${#shas[@]} pull requests"