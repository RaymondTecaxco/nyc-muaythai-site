-- Migration: create_post_feed_and_coach_directory_views
-- Jira: KAN-49 (Hide fighter names on posts)
--
-- Row-level security decides whether a whole row is visible; it can't hide
-- one column inside a visible row. So other coaches get these two views
-- (saved queries you read like tables) that leave the private columns out:
--
--   * post_feed:       open posts with fighter details, but no fighter name.
--   * coach_directory: approved coaches' id, name and gym only.
--
-- Pages that show posts or other coaches read these views, never the
-- fighter or coach tables directly. Offers and bouts don't exist yet; their
-- name-hiding views come with those cards.
--
-- How the views get past RLS: a view normally runs with its OWNER's rights
-- (the role that ran this migration, which also owns the tables). Table
-- owners skip RLS, so each view does its own access check in its WHERE
-- clause: (select public.is_approved_coach()). Supabase's security advisor
-- flags views like this ("security definer view"). Here it's on purpose,
-- since the WHERE clause and the chosen columns are the protection.
--
-- security_barrier = true: Postgres normally may run a reader's filter
-- before the view's own WHERE. A filter built on a function that reports
-- errors or values could then see rows the view is meant to hide. With a
-- security barrier, the view's WHERE always runs first.


-- ---------------------------------------------------------------------------
-- 1. post_feed
-- ---------------------------------------------------------------------------
-- Left out on purpose: display_name, birth_date (age is shown instead) and
-- fighter_id (an id would let anyone follow one fighter across posts).

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
  -- Who posted it, so coaches can send an offer or a message.
  m.coach_id,
  c.name                      as coach_name,
  g.id                        as gym_id,
  g.name                      as gym_name,
  g.borough_or_city           as gym_borough_or_city,
  g.state                     as gym_state,
  -- True on your own posts, so the page can show "edit" instead of "offer".
  (m.coach_id = (select auth.uid())) as is_mine,
  -- The fighter, minus the name. age() gives years, months and days
  -- between two dates; date_part('year', ...) keeps only the years.
  f.sex,
  date_part('year', age(f.birth_date))::integer as fighter_age,
  f.height_in,
  f.walk_around_lbs,
  f.stance,
  f.bout_type                 as fighter_bout_type,
  -- Records: a LEFT JOIN keeps the post even when the fighter has no
  -- record row of that type (the columns are then null).
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
  -- A suspended coach's posts leave the feed too.
  and c.status = 'approved';

comment on view public.post_feed is
  'The matchmaker feed: open posts with fighter details but no fighter name. Approved coaches and the admin only.';


-- ---------------------------------------------------------------------------
-- 2. coach_directory
-- ---------------------------------------------------------------------------
-- Left out on purpose: role, status, verification_checks, verified_by,
-- verified_at, feature_opt_in, feature_opt_in_at. Email isn't in public
-- tables at all (it stays in auth.users).

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
  -- The admin (The Kru) isn't a coach, so it isn't listed.
  and c.role = 'coach';

comment on view public.coach_directory is
  'Approved coaches for the directory, profiles, offers and messages: id, name and gym only. Approved coaches and the admin only.';


-- ---------------------------------------------------------------------------
-- 3. Privileges
-- ---------------------------------------------------------------------------
-- Read-only, and only for signed-in users; the WHERE clauses above narrow
-- that to approved coaches. Logged-out visitors get "permission denied".

revoke all on table public.post_feed, public.coach_directory from anon, authenticated;
grant select on table public.post_feed, public.coach_directory to authenticated;
