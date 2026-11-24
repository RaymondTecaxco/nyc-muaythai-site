-- Coach-to-coach messages (KAN-47). A conversation is between two approved
-- coaches, optionally about a post; one thread per pair of coaches per post.
-- Only the two coaches can read or send. Email never comes into it.
--
-- The pair is stored in a fixed order (coach_a_id < coach_b_id) so that
-- "A and B" and "B and A" are the same row, which is what lets a plain
-- unique constraint enforce one thread per pair.


create table public.conversation (
  id               uuid primary key default gen_random_uuid(),
  coach_a_id       uuid not null references public.coach (id) on delete cascade,
  coach_b_id       uuid not null references public.coach (id) on delete cascade,
  -- a thread about a post goes with the post if the admin ever deletes it
  match_request_id uuid references public.match_request (id) on delete cascade,
  -- set by the message trigger, for sorting the inbox
  last_message_at  timestamptz,
  created_at       timestamptz not null default now(),

  constraint conversation_pair_ordered
    check (coach_a_id < coach_b_id),
  -- nulls not distinct: without it, every "no post" thread would count as
  -- different (null <> null) and a pair could open any number of them
  constraint conversation_one_per_pair_per_post
    unique nulls not distinct (coach_a_id, coach_b_id, match_request_id)
);

comment on table public.conversation is
  'Message threads between two coaches, optionally about a post. Only the two coaches can see them.';

create index conversation_coach_b_id_idx on public.conversation (coach_b_id);
create index conversation_match_request_id_idx on public.conversation (match_request_id);


create table public.message (
  id              uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversation (id) on delete cascade,
  sender_coach_id uuid not null default auth.uid() references public.coach (id) on delete cascade,
  body            text not null check (length(trim(body)) between 1 and 4000),
  -- set by the database when the recipient opens it
  read_at         timestamptz,
  created_at      timestamptz not null default now()
);

comment on table public.message is
  'Messages in a conversation. Can''t be edited or deleted; the recipient can mark them read.';

create index message_conversation_id_created_at_idx on public.message (conversation_id, created_at);
create index message_sender_coach_id_idx on public.message (sender_coach_id);


-- Triggers: conversation

-- security definer: the starting coach can't read other coaches' rows
-- (coach is own-row only), but has to know the other side is approved
create or replace function public.conversation_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_swap uuid;
begin
  if new.coach_a_id > new.coach_b_id then
    v_swap         := new.coach_a_id;
    new.coach_a_id := new.coach_b_id;
    new.coach_b_id := v_swap;
  end if;

  if new.coach_a_id = new.coach_b_id then
    raise exception 'You can''t start a conversation with yourself'
      using errcode = '23514';
  end if;

  if auth.uid() is not null and auth.uid() not in (new.coach_a_id, new.coach_b_id) then
    raise exception 'You can only start conversations you''re part of'
      using errcode = '42501';
  end if;

  if (select count(*) from public.coach c
      where c.id in (new.coach_a_id, new.coach_b_id)
        and c.status = 'approved'
        and c.role = 'coach') < 2
  then
    raise exception 'Conversations are between two approved coaches'
      using errcode = '23514';
  end if;

  if new.match_request_id is not null
     and not exists (select 1 from public.match_request m
                     where m.id = new.match_request_id
                       and m.coach_id in (new.coach_a_id, new.coach_b_id))
  then
    raise exception 'A conversation about a post has to include the post''s coach'
      using errcode = '23514';
  end if;

  new.last_message_at := null;
  new.created_at      := now();
  return new;
end;
$$;

create trigger conversation_before_insert
  before insert on public.conversation
  for each row execute function public.conversation_before_insert();


-- Triggers: message

create or replace function public.message_before_insert()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.read_at    := null;
  new.created_at := now();
  return new;
end;
$$;

create trigger message_before_insert
  before insert on public.message
  for each row execute function public.message_before_insert();

-- Coaches can't update conversation rows at all, so bumping
-- last_message_at needs security definer.
create or replace function public.message_after_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.conversation
  set last_message_at = new.created_at
  where id = new.conversation_id;
  return null;
end;
$$;

create trigger message_after_insert
  after insert on public.message
  for each row execute function public.message_after_insert();

-- The only change allowed is the recipient marking a message read, and the
-- time comes from the database.
create or replace function public.message_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null or public.is_admin() then
    return new;
  end if;

  if (new.conversation_id, new.sender_coach_id, new.body, new.created_at)
     is distinct from
     (old.conversation_id, old.sender_coach_id, old.body, old.created_at)
  then
    raise exception 'Messages can''t be edited'
      using errcode = '42501';
  end if;

  if new.read_at is distinct from old.read_at then
    if auth.uid() = old.sender_coach_id then
      raise exception 'Only the recipient can mark a message read'
        using errcode = '42501';
    end if;
    -- first read wins; it can't be unread or moved
    new.read_at := coalesce(old.read_at, now());
  end if;

  return new;
