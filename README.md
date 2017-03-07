# slate-init-db
Creates and initializes a Postgresql database for use by Slate applications.

The purpose of slate-init-db is to create and initialize a new `Postgresql` database to contain either a `source` or `destination` events table (see [`Database Initialization`](#database-initialization)).

slate-init-db requires the `Postgresql contrib` package be installed on the `source` database server when initializing a `source` database so that the `dblink` extension can be installed (see [`Source Database Disaster Recovery`](#source-database-disaster-recovery)).

# Installation
> npm install -g @panosoft/slate-init-db

# Usage

#### Run slate-init-db

    slate-init-db [options]

    Options:

      -h, --help                               output usage information
      --host <name>                            database server name
      --user <name>                            database user name.  must have database creation privileges.  if not specified, prompt for user name.
      --password <password>                    database password.  if not specified, prompt for password.
      --connect-timeout <millisecs>            database connection timeout.  if not specified, defaults to 15000 millisecs.
      -n, --new-database <name>                name of database to create
      -t, --table-type <source | destination>  type of events table to create in new database:  must be "source"  or "destination"
      --dry-run                                if specified, display run parameters and end program without performing database initialization

# Operations
### Start up validations
- Run options are validated
- Database to be created must NOT exist and its name must be a valid `Postgresql` identifier
- If `slate-init-db` is started in `--dry-run` mode then it will validate and display run options without performing database initialization
- All start up information and any options errors are logged

### Error Recovery
- All operational errors will be logged
- If errors are reported when running `slate-init-db` then the new database was not initialized properly and MUST be deleted manually before re-running

# Database Initialization
Initialization differs depending on the `table-type`.

When creating a `source` database, the following source-only database objects are created: an `id` table, an `insert_events` function, a `restore_events` function, an `events` table NOTIFY trigger and its trigger function, and an `events` table COMMAND CHECK trigger and it trigger function.

The `id` table in a `source` database is used to assign ids to the rows as they are inserted into the `events` table by the `insert_events` function. The ids start at 1 and are guaranteed to be consecutive.

The `id` and `ts` column values in a `source` events table row are generated by the `insert_events` function. This means that the singleton `source` database is the master clock for all events.

The `restore_events` function is used to perform `source` database disaster recovery (see [`Source Database Disaster Recovery`](#source-database-disaster-recovery)).

## Database Initialization Details

### Source and Destination

```sql
--create events table

CREATE TABLE events
(
  id bigint NOT NULL,
  ts timestamp with time zone NOT NULL,
  event jsonb NOT NULL,
  CONSTRAINT events_pkey PRIMARY KEY (id)
)
WITH (
  OIDS=FALSE
);

--create events table indexes

CREATE INDEX events_event_target on events ((event #>> '{target}'));

CREATE INDEX events_event_operation on events ((event #>> '{operation}'));

CREATE INDEX events_event_propertyname on events ((event #>> '{propertyName}'));

CREATE INDEX events_ts on events (ts);

CREATE INDEX events_event_entityid on events ((event #>> '{entityId}'));
```

### Source ONLY

#### Events Table NOTIFY trigger and trigger function (the trigger and trigger function do not exist in a destination database)

```sql
--create NOTIFY trigger function

CREATE FUNCTION notify_event_insert() RETURNS trigger AS $$
DECLARE
BEGIN
  PERFORM pg_notify('eventsinsert', json_build_object('table', TG_TABLE_NAME, 'id', NEW.id, 'event', NEW.event )::text);
  RETURN new;
END;
$$ LANGUAGE plpgsql;

--create NOTIFY trigger

CREATE TRIGGER notify_insert AFTER INSERT ON events
FOR EACH ROW EXECUTE PROCEDURE notify_event_insert();
```

#### Events Table COMMAND CHECK trigger and trigger function (the trigger and trigger function do not exist in a destination database)

```sql
--create COMMAND CHECK trigger function

CREATE FUNCTION filter_sql_command()
	RETURNS TRIGGER as $$
BEGIN
	RAISE EXCEPTION 'cannot perform SQL command on events table:  %', TG_OP;
END;
$$ LANGUAGE plpgsql;

--create COMMAND CHECK trigger

CREATE TRIGGER check_sql_command BEFORE UPDATE OR DELETE OR TRUNCATE ON events
FOR EACH STATEMENT EXECUTE PROCEDURE filter_sql_command();
```

#### ID Table Initialization (this table does not exist in a destination database)

```sql
CREATE TABLE id (
  id bigint NOT NULL,
  CONSTRAINT id_pkey PRIMARY KEY (id))
WITH (
  OIDS=FALSE
);
```
#### insert_events function (this function does not exist in a destination database)

```sql
CREATE FUNCTION insert_events(insertValues text)
	RETURNS integer AS $$
DECLARE
	ts timestamp with time zone;
	startId bigint;
	nextStartId bigint;
	idxs bigint[];
	ids bigint[];
	lastIdx integer;
	idx bigint;
	rowsInserted bigint;
	countRows bigint;
	maxIndex bigint;
	tsMatches text[];
BEGIN
	LOCK TABLE ID IN ACCESS EXCLUSIVE MODE;
	-- get timestamp to insert in each ts column
	ts := transaction_timestamp();
	-- insertValues is a string value that represents the column values to insert for one or more rows for one INSERT statement.
	-- insertValues is formatted to follow the VALUES keyword of the statement "INSERT INTO events (id, ts, event) VALUES "
	-- (e.g. '($1[1], $2, '<json string for event>'), ($1[2], $2, '<json string for event>')'.
	-- The id column for each row to insert is formatted as a substitution parameter, $1[x], where x is an index value.
	-- index values start at 1 for the first row to insert and must be a consecutive positive integer for each additional row.
	-- The ts (event timestamp) column is generated by this function and is represented  by the parameter $2.

	SELECT ARRAY(SELECT unnest(regexp_matches(insertValues, '\$1\[([0-9]+)\]', 'g'))) into idxs;
	SELECT ARRAY(SELECT unnest(regexp_matches(insertValues, '(\$2),', 'g'))) into tsMatches;
	countRows := 0;
	lastIdx := 0;
	-- find the row count, maximum index for a row, and check that the indices are consecutive positive integers.
	FOREACH idx IN ARRAY idxs
	LOOP
		countRows := countRows + 1;
		IF lastIdx = 0 THEN
			lastIdx := idx;
		ELSE
			IF idx = lastIdx + 1 THEN
				lastIdx := idx;
				maxIndex := idx;
			ELSE
				RAISE EXCEPTION 'Parameter index is not consecutive at ------> %,  previous index ------> %', idx, lastIdx
					USING HINT = 'Parameter for id column of the form "$1[x]" where x is the 1-based index for the row to be inserted is not greater than the previous row''s index';
			END IF;
		END IF;
	END LOOP;
	IF countRows < 1 THEN
		RAISE EXCEPTION 'No inserted rows found with id substitution parameters' USING HINT = 'id column substitution parameter value for row to be inserted must be of the form "$1[x]" where x is the 1-indexed based index of the row';
	END IF;
	IF countRows != maxIndex THEN
		RAISE EXCEPTION 'Number of rows to be inserted (%) does not match the highest row index (%)', countRows, maxIndex USING HINT = 'The highest id column parameter substitution parameter index value does not match the number of rows to be inserted';
	END IF;
	IF countRows != coalesce(array_length(tsMatches, 1), 0) THEN
		RAISE EXCEPTION 'Number of rows to be inserted (%) does not match number of rows with a ts substitution parameter (%)', countRows, coalesce(array_length(tsMatches, 1), 0) USING HINT = 'ts column parameter substitution value for row to be inserted must be "$2"';
	END IF;

	-- update id table to point to the next starting id value to use
	UPDATE id SET id = id + countRows RETURNING id INTO nextStartId;
	-- start id for first insert statement
	startId := nextStartId - countRows;
	-- get ids to use for each inserted row's id column
	SELECT into ids ARRAY(SELECT generate_series(startId, nextStartId - 1));
	-- RAISE NOTICE 'ids ----> %', ids;
	EXECUTE 'INSERT INTO events (id, ts, event) VALUES ' || insertValues USING ids, ts;
	GET DIAGNOSTICS rowsInserted = ROW_COUNT;
	RETURN rowsInserted;
END;
$$ LANGUAGE plpgsql;
```
#### restore_events function (this function does not exist in a destination database)

```sql
CREATE FUNCTION restore_events(fromHost text, fromDatabase text, fromDatabaseUser text, fromDatabasePassword text, OUT rows_restored bigint, OUT next_insert_id bigint)
	AS $$
DECLARE
	getEventsStmt CONSTANT text = 'SELECT id, ts, event FROM events ORDER BY id';
	getCountMaxIdStmt CONSTANT text = 'SELECT MAX(id) AS maxid, count(*) AS count FROM events';
	connectionInfo text;
	sourceEventsCount bigint;
	sourceEventsMaxId bigint;
	sourceNextIdValue bigint;
	fromEventsCount bigint;
	fromEventsMaxId bigint;
BEGIN
	connectionInfo := 'host=' || fromHost || ' dbname=' || fromDatabase || ' user=' || fromDatabaseUser || ' password=' || fromDatabasePassword;
	-- get row count from Source events table.  must be 0 after being created by slate-init-db.
	SELECT count(*) from events into sourceEventsCount;
	IF sourceEventsCount != 0 THEN
		RAISE EXCEPTION 'Source events table row count (%) is not 0', sourceEventsCount USING HINT = 'The Source events database must be initialized with slate-init-db';
	END IF;
	-- get next event id from id table.  must be 1 after being created by slate-init-db.
	SELECT id from id into sourceNextIdValue;
	IF sourceNextIdValue != 1 THEN
		RAISE EXCEPTION 'Source id table id value (%) is not 1', sourceNextIdValue USING HINT = 'The Source events database must be initialized with slate-init-db';
	END IF;
	-- get maximum event id and row count from events table in remote database being used to restore the Source events table.
	-- maximum event id must be 1 or greater and equal to the row count.
	SELECT fe.maxid, fe.count FROM dblink(connectionInfo, getCountMaxIdStmt) AS fe(maxid bigint, count bigint) INTO fromEventsMaxId, fromEventsCount;
	IF fromEventsMaxId IS NULL OR fromEventsMaxId < 1 THEN
		RAISE EXCEPTION 'The from events table maximum id value (%) is not 1 or greater', fromEventsMaxId USING HINT = 'The events table used to restore the Source events table must have a maximum id value of 1 or greater';
	END IF;
	IF fromEventsCount != fromEventsMaxId THEN
		RAISE EXCEPTION 'The from events table row count (%) is not equal to the from events table maximum id (%)', fromEventsCount, fromEventsMaxId USING HINT = 'The events table used to restore the Source events table is not valid';
	END IF;
	-- copy the events in order by id from the remote events table to the Source events table.
	INSERT INTO events (id, ts, event)
		SELECT fe.id, fe.ts, fe.event
			FROM dblink(connectionInfo, getEventsStmt)
			AS fe(id bigint, ts timestamp with time zone, event jsonb);
	GET DIAGNOSTICS rows_restored = ROW_COUNT;
	SELECT MAX(id), count(*) FROM events INTO sourceEventsMaxId, sourceEventsCount;
	IF sourceEventsCount != sourceEventsMaxId THEN
		RAISE EXCEPTION 'The Source events table row count (%) is not equal to the Source events table maximum id (%)', sourceEventsCount, sourceEventsMaxId USING HINT = 'The restored Source events table is not valid';
	END IF;
	IF sourceEventsCount != rows_restored THEN
		RAISE EXCEPTION 'The Source events table row count (%) is not equal to the Source events table rows restored (%)', sourceEventsCount, rows_restored USING HINT = 'The Source events table restore had a program logic error';
	END IF;
	-- update the id value in the Source id table to the maximum id value + 1 from the remote events table used to restore the Source events table.
	UPDATE id SET id = sourceEventsMaxId + 1 RETURNING id INTO next_insert_id;
	-- the count of events copied to the Source events table and the next events table id value to be used for the next event inserted into the Source events table are returned.
END;
$$ LANGUAGE plpgsql;
```

# Source Database Disaster Recovery

If a `source` database disaster occurs, the `source` database tables can be restored using the `restore_events` function residing in the `source` database.

To run the `restore_events` function, the `Postgresql contrib` package must be installed on the database server where the `source` database resides.

The `dblink` extension from the `Postgresql contrib` package must be installed into the `source` database.  This extension is installed by `slate-init-db` when a `source` database is initialized.

An online backup database is required to perform the disaster recovery procedure.

One or more online backup databases can be created by using the `slate-replicator`.  For further information, please see refer to [`slate-replicator`](https://github.com/panosoft/slate-replicator).

## Source Database Recovery Steps
- Stop any programs using the `source` database and drop any connections to it
- Stop any programs modifying the backup database
- Delete the `source` database being recovered (if it still exists and is corrupt)
- Create and initialize a new `source` database using `slate-init-db`
- Run the `restore_events` function with parameters pointing to the online backup database while connected to the newly initialized `source` database
- Optionally use the eventsDiff program in the `slate-replicator` project to compare the restored `source` database events table with the backup database events table

### Running the restore_events Function

In order to recover the `source` database from the backup database, run the SQL statement below while connected to the `source` database substituting the appropriate parameters for the backup database.

```sql
--restore the source database from a backup database on host 'backupDatabaseHostName' using database 'backupDatabaseName' accessed with database user 'backupDatabaseUser' and password 'backupDatabasePassword'

SELECT restore_events(fromHost := 'backupDatabaseHostName', fromDatabase := 'backupDatabaseName', fromDatabaseUser := 'backupDatabaseUser', fromDatabasePassword := 'backupDatabasePassword');
```

If there are any errors running the `restore_events` events function, then the cause of the errors must be corrected and the Recovery Steps need to be performed again **from the beginning**.
