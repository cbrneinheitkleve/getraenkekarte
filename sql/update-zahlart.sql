-- CBRN Getränkekasse – Update: Zahlungsart (Bar oder PayPal) bei Einnahmen und Aufladungen
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.
-- Bisherige Einträge ohne Angabe gelten als Bar.

alter table public.kasse     add column if not exists zahlart text;
alter table public.buchungen add column if not exists zahlart text;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'kasse_zahlart_check') then
    alter table public.kasse add constraint kasse_zahlart_check check (zahlart in ('bar','paypal'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'buchungen_zahlart_check') then
    alter table public.buchungen add constraint buchungen_zahlart_check check (zahlart in ('bar','paypal'));
  end if;
end $$;

notify pgrst, 'reload schema';
