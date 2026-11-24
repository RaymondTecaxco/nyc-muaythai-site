-- Offers and bouts (KAN-46). A coach answers a post with one of their own
-- fighters; the post's coach accepts or declines. Accepting creates the bout,
-- marks the post matched and declines every other pending offer.
--
-- Offers must be same-sex as the posted fighter. Smokers aren't judged, so
-- only amateur bouts get a result (winner plus method).


-- Used by offer RLS and the offer guard. security definer so the offering
-- coach's side still works after the post leaves their view (closed, expired).
create or replace function public.match_request_owner(p_match_request_id uuid)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select coach_id from public.match_request where id = p_match_request_id;
$$;

revoke execute on function public.match_request_owner(uuid) from public, anon;
grant execute on function public.match_request_owner(uuid) to authenticated, service_role;


create table public.offer (
  id               uuid primary key default gen_random_uuid(),
  match_request_id uuid not null references public.match_request (id) on delete cascade,
  coach_id         uuid not null default auth.uid(),
  fighter_id       uuid not null,
  note             text check (length(note) <= 1000),
  status           text not null default 'pending'
                     check (status in ('pending', 'accepted', 'declined', 'withdrawn')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- only your own fighters, and offers follow a fighter moved by the admin
  constraint offer_fighter_coach_fkey
    foreign key (fighter_id, coach_id)
    references public.fighter (id, coach_id)
    on update cascade
    on delete cascade,

  constraint offer_one_per_fighter_per_post
    unique (match_request_id, fighter_id)
);

comment on table public.offer is
  'Private replies to a post, each with one of the replying coach''s fighters. Visible only to the two coaches.';

create unique index offer_one_accepted_per_post
  on public.offer (match_request_id)
  where status = 'accepted';

create index offer_coach_id_idx on public.offer (coach_id);
create index offer_fighter_id_coach_id_idx on public.offer (fighter_id, coach_id);


create table public.bout (
  id               uuid primary key default gen_random_uuid(),
  offer_id         uuid not null unique references public.offer (id) on delete restrict,
  bout_type        text not null check (bout_type in ('smoker', 'amateur')),
  -- side a is the post, side b the accepted offer. The coach ids are copies,
  -- kept so RLS doesn't have to join through offer and match_request.
  coach_a_id       uuid not null,
  fighter_a_id     uuid not null,
  coach_b_id       uuid not null,
  fighter_b_id     uuid not null,
  -- agreed in conversation, often after the offer is accepted
  agreed_weight    numeric(5,1) check (agreed_weight > 0 and agreed_weight < 500),
  -- events belongs to the aggregator repo; the aggregator never deletes rows,
  -- but if one ever goes, the bout just loses its link
  event_id         bigint references public.events (id) on delete set null,
  event_name_other text check (length(trim(event_name_other)) between 1 and 200),
  event_date       date,
  status           text not null default 'agreed'
                     check (status in ('agreed', 'sent_to_promotion', 'completed', 'cancelled')),
  result           text check (result in ('fighter_a', 'fighter_b', 'draw', 'no_contest')),
  result_method    text check (result_method in ('decision', 'ko', 'tko', 'dq')),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),

  -- restrict: a fighter with a bout can't be deleted, so both coaches keep
  -- their history
  constraint bout_fighter_a_coach_fkey
    foreign key (fighter_a_id, coach_a_id)
    references public.fighter (id, coach_id)
    on update cascade
    on delete restrict,
  constraint bout_fighter_b_coach_fkey
    foreign key (fighter_b_id, coach_b_id)
    references public.fighter (id, coach_id)
    on update cascade
    on delete restrict,

  constraint bout_different_fighters
    check (fighter_a_id <> fighter_b_id),
  constraint bout_one_event_source
    check (event_id is null or event_name_other is null),
  constraint bout_result_when_completed
    check (result is null or status = 'completed'),
  constraint bout_smokers_have_no_result
    check (bout_type = 'amateur' or (result is null and result_method is null)),
  -- a win needs a method; a draw, no contest or no result has none
  constraint bout_method_matches_result
    check (case when result in ('fighter_a', 'fighter_b')
                then result_method is not null
                else result_method is null
           end)
);

comment on table public.bout is
  'One row per accepted offer. Visible only to its two coaches and the admin. Created by the database, never inserted directly.';
comment on column public.bout.result is
  'Amateur bouts only, once completed: fighter_a (the post''s fighter) or fighter_b won, draw, or no_contest.';

create index bout_coach_a_id_idx on public.bout (coach_a_id);
create index bout_coach_b_id_idx on public.bout (coach_b_id);
create index bout_fighter_a_idx on public.bout (fighter_a_id, coach_a_id);
create index bout_fighter_b_idx on public.bout (fighter_b_id, coach_b_id);
create index bout_event_id_idx on public.bout (event_id);


-- Triggers: offer

create trigger offer_set_updated_at
  before update on public.offer
  for each row execute function public.set_updated_at();

