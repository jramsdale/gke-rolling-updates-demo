#!/usr/bin/env bash
# Copyright 2018 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# shellcheck source=.env

# validate.sh - a script to validate that an upgrade has completed successfully.
# It relies on the use of kubectl and jq.

# Stop immediately if something goes wrong
set -euo pipefail

# The absolute path to the root of the repository
REPO_HOME="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"

fail() {
  echo "ERROR: ${*}"
  exit 2
}

# Validate that this workstation has access to the required executables
command -v kubectl >/dev/null || fail "kubectl is not installed!"
command -v jq >/dev/null || fail "jq is not installed!"

# Source the properties file
if [ -f "${REPO_HOME}/.env" ] ; then
  source "${REPO_HOME}/.env"
else
  echo "ERROR: Define a properties file '.env'"
  exit 1
fi

# Check that the NEW_K8S_VER variable has been set
if [ -z ${NEW_K8S_VER:+exists} ]; then
  echo "ERROR: Set the NEW_K8S_VER environment variable"
  exit 1
fi

# compare_semver - determines if two version strings are semver equivalent.
# We allow users to choose cluster versions of the form 1.X or 1.X.Y as GKE
# will pick an appropriate GKE version.  To validate that the cluster has been
# successfully upgraded, we need to compare the chosen versions with the actual
# cluster versions.  Some examples:
# 1.10 and 1.10.4 are equivalent
# 1.10.4 and 1.10.3 are not equivalent
# 1.10 and 1.9.7 are not equivalent
# Returns:
# 0 - when the two versions are semver equivalent
# 1 - when the two versions are not semver equivalent
compare_semver() {
  FIRST_VER=$1
  SECOND_VER=$2
  # Convert the two semvers to arrays, splitting on each '.'
  IFS='.' read -r -a FIRST_VER_ARRAY <<< "$FIRST_VER"
  IFS='.' read -r -a SECOND_VER_ARRAY <<< "$SECOND_VER"

  # Calculate the length of each array
  FIRST_LENGTH=${#FIRST_VER_ARRAY[@]}
  SECOND_LENGTH=${#SECOND_VER_ARRAY[@]}

  # Find the shortest length because we only need to compare the digits of the
  # shortest semver.
  MIN=$(( FIRST_LENGTH < SECOND_LENGTH ? FIRST_LENGTH : SECOND_LENGTH))

  # Arrays are 0 indexed so subtract 1.
  MIN=$(( MIN - 1 ))
  for i in $(seq 0 $MIN); do
    # Compare the two semvers at each level
    if [[ "${FIRST_VER_ARRAY[$i]}" != "${SECOND_VER_ARRAY[$i]}" ]]; then
      echo "ERROR: Version $1 is not equivalent to $2"
      return 1
    fi
  done
  # If we made it here the two versions are equivalent
  # echo "Version $1 is equivalent to $2"
  return 0
}

# Strips the leading `v` and trailing `-gke.N` from a gke version number
# The result is a kubernetes semver, ex: v1.10.4-gke.2 => 1.10.4
strip_gke_ver() {
  local GKE_VER=$1
  # remove the trailing gke patch version
  K8S=${GKE_VER%%-*}
  # remove the preceeding v
  K8S=${K8S#v}
  echo "${K8S}"
}

# Validate the control plane version has been upgraded.  Returns:
# 0 - when the control plane version == NEW_K8S_VER
# 1 - when the control plane version != NEW_K8S_VER
validate_control() {
  CONTROL_VER=$(kubectl version -o json | jq -r .serverVersion.gitVersion)
  VER=$(strip_gke_ver "${CONTROL_VER}")
  if compare_semver "$VER" "$NEW_K8S_VER"; then
    return 0
  else
    echo "Control plane should be ${NEW_K8S_VER} but is ${VER}"
    return 1
  fi
}

# Validate that all nodes have been upgraded.
# Returns:
# 0 - when all node versions == NEW_K8S_VER
# 1 - when a node version != NEW_K8S_VER
validate_nodes() {
  NODES=$(kubectl get nodes -o name)
  for NODE in ${NODES}; do
    # Find the kubelet version on each node.  This will match the gke version
    NODE_VER=$(kubectl get "${NODE}" -o json | \
      jq -r '.status.nodeInfo.kubeletVersion')
    # Strip out the gke patch number to compare with NEW_K8S_VER
    VER=$(strip_gke_ver "${NODE_VER}")
    if ! compare_semver "$VER" "$NEW_K8S_VER"; then
      echo -n "ERROR: ${NODE} has version ${VER}, "
      echo "but should have ${NEW_K8S_VER}"
      return 1
    fi
  done
  return 0
}

# Validates that the upgrade was completed
validate() {
  echo "Validating the control plane version..."
  if validate_control ; then
    echo "Control plane is upgraded to ${NEW_K8S_VER}!"
  else
    exit 1
  fi
  echo "Validating the Nodes..."
  if validate_nodes ; then
    echo "All nodes upgraded to ${NEW_K8S_VER}!"
  else
    echo "ERROR: Not all nodes have been upgraded."
    exit 1
  fi
  return 0
}

# Time to validate
validate
