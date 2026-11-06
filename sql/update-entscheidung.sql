-- CBRN Getränkekasse – Update: Karteninhaber entscheiden selbst (Klarname oder Deckname)
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.
-- Voraussetzung: update-einwilligung.sql wurde bereits ausgeführt.

alter table public.karten add column if not exists einwilligung timestamptz;
alter table public.karten add column if not exists wahl text;          -- 'klar' oder 'deck', null = noch nicht entschieden
alter table public.karten add column if not exists wahl_am timestamptz;
alter table public.karten add column if not exists freigegeben boolean not null default true;  -- bestehende Karten bleiben nutzbar

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'karten_wahl_check') then
    alter table public.karten add constraint karten_wahl_check check (wahl in ('klar','deck'));
  end if;
end $$;

-- Karte anzeigen (ohne Anmeldung, nur mit Code + geheimem Token aus dem Link)
create or replace function public.karte_anzeigen(p_code text, p_token text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'code', k.code, 'name', k.name, 'aktiv', k.aktiv, 'wert', k.wert,
    'freigegeben', k.freigegeben, 'wahl', k.wahl, 'wahl_am', k.wahl_am, 'einwilligung', k.einwilligung,
    'guthaben', coalesce((select sum(case when b.typ = 'auf' then b.betrag else -b.betrag end)
                          from public.buchungen b where b.karte = k.code), 0),
    'preis', c.preis, 'einheit', c.einheit,
    'logo', c.logo, 'farbe', c.farbe, 'akzent', c.akzent,
    'verlauf', coalesce((select json_agg(x) from (
        select typ, betrag, anzahl, created_at from public.buchungen b
        where b.karte = k.code order by created_at desc limit 20) x), '[]'::json)
  )
  from public.karten k cross join public.config c
  where c.id = 1 and k.code = upper(p_code) and k.token = p_token;
$$;
grant execute on function public.karte_anzeigen(text, text) to anon, authenticated;

-- Entscheidung der Person: 'klar' = Einwilligung in Klarnamen (Karte wird sofort freigeschaltet),
-- 'deck' = Deckname gewünscht (Admin vergibt Deckname und schaltet frei). Widerruf = 'deck'.
create or replace function public.karte_entscheidung(p_code text, p_token text, p_wahl text) returns json
language plpgsql security definer set search_path = public as $$
begin
  if p_wahl not in ('klar','deck') then raise exception 'Ungültige Auswahl'; end if;
  update public.karten set
    wahl = p_wahl,
    wahl_am = now(),
    einwilligung = case when p_wahl = 'klar' then now() else null end,
    freigegeben = case when p_wahl = 'klar' then true else freigegeben end
  where code = upper(p_code) and token = p_token;
  return public.karte_anzeigen(p_code, p_token);
end $$;
revoke execute on function public.karte_entscheidung(text, text, text) from public;
grant execute on function public.karte_entscheidung(text, text, text) to anon, authenticated;

-- Abbuchen beim Scannen: zusätzlich nur freigeschaltete Karten
create or replace function public.abbuchen(p_code text, p_anzahl int default 1) returns json
language plpgsql security definer set search_path = public as $$
declare
  k public.karten;
  v_anz int := greatest(1, least(coalesce(p_anzahl, 1), 10));
  v_preis int; v_bal int; v_betrag int; v_id uuid;
begin
  if not public.is_admin() then raise exception 'Keine Berechtigung'; end if;
  select * into k from public.karten where code = upper(p_code) for update;
  if not found then return json_build_object('ok', false, 'fehler', 'nicht_gefunden'); end if;
  if not k.aktiv then return json_build_object('ok', false, 'fehler', 'deaktiviert', 'name', k.name); end if;
  if not k.freigegeben then return json_build_object('ok', false, 'fehler', 'nicht_freigegeben', 'name', k.name, 'wahl', k.wahl); end if;
  select preis into v_preis from public.config where id = 1;
  v_betrag := v_preis * v_anz;
  select coalesce(sum(case when typ = 'auf' then betrag else -betrag end), 0) into v_bal
    from public.buchungen where karte = k.code;
  if v_bal < v_betrag then
    return json_build_object('ok', false, 'fehler', 'guthaben', 'name', k.name, 'guthaben', v_bal, 'betrag', v_betrag);
  end if;
  insert into public.buchungen(karte, typ, betrag, anzahl) values (k.code, 'ab', v_betrag, v_anz) returning id into v_id;
  return json_build_object('ok', true, 'id', v_id, 'code', k.code, 'name', k.name,
                           'betrag', v_betrag, 'anzahl', v_anz, 'guthaben', v_bal - v_betrag);
end $$;
revoke execute on function public.abbuchen(text, int) from public, anon;
grant execute on function public.abbuchen(text, int) to authenticated;

notify pgrst, 'reload schema';
