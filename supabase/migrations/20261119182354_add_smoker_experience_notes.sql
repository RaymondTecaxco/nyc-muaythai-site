-- Optional free-text experience on smoker records, e.g. "two smokers, a
-- year of sparring, some boxing" (KAN-44). A bout count alone doesn't say
-- much for fighters looking for their first amateur bout.


alter table public.fighter_record
  add column experience_notes text,
  -- two checks instead of one so each failure has a clear error
  add constraint fighter_record_notes_smoker_only
    check (fight_type = 'smoker' or experience_notes is null),
  add constraint fighter_record_notes_length
    check (length(experience_notes) <= 500);

comment on column public.fighter_record.experience_notes is
  'Smoker rows only, optional: previous experience in the coach''s words. Other approved coaches will see it next to the fighter''s details, so it should not include the fighter''s name.';
