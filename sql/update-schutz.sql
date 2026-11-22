-- CBRN Getränkekasse – Update: geschützter Admin (kann nicht entfernt werden)
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.
-- WICHTIG: In Zeile "update public.admins set geschuetzt = true where ..." muss die E-Mail stehen,
--          mit der DU in der App angemeldet bist (Mehr → ganz unten "Angemeldet als …").

alter table public.admins add column if not exists geschuetzt boolean not null default false;

-- Dich schützen:
update public.admins set geschuetzt = true where lower(email) = lower('cbrn.einheit@web.de');

-- Hilfsfunktion: ist der angemeldete Admin geschützt?
create or replace function public.ist_geschuetzt() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.admins
                where lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')) and geschuetzt);
$$;
grant execute on function public.ist_geschuetzt() to authenticated;

-- Admins dürfen neue Admins nur mit E-Mail anlegen (nicht geschützt) und Einträge nicht direkt ändern
revoke insert, update on public.admins from authenticated;
grant insert (email) on public.admins to authenticated;

-- Schutz vergeben/entziehen: nur durch einen geschützten Admin; der letzte Schutz bleibt immer bestehen
create or replace function public.schutz_setzen(p_email text, p_an boolean) returns json
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  if not public.ist_geschuetzt() then raise exception 'Keine Berechtigung'; end if;
  if not p_an and (select count(*) from public.admins where geschuetzt and lower(email) <> lower(p_email)) = 0 then
    raise exception 'Mindestens ein Admin muss geschützt bleiben';
  end if;
  update public.admins set geschuetzt = p_an where lower(email) = lower(p_email);
  get diagnostics v_n = row_count;
  return json_build_object('ok', v_n = 1);
end $$;
revoke execute on function public.schutz_setzen(text, boolean) from public, anon;
grant execute on function public.schutz_setzen(text, boolean) to authenticated;

-- Löschen: geschützte Admins können nicht entfernt werden (Rest wie bisher, inkl. Protokoll)
create or replace function public.loeschen(p_bereich text, p_id text, p_grund text) returns json
language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_beleg text; v_belege text[];
begin
  if not public.is_admin() then raise exception 'Keine Berechtigung'; end if;
  if coalesce(trim(p_grund), '') = '' then raise exception 'Bitte einen Löschgrund angeben'; end if;
  perform set_config('app.grund', left(trim(p_grund), 300), true);
  if p_bereich = 'buchung' then
    delete from public.buchungen where id = p_id::uuid;
    get diagnostics v_n = row_count;
  elsif p_bereich = 'kasse' then
    delete from public.kasse where id = p_id::uuid returning beleg into v_beleg;
    get diagnostics v_n = row_count;
    v_belege := array_remove(array[v_beleg], null);
  elsif p_bereich = 'kasse_karte' then
    select array_agg(beleg) filter (where beleg is not null) into v_belege from public.kasse where karte = upper(p_id);
    delete from public.kasse where karte = upper(p_id);
    get diagnostics v_n = row_count;
  elsif p_bereich = 'karte' then
    delete from public.karten where code = upper(p_id);
    get diagnostics v_n = row_count;
  elsif p_bereich = 'admin' then
    if lower(p_id) = lower(coalesce(auth.jwt() ->> 'email', '')) then raise exception 'Du kannst dich nicht selbst entfernen'; end if;
    if exists (select 1 from public.admins where lower(email) = lower(p_id) and geschuetzt) then
      raise exception 'Dieser Admin kann nicht entfernt werden';
    end if;
    delete from public.admins where lower(email) = lower(p_id);
    get diagnostics v_n = row_count;
  else
    raise exception 'Unbekannter Bereich';
  end if;
  return json_build_object('ok', v_n > 0, 'anzahl', v_n, 'belege', coalesce(to_json(v_belege), '[]'::json));
end $$;
revoke execute on function public.loeschen(text, text, text) from public, anon;
grant execute on function public.loeschen(text, text, text) to authenticated;

notify pgrst, 'reload schema';

-- Kontrolle: zeigt, wer geschützt ist
select email, geschuetzt from public.admins order by email;