-- security definer: the offering coach can't read the posted fighter, but
-- the same-sex rule needs it
create or replace function public.offer_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_post_coach  uuid;
  v_post_status text;
  v_expires_at  timestamptz;
  v_post_sex    text;
  v_active      boolean;
  v_sex         text;
begin
  if auth.uid() is not null and new.coach_id is distinct from auth.uid() then
    raise exception 'Offers can only be made as yourself'
      using errcode = '42501';
  end if;

  -- checked first so the messages below never describe another coach's fighter
  select f.active, f.sex into v_active, v_sex
  from public.fighter f
  where f.id = new.fighter_id and f.coach_id = new.coach_id;

  if not found then
    raise exception 'Pick one of your own fighters'
      using errcode = '23503';  -- foreign_key_violation
  end if;

  select m.coach_id, m.status, m.expires_at, f.sex
    into v_post_coach, v_post_status, v_expires_at, v_post_sex
  from public.match_request m
  join public.fighter f on f.id = m.fighter_id
  where m.id = new.match_request_id;

  if not found or v_post_status not in ('open', 'in_talks') or v_expires_at <= now() then
    raise exception 'This post is no longer open'
      using errcode = '23514';
  end if;

  if v_post_coach = new.coach_id then
    raise exception 'You can''t make an offer on your own post'
      using errcode = '23514';
  end if;

  if not v_active then
    raise exception 'This fighter is deactivated; reactivate them before making an offer'
      using errcode = '23514';
  end if;

  if v_sex is distinct from v_post_sex then
    raise exception 'Offers must be for a fighter of the same sex as the posted fighter'
      using errcode = '23514';
  end if;

  new.status := 'pending';
  return new;
end;
$$;

create trigger offer_before_insert
  before insert on public.offer
  for each row execute function public.offer_before_insert();

create or replace function public.offer_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_post_status text;
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  if new.match_request_id is distinct from old.match_request_id
     or new.coach_id      is distinct from old.coach_id
     or new.fighter_id    is distinct from old.fighter_id
  then
    raise exception 'An offer''s post, coach and fighter can''t change'
      using errcode = '42501';
  end if;

  if old.status <> 'pending' then
    raise exception 'This offer is % and can''t change', old.status
      using errcode = '42501';
  end if;

  if new.note is distinct from old.note and auth.uid() <> old.coach_id then
    raise exception 'Only the coach who made the offer can edit its note'
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status then
    if new.status = 'withdrawn' and auth.uid() = old.coach_id then
      null;
    elsif new.status in ('accepted', 'declined')
          and auth.uid() = public.match_request_owner(old.match_request_id)
    then
      if new.status = 'accepted' then
        select m.status into v_post_status
        from public.match_request m
        where m.id = old.match_request_id;

        if v_post_status not in ('open', 'in_talks') then
          raise exception 'This post is % and can''t accept offers', v_post_status
            using errcode = '42501';
        end if;
      end if;
    else
      raise exception 'Only the offering coach can withdraw an offer, and only the post''s coach can accept or decline it'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

create trigger offer_guard
  before update on public.offer
  for each row execute function public.offer_guard();

-- Keeps the post's status in step with its offers, and creates the bout.
-- security definer: the offering coach's actions change a post they don't
-- own, and nobody inserts into bout directly.
create or replace function public.offer_sync()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_post public.match_request%rowtype;
begin
  if tg_op = 'INSERT' then
    update public.match_request
    set status = 'in_talks'
    where id = new.match_request_id and status = 'open';
    return null;
  end if;

  if new.status is not distinct from old.status then
    return null;
  end if;

  if new.status = 'accepted' then
    select * into v_post from public.match_request where id = new.match_request_id;

    insert into public.bout (offer_id, bout_type, coach_a_id, fighter_a_id, coach_b_id, fighter_b_id)
    values (new.id, v_post.bout_type, v_post.coach_id, v_post.fighter_id, new.coach_id, new.fighter_id);

    -- matched before the declines, otherwise the last decline would reopen it
    update public.match_request set status = 'matched' where id = new.match_request_id;

    update public.offer
    set status = 'declined'
    where match_request_id = new.match_request_id
      and id <> new.id
      and status = 'pending';

  elsif new.status in ('declined', 'withdrawn') then
    update public.match_request m
    set status = 'open'
    where m.id = new.match_request_id
      and m.status = 'in_talks'
      and not exists (
        select 1 from public.offer o
        where o.match_request_id = m.id
          and o.status in ('pending', 'accepted')
      );
  end if;

  return null;
end;
$$;

create trigger offer_sync
  after insert or update of status on public.offer
  for each row execute function public.offer_sync();


-- Triggers: bout

create trigger bout_set_updated_at
  before update on public.bout
  for each row execute function public.set_updated_at();

