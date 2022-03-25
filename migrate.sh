#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

function help() {
  cat << EOF
Usage: $SCRIPT_NAME <command>

    --help          display this message and exit

Commands:

    initialize      create the migrations content type, to track applied migrations
                    Should only be run once for a new project, unless something funky
                    is going on
    list            view the migrations that would be run
    list-applied    list migrations have already been applied to this environment
    new <some-name> create a new migration file
    dry-run         parse and validate migrations, but do not apply
    migrate         apply migrations to this environment
    download        download the latest schema for this environment
                    Runs automatically as part of `migrate` and `new`.

expects the following environment variables:
 - CONTENTFUL_SPACE=xbjnebryrf2g
 - CONTENTFUL_ENVIRONMENT=dev
 - CONTENTFUL_MANAGEMENT_KEY=CFPAT-a7...4f

To apply a single migration, use the contentful cli directly.
EOF
  exit 0
}

function download_updated_schema() {
  contentful space export \
    --skip-content --skip-roles --skip-webhooks \
    --content-file current-schema.json \
    --export-dir $SCRIPT_DIR/migrations \
    --management-token $CONTENTFUL_MANAGEMENT_KEY \
    --space-id $CONTENTFUL_SPACE \
    --environment-id $CONTENTFUL_ENVIRONMENT
}

function new_migration() {
  readonly LATEST_NUM=$(cd $SCRIPT_DIR/migrations && ls -- *.js | cut -f1 -d- | sort | tail -n1)
  readonly NEXT_NUM=$(( $LATEST_NUM + 1))
  readonly CLEANED_FILENAME=$(echo ${2:-new-migration} | sed -E -e 's/^[0-9]+-//g' -e 's/\.js$//g')
  readonly WRITE_TO=$SCRIPT_DIR/migrations/$(printf %02d-${CLEANED_FILENAME}.js $NEXT_NUM)
  cat > $WRITE_TO << EOF
// @ts-check

/**
 * @type {import("./current-schema").ContentfulSchema}
 */
// @ts-ignore because the explicit types are more correct than TypeScript's guess
const currentSchema = require('./current-schema.json');
// The currentSchema file will be updated prior to each migration run.

/**
 * @param {import("contentful-migration").default} migration
 */
module.exports = function (migration) {
  // see https://github.com/contentful/contentful-migration/tree/master/examples
  // for migration examples
}
EOF
  download_updated_schema
  echo "Created new migration file at $WRITE_TO"
}

function initialize() {
  curl --fail --silent -H "$AUTH_HEADER" $ROOT/content_types > $tmpdir/content_types.json
  if jq -r '.items[] | .sys.id' $tmpdir/content_types.json | grep '^migrations$' > /dev/null; then
    echo "error: this environment already has a content type named 'migrations'
have you already initialized this environment, or one from which this one was forked?" >&2
    exit 4
  fi
  download_updated_schema
  contentful space migration $SCRIPT_DIR/migrations/00-initial-migration.js \
     --management-token $CONTENTFUL_MANAGEMENT_KEY \
     --space-id $CONTENTFUL_SPACE \
     --environment-id $CONTENTFUL_ENVIRONMENT \
     --yes
  record_migration 00-initial-migration.js
}

function error_usage() {
 echo "Try '$SCRIPT_NAME --help' for more information"
 exit 2
}

if [[ -z ${CONTENTFUL_SPACE-} ]]; then
  echo "error: CONTENTFUL_SPACE environment variable was not set" 1>&2
  error_usage
fi

if [[ -z ${CONTENTFUL_ENVIRONMENT-} ]]; then
  echo "error: CONTENTFUL_ENVIRONMENT environment variable was not set" 1>&2
  error_usage
fi

if [[ ${CONTENTFUL_MANAGEMENT_KEY-} =~ '^CFPAT-' ]]; then
  echo "error: CONTENTFUL_MANAGEMENT_KEY environment variable did not match pattern (make sure you're using a personal access token)" 1>&2
  error_usage
fi

