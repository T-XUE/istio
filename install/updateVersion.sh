#!/bin/bash

# Copyright 2017 Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at

#       http://www.apache.org/licenses/LICENSE-2.0

#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.."
VERSION_FILE="${ROOT}/istio.VERSION"
TEMP_DIR="/tmp"
GIT_COMMIT=false

set -o errexit
set -o pipefail
set -x

function usage() {
  [[ -n "${1}" ]] && echo "${1}"

  cat <<EOF
usage: ${BASH_SOURCE[0]} [options ...]"
  options:
    -i ... URL to download istioctl binary
    -p ... <hub>,<tag> for the pilot docker image
    -x ... <hub>,<tag> for the mixer docker image
    -c ... <hub>,<tag> for the istio-ca docker image
    -g ... create a git commit for the changes
EOF
  exit 2
}

source "$VERSION_FILE" || error_exit "Could not source versions"

while getopts :gi:p:x:c: arg; do
  case ${arg} in
    i) ISTIOCTL_URL="${OPTARG}";;
    p) PILOT_HUB_TAG="${OPTARG}";; # Format: "<hub>,<tag>"
    x) MIXER_HUB_TAG="${OPTARG}";; # Format: "<hub>,<tag>"
    c) CA_HUB_TAG="${OPTARG}";; # Format: "<hub>,<tag>"
    g) GIT_COMMIT=true;;
    *) usage;;
  esac
done

if [[ -n ${PILOT_HUB_TAG} ]]; then
    PILOT_HUB="$(echo ${PILOT_HUB_TAG}|cut -f1 -d,)"
    PILOT_TAG="$(echo ${PILOT_HUB_TAG}|cut -f2 -d,)"
fi

if [[ -n ${MIXER_HUB_TAG} ]]; then
    MIXER_HUB="$(echo ${MIXER_HUB_TAG}|cut -f1 -d,)"
    MIXER_TAG="$(echo ${MIXER_HUB_TAG}|cut -f2 -d,)"
fi

if [[ -n ${CA_HUB_TAG} ]]; then
    CA_HUB="$(echo ${CA_HUB_TAG}|cut -f1 -d,)"
    CA_TAG="$(echo ${CA_HUB_TAG}|cut -f2 -d,)"
fi

function error_exit() {
  # ${BASH_SOURCE[1]} is the file name of the caller.
  echo "${BASH_SOURCE[1]}: line ${BASH_LINENO[0]}: ${1:-Unknown Error.} (exit ${2:-1})" 1>&2
  exit ${2:-1}
}

function set_git() {
  if [[ ! -e "${HOME}/.gitconfig" ]]; then
    cat > "${HOME}/.gitconfig" << EOF
[user]
  name = istio-testing
  email = istio.testing@gmail.com
EOF
  fi
}


function create_commit() {
  set_git
  # If nothing to commit skip
  check_git_status && return

  echo 'Creating a commit'
  git commit -a -m "Updating istio version" \
    || error_exit 'Could not create a commit'

}

function check_git_status() {
  local git_files="$(git status -s)"
  [[ -z "${git_files}" ]] && return 0
  return 1
}

# Generated merge yaml files for easy installation
function merge_files() {
  SRC=$TEMP_DIR/templates
  AUTH_SRC=$SRC/istio-auth
  ISTIO=$ROOT/install/kubernetes/istio.yaml
  ISTIO_AUTH=$ROOT/install/kubernetes/istio-auth.yaml
  ISTIO_AUTH_WITH_CLUSTER_CA=$ROOT/install/kubernetes/istio-auth-with-cluster-ca.yaml

  echo "# GENERATED FILE. Use with Kubernetes 1.5+" > $ISTIO
  echo "# TO UPDATE, modify files in install/kubernetes/templates and run install/updateVersion.sh" >> $ISTIO
  cat $SRC/istio-mixer.yaml >> $ISTIO
  cat $SRC/istio-pilot.yaml >> $ISTIO
  cp $ISTIO $ISTIO_AUTH
  cat $SRC/istio-ingress.yaml >> $ISTIO
  cat $SRC/istio-egress.yaml >> $ISTIO

  sed -i "s/# authPolicy: MUTUAL_TLS/authPolicy: MUTUAL_TLS/" $ISTIO_AUTH
  cat $AUTH_SRC/istio-ingress-auth.yaml >> $ISTIO_AUTH
  cat $AUTH_SRC/istio-egress-auth.yaml >> $ISTIO_AUTH
  cp $ISTIO_AUTH $ISTIO_AUTH_WITH_CLUSTER_CA
  cat $AUTH_SRC/istio-namespace-ca.yaml >> $ISTIO_AUTH
}

function update_version_file() {
  cat <<EOF > "${VERSION_FILE}"
# DO NOT EDIT THIS FILE MANUALLY instead use
# install/updateVersion.sh (see install/README.md)
export CA_HUB="${CA_HUB}"
export CA_TAG="${CA_TAG}"
export MIXER_HUB="${MIXER_HUB}"
export MIXER_TAG="${MIXER_TAG}"
export ISTIOCTL_URL="${ISTIOCTL_URL}"
export PILOT_HUB="${PILOT_HUB}"
export PILOT_TAG="${PILOT_TAG}"
EOF
}

function update_istio_install() {
  pushd $TEMP_DIR/templates
  sed -i "s|image: {PILOT_HUB}/\(.*\):{PILOT_TAG}|image: ${PILOT_HUB}/\1:${PILOT_TAG}|" istio-pilot.yaml
  sed -i "s|image: {PROXY_HUB}/\(.*\):{PROXY_TAG}|image: ${PILOT_HUB}/\1:${PILOT_TAG}|" istio-ingress.yaml
  sed -i "s|image: {PROXY_HUB}/\(.*\):{PROXY_TAG}|image: ${PILOT_HUB}/\1:${PILOT_TAG}|" istio-egress.yaml
  sed -i "s|image: {MIXER_HUB}/\(.*\):{MIXER_TAG}|image: ${MIXER_HUB}/\1:${MIXER_TAG}|" istio-mixer.yaml
  popd
}

function update_istio_addons() {
  pushd $ROOT/install/kubernetes/addons
  sed -i "s|image: .*/\(.*\):.*|image: ${MIXER_HUB}/\1:${MIXER_TAG}|" grafana.yaml
  popd
}

function update_istio_auth() {
  pushd $TEMP_DIR/templates/istio-auth
  sed -i "s|image: {CA_HUB}/\(.*\):{CA_TAG}|image: ${CA_HUB}/\1:${CA_TAG}|" istio-cluster-ca.yaml
  sed -i "s|image: {PROXY_HUB}/\(.*\):{PROXY_TAG}|image: ${PILOT_HUB}/\1:${PILOT_TAG}|" istio-egress-auth.yaml
  sed -i "s|image: {PROXY_HUB}/\(.*\):{PROXY_TAG}|image: ${PILOT_HUB}/\1:${PILOT_TAG}|" istio-ingress-auth.yaml
  sed -i "s|image: {CA_HUB}/\(.*\):{CA_TAG}|image: ${CA_HUB}/\1:${CA_TAG}|" istio-namespace-ca.yaml
  popd
}

if [[ ${GIT_COMMIT} == true ]]; then
    check_git_status \
      || error_exit "You have modified files. Please commit or reset your workspace."
fi

cp -R $ROOT/install/kubernetes/templates $TEMP_DIR/templates
update_version_file
update_istio_install
update_istio_addons
update_istio_auth
merge_files
rm -R $TEMP_DIR/templates

if [[ ${GIT_COMMIT} == true ]]; then
    create_commit
fi