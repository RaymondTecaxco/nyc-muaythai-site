-- Migration: create_updated_at_helper
-- Jira: KAN-42 (Set up database migrations)
--
-- A shared helper that every matchmaker table will use. Whenever a row is
-- updated, it stamps the row's updated_at column with the current time, so
-- we always know when a coach profile, post or bout last changed.
--
-- It is a trigger function: Postgres runs it automatically "before update"
-- on any table that attaches it with a trigger (added in later migrations).

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Trigger helper: sets updated_at to now() before each row update.';
