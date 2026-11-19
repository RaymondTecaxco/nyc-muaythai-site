-- Migration: create_fighters_and_records
-- Jira: KAN-44 (Fighter profiles and records)
--
-- Each coach keeps a roster of fighters, so posting a fighter later doesn't
-- mean retyping their details. A fighter's win/loss record is kept in a
-- second table, one row per fight type (smoker, amateur, pro).
--
-- Privacy: only a fighter's own coach (and the admin) can read this table
-- directly. Row-level security hides whole rows, not single columns, so if
-- every approved coach could read it, every fighter's name would be one
-- query away from their post. Other coaches will see fighter details
-- through views that leave the name out (KAN-49).


-- ---------------------------------------------------------------------------
-- 1. Let fighters point at a coach AND that coach's gym together
-- ---------------------------------------------------------------------------
-- A foreign key can point at several columns at once, but only at columns
-- that are unique together. coach.id is already unique on its own, so this
-- adds nothing new to coach; it just makes (id, gym_id) a valid target.

alter table public.coach
  add constraint coach_id_gym_id_key unique (id, gym_id);


-- ---------------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------------

create table public.fighter (
  id                   uuid primary key default gen_random_uuid(),
  -- The coach who manages this fighter. Defaults to whoever is signed in.
  coach_id             uuid not null default auth.uid(),
  -- Copied from the coach by the fighter_guard trigger below; the browser
  -- never chooses it.
  gym_id               uuid not null references public.gym (id) on delete restrict,
  display_name         text not null
                         check (length(trim(display_name)) between 1 and 80),
  sex                  text not null check (sex in ('female', 'male')),
  birth_date           date not null,
  height_in            numeric(4,1) not null,
  walk_around_lbs      numeric(5,1) not null,
  experience_level     text not null
                         check (experience_level in ('novice', 'intermediate', 'advanced')),
  stance               text check (stance in ('orthodox', 'southpaw', 'switch')),
  -- The coach confirms the fighter agreed to be listed. A fighter can't be
  -- saved without it.
  consent_confirmed    boolean not null,
  consent_confirmed_at timestamptz not null default now(),
  -- Coaches deactivate fighters instead of deleting them, so past bouts
  -- keep pointing at a real fighter.
  active               boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  -- (coach_id, gym_id) must match a real coach row, so the gym is always
  -- the coach's gym. If the admin moves a coach to a new gym, ON UPDATE
  -- CASCADE moves their fighters too. Deleting the coach deletes their
  -- fighters (and, below, their records).
  constraint fighter_coach_gym_fkey
    foreign key (coach_id, gym_id)
    references public.coach (id, gym_id)
    on update cascade
    on delete cascade,

  -- Youth fighters are not allowed. A birth date on or before "today minus
  -- 18 years" means the fighter is at least 18. Postgres only runs a CHECK
  -- when a row is written, which is safe here: someone who is 18 today is
  -- still 18 or older tomorrow, so a saved row can never become invalid.
  constraint fighter_is_adult
    check (birth_date <= (current_date - interval '18 years')::date),
  -- Catches typos such as a two-digit year.
  constraint fighter_birth_date_plausible
    check (birth_date >= date '1900-01-01'),
  constraint fighter_consent_confirmed
    check (consent_confirmed),
  -- Positive, with an upper limit that catches centimetres or kilograms
  -- typed into the wrong box.
  constraint fighter_height_positive
    check (height_in > 0 and height_in < 100),
  constraint fighter_weight_positive
    check (walk_around_lbs > 0 and walk_around_lbs < 500)
);

comment on table public.fighter is
  'Fighters on a coach''s roster. Readable only by their coach and the admin; other coaches use views that leave the name out.';
comment on column public.fighter.gym_id is
  'Always the coach''s gym: set by fighter_guard and kept in step by the (coach_id, gym_id) foreign key.';
comment on column public.fighter.consent_confirmed_at is
  'When the coach confirmed consent. Set by the database on insert.';

-- Postgres doesn't index foreign keys automatically. The first index serves
-- the (coach_id, gym_id) key and every "coach_id = me" rule below (an index
-- on two columns also works for lookups on its first column alone). The
-- second speeds up "which fighters train here?" and lets Postgres check
-- quickly whether a gym can be deleted.
create index fighter_coach_id_gym_id_idx on public.fighter (coach_id, gym_id);
create index fighter_gym_id_idx on public.fighter (gym_id);


