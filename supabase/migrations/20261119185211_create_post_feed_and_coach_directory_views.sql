-- Read-only views for what other coaches can see (KAN-49). RLS can't hide
-- columns, so pages that show posts or other coaches read these instead of
-- the fighter and coach tables. Views for offers and bouts come with KAN-46.
--
-- These run with the owner's rights and so bypass RLS. That's intentional
-- (Supabase's advisor will flag them): the is_approved_coach() check in each
-- WHERE clause and the column list are the access control. security_barrier
-- makes sure that WHERE runs before any filter the caller adds.


-- post_feed
-- No display_name, no birth_date (age instead), and no fighter_id, which
-- would let someone track one fighter across posts.

create view public.post_feed
with (security_barrier = true)
as
select
  m.id,
  m.kind,
  m.bout_type,
  m.weight_min,
  m.weight_max,
  m.earliest_date,
  m.latest_date,
  m.travel_radius_mi,
  m.short_notice,
  m.event_name,
  m.status,
  m.expires_at,
  m.created_at,
  m.coach_id,
  c.name                      as coach_name,
  g.id                        as gym_id,
  g.name                      as gym_name,
  g.borough_or_city           as gym_borough_or_city,
  g.state                     as gym_state,
  -- lets the page show "edit" instead of "offer" on your own posts
  (m.coach_id = (select auth.uid())) as is_mine,
  f.sex,
  date_part('year', age(f.birth_date))::integer as fighter_age,
  f.height_in,
  f.walk_around_lbs,
  f.stance,
  f.bout_type                 as fighter_bout_type,
  -- left joins: a fighter may not have both record types
  ra.wins                     as amateur_wins,
  ra.losses                   as amateur_losses,
  ra.draws                    as amateur_draws,
  rs.smoker_bouts,
  rs.experience_notes         as smoker_experience_notes
from public.match_request m
join public.fighter f on f.id = m.fighter_id
join public.coach   c on c.id = m.coach_id
join public.gym     g on g.id = f.gym_id
left join public.fighter_record ra
  on ra.fighter_id = f.id and ra.fight_type = 'amateur'
left join public.fighter_record rs
  on rs.fighter_id = f.id and rs.fight_type = 'smoker'
where (select public.is_approved_coach())
  and m.status in ('open', 'in_talks')
  and m.expires_at > now()
  and f.active
  -- hides posts from suspended coaches
  and c.status = 'approved';

comment on view public.post_feed is
  'The matchmaker feed: open posts with fighter details but no fighter name. Approved coaches and the admin only.';


-- coach_directory
-- Public profile fields only; status, verification and opt-in stay private.

create view public.coach_directory
with (security_barrier = true)
as
select
  c.id,
  c.name,
  c.gym_id,
  g.name            as gym_name,
  g.borough_or_city as gym_borough_or_city,
  g.state           as gym_state
from public.coach c
join public.gym g on g.id = c.gym_id
where (select public.is_approved_coach())
  and c.status = 'approved'
  -- leaves out the admin account
  and c.role = 'coach';

comment on view public.coach_directory is
  'Approved coaches for the directory, profiles, offers and messages: id, name and gym only. Approved coaches and the admin only.';


-- Privileges: read-only, signed-in users only

revoke all on table public.post_feed, public.coach_directory from anon, authenticated;
grant select on table public.post_feed, public.coach_directory to authenticated;
