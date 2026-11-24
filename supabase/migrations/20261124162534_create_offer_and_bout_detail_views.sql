-- The rest of KAN-49, now that offers and bouts exist (KAN-46).
--   offer_detail: an offer with the offered fighter's details, never the name
--   bout_detail:  an accepted bout with both fighters' names, for its two
--                 coaches only
-- Same approach as post_feed: owner's rights, security_barrier, and the
-- WHERE clause decides who gets rows.


-- offer_detail
-- The post's coach can't read the offered fighter (fighter is owner-only),
-- so this is how they see who they're being offered. No display_name,
-- birth_date or fighter_id, even after acceptance; names live on bout_detail.

create view public.offer_detail
with (security_barrier = true)
as
select
  o.id,
  o.match_request_id,
  o.status,
  o.note,
  o.created_at,
  o.updated_at,
  o.coach_id,
  c.name                      as coach_name,
  g.id                        as gym_id,
  g.name                      as gym_name,
  g.borough_or_city           as gym_borough_or_city,
  g.state                     as gym_state,
  -- true for the coach who made the offer, false for the post's coach
  (o.coach_id = (select auth.uid())) as is_mine,
  f.sex,
  date_part('year', age(f.birth_date))::integer as fighter_age,
  f.height_in,
  f.walk_around_lbs,
  f.stance,
  f.bout_type                 as fighter_bout_type,
  ra.wins                     as amateur_wins,
  ra.losses                   as amateur_losses,
  ra.draws                    as amateur_draws,
  rs.smoker_bouts,
  rs.experience_notes         as smoker_experience_notes
from public.offer o
join public.match_request m on m.id = o.match_request_id
join public.fighter f on f.id = o.fighter_id
join public.coach   c on c.id = o.coach_id
join public.gym     g on g.id = f.gym_id
left join public.fighter_record ra
  on ra.fighter_id = f.id and ra.fight_type = 'amateur'
left join public.fighter_record rs
  on rs.fighter_id = f.id and rs.fight_type = 'smoker'
where o.coach_id = (select auth.uid())
   or m.coach_id = (select auth.uid());

comment on view public.offer_detail is
  'Offers with the offered fighter''s details but no name. Only the two coaches get rows.';


-- bout_detail
-- Names show only here, and only to the two coaches. The admin reads the
-- base tables instead.

create view public.bout_detail
with (security_barrier = true)
as
select
  b.id,
  b.offer_id,
  b.bout_type,
  b.status,
  b.agreed_weight,
  b.event_id,
  e.promotion                 as event_promotion,
  e.details                   as event_details,
  e.url                       as event_url,
  b.event_name_other,
  -- the bout's own date wins; otherwise the listed event's
  coalesce(b.event_date, e.event_date) as event_date,
  b.result,
  b.result_method,
  b.created_at,
  b.updated_at,
  b.coach_a_id,
  ca.name                     as coach_a_name,
  b.fighter_a_id,
  fa.display_name             as fighter_a_name,
  b.coach_b_id,
  cb.name                     as coach_b_name,
  b.fighter_b_id,
  fb.display_name             as fighter_b_name,
  -- which side the viewer is on, so the page can say "your fighter"
  case when b.coach_a_id = (select auth.uid()) then 'a' else 'b' end as my_side
from public.bout b
join public.coach   ca on ca.id = b.coach_a_id
join public.coach   cb on cb.id = b.coach_b_id
join public.fighter fa on fa.id = b.fighter_a_id
join public.fighter fb on fb.id = b.fighter_b_id
left join public.events e on e.id = b.event_id
where b.coach_a_id = (select auth.uid())
   or b.coach_b_id = (select auth.uid());

comment on view public.bout_detail is
  'Bouts with both fighters'' and coaches'' names. Only the bout''s two coaches get rows.';


revoke all on table public.offer_detail, public.bout_detail from anon, authenticated;
grant select on table public.offer_detail, public.bout_detail to authenticated;
