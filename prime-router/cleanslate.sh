#!/usr/bin/env bash

# Formatting colors
RED="\e[1;91m"
GREEN="\e[1;92m"
YELLOW="\e[1;33m"
PLAIN="\e[0m"
WHITE="\e[1;97m"

# Actual variables we'll reference
HERE="$(dirname "${0}")"
LOG="${0}.log" # myscript.sh.log
VAULT_ENV_LOCAL_FILE=".vault/env/.env.local"
DOCKER_COMPOSE_PREFIX="prime-router_"

VERBOSE=0
SHOW_HELP=0
KEEP_VAULT=0
KEEP_BUILD_ARTIFACTS=0
KEEP_PRIME_CONTAINER_IMAGES=0
KEEP_ALL=0
PRUNE_VOLUMES=0

function usage() {
  cat <<EOF

usage: ${0} [OPTIONS...]

This script sets you up for your first run (or re-initializes your environment \
as if it were your first run).

OPTIONS:
  --keep-all                Activates all --keep-* flags
  --keep-build-artifacts    Does not eliminate gradle's build artifacts
  --keep-images             Does not delete docker images
  --keep-vault              Does not eliminate your vault information
  --prune-volumes           Forces a docker volume prune -f after taking containers
                            down (disables --keep-vault, including when set via --keep-all)
  --verbose                 Get "more" output
  --help|-h                 Shows this help


Examples:

  # Default mode: tries to eliminate as much as possible and get you to a totally
  # clean state; your vault is reset but your database sticks around
  $ ${0}

  # Most aggressive mode: same as default mode but also get rid of docker volumes,
  # this affects your PostgreSQL database
  # CAVEAT EMPTOR: this performs a `docker volume prune -f` after having stopped our
  # own containers, make sure you understand what this means for other unattached
  # or unused volumes on your system
  $ ${0} --prune-volumes

  # Reset any stored information but keep build artifacts and images; useful to reset
  # your vault and database
  # NOTE that --prune-volumes overrides instructions keep the vault around (and thus
  # deletes/resets the vault information)
  $ ${0} --keep-all --prune-volumes

  # Keep the results of your gradle build but rebuild container images (and bring them up)
  $ ${0} --keep-build-artifacts

  # Rebuild docker container images but keep data and vault around
  $ ${0} --keep-build-artifacts --keep-vault

  # Take things down, and bring them up again; rather ineffectual and likely not what
  # you want (but it's a thing you can do)
  $ ${0} --keep-all

  # Use this if you like chassing red herrings in debug-land
  $ ${0} --keep-images

EOF
}

function verbose() {
  if [[ ${VERBOSE?} != 0 ]]; then
    echo -e "${WHITE?}VERBOSE:${PLAIN?} ${*}" | tee -a "${LOG?}"
  fi
}

# Helper function to output infos
function info() {
  echo -e "${WHITE?}INFO:${PLAIN?} ${*}" | tee -a "${LOG?}"
}

# Helper function to output warnings
function warn() {
  echo -e "${YELLOW?}WARNING: ${PLAIN?} ${*}" | tee -a "${LOG?}"
}

# Helper function to output errors
function error() {
  echo -e "${RED?}ERROR:${PLAIN?} ${*}" | tee -a "${LOG?}"
}

# Takes ownership of some directories that are potentially shared with container instances
function take_directory_ownership() {
  info "Taking ownership of directories (may require elevation)..."
  TARGETS=(
    "./build/"
    "./docs/"
    "./.gradle/"
    "./.vault/"
  )

  for d in ${TARGETS[*]}; do
    echo -ne "    - ${d?}..."
    if [[ -d "${d?}" ]]; then
      sudo chown -R "$(id -u -n):$(id -g -n)" "${d?}"
      sudo chmod -R a+w "${d?}"
      echo "DONE"
    else
      echo "NOT_THERE"
    fi
  done
}

