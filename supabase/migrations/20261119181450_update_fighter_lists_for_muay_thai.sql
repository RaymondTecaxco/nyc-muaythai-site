-- Migration: update_fighter_lists_for_muay_thai
-- Jira: KAN-44 (Fighter profiles and records)
--
-- Replaces the placeholder lists from 20261119170704 with the ones local
-- Muay Thai actually uses. That migration is already applied, so it stays
-- as it is; changes go in a new file.
--
--   * bout type (was "experience level"): smoker / amateur
--   * stance: orthodox / southpaw (now required)
--   * fight types on a record: smoker / amateur (pros come later)
--   * record shape: an amateur record is wins / losses / draws. A smoker
--     (exhibition bout) isn't judged, so a smoker record is just how many
--     smoker bouts the fighter has had ("previous experience").
--
-- If any existing row breaks a new rule (for example a stance of 'switch'),
-- the whole migration fails and nothing changes, because Supabase runs each
-- migration file inside one transaction.


-- ---------------------------------------------------------------------------
-- 1. fighter: bout type and stance
-- ---------------------------------------------------------------------------

-- Renaming keeps the column's data, its NOT NULL and its position. The old
-- CHECK keeps its old name, so it is dropped by that name.
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


-- ---------------------------------------------------------------------------
-- 2. fighter_record: smoker / amateur, each with its own shape
-- ---------------------------------------------------------------------------

alter table public.fighter_record
  drop constraint fighter_record_fight_type_check,
  add constraint fighter_record_fight_type_check
    check (fight_type in ('smoker', 'amateur'));

-- Smoker rows leave wins / losses / draws empty, so these columns can now be
-- null, and the old default of 0 goes (a 0 would put a "record" on a smoker
-- row). The existing "no negative counts" checks still apply: a CHECK passes
-- when the value is null, so they only bite when a number is given.
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

-- Each row must have exactly the fields for its fight type:
--   amateur -> wins, losses and draws filled in; smoker_bouts empty
--   smoker  -> smoker_bouts filled in; wins, losses and draws empty
-- "num_nonnulls" counts how many of its arguments are not null.
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
