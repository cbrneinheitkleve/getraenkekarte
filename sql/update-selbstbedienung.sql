-- CBRN Getränkekasse – Update: Selbstbedienung per QR-Code am Getränkestand
-- Im Supabase SQL Editor einfügen und "Run" drücken. Mehrfaches Ausführen schadet nicht.
-- Voraussetzung: update-entscheidung.sql wurde bereits ausgeführt.

alter table public.config add column if not exists selbstbedienung boolean not null default false;

-- Karte anzeigen (ohne Anmeldung, nur mit Code + geheimem Token aus dem Link) – jetzt mit Selbstbedienungs-Schalter
create or replace function public.karte_anzeigen(p_code text, p_token text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'code', k.code, 'name', k.name, 'aktiv', k.aktiv, 'wert', k.wert,
    'freigegeben', k.freigegeben, 'wahl', k.wahl, 'wahl_am', k.wahl_am, 'einwilligung', k.einwilligung,
    'guthaben', coalesce((select sum(case when b.typ = 'auf' then b.betrag else -b.betrag end)
                          from public.buchungen b where b.karte = k.code), 0),
    'preis', c.preis, 'einheit', c.einheit, 'selbstbedienung', c.selbstbedienung,
    'logo', c.logo, 'farbe', c.farbe, 'akzent', c.akzent,
    'verlauf', coalesce((select json_agg(x) from (
        select typ, betrag, anzahl, created_at, (von = 'Selbstbedienung') as selbst from public.buchungen b
        where b.karte = k.code order by created_at desc limit 20) x), '[]'::json)
  )
  from public.karten k cross join public.config c
  where c.id = 1 and k.code = upper(p_code) and k.token = p_token;
$$;
grant execute on function public.karte_anzeigen(text, text) to anon, authenticated;

-- Selbst abbuchen: Karteninhaber bucht mit dem eigenen Kartenlink ab (nur wenn Selbstbedienung eingeschaltet).
-- p_bewusst = false beim Scannen des Aushangs (Schutz gegen Doppel-Scan), true bei bewusstem Tipp auf "Noch ein Getränk".
drop function if exists public.selbst_abbuchen(text, text, int);
create or replace function public.selbst_abbuchen(p_code text, p_token text, p_anzahl int default 1, p_bewusst boolean default false) returns json
language plpgsql security definer set search_path = public as $$
declare
  k public.karten;
  v_anz int := greatest(1, least(coalesce(p_anzahl, 1), 5));
  v_preis int; v_an boolean; v_bal int; v_betrag int; v_id uuid;
begin
  select preis, selbstbedienung into v_preis, v_an from public.config where id = 1;
  if not v_an then return json_build_object('ok', false, 'fehler', 'aus'); end if;
  select * into k from public.karten where code = upper(p_code) and token = p_token for update;
  if not found then return json_build_object('ok', false, 'fehler', 'nicht_gefunden'); end if;
  if not k.aktiv then return json_build_object('ok', false, 'fehler', 'deaktiviert'); end if;
  if not k.freigegeben then return json_build_object('ok', false, 'fehler', 'nicht_freigegeben'); end if;
  -- Schutz gegen versehentliches Doppel-Tippen
  if not coalesce(p_bewusst, false) and exists (select 1 from public.buchungen where karte = k.code and von = 'Selbstbedienung'
             and created_at > now() - interval '15 seconds') then
    return json_build_object('ok', false, 'fehler', 'zu_schnell');
  end if;
  v_betrag := v_preis * v_anz;
  select coalesce(sum(case when typ = 'auf' then betrag else -betrag end), 0) into v_bal
    from public.buchungen where karte = k.code;
  if v_bal < v_betrag then
    return json_build_object('ok', false, 'fehler', 'guthaben', 'guthaben', v_bal, 'betrag', v_betrag);
  end if;
  insert into public.buchungen(karte, typ, betrag, anzahl, von)
    values (k.code, 'ab', v_betrag, v_anz, 'Selbstbedienung') returning id into v_id;
  return json_build_object('ok', true, 'id', v_id, 'name', k.name, 'betrag', v_betrag, 'anzahl', v_anz, 'guthaben', v_bal - v_betrag);
end $$;
revoke execute on function public.selbst_abbuchen(text, text, int, boolean) from public;
grant execute on function public.selbst_abbuchen(text, text, int, boolean) to anon, authenticated;

-- Kein Selbst-Storno: Fehlbuchungen storniert nur ein Admin (in der App)
drop function if exists public.selbst_storno(text, text, uuid);

notify pgrst, 'reload schema';
