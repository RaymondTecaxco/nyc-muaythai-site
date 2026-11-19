-- Migration: create_gyms_and_coaches
-- Jira: KAN-43 (Gyms and coach accounts)
--
-- The first matchmaker tables. Every coach belongs to a gym and has a
-- verification status, so only coaches the admin has approved can use the
-- matchmaker. Security rules ship in the same file as the tables.
--
-- Email is deliberately NOT stored here. It already lives in auth.users,
-- which the browser can't query. Row-level security hides whole rows, not
-- single columns, so leaving email out of public tables is the surest way to
-- keep it away from other coaches.


-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

create table public.gym (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(trim(name)) > 0),
  borough_or_city text not null check (length(trim(borough_or_city)) > 0),
  state           text not null check (state ~ '^[A-Z]{2}$'),
  website         text,
  instagram       text,
  -- Who added the gym. Lets a coach read back the gym they just created at
  -- sign-up, before their coach row points at it.
  created_by      uuid default auth.uid() references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- The admin verifies a gym through its website or Instagram, so we need one.
  constraint gym_has_website_or_instagram
    check (website is not null or instagram is not null)
);

comment on table public.gym is
  'Muay Thai gyms. One gym per coach for now. Edited only by the admin.';


create table public.coach (
  -- Same id as the coach's Supabase login. Deleting the login deletes the coach.
  id                  uuid primary key references auth.users (id) on delete cascade,
  gym_id              uuid references public.gym (id) on delete restrict,
  name                text not null check (length(trim(name)) > 0),
  role                text not null default 'coach'
                        check (role in ('coach', 'admin')),
  status              text not null default 'pending'
                        check (status in ('pending', 'approved', 'rejected', 'suspended')),
  verified_by         uuid references public.coach (id) on delete set null,
  verified_at         timestamptz,
  verification_checks jsonb not null default '{}'::jsonb
                        check (jsonb_typeof(verification_checks) = 'object'),
  feature_opt_in      boolean not null default false,
  feature_opt_in_at   timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  -- Every coach needs a gym; the admin (The Kru) doesn't belong to one.
  constraint coach_needs_gym
    check (role = 'admin' or gym_id is not null),
  -- An approved coach always has an approval time.
  constraint coach_approved_has_verified_at
    check (status <> 'approved' or verified_at is not null)
);

comment on table public.coach is
  'Coach accounts, one per Supabase login. Email lives in auth.users, never here.';
comment on column public.coach.verification_checks is
  'Which checklist items passed, e.g. {"established_instagram": true, "listed_by_gym": true}. Set by the admin; the coach can read their own, so keep private notes elsewhere.';
comment on column public.coach.feature_opt_in_at is
  'Set by the database when the coach opts in; cleared when they opt out.';

-- Postgres doesn't index foreign keys automatically. This speeds up
-- "which coaches are at this gym?" and the gym read rule below.
create index coach_gym_id_idx on public.coach (gym_id);


-- ---------------------------------------------------------------------------
-- 2. Helper functions for security rules (reused by later migrations)
-- ---------------------------------------------------------------------------

-- True when the signed-in user is an approved admin.
-- security definer: runs with the owner's rights, so it can read public.coach
--   even though RLS is on. Without it, a coach rule that calls is_admin()
--   would trigger the same rule again (infinite recursion).
-- set search_path = '': names must be fully qualified (public.coach,
--   auth.uid()), so nobody can trick the function with a look-alike table.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.coach
    where id = auth.uid()
      and role = 'admin'
      and status = 'approved'
  );
$$;

-- True when the signed-in user is an approved coach (the admin counts too,
-- because the admin can do everything a coach can).
create or replace function public.is_approved_coach()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.coach
    where id = auth.uid()
      and status = 'approved'
  );
$$;

comment on function public.is_admin() is
  'RLS helper: true if the current user is an approved admin.';
comment on function public.is_approved_coach() is
  'RLS helper: true if the current user is an approved coach or admin.';

-- Logged-out visitors (anon) never need these.
revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.is_approved_coach() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;
grant execute on function public.is_approved_coach() to authenticated, service_role;


-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------

-- Keep updated_at current (helper from migration 20261118170137).
create trigger gym_set_updated_at
  before update on public.gym
  for each row execute function public.set_updated_at();

create trigger coach_set_updated_at
  before update on public.coach
  for each row execute function public.set_updated_at();