for arg in "$@"; do
  case $arg in
    -h|--help)
    help

    ;;
    new)
    new_migration
    exit 0

    ;;
    download)
    download_updated_schema
    exit 0

    ;;
    initialize)
    COMMAND=initialize

    ;;
    dry-run)
    COMMAND=dry-run

    ;;
    list-applied)
    COMMAND=list-applied

    ;;
    list)
    COMMAND=list

    ;;
    migrate)
    COMMAND=migrate

    ;;
    *)
      echo "$SCRIPT_NAME: invalid option -- '$arg'"
      error_usage
  esac
done

# Make a directory for intermediate results
tmpdir=$(mktemp -d -p .)
# ensure it's removed when this script exits
trap "rm -rf $tmpdir" EXIT HUP INT TERM

if [[ -z ${COMMAND-} ]]; then
  echo "error: must specify a command"
  error_usage
fi

readonly ROOT=https://api.contentful.com/spaces/$CONTENTFUL_SPACE/environments/$CONTENTFUL_ENVIRONMENT
readonly AUTH_HEADER="Authorization: Bearer $CONTENTFUL_MANAGEMENT_KEY"

if ! curl --silent --fail -H "$AUTH_HEADER" $ROOT/locales > /dev/null ; then
  echo "error: unable to access that contentful environment using supplied credentials"
  exit 3
fi

function record_migration() {
  curl --silent --fail \
     --request POST \
     --header "$AUTH_HEADER" \
     --header 'Content-Type: application/vnd.contentful.management.v1+json' \
     --header 'X-Contentful-Content-Type: migrations' \
     --data-binary "{ \"fields\": {
       \"name\": { \"en-US\": \"$1\" },
       \"appliedAt\": { \"en-US\": \"$(date --iso-8601=seconds --utc)\" }
      } }" \
    $ROOT/entries > /dev/null
}

function list_migrations() {
  curl --silent --fail --get -H "$AUTH_HEADER" $ROOT/entries -d content_type=migrations -d select=sys.archivedAt,fields.name |
  jq -r '.items | .[] | select(.sys.archivedAt == null) | .fields.name."en-US"'
}

if [[ $COMMAND == initialize ]]; then
  initialize
  exit 0
fi


(cd $SCRIPT_DIR/migrations && ls -- *.js) | sort > $tmpdir/in_directory
list_migrations | sort > $tmpdir/already_applied
comm -13 $tmpdir/already_applied $tmpdir/in_directory > $tmpdir/to_apply

if [[ $COMMAND == list ]]; then
  cat $tmpdir/to_apply
  exit 0
elif [[ $COMMAND == list-applied ]]; then
  cat $tmpdir/already_applied
  exit 0
elif [[ $COMMAND == migrate ]]; then
  APPLY_YN=y
  if [[ $CONTENTFUL_ENVIRONMENT == "master" && -z ${CI-} ]]; then
    read -p "migrating master environment, but CI env var is not set. Are you sure (y/N)? " -n 1 -r REPLY
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
elif [[ $COMMAND == dry-run ]]; then
  APPLY_YN=n
fi

if [[ $(cat $tmpdir/to_apply | wc -l) == 0 ]]; then
  echo "Environment $CONTENTFUL_ENVIRONMENT is up to date"
  exit 0
fi
echo "Found $(cat $tmpdir/to_apply | wc -l) new migration(s)"

cat $tmpdir/to_apply | while read -r migration; do
  if [[ $APPLY_YN =~ ^[Yy]$ ]]; then
    echo "Applying $migration"
  else
    echo "Dry running $migration"
  fi
  download_updated_schema
  echo $APPLY_YN | contentful space migration $SCRIPT_DIR/migrations/$migration \
     --management-token $CONTENTFUL_MANAGEMENT_KEY \
     --space-id $CONTENTFUL_SPACE \
     --environment-id $CONTENTFUL_ENVIRONMENT
  if [[ $APPLY_YN =~ ^[Yy]$ ]]; then
    record_migration $migration
  fi
done

if [[ $APPLY_YN =~ ^[Yy]$ ]]; then
  echo -n "Successfully applied"
else
  echo -n "Successfully dry ran"
fi

echo " $(cat $tmpdir/to_apply | wc -l) migration(s)"
