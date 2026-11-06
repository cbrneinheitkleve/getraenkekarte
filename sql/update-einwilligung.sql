-- CBRN Getränkekasse – Update: Klarname mit Einwilligung
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.

alter table public.karten add column if not exists einwilligung timestamptz;
notify pgrst, 'reload schema';