end;
$$;

create trigger message_guard
  before update on public.message
  for each row execute function public.message_guard();


-- Finds the thread for this pair (and post), or starts it. Saves the page
-- from having to catch a unique violation when a thread already exists.
-- Runs as the caller, so RLS and the insert trigger still apply.
create or replace function public.start_conversation(
  p_other_coach_id uuid,
  p_match_request_id uuid default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_a  uuid := least(auth.uid(), p_other_coach_id);
  v_b  uuid := greatest(auth.uid(), p_other_coach_id);
  v_id uuid;
begin
  insert into public.conversation (coach_a_id, coach_b_id, match_request_id)
  values (v_a, v_b, p_match_request_id)
  on conflict on constraint conversation_one_per_pair_per_post do nothing
  returning id into v_id;

  if v_id is null then
    select c.id into v_id
    from public.conversation c
    where c.coach_a_id = v_a
      and c.coach_b_id = v_b
      and c.match_request_id is not distinct from p_match_request_id;
  end if;

  return v_id;
end;
$$;

revoke execute on function public.start_conversation(uuid, uuid) from public, anon;
grant execute on function public.start_conversation(uuid, uuid) to authenticated, service_role;


-- inbox
-- One row per thread for the signed-in coach. Owner's rights because the
-- other coach's name and gym aren't readable from coach (own-row only); the
-- WHERE clause keeps it to your own threads. Shows the name even if the
-- other coach is later suspended, since you've already been talking.
-- Views can't promise an order, so the page sorts by last_message_at.

create view public.inbox
with (security_barrier = true)
as
select
  c.id                         as conversation_id,
  c.match_request_id,
  mr.kind                      as post_kind,
  other.id                     as other_coach_id,
  other.name                   as other_coach_name,
  g.name                       as other_gym_name,
  c.last_message_at,
  left(last_msg.body, 120)     as last_message_preview,
  (last_msg.sender_coach_id = (select auth.uid())) as last_message_is_mine,
  (select count(*)::integer
   from public.message m
   where m.conversation_id = c.id
     and m.sender_coach_id <> (select auth.uid())
     and m.read_at is null)    as unread_count,
  c.created_at
from public.conversation c
join public.coach other
  on other.id = case when c.coach_a_id = (select auth.uid())
                     then c.coach_b_id else c.coach_a_id end
left join public.gym g on g.id = other.gym_id
left join public.match_request mr on mr.id = c.match_request_id
-- lateral: a subquery that can use columns from the row it's joined to,
-- here to pick each thread's newest message
left join lateral (
  select m.body, m.sender_coach_id
  from public.message m
  where m.conversation_id = c.id
  order by m.created_at desc
  limit 1
) last_msg on true
where c.coach_a_id = (select auth.uid())
   or c.coach_b_id = (select auth.uid());

comment on view public.inbox is
  'The signed-in coach''s threads: the other coach, the post (if any), newest message preview and unread count.';


-- Privileges: no updates to conversations, no deletes anywhere, and the
-- only message update is marking read (see message_guard)

revoke all on table public.conversation, public.message, public.inbox from anon, authenticated;
grant select, insert on table public.conversation to authenticated;
grant select, insert, update on table public.message to authenticated;
grant select on table public.inbox to authenticated;


-- RLS: conversation (the two coaches only, no admin read, per the card)

alter table public.conversation enable row level security;

create policy "conversation: the two coaches read"
  on public.conversation for select
  to authenticated
  using (coach_a_id = (select auth.uid()) or coach_b_id = (select auth.uid()));

create policy "conversation: approved coach starts"
  on public.conversation for insert
  to authenticated
  with check (
    (coach_a_id = (select auth.uid()) or coach_b_id = (select auth.uid()))
    and (select public.is_approved_coach())
  );


-- RLS: message
-- The subquery reads conversation, whose own rule already limits it to
-- threads you're in.

alter table public.message enable row level security;

create policy "message: the two coaches read"
  on public.message for select
  to authenticated
  using (
    exists (select 1 from public.conversation c
            where c.id = message.conversation_id)
  );

create policy "message: approved coach sends in own threads"
  on public.message for insert
  to authenticated
  with check (
    sender_coach_id = (select auth.uid())
    and (select public.is_approved_coach())
    and exists (select 1 from public.conversation c
                where c.id = message.conversation_id)
  );

-- marking read; message_guard limits it to read_at, recipient only
create policy "message: the two coaches mark read"
  on public.message for update
  to authenticated
  using (
    exists (select 1 from public.conversation c
            where c.id = message.conversation_id)
  )
  with check (
    exists (select 1 from public.conversation c
            where c.id = message.conversation_id)
  );
