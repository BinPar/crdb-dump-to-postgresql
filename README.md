# CockroachDB Dump to PostgreSQL

Export your Cockroach DB structure and data to PostgreSQL format and generate a restore script
to restore de data on your PostgreSQL DB.

## Requires

- psql
- awk (gensub capable)
- node

## Env vars

ON_ERROR_STOP: Default 0. The ON_ERROR_STOP value is used in psql -v ON_ERROR_STOP=
SPLIT_INSERT: Default to 10. The maximum number of rows per INSERT INTO statement.

## Usage

Dump script:
```sh
./crdb-dump-database.sh "connectionStringCockroachDB(must include the DB to backup)" "dbName"

# Example:
./crdb-dump-database.sh "postgres://username:password@my-cockroach-db.example.com:26257/exampledb?sslmode=verify-full&sslrootcert=/path/to/ca.crt" "exampledb"
```

Restore script:
```sh
./dbname-restore.sh "connectionStringDBPostgres(must include the DB to restore in)"
# Ejemplo:
./exampledb-restore.sh "postgres://username:password@127.0.0.1:5432/exampledb"
```
