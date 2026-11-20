-- Posts (KAN-45). The UI calls them posts; the table keeps the spec's name.
--   seeking:   looking for an opponent, expires after 21 days
--   available: ready to fight, optionally on short notice, expires after 14
-- One open post per fighter. Posts carry a weight range; the exact weight
-- gets agreed on the bout.
--
-- Left out from the spec: experience_wanted, intensity, rules and gear.
-- Coaches don't filter on those when looking for bouts.


-- Composite FK target, same pattern as fighter -> coach. Guarantees a post's
-- coach is the fighter's coach.

alter table public.fighter
  add constraint fighter_id_coach_id_key unique (id, coach_id);


-- Table

create table public.match_request (
  id               uuid primary key default gen_random_uuid(),
  coach_id         uuid not null default auth.uid()
                     references public.coach (id) on delete cascade,
  fighter_id       uuid not null,
  kind             text not null check (kind in ('seeking', 'available')),
  -- defaults to the fighter's bout type, but can differ (e.g. a smoker
  -- fighter looking for a first amateur bout)
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
  -- set by the insert trigger from kind
  expires_at       timestamptz not null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- posts follow the fighter if the admin moves them to another coach
  constraint match_request_fighter_coach_fkey
    foreign key (fighter_id, coach_id)
    references public.fighter (id, coach_id)
    on update cascade
    on delete cascade,

  constraint match_request_weight_positive
    check (weight_min > 0 and weight_max < 500),
  constraint match_request_weight_range
    check (weight_min <= weight_max),
  -- null on either side passes, so open-ended ranges are fine
  constraint match_request_date_range
    check (earliest_date <= latest_date),
  constraint match_request_short_notice_available_only
    check (kind = 'available' or not short_notice)
);

comment on table public.match_request is
  'Posts: one fighter seeking an opponent or listed as available. Approved coaches read open posts; only the owner edits or closes.';
comment on column public.match_request.status is
  'open -> in_talks -> matched, or closed by the coach, or expired. open and in_talks both count as an open post.';
comment on column public.match_request.expires_at is
  'Set on insert: 21 days for seeking, 14 for available. Read with expires_at > now(); a post past this time is treated as expired even before its status says so.';


-- Indexes

-- One open post per fighter. Index predicates can't use now(), which is why
-- expiry also has to be written to status (see the insert trigger) instead
-- of relying on expires_at alone.
create unique index match_request_one_open_per_fighter
  on public.match_request (fighter_id)
  where status in ('open', 'in_talks');

create index match_request_fighter_id_coach_id_idx on public.match_request (fighter_id, coach_id);
create index match_request_coach_id_idx on public.match_request (coach_id);

-- for the feed (open posts by expiry)
create index match_request_open_feed_idx
  on public.match_request (expires_at)
  where status in ('open', 'in_talks');


-- Triggers

create trigger match_request_set_updated_at
  before update on public.match_request
  for each row execute function public.set_updated_at();

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
  -- The else branch is only there so a bad kind fails on the kind check.
  -- Without it expires_at would be null, and NOT NULL is checked first,
  -- which gives a misleading error.
  new.expires_at := now() + case new.kind
                              when 'seeking'   then interval '21 days'
                              when 'available' then interval '14 days'
                              else interval '0 days'
                            end;

  if new.latest_date < current_date then
    raise exception 'The latest date is already in the past'
      using errcode = '23514';
  end if;

  -- An old post can be past expires_at but still marked open. Expire it here
  -- so it doesn't trip the one-open-post index.
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

-- RLS covers who can update a post; this covers what they can change.
create or replace function public.match_request_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- admin and server code can change anything (e.g. extend a post)
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  new.expires_at := old.expires_at;

  if new.coach_id   is distinct from old.coach_id
     or new.fighter_id is distinct from old.fighter_id
     or new.kind       is distinct from old.kind
  then
    raise exception 'A post''s coach, fighter and kind can''t change; close it and post again'
      using errcode = '42501';  -- insufficient_privilege
  end if;

  if old.status not in ('open', 'in_talks') then
    raise exception 'This post is % and can''t be edited', old.status
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    -- in_talks and matched will be set by offers (KAN-46), not by hand
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

-- Deactivating a fighter pulls their open post from the feed.
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
  return null;
end;
$$;

create trigger fighter_close_posts_on_deactivate
  after update of active on public.fighter
  for each row
  when (old.active and not new.active)
  execute function public.fighter_close_posts_on_deactivate();


-- Privileges

revoke all on table public.match_request from anon, authenticated;
grant select, insert, update, delete on table public.match_request to authenticated;


-- RLS
-- fighter_id is visible to other coaches, but fighter rows aren't, so it
-- doesn't expose a name. The feed goes through post_feed (KAN-49).

alter table public.match_request enable row level security;

create policy "match_request: approved coaches read open posts"
  on public.match_request for select
  to authenticated
  using (
    (select public.is_approved_coach())
    and status in ('open', 'in_talks')
    and expires_at > now()
  );

-- including closed and expired ones
create policy "match_request: coach reads own posts"
  on public.match_request for select
  to authenticated
  using (coach_id = (select auth.uid()));

create policy "match_request: admin reads all"
  on public.match_request for select
  to authenticated
  using ((select public.is_admin()));

-- the composite FK already blocks posting another coach's fighter
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

-- coaches close posts rather than delete them, so offers keep their post
create policy "match_request: admin deletes"
  on public.match_request for delete
  to authenticated
  using ((select public.is_admin()));