# Helper function to wait for vault credentials to become available
__SHOWN_VAULT_INFO=0
function wait_for_vault_creds() {
  # Make sure the vault is brought up and that the credentials are present
  docker-compose up --detach vault 1>/dev/null 2>/dev/null
  if [[ ${?} != 0 ]]; then
    error "The vault could not be brought up"
  fi

  # Wait for the vault to fully spin up and populate the vault file
  while [[ $(wc -c "${VAULT_ENV_LOCAL_FILE?}" | cut -d " " -f 1) == 0 ]]; do
    echo "Waiting for ${VAULT_ENV_LOCAL_FILE?} to be populated..."
    sleep 2
  done

  export $(cat .vault/env/.env.local | xargs)
  if [[ ${__SHOWN_VAULT_INFO} == 0 ]]; then
    info "Your vault credentials are:"
    echo -en "${WHITE?}" |
      tee -a "${LOG?}"
    cat "${VAULT_ENV_LOCAL_FILE?}" |
      sed 's/^/    /g' |
      tee -a "${LOG?}"
    echo -en "${PLAIN?}" |
      tee -a "${LOG?}"

    __SHOWN_VAULT_INFO=1
  fi
}

# Takes down any PRIME related docker instances
function docker_decompose() {
  info "Decomposing docker environments..."
  TARGETS=(
    docker-compose.yml
    docker-compose.build.yml
  )

  for target in ${TARGETS[*]}; do
    verbose "Taking down '${target?}'"
    docker-compose --file "${target?}" down 2>/dev/null |
      tee -a "${LOG?}"
    if [[ ${PIPESTATUS[0]} != 0 ]]; then
      warn "There was an error taking down '${target?}' (this is probably fine)."
    fi
  done

  if [[ ${PRUNE_VOLUMES?} != 0 ]]; then
    verbose "Pruning docker volumes"
    docker volume prune -f 2>/dev/null |
      tee -a "${LOG?}"
  fi
}

function cleanup_build_artifacts() {
  if [[ ${KEEP_BUILD_ARTIFACTS} == 0 ]]; then
    info "Cleaning up build artifacts"
    TARGETS=(
      ./build
      ./.gradle
    )

    for target in ${TARGETS[*]}; do
      verbose "Removing build artifact '${target?}'."
      rm -rf "${target?}" |
        tee -a "${LOG?}"
    done
  else
    info "SKIP Cleaning up build artifacts"
  fi

  if [[ ${KEEP_PRIME_CONTAINER_IMAGES} == 0 ]]; then
    info "Removing the the ${DOCKER_COMPOSE_PREFIX} container images"
    docker images 'prime-router_*' -q |
      xargs -I_ docker image rm "_" 1>>"${LOG?}" 2>&1
  else
    info "SKIP Removing the the ${DOCKER_COMPOSE_PREFIX} container images"
  fi

}

# Cleans up your vault (i.e. )
function reset_vault() {
  if [[ ${KEEP_VAULT?} == 0 ]]; then
    info "Cleaning up vault information"
    mkdir -p .vault/env
    rm -rf .vault/env/{key,.env.local}

    # Create an empty .env.local file
    cat /dev/null >"${VAULT_ENV_LOCAL_FILE?}"
    docker volume ls --filter "name=${DOCKER_COMPOSE_PREFIX?}vault" -q |
      xargs -I_ docker volume rm "_" 1>>"${LOG?}" 2>&1
  else
    info "SKIP Cleaning up vault information"
  fi
}

# Finds image references in docker-compose files and pulls those down
function refresh_docker_images() {
  info "Pulling down pre-baked images"
  COMPOSE_FILES=(
    docker-compose.yml
    docker-compose.build.yml
  )

  for compose_file in ${COMPOSE_FILES[*]}; do
    verbose "Processing '${compose_file?}' for pre-baked images"

    # The only reason for not doing this in a single piped command is debuggability and verbosity
    IMAGES=(
      $(grep "image: " "${compose_file}" |
        cut -d ":" -f 2-)
    )
    for img in ${IMAGES[*]}; do
      verbose "Pulling down '${img?}'..."
      docker pull "${img?}" 2>&1 1>/dev/null
      if [[ $? != 0 ]]; then
        error "There was an error pulling down '${img?}'."
      fi
    done
  done
}

function ensure_build_dependencies() {
  verbose "Bringing up the minimum build dependencies"
  docker-compose --file "docker-compose.build.yml" up --detach 1>>"${LOG?}" 2>&1
  if [[ ${?} != 0 ]]; then
    error "The docker-compose.build.yml environment could not be brought up"
  fi

  sleep 2
}

