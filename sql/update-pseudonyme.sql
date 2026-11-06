-- Getränkekarte: Element-Decknamen + verschlüsselte Klarnamen
-- Einmal im Supabase-Dashboard unter "SQL Editor" ausführen.

-- Verschlüsselter Klarname (nur Zeichensalat, Schlüssel kennt nur der Admin-Browser)
alter table public.karten add column if not exists name_enc text;

-- Salz und Prüfwert für das gemeinsame Admin-Passwort (enthält kein Passwort)
alter table public.config add column if not exists krypto jsonb;

-- Schema-Cache neu laden, damit die App die Spalten sofort sieht
notify pgrst, 'reload schema';
