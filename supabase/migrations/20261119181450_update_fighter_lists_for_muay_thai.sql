-- Swap the placeholder lists from 20261119170704 for the ones local Muay
-- Thai actually uses (KAN-44):
--   bout type (was experience_level): smoker / amateur
--   stance: orthodox / southpaw, now required
--   record fight types: smoker / amateur (pro comes later)
-- Amateur records keep W/L/D. Smokers aren't judged, so a smoker record is
-- just a bout count.


-- fighter

-- the old check constraint keeps its old name after the rename
alter table public.fighter
  rename column experience_level to bout_type;

alter table public.fighter
  drop constraint fighter_experience_level_check,
  add constraint fighter_bout_type_check
    check (bout_type in ('smoker', 'amateur'));

comment on column public.fighter.bout_type is
  'The kind of bout this fighter takes now. Smoker = exhibition (not judged); amateur = judged amateur bout.';

alter table public.fighter
  drop constraint fighter_stance_check,
  add constraint fighter_stance_check
    check (stance in ('orthodox', 'southpaw')),
  alter column stance set not null;


-- fighter_record

alter table public.fighter_record
  drop constraint fighter_record_fight_type_check,
  add constraint fighter_record_fight_type_check
    check (fight_type in ('smoker', 'amateur'));

-- W/L/D become nullable with no default, since smoker rows leave them empty.
-- The existing >= 0 checks still apply when a number is given.
alter table public.fighter_record
  alter column wins   drop not null,
  alter column wins   drop default,
  alter column losses drop not null,
  alter column losses drop default,
  alter column draws  drop not null,
  alter column draws  drop default,
  add column smoker_bouts integer
    constraint fighter_record_smoker_bouts_check check (smoker_bouts >= 0);

comment on column public.fighter_record.smoker_bouts is
  'Smoker rows only: how many smoker (exhibition) bouts the fighter has had. Smokers are not judged, so there is no W/L/D.';

-- amateur rows: W/L/D only. smoker rows: smoker_bouts only.
alter table public.fighter_record
  add constraint fighter_record_matches_fight_type check (
    (fight_type = 'amateur'
       and num_nonnulls(wins, losses, draws) = 3
       and smoker_bouts is null)
    or
    (fight_type = 'smoker'
       and smoker_bouts is not null
       and num_nonnulls(wins, losses, draws) = 0)
  );

comment on table public.fighter_record is
  'One row per fighter and fight type: amateur rows hold W/L/D, smoker rows hold a bout count. Same visibility as fighter.';