create table public.fighter_record (
  fighter_id uuid not null references public.fighter (id) on delete cascade,
  fight_type text not null check (fight_type in ('smoker', 'amateur', 'pro')),
  wins       integer not null default 0 check (wins >= 0),
  losses     integer not null default 0 check (losses >= 0),
  draws      integer not null default 0 check (draws >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- A composite primary key: the pair (fighter, fight type) is the row's
  -- identity, so a fighter can have at most one row per fight type.
  primary key (fighter_id, fight_type)
);

comment on table public.fighter_record is
  'Win/loss/draw counts per fighter and fight type. Same visibility as fighter.';


-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------

-- Keep updated_at current (helper from migration 20261118170137).
create trigger fighter_set_updated_at
  before update on public.fighter
  for each row execute function public.set_updated_at();

create trigger fighter_record_set_updated_at
  before update on public.fighter_record
  for each row execute function public.set_updated_at();

-- Fills in the columns the database owns, and stops a coach from handing a
-- fighter to another coach.
create or replace function public.fighter_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    -- The gym always comes from the coach's own row. A coach can read their
    -- own coach row, so this works without extra privileges.
    select c.gym_id into new.gym_id
    from public.coach c
    where c.id = new.coach_id;

    new.consent_confirmed_at := now();
    return new;
  end if;

  -- Only the admin (or trusted server code, where auth.uid() is null) can
  -- move a fighter to a different coach.
  if auth.uid() is not null
     and not public.is_admin()
     and new.coach_id is distinct from old.coach_id
  then
    raise exception 'Only the admin can move a fighter to another coach'
      using errcode = '42501';  -- insufficient_privilege
  end if;

  -- Consent was confirmed once, when the fighter was added.
  new.consent_confirmed_at := old.consent_confirmed_at;
  return new;
end;
$$;

create trigger fighter_guard
  before insert or update on public.fighter
  for each row execute function public.fighter_guard();


-- ---------------------------------------------------------------------------
-- 4. Table privileges
-- ---------------------------------------------------------------------------
-- Same approach as KAN-43: start from nothing, grant what the app uses, and
-- let RLS narrow it to rows. Logged-out visitors get no access at all.

revoke all on table public.fighter, public.fighter_record from anon, authenticated;
grant select, insert, update, delete on table public.fighter, public.fighter_record to authenticated;


-- ---------------------------------------------------------------------------
-- 5. Row-level security: fighter
-- ---------------------------------------------------------------------------

alter table public.fighter enable row level security;

create policy "fighter: coach reads own fighters"
  on public.fighter for select
  to authenticated
  using (coach_id = (select auth.uid()));

create policy "fighter: admin reads all"
  on public.fighter for select
  to authenticated
  using ((select public.is_admin()));

-- Only approved coaches can add fighters, and only to their own roster.
create policy "fighter: approved coach adds own fighters"
  on public.fighter for insert
  to authenticated
  with check (
    coach_id = (select auth.uid())
    and (select public.is_approved_coach())
  );

-- Editing and deactivating (active = false) are both updates.
create policy "fighter: approved coach updates own fighters"
  on public.fighter for update
  to authenticated
  using (
    coach_id = (select auth.uid())
    and (select public.is_approved_coach())
  )
  with check (coach_id = (select auth.uid()));

create policy "fighter: admin updates all"
  on public.fighter for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- Coaches deactivate rather than delete, so past bouts keep their fighter.
create policy "fighter: admin deletes"
  on public.fighter for delete
  to authenticated
  using ((select public.is_admin()));


-- ---------------------------------------------------------------------------
-- 6. Row-level security: fighter_record
-- ---------------------------------------------------------------------------
-- A record belongs to whoever owns the fighter. The subquery reads
-- public.fighter, whose own rules (above) already limit it to the coach's
-- own fighters, so "exists" is true only for your own fighter.

alter table public.fighter_record enable row level security;

create policy "fighter_record: coach reads own"
  on public.fighter_record for select
  to authenticated
  using (
    exists (
      select 1 from public.fighter f
      where f.id = fighter_record.fighter_id
        and f.coach_id = (select auth.uid())
    )
  );

create policy "fighter_record: admin reads all"
  on public.fighter_record for select
  to authenticated
  using ((select public.is_admin()));

-- Approved coaches add, fix and remove rows for their own fighters.
create policy "fighter_record: approved coach writes own"
  on public.fighter_record for all
  to authenticated
  using (
    (select public.is_approved_coach())
    and exists (
      select 1 from public.fighter f
      where f.id = fighter_record.fighter_id
        and f.coach_id = (select auth.uid())
    )
  )
  with check (
    (select public.is_approved_coach())
    and exists (
      select 1 from public.fighter f
      where f.id = fighter_record.fighter_id
        and f.coach_id = (select auth.uid())
    )
  );

create policy "fighter_record: admin writes all"
  on public.fighter_record for all
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));
