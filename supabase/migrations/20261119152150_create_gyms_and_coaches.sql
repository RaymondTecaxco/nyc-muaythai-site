-- Gyms and coach accounts (KAN-43).
--
-- Coach email isn't stored here on purpose. It already lives in auth.users,
-- and since RLS can only hide rows, not columns, keeping it out of public
-- tables is the simplest way to make sure other coaches never see it.


-- Tables

create table public.gym (
  id              uuid primary key default gen_random_uuid(),
  name            text not null check (length(trim(name)) > 0),
  borough_or_city text not null check (length(trim(borough_or_city)) > 0),
  state           text not null check (state ~ '^[A-Z]{2}$'),
  website         text,
  instagram       text,
  -- lets a new coach read back the gym they just created, before their
  -- coach row points at it
  created_by      uuid default auth.uid() references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  -- needed to verify the gym
  constraint gym_has_website_or_instagram
    check (website is not null or instagram is not null)
);

comment on table public.gym is
  'Muay Thai gyms. One gym per coach for now. Edited only by the admin.';


create table public.coach (
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
  -- the admin account (The Kru) isn't tied to a gym
  constraint coach_needs_gym
    check (role = 'admin' or gym_id is not null),
  constraint coach_approved_has_verified_at
    check (status <> 'approved' or verified_at is not null)
);

comment on table public.coach is
  'Coach accounts, one per Supabase login. Email lives in auth.users, never here.';
comment on column public.coach.verification_checks is
  'Which checklist items passed, e.g. {"established_instagram": true, "listed_by_gym": true}. Set by the admin; the coach can read their own, so keep private notes elsewhere.';
comment on column public.coach.feature_opt_in_at is
  'Set by the database when the coach opts in; cleared when they opt out.';

-- Postgres doesn't index foreign keys on its own; the gym read policy uses this.
create index coach_gym_id_idx on public.coach (gym_id);


-- RLS helpers (also used by later migrations)

-- security definer so policies on coach can call these without recursing
-- into coach's own RLS. Empty search_path forces fully qualified names.
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

-- includes the admin
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

revoke execute on function public.is_admin() from public, anon;
revoke execute on function public.is_approved_coach() from public, anon;
grant execute on function public.is_admin() to authenticated, service_role;
grant execute on function public.is_approved_coach() to authenticated, service_role;


-- Triggers

create trigger gym_set_updated_at
  before update on public.gym
  for each row execute function public.set_updated_at();

create trigger coach_set_updated_at
  before update on public.coach
  for each row execute function public.set_updated_at();

-- RLS decides which rows a coach can update, but not which columns. This
-- trigger blocks the columns only the admin should touch and fills in the
-- timestamps the database owns.
create or replace function public.coach_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.feature_opt_in_at := case when new.feature_opt_in then now() end;
    return new;
  end if;

  -- auth.uid() is null in the SQL editor and for the service role, so those
  -- skip the checks
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

    -- name and gym were what got verified, so they lock after review
    -- (pending coaches can still fix typos)
    if old.status <> 'pending'
       and (new.name is distinct from old.name
            or new.gym_id is distinct from old.gym_id)
    then
      raise exception 'Name and gym are locked after review; ask the admin to change them'
        using errcode = '42501';
    end if;
  end if;

  if new.feature_opt_in is distinct from old.feature_opt_in then
    new.feature_opt_in_at := case when new.feature_opt_in then now() end;
  else
    new.feature_opt_in_at := old.feature_opt_in_at;
  end if;

  -- keep a verifier the admin named in the same update; otherwise use
  -- whoever is approving (or the previous one, from the SQL editor)
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


-- Privileges: nothing for anon; RLS narrows the rest

revoke all on table public.gym, public.coach from anon, authenticated;
grant select, insert, update, delete on table public.gym, public.coach to authenticated;


-- RLS: gym

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


-- RLS: coach
-- Coaches only see their own row. Other coaches come from the
-- coach_directory view.

alter table public.coach enable row level security;

create policy "coach: read own row"
  on public.coach for select
  to authenticated
  using (id = (select auth.uid()));

create policy "coach: admin reads all"
  on public.coach for select
  to authenticated
  using ((select public.is_admin()));

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

-- coach_guard limits which columns
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
