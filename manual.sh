#!/bin/bash

# Exit if any command fails
set -e

# Check if at least two arguments are provided
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 postgres_version rdkit_version [boost_version]"
    echo "Example: $0 13.3 2023_03_02 1.74 or 1.74.0"
    exit 1
fi

# Extract arguments
postgres_version=$1
rdkit_version=$2
boost_version=$3

# Regular expressions for version validation
postgres_version_regex="^[0-9]+\.[0-9]+$"
rdkit_version_regex="^[0-9]{4}_[0-9]{2}_[0-9]{2}$"
boost_version_regex="^[0-9]+\.[0-9]+(\.[0-9]+)?$" # Adjusted to allow version without patch

# Validate postgres_version
if [[ ! $postgres_version =~ $postgres_version_regex ]]; then
  echo "Invalid format for postgres_version. Expected format: X.Y, where X and Y are numbers. Example: 13.3"
  exit 1
fi

# Validate rdkit_version
if [[ ! $rdkit_version =~ $rdkit_version_regex ]]; then
  echo "Invalid format for rdkit_version. Expected format: YYYY_MM_DD, where YYYY, MM, and DD are numbers. Example: 2023_03_02"
  exit 1
fi

# Validate boost_version if specified
if [ -n "${boost_version}" ]; then
  if [[ ! $boost_version =~ $boost_version_regex ]]; then
    echo "Invalid format for boost_version. Expected format: X.Y or X.Y.Z, where X, Y, and Z are numbers. Example: 1.74 or 1.74.0"
    exit 1
  fi
fi

# Create branch name
branch_name="postgres-${postgres_version}-rdkit-${rdkit_version}"

# Create and checkout new branch
git checkout -b "${branch_name}"

# Update boost version in Dockerfile if specified
if [ -n "${boost_version}" ]; then
    sed -i "s/^ARG boost_version=.*/ARG boost_version=${boost_version}/" Dockerfile
    git add Dockerfile
    git commit -m "Update Boost version to ${boost_version}"
fi

echo "Branch ${branch_name} created and ready to be pushed."
