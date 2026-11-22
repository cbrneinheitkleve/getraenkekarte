-- CBRN Getränkekasse – Update: Löschprotokoll mit Löschgrund
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.
-- Danach kann nur noch über die App (mit Grund) gelöscht werden; jede Löschung wird automatisch protokolliert.

-- 1) Protokoll-Tabelle: nur lesbar für Admins, nicht änderbar
create table if not exists public.protokoll (
  id bigint generated always as identity primary key,
  zeit timestamptz not null default now(),
  admin text,
  aktion text not null,
  bereich text not null,
  karte text,
  betrag int,
  grund text,
  details jsonb
);
alter table public.protokoll enable row level security;
drop policy if exists protokoll_lesen on public.protokoll;
create policy protokoll_lesen on public.protokoll for select to authenticated using (public.is_admin());
revoke all on public.protokoll from anon, authenticated;
grant select on public.protokoll to authenticated;

-- 2) Trigger: jede Löschung wird festgehalten (auch Löschungen, die automatisch mit einer Karte mitgehen)
create or replace function public.protokoll_loeschung() returns trigger
language plpgsql security definer set search_path = public as $$
declare d jsonb := to_jsonb(old); v_bereich text;
begin
  v_bereich := case tg_table_name
    when 'buchungen' then case d->>'typ' when 'auf' then 'Aufladung' else 'Abbuchung' end
    when 'kasse' then 'Kassenbuch'
    when 'karten' then 'Karte'
    when 'admins' then 'Admin'
    else tg_table_name end;
  if tg_table_name = 'karten' then
    d := d - 'token' - 'name_enc';
    if d->>'einwilligung' is not null then d := d - 'name'; end if;   -- Klarnamen nicht ins Protokoll übernehmen
  end if;
  insert into public.protokoll(admin, aktion, bereich, karte, betrag, grund, details)
  values (auth.jwt() ->> 'email', 'gelöscht', v_bereich,
          coalesce(d->>'karte', d->>'code'),
          nullif(d->>'betrag','')::int,
          nullif(current_setting('app.grund', true), ''),
          d);
  return old;
end $$;

drop trigger if exists protokoll_del on public.buchungen;
create trigger protokoll_del after delete on public.buchungen for each row execute function public.protokoll_loeschung();
drop trigger if exists protokoll_del on public.kasse;
create trigger protokoll_del after delete on public.kasse for each row execute function public.protokoll_loeschung();
drop trigger if exists protokoll_del on public.karten;
create trigger protokoll_del after delete on public.karten for each row execute function public.protokoll_loeschung();
drop trigger if exists protokoll_del on public.admins;
create trigger protokoll_del after delete on public.admins for each row execute function public.protokoll_loeschung();

-- 3) Löschen nur noch mit Grund über diese Funktion
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
    delete from public.admins where lower(email) = lower(p_id);
    get diagnostics v_n = row_count;
  else
    raise exception 'Unbekannter Bereich';
  end if;
  return json_build_object('ok', v_n > 0, 'anzahl', v_n, 'belege', coalesce(to_json(v_belege), '[]'::json));
end $$;
revoke execute on function public.loeschen(text, text, text) from public, anon;
grant execute on function public.loeschen(text, text, text) to authenticated;

-- 4) Direktes Löschen aus der App heraus sperren (geht nur noch über loeschen())
revoke delete on public.buchungen, public.kasse, public.karten, public.admins from authenticated;

notify pgrst, 'reload schema';
