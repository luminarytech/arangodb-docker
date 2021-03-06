#!/bin/bash
set -eo pipefail

AUTHENTICATION="false"

# if command starts with an option, prepend arangod
if [ "${1:0:1}" = '-' ]; then
	set -- arangod "$@"
fi


if [ "$1" = 'arangod' ]; then
        mkdir -p /var/lib/arangodb3
        mkdir -p /var/lib/arangodb3-apps
        
        # by doing this here we explicitly break support for mounting volumes from the mac (at least for docker pre 1.11)
        # but otherwise there will be too many problems like this https://github.com/arangodb/arangodb-docker/issues/23
        # mysql as well as postgres are doing it exactly like this so stick to this
        chown -R arangodb /var/lib/arangodb3
        chown -R arangodb /var/lib/arangodb3-apps

	if [ ! -f /var/lib/arangodb3/SERVER ]; then
		if [ -z "$ARANGO_ROOT_PASSWORD" -a -z "$ARANGO_NO_AUTH" -a -z "$ARANGO_RANDOM_ROOT_PASSWORD" ]; then
			echo >&2 'error: database is uninitialized and password option is not specified '
			echo >&2 '  You need to specify one of $ARANGO_ROOT_PASSWORD, $ARANGO_NO_AUTH and $ARANGO_RANDOM_ROOT_PASSWORD'
			exit 1
		fi
                
                echo "Initializing database...Hang on..."
                if [ ! -z "$ARANGO_RANDOM_ROOT_PASSWORD" ]; then
                  ARANGO_ROOT_PASSWORD=$(pwgen -s -1 16)
                  echo "==========================================="
                  echo "GENERATED ROOT PASSWORD: $ARANGO_ROOT_PASSWORD"
                  echo "==========================================="
                fi
                
                "$@" --server.authentication false --server.endpoint=tcp://127.0.0.1:8529 --log.output file:///tmp/init-log &>/dev/null &
		pid="$!"
                
                counter=0
                ARANGO_UP=0
                while [ "$ARANGO_UP" = "0" ];do
                  if [ $counter -gt 0 ];then
                    sleep 1
                  fi

                  if [ "$counter" -gt 100 ];then
                    echo "ArangoDB didn't start correctly during init"
                    cat /tmp/init-log
                    exit 1
                  fi
                  let counter=counter+1
                  ARANGO_UP=1
                  curl -s localhost:8529/_api/version &>/dev/null || ARANGO_UP=0
                done

                if [ ! -z "$ARANGO_ROOT_PASSWORD" ]; then
                  (
                    echo "require(\"org/arangodb/users\").replace(\"root\", \"$ARANGO_ROOT_PASSWORD\");"
                  ) | arangosh &>/dev/null
                  AUTHENTICATION="true"
                fi

                echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)     echo "$0: running $f"; . "$f" ;;
				*.js)     echo "$0: running $f"; arangosh --javascript.execute "$f" ;;
				*/dumps)    echo "$0: restoring databases"; for d in $f/*; do echo "restoring $d";arangorestore --server.endpoint=tcp://127.0.0.1:8529 --create-database true --include-system-collections true --input-directory $d; done; echo ;;
			esac
		done
		if ! kill -s TERM "$pid" || ! wait "$pid"; then
                  echo >&2 'ArangoDB Init failed.'
                  exit 1
		fi
	fi
fi

if [ "$1" == "arangod" ]; then
  # if we really want to start arangod and not bash or any other thing
  # prepend --authentication as the FIRST argument
  # (so it is overridable via command line as well)
  shift
  set -- arangod --server.authentication="$AUTHENTICATION" "$@"
fi

exec "$@"
