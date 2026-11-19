-- Migration: add_smoker_experience_notes
-- Jira: KAN-44 (Fighter profiles and records)
--
-- Smokers aren't judged, so a smoker record is a bout count rather than
-- W/L/D (migration 20261119181450). Coaches can now also describe that
-- experience in words, for example "two smokers, a year of sparring,
-- some boxing".
--
-- The smoker row itself stays optional for every fighter, so a coach can
-- skip it for an amateur fighter. It mostly matters for smoker fighters and
-- for amateurs looking for their first amateur bout.


alter table public.fighter_record
  add column experience_notes text,
  -- Notes only belong on smoker rows; an amateur row is its W/L/D.
  -- Separate checks keep each error message specific.
  add constraint fighter_record_notes_smoker_only
    check (fight_type = 'smoker' or experience_notes is null),
  add constraint fighter_record_notes_length
    check (length(experience_notes) <= 500);

comment on column public.fighter_record.experience_notes is
  'Smoker rows only, optional: previous experience in the coach''s words. Other approved coaches will see it next to the fighter''s details, so it should not include the fighter''s name.';