# Ensures that the binaries exist
function ensure_binaries() {
  CANARY="./build/azure-functions/prime-data-hub-router/prime-router-0.1-SNAPSHOT.jar"
  if [[ ! -f "${CANARY?}" ]]; then
    ensure_build_dependencies

    # Filter out some less valuable lines
    ./gradlew clean package 2>&1 |
      sed '/org.jooq.tools.JooqLogger info/d' |
      sed '/^@@@@@@@/d' |
      sed '/jOOQ tip of the day:/d' |
      tee -a "${LOG?}"
  else
    verbose "The canary file exists ('${CANARY?}'), skipping building"
  fi
}

function activate_containers() {
  info "Bringing up your development containers"
  docker-compose --file "docker-compose.build.yml" up --detach postgresql 1>>"${LOG?}" 2>&1
  wait_for_vault_creds
  docker-compose --file "docker-compose.yml" up --detach 1>>"${LOG?}" 2>&1
}

function populate_vault() {
  info "Populating your vault (http://localhost:8200/ui) with credentials"
  # Make sure we have vault credentials loaded
  wait_for_vault_creds

  ./prime create-credential --type=UserPass --persist=DEFAULT-SFTP --user foo --pass pass 1>>${LOG?} 2>&1
  ./prime multiple-settings set --input settings/organizations.yml 1>>${LOG?} 2>&1
}

# Orchestration for any clean-up-related activity
function cleanup() {
  info "> Cleaning up your environment..."
  docker_decompose
  take_directory_ownership
  cleanup_build_artifacts
  reset_vault
  return 0
}

# Orchestration for any initialization-related activity
function initialize() {
  info "> Initializing your environment..."
  refresh_docker_images
  ensure_binaries
  activate_containers
  populate_vault
  take_directory_ownership
  return 0
}

#
# Parse arguments
#
while [[ -n ${1} ]]; do
  case "${1}" in
  "--keep-all")
    KEEP_BUILD_ARTIFACTS=1
    KEEP_PRIME_CONTAINER_IMAGES=1
    KEEP_VAULT=1
    ;;
  "--keep-build-artifacts")
    KEEP_BUILD_ARTIFACTS=1
    ;;
  "--keep-images")
    KEEP_PRIME_CONTAINER_IMAGES=1
    ;;
  "--keep-vault")
    KEEP_VAULT=1
    ;;
  "--prune-volumes")
    PRUNE_VOLUMES=1
    ;;
  "--help" | "-h")
    SHOW_HELP=1
    ;;
  "--verbose")
    VERBOSE=1
    ;;
  *)
    usage
    error "Unknown command line switch '${1}'."
    exit
    ;;
  esac

  shift
done

if [[ ${SHOW_HELP?} != 0 ]]; then
  usage
  exit 0
fi

pushd "${HERE?}" 2>&1 1>/dev/null

#
# Stage 0: Self-setup
#
echo "${0} - Starting at $(date +%Y-%m-%d@%H:%M:%S)" >"${LOG}"

# Fix up and sanity-check arguments
if [[ ${PRUNE_VOLUMES?} != 0 ]]; then
  KEEP_VAULT=0
fi

if [[ ${KEEP_BUILD_ARTIFACTS?} == 0 ]] && [[ ${KEEP_PRIME_CONTAINER_IMAGES} != 0 ]]; then
  # Just trying to save you some time and discomfort...
  warn "You seem to want to rebuild the product, but ${WHITE?}not${PLAIN?} the container images. Are you sure this is what you want?"
  echo -n "Enter 'YES' verbatim if this is what you really want to do: " |
    tee -a "${LOG?}"
  read __YOU_SURE_ANSWER
  echo "${__YOU_SURE_ANSWER}" >> "${LOG?}"
  if [[ "${__YOU_SURE_ANSWER}" != "YES" ]]; then
    info "wise choice"
    exit 2
  else
    info "OK then..."
  fi
fi

#
# Stage 1: clean up your environment
#
RC=0
cleanup
RC=$?
if [[ ${RC?} != 0 ]]; then
  error "The cleanup activity failed."
fi

#
# Stage 2: bring it all up again
#
if [[ ${RC?} == 0 ]]; then
  initialize
  RC=$?
fi

cat <<EOF

Your environment has been reset to as clean a slate as possible. Please run \
the following command to load your credentials:

EOF

echo -e "    \$ ${WHITE?}export \$(xargs < "${VAULT_ENV_LOCAL_FILE?}")${PLAIN?}"
echo -e "    \$ ${WHITE?}./gradlew testEnd2End${PLAIN?}\n"

popd 2>&1 1>/dev/null

exit ${RC?}
