-- v0.46b Bot avatars — display only. Empty until avatars exist; the console shows a placeholder circle.
-- Value = image URL or a path relative to the tablet app, e.g. 'avatars/milk_planning.png'.
alter table fabula.bot_nicknames add column if not exists avatar_url text;
comment on column fabula.bot_nicknames.avatar_url is 'Display only: small square avatar (any size, shown at 44 px). Null = placeholder with initial.';
