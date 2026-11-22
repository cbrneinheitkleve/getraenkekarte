-- CBRN Getränkekasse – Update: anzeigen, welche Admins gerade online sind
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.

alter table public.admins add column if not exists zuletzt_aktiv timestamptz;

-- Jeder Admin darf nur seinen eigenen Zeitstempel setzen (Zeit kommt vom Server)
create or replace function public.admin_lebenszeichen() returns void
language sql security definer set search_path = public as $$
  update public.admins set zuletzt_aktiv = now()
  where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and public.is_admin();
$$;
revoke execute on function public.admin_lebenszeichen() from public, anon;
grant execute on function public.admin_lebenszeichen() to authenticated;

notify pgrst, 'reload schema';