create or replace function public.bout_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  if (new.offer_id, new.bout_type, new.coach_a_id, new.fighter_a_id, new.coach_b_id, new.fighter_b_id)
     is distinct from
     (old.offer_id, old.bout_type, old.coach_a_id, old.fighter_a_id, old.coach_b_id, old.fighter_b_id)
  then
    raise exception 'A bout''s fighters and coaches can''t change'
      using errcode = '42501';
  end if;

  if old.status = 'cancelled' then
    raise exception 'This bout was cancelled and can''t be edited'
      using errcode = '42501';
  end if;

  -- after the event only the result can still be fixed
  if old.status = 'completed'
     and (new.status, new.agreed_weight, new.event_id, new.event_name_other, new.event_date)
         is distinct from
         (old.status, old.agreed_weight, old.event_id, old.event_name_other, old.event_date)
  then
    raise exception 'A completed bout can only have its result changed'
      using errcode = '42501';
  end if;

  if new.status is distinct from old.status
     and not ((old.status = 'agreed' and new.status in ('sent_to_promotion', 'completed', 'cancelled'))
              or (old.status = 'sent_to_promotion' and new.status in ('completed', 'cancelled')))
  then
    raise exception 'A bout can''t go from % to %', old.status, new.status
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger bout_guard
  before update on public.bout
  for each row execute function public.bout_guard();


-- Posts: status now follows offers. Replaces the KAN-45 guard, which only
-- let coaches close or expire. Each status is allowed only when it's true:
-- in_talks needs a pending offer, matched an accepted one, and so on.

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

  if new.status is distinct from old.status
     and not (
       new.status = 'closed'
       or (new.status = 'expired' and old.expires_at <= now())
       or (new.status = 'in_talks' and old.status = 'open'
           and exists (select 1 from public.offer o
                       where o.match_request_id = old.id and o.status = 'pending'))
       or (new.status = 'open' and old.status = 'in_talks'
           and not exists (select 1 from public.offer o
                           where o.match_request_id = old.id and o.status in ('pending', 'accepted')))
       or (new.status = 'matched'
           and exists (select 1 from public.offer o
                       where o.match_request_id = old.id and o.status = 'accepted'))
     )
  then
    raise exception 'A coach can only close a post (or expire one past its time); offers set the other statuses'
      using errcode = '42501';
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

-- Closing or expiring a post declines what's still pending. security definer
-- because the admin can't see offers (they're private to the two coaches).
create or replace function public.match_request_decline_offers_on_close()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.offer
  set status = 'declined'
  where match_request_id = new.id and status = 'pending';
  return null;
end;
$$;

create trigger match_request_decline_offers_on_close
  after update of status on public.match_request
  for each row
  when (old.status in ('open', 'in_talks') and new.status in ('closed', 'expired'))
  execute function public.match_request_decline_offers_on_close();

-- Deactivating a fighter withdraws their pending offers (their own post is
-- already closed by fighter_close_posts_on_deactivate).
create or replace function public.fighter_withdraw_offers_on_deactivate()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.offer
  set status = 'withdrawn'
  where fighter_id = new.id and status = 'pending';
  return null;
end;
$$;

create trigger fighter_withdraw_offers_on_deactivate
  after update of active on public.fighter
  for each row
  when (old.active and not new.active)
  execute function public.fighter_withdraw_offers_on_deactivate();


-- Privileges: no insert on bout (only offer_sync creates bouts) and no
-- deletes for coaches (withdraw or cancel instead)

revoke all on table public.offer, public.bout from anon, authenticated;
grant select, insert, update on table public.offer to authenticated;
grant select, update on table public.bout to authenticated;


-- RLS: offer (the two coaches only, per the card; no admin read)

alter table public.offer enable row level security;

create policy "offer: the two coaches read"
  on public.offer for select
  to authenticated
  using (
    coach_id = (select auth.uid())
    or public.match_request_owner(match_request_id) = (select auth.uid())
  );

-- open post, your own fighter, same sex: checked by offer_before_insert
create policy "offer: approved coach makes offers"
  on public.offer for insert
  to authenticated
  with check (
    coach_id = (select auth.uid())
    and (select public.is_approved_coach())
  );

-- what each side may change is decided by offer_guard
create policy "offer: the two coaches update"
  on public.offer for update
  to authenticated
  using (
    (select public.is_approved_coach())
    and (coach_id = (select auth.uid())
         or public.match_request_owner(match_request_id) = (select auth.uid()))
  )
  with check (
    coach_id = (select auth.uid())
    or public.match_request_owner(match_request_id) = (select auth.uid())
  );


-- RLS: bout

alter table public.bout enable row level security;

create policy "bout: the two coaches read"
  on public.bout for select
  to authenticated
  using (coach_a_id = (select auth.uid()) or coach_b_id = (select auth.uid()));

create policy "bout: admin reads all"
  on public.bout for select
  to authenticated
  using ((select public.is_admin()));

create policy "bout: the two coaches update"
  on public.bout for update
  to authenticated
  using (
    (select public.is_approved_coach())
    and (coach_a_id = (select auth.uid()) or coach_b_id = (select auth.uid()))
  )
  with check (coach_a_id = (select auth.uid()) or coach_b_id = (select auth.uid()));

create policy "bout: admin updates all"
  on public.bout for update
  to authenticated
  using ((select public.is_admin()))
  with check ((select public.is_admin()));
