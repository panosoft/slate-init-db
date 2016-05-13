CREATE FUNCTION events_notify_trigger()
	RETURNS trigger AS $$
DECLARE
BEGIN
	PERFORM pg_notify('eventsinsert', json_build_object('table', TG_TABLE_NAME, 'id', NEW.id )::text);
	RETURN new;
END;
$$ LANGUAGE plpgsql;