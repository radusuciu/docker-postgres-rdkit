#!/bin/bash

# Check if at least two arguments are given
if [ $# -lt 2 ]
then
  echo "Usage: $0 <source_branch> <target_branch1> [target_branch2] ..."
  exit 1
fi

# The branch where the changes are coming from
source_branch="$1"
shift

# List of branches where the changes should be merged to
branches=("$@")

# Get the ARG boost_version line from the Dockerfile in the source branch
git checkout "${source_branch}"
source_boost_line=$(grep '^ARG boost_version=' Dockerfile)

# Go through each branch
for branch in "${branches[@]}"; do
  # Checkout the branch
  git checkout "${branch}"

  # Get the ARG boost_version line from the Dockerfile in the target branch
  target_boost_line=$(grep '^ARG boost_version=' Dockerfile)

  # Merge changes from the source branch
  git merge --no-commit --no-ff "${source_branch}"

  # Replace the ARG boost_version line with the one from the Dockerfile of the currently checked out branch
  sed -i "s|${source_boost_line}|${target_boost_line}|" Dockerfile

  # Commit the changes
  git commit -a -m "Merge changes from ${source_branch}, updating ARG boost_version to match ${branch}"
  git push
done

# Go back to the source branch
git checkout "${source_branch}"
