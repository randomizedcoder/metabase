{ pkgs }:
let
  postgresql = pkgs.postgresql_17;
  # Two single quotes - defined in "..." string to avoid ''...'' escaping issues
  emptyPgStr = "''";
in
{
  inherit postgresql;

  shellHook = ''
    export PGDATA="$PWD/.pgdata"
    export PGHOST="$PWD/.pgsocket"
    export PGUSER="metabase"
    export PGDATABASE="metabase"

    mkdir -p "$PGHOST"

    if [ ! -d "$PGDATA" ]; then
      echo "Initializing PostgreSQL database..."
      initdb --encoding=UTF8 --locale=C -U metabase "$PGDATA" > /dev/null

      echo "listen_addresses = ${emptyPgStr}" >> "$PGDATA/postgresql.conf"
      echo "unix_socket_directories = '$PGHOST'" >> "$PGDATA/postgresql.conf"
    fi

    if ! pg_ctl status -D "$PGDATA" > /dev/null 2>&1; then
      pg_ctl start -D "$PGDATA" -l "$PWD/.postgres.log" -o "-k $PGHOST" -w
    fi

    if ! psql -d postgres -lqt 2>/dev/null | cut -d'|' -f1 | grep -qw metabase; then
      createdb -U metabase metabase
      if [ -f "$PWD/metabase.sql" ]; then
        echo "Loading metabase.sql..."
        psql -U metabase -d metabase -f "$PWD/metabase.sql" > /dev/null 2>&1
        echo "Database loaded."
      fi
    fi

    # Set env vars for the Python export script
    export MB_DB_HOST="$PGHOST"
    export MB_DB_PORT="5432"
    export MB_DB_DBNAME="metabase"
    export MB_DB_USER="metabase"
    export MB_DB_PASS=""

    trap 'pg_ctl stop -D "$PGDATA" -m fast 2>/dev/null || true' EXIT
  '';
}