-- RLS can say WHICH rows a coach may update, but not WHICH COLUMNS changed.
-- This trigger compares the old and new row and refuses changes a coach
-- isn't allowed to make. It also fills in the timestamps the database owns.
create or replace function public.coach_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The opt-in time always comes from the database, never the browser.
  if tg_op = 'INSERT' then
    new.feature_opt_in_at := case when new.feature_opt_in then now() end;
    return new;
  end if;

  -- auth.uid() is null for the SQL editor and the service role (trusted
  -- server code), so only signed-in, non-admin users are checked.
  if auth.uid() is not null and not public.is_admin() then
    if new.role                is distinct from old.role
       or new.status              is distinct from old.status
       or new.verified_by         is distinct from old.verified_by
       or new.verified_at         is distinct from old.verified_at
       or new.verification_checks is distinct from old.verification_checks
    then
      raise exception 'Only the admin can change role, status or verification fields'
        using errcode = '42501';  -- insufficient_privilege
    end if;

    -- Name and gym were checked during verification, so they lock once the
    -- admin has reviewed the coach. A pending coach can still fix typos.
    if old.status <> 'pending'
       and (new.name is distinct from old.name
            or new.gym_id is distinct from old.gym_id)
    then
      raise exception 'Name and gym are locked after review; ask the admin to change them'
        using errcode = '42501';
    end if;
  end if;

  -- Opting in stamps the time; opting out clears it; otherwise keep it.
  if new.feature_opt_in is distinct from old.feature_opt_in then
    new.feature_opt_in_at := case when new.feature_opt_in then now() end;
  else
    new.feature_opt_in_at := old.feature_opt_in_at;
  end if;

  -- Approving a coach records when, and who. If the admin named a verifier
  -- in the same update, keep it; otherwise it's whoever is approving now
  -- (or the previous verifier, when approving from the SQL editor).
  if new.status = 'approved' and old.status is distinct from 'approved' then
    new.verified_at := now();
    if new.verified_by is not distinct from old.verified_by then
      new.verified_by := coalesce(auth.uid(), old.verified_by);
    end if;
  end if;

  return new;
end;
$$;

create trigger coach_guard
  before insert or update on public.coach
  for each row execute function public.coach_guard();


-- ---------------------------------------------------------------------------
-- 4. Table privileges
-- ---------------------------------------------------------------------------
-- Start from nothing, then grant only what the app uses. Logged-out visitors
-- get no access at all. RLS below then narrows these to specific rows.

revoke all on table public.gym, public.coach from anon, authenticated;
grant select, insert, update, delete on table public.gym, public.coach to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Row-level security: gym
-- ---------------------------------------------------------------------------

alter table public.gym enable row level security;

create policy "gym: approved coaches read all"
  on public.gym for select
  to authenticated
  using ((select public.is_approved_coach()));

create policy "gym: pending coach reads own gym"
  on public.gym for select
  to authenticated
  using (
    created_by = (select auth.uid())
    or id in (select c.gym_id from public.coach c where c.id = (select auth.uid()))
  );

create policy "gym: signed-in users add gyms at sign-up"
  on public.gym for insert
  to authenticated
  with check (created_by = (select auth.uid()));

create policy "gym: admin updates"
  on public.gym for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

create policy "gym: admin deletes"
  on public.gym for delete
  to authenticated
  using ((select public.is_admin()));


-- ---------------------------------------------------------------------------
-- 6. Row-level security: coach
-- ---------------------------------------------------------------------------
-- Coaches read only their own row. Other coaches' names for the directory
-- and offers will come from a view that leaves out admin-only columns.

alter table public.coach enable row level security;

create policy "coach: read own row"
  on public.coach for select
  to authenticated
  using (id = (select auth.uid()));

create policy "coach: admin reads all"
  on public.coach for select
  to authenticated
  using ((select public.is_admin()));

-- Sign-up: you can create only your own row, and only as a pending coach.
create policy "coach: create own pending row"
  on public.coach for insert
  to authenticated
  with check (
    id = (select auth.uid())
    and role = 'coach'
    and status = 'pending'
    and verified_by is null
    and verified_at is null
    and verification_checks = '{}'::jsonb
  );

-- A coach may update their own row; coach_guard limits which columns.
create policy "coach: update own row"
  on public.coach for update
  to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy "coach: admin updates all"
  on public.coach for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

create policy "coach: admin deletes"
  on public.coach for delete
  to authenticated
  using ((select public.is_admin()));
