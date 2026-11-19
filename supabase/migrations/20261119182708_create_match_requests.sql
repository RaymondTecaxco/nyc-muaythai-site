-- Migration: create_match_requests
-- Jira: KAN-45 (Posts / match requests)
--
-- A post puts one of a coach's fighters on the board, in one of two kinds:
--   * seeking:   "I need a match for this fighter."    Expires after 21 days.
--   * available: "My fighter is ready, maybe on short notice." Expires after 14.
-- Every post gives a weight range; the exact weight is agreed later and saved
-- on the bout. A fighter can have only one open post at a time.
--
-- The table is called match_request (the spec's name); "post" is what the
-- pages call it. The spec's experience_wanted, intensity, rules and gear
-- fields are left out: coaches don't use them when finding bouts.


-- ---------------------------------------------------------------------------
-- 1. Let posts point at a fighter AND that fighter's coach together
-- ---------------------------------------------------------------------------
-- Same idea as fighter -> coach in KAN-44: (id, coach_id) becomes a valid
-- target for a two-column foreign key, so a post's coach_id must be the
-- fighter's own coach. A coach can't post someone else's fighter.

alter table public.fighter
  add constraint fighter_id_coach_id_key unique (id, coach_id);


-- ---------------------------------------------------------------------------
-- 2. Table
-- ---------------------------------------------------------------------------

create table public.match_request (
  id               uuid primary key default gen_random_uuid(),
  coach_id         uuid not null default auth.uid()
                     references public.coach (id) on delete cascade,
  fighter_id       uuid not null,
  kind             text not null check (kind in ('seeking', 'available')),
  -- Defaults to the fighter's bout type (filled in by the trigger), but a
  -- coach can change it, e.g. a smoker fighter looking for a first amateur bout.
  bout_type        text not null check (bout_type in ('smoker', 'amateur')),
  weight_min       numeric(5,1) not null,
  weight_max       numeric(5,1) not null,
  earliest_date    date,
  latest_date      date,
  travel_radius_mi integer check (travel_radius_mi > 0 and travel_radius_mi <= 3000),
  short_notice     boolean not null default false,
  event_name       text check (length(event_name) <= 200),
  status           text not null default 'open'
                     check (status in ('open', 'in_talks', 'matched', 'closed', 'expired')),
  -- Set by the database from the kind; never by the browser.
  expires_at       timestamptz not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- The post's coach must be the fighter's coach. ON UPDATE CASCADE: if the
  -- admin moves a fighter to another coach, their posts move too.
  constraint match_request_fighter_coach_fkey
    foreign key (fighter_id, coach_id)
    references public.fighter (id, coach_id)
    on update cascade
    on delete cascade,

  constraint match_request_weight_positive
    check (weight_min > 0 and weight_max < 500),
  constraint match_request_weight_range
    check (weight_min <= weight_max),
  -- A CHECK passes when either side is null, so open-ended dates are fine.
  constraint match_request_date_range
    check (earliest_date <= latest_date),
  -- Short notice only makes sense for "my fighter is available".
  constraint match_request_short_notice_available_only
    check (kind = 'available' or not short_notice)
);

comment on table public.match_request is
  'Posts: one fighter seeking an opponent or listed as available. Approved coaches read open posts; only the owner edits or closes.';
comment on column public.match_request.status is
  'open -> in_talks -> matched, or closed by the coach, or expired. open and in_talks both count as an open post.';
comment on column public.match_request.expires_at is
  'Set on insert: 21 days for seeking, 14 for available. Read with expires_at > now(); a post past this time is treated as expired even before its status says so.';


-- ---------------------------------------------------------------------------
-- 3. Indexes
-- ---------------------------------------------------------------------------

-- One open post per fighter. A partial unique index only includes rows that
-- match its WHERE clause, so closed, matched and expired posts don't count
-- and a fighter can be posted again later.
-- The WHERE clause can't mention now(): an index condition must give the same
-- answer every time it's checked. That's why expiry is a status change
-- (see match_request_before_insert below) and not just a time.
create unique index match_request_one_open_per_fighter
  on public.match_request (fighter_id)
  where status in ('open', 'in_talks');

-- Foreign keys aren't indexed automatically.
create index match_request_fighter_id_coach_id_idx on public.match_request (fighter_id, coach_id);
create index match_request_coach_id_idx on public.match_request (coach_id);

-- The feed: open posts, soonest-expiring first.
create index match_request_open_feed_idx
  on public.match_request (expires_at)
  where status in ('open', 'in_talks');


-- ---------------------------------------------------------------------------
-- 4. Triggers
-- ---------------------------------------------------------------------------

create trigger match_request_set_updated_at
  before update on public.match_request
  for each row execute function public.set_updated_at();

-- New posts: fill in the columns the database owns.
create or replace function public.match_request_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_active    boolean;
  v_bout_type text;
begin
  select f.active, f.bout_type into v_active, v_bout_type
  from public.fighter f
  where f.id = new.fighter_id;

  if v_active is false then
    raise exception 'This fighter is deactivated; reactivate them before posting'
      using errcode = '23514';  -- check_violation
  end if;

  new.bout_type  := coalesce(new.bout_type, v_bout_type);
  new.status     := 'open';
  -- The "else" never applies to a real post: an unknown kind is refused by
  -- the kind CHECK. Without it the CASE would give null, and Postgres checks
  -- NOT NULL before CHECK, so the coach would see a confusing expires_at error.
  new.expires_at := now() + case new.kind
                              when 'seeking'   then interval '21 days'
                              when 'available' then interval '14 days'
                              else interval '0 days'
                            end;

  if new.latest_date < current_date then
    raise exception 'The latest date is already in the past'
      using errcode = '23514';
  end if;

  -- A previous post for this fighter may be past its expiry time while its
  -- status still says open (nothing has marked it yet). Mark it expired now
  -- so it doesn't block the new post through the one-open-post index.
  update public.match_request
  set status = 'expired'
  where fighter_id = new.fighter_id
    and status in ('open', 'in_talks')
    and expires_at <= now();

  return new;
end;
$$;

create trigger match_request_before_insert
  before insert on public.match_request
  for each row execute function public.match_request_before_insert();

-- Edits: RLS decides WHO can update a post; this decides WHAT they can change.
create or replace function public.match_request_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- The admin and trusted server code (auth.uid() is null) can change
  -- anything, e.g. extend a post by hand.
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  -- For coaches, the expiry time always stays what the database set.
  new.expires_at := old.expires_at;

  if new.coach_id   is distinct from old.coach_id
     or new.fighter_id is distinct from old.fighter_id
     or new.kind       is distinct from old.kind
  then
    raise exception 'A post''s coach, fighter and kind can''t change; close it and post again'
      using errcode = '42501';  -- insufficient_privilege
  end if;

  -- Closed, matched and expired posts are finished.
  if old.status not in ('open', 'in_talks') then
    raise exception 'This post is % and can''t be edited', old.status
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    -- A coach can close their own post at any time, and mark it expired
    -- once its time is up. Moving to in_talks or matched will happen through
    -- offers (a later card), not by editing the post.
    if not (new.status = 'closed'
            or (new.status = 'expired' and old.expires_at <= now()))
    then
      raise exception 'A coach can only close a post (or expire one past its time)'
        using errcode = '42501';
    end if;
  end if;

  if new.latest_date is distinct from old.latest_date
     and new.latest_date < current_date
  then
    raise exception 'The latest date is already in the past'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger match_request_guard
  before update on public.match_request
  for each row execute function public.match_request_guard();

-- Deactivating a fighter closes their open post, so it leaves the feed.
create or replace function public.fighter_close_posts_on_deactivate()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  update public.match_request
  set status = 'closed'
  where fighter_id = new.id
    and status in ('open', 'in_talks');
  return null;  -- the return value of an AFTER trigger is ignored
end;
$$;

-- "update of active ... when (...)" runs the function only when the active
-- column is part of the update and it changed from true to false.
create trigger fighter_close_posts_on_deactivate
  after update of active on public.fighter
  for each row
  when (old.active and not new.active)
  execute function public.fighter_close_posts_on_deactivate();


-- ---------------------------------------------------------------------------
-- 5. Table privileges
-- ---------------------------------------------------------------------------

revoke all on table public.match_request from anon, authenticated;
grant select, insert, update, delete on table public.match_request to authenticated;


-- ---------------------------------------------------------------------------
-- 6. Row-level security
-- ---------------------------------------------------------------------------
-- Other coaches can see a post's fighter_id, but the fighter table only
-- shows a fighter to their own coach, so the id doesn't reveal a name. The
-- feed will read posts with fighter details (minus the name) through a view
-- (KAN-49).

alter table public.match_request enable row level security;

create policy "match_request: approved coaches read open posts"
  on public.match_request for select
  to authenticated
  using (
    (select public.is_approved_coach())
    and status in ('open', 'in_talks')
    and expires_at > now()
  );

-- Coaches always see their own posts, including closed and expired ones.
create policy "match_request: coach reads own posts"
  on public.match_request for select
  to authenticated
  using (coach_id = (select auth.uid()));

create policy "match_request: admin reads all"
  on public.match_request for select
  to authenticated
  using ((select public.is_admin()));

-- The (fighter_id, coach_id) foreign key already stops a coach from posting
-- someone else's fighter; this makes sure coach_id is really you.
create policy "match_request: approved coach posts own fighters"
  on public.match_request for insert
  to authenticated
  with check (
    coach_id = (select auth.uid())
    and (select public.is_approved_coach())
  );

create policy "match_request: approved coach updates own posts"
  on public.match_request for update
  to authenticated
  using (
    coach_id = (select auth.uid())
    and (select public.is_approved_coach())
  )
  with check (coach_id = (select auth.uid()));

create policy "match_request: admin updates all"
  on public.match_request for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));

-- Coaches close posts instead of deleting them, so offers keep their post.
create policy "match_request: admin deletes"
  on public.match_request for delete
  to authenticated
  using ((select public.is_admin()));
