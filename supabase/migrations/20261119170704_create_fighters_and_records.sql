-- Fighter rosters and records (KAN-44).
--
-- Only a fighter's own coach and the admin can read these tables. Other
-- coaches get fighter details through views that leave the name out (KAN-49),
-- since RLS can't hide a single column.


-- Composite FK target, so fighter can reference (coach_id, gym_id) together.
-- coach.id is already unique; this just makes the pair a valid target.

alter table public.coach
  add constraint coach_id_gym_id_key unique (id, gym_id);


-- Tables

create table public.fighter (
  id                   uuid primary key default gen_random_uuid(),
  coach_id             uuid not null default auth.uid(),
  -- set by fighter_guard from the coach's row, never by the client
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
  consent_confirmed    boolean not null,
  consent_confirmed_at timestamptz not null default now(),
  -- deactivate instead of deleting so past bouts keep their fighter
  active               boolean not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),

  -- keeps gym_id in sync with the coach's gym, including when the admin
  -- moves a coach to a new gym
  constraint fighter_coach_gym_fkey
    foreign key (coach_id, gym_id)
    references public.coach (id, gym_id)
    on update cascade
    on delete cascade,

  -- 18+ only. Safe as a CHECK because someone who passes today still
  -- passes tomorrow.
  constraint fighter_is_adult
    check (birth_date <= (current_date - interval '18 years')::date),
  -- catches two-digit years
  constraint fighter_birth_date_plausible
    check (birth_date >= date '1900-01-01'),
  constraint fighter_consent_confirmed
    check (consent_confirmed),
  -- upper bounds catch cm or kg typed into the wrong field
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

-- The first index also covers coach_id-only lookups in the policies below.
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
  -- one row per fighter per fight type
  primary key (fighter_id, fight_type)
);

comment on table public.fighter_record is
  'Win/loss/draw counts per fighter and fight type. Same visibility as fighter.';


-- Triggers

create trigger fighter_set_updated_at
  before update on public.fighter
  for each row execute function public.set_updated_at();

create trigger fighter_record_set_updated_at
  before update on public.fighter_record
  for each row execute function public.set_updated_at();

create or replace function public.fighter_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    select c.gym_id into new.gym_id
    from public.coach c
    where c.id = new.coach_id;

    new.consent_confirmed_at := now();
    return new;
  end if;

  -- only the admin (or server code, where auth.uid() is null) can move a
  -- fighter to another coach
  if auth.uid() is not null
     and not public.is_admin()
     and new.coach_id is distinct from old.coach_id
  then
    raise exception 'Only the admin can move a fighter to another coach'
      using errcode = '42501';  -- insufficient_privilege
  end if;

  new.consent_confirmed_at := old.consent_confirmed_at;
  return new;
end;
$$;

create trigger fighter_guard
  before insert or update on public.fighter
  for each row execute function public.fighter_guard();


-- Privileges

revoke all on table public.fighter, public.fighter_record from anon, authenticated;
grant select, insert, update, delete on table public.fighter, public.fighter_record to authenticated;


-- RLS: fighter

alter table public.fighter enable row level security;

create policy "fighter: coach reads own fighters"
  on public.fighter for select
  to authenticated
  using (coach_id = (select auth.uid()));

create policy "fighter: admin reads all"
  on public.fighter for select
  to authenticated
  using ((select public.is_admin()));

create policy "fighter: approved coach adds own fighters"
  on public.fighter for insert
  to authenticated
  with check (
    coach_id = (select auth.uid())
    and (select public.is_approved_coach())
  );

-- covers deactivating too (active = false)
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

create policy "fighter: admin deletes"
  on public.fighter for delete
  to authenticated
  using ((select public.is_admin()));


-- RLS: fighter_record
-- Ownership goes through fighter, whose own policies already limit the
-- subquery to the coach's fighters.

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
