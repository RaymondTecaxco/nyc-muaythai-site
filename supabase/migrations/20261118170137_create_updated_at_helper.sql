-- Shared trigger function: every matchmaker table attaches it as a
-- before-update trigger to keep updated_at current.

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
