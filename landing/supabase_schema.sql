-- Human Typer licensing — run this once in the Supabase SQL editor.
--
-- All access is via the two functions below, called by the Vercel API using the
-- SERVICE_ROLE key (which bypasses RLS). The table itself is locked down (RLS on,
-- no policies), so the public/publishable key can neither read nor write it.

create table if not exists public.licenses (
  key          text primary key,
  status       text not null default 'active',   -- 'active' | 'revoked'
  sold         boolean not null default false,    -- claimed via a Paystack payment
  email        text,
  payment_ref  text,
  device_id    text,                              -- bound machine (null until activated)
  activated_at timestamptz,
  created_at   timestamptz not null default now()
);

alter table public.licenses enable row level security;
-- (no policies on purpose => anon/publishable key has zero access to this table)

-- Canonical form: alphanumerics only, uppercased. Matches the app's _normalize_key
-- and gen_licenses.py, so dashes/case/spacing in a pasted key never matter.
create or replace function public.canon(p text)
returns text language sql immutable as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'))
$$;

-- Activate (bind) a key to one device. Returns {ok, reason}.
--   reasons: invalid | revoked | in_use
create or replace function public.activate_key(p_key text, p_device text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.licenses;
begin
  select * into r from public.licenses where canon(key) = canon(p_key) for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'invalid'); end if;
  if r.status = 'revoked' then return jsonb_build_object('ok', false, 'reason', 'revoked'); end if;
  if r.device_id is null then
    update public.licenses set device_id = p_device, activated_at = now() where key = r.key;
    return jsonb_build_object('ok', true);
  elsif r.device_id = p_device then
    return jsonb_build_object('ok', true);           -- same machine re-checking; fine
  else
    return jsonb_build_object('ok', false, 'reason', 'in_use');
  end if;
end $$;

-- Atomically hand out one unsold key for a paid order. Idempotent per payment_ref.
-- Returns {key, new} ; key is null if the pool is empty.
create or replace function public.claim_key(p_email text, p_ref text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k text;
begin
  -- serialize concurrent calls for the same payment (client callback + webhook)
  perform pg_advisory_xact_lock(hashtext(p_ref));
  select key into k from public.licenses where payment_ref = p_ref limit 1;
  if k is not null then return jsonb_build_object('key', k, 'new', false); end if;

  select key into k from public.licenses
    where sold = false and status = 'active'
    order by created_at limit 1 for update skip locked;
  if k is null then return jsonb_build_object('key', null, 'new', false); end if;

  update public.licenses set sold = true, email = p_email, payment_ref = p_ref where key = k;
  return jsonb_build_object('key', k, 'new', true);
end $$;

-- Only the service_role (the Vercel API) may call these; lock out the public key.
revoke all on function public.activate_key(text, text) from public, anon, authenticated;
revoke all on function public.claim_key(text, text)   from public, anon, authenticated;

-- To REVOKE a key later (kills it on next online check / blocks new activation):
--   update public.licenses set status = 'revoked' where key = 'HT-XXXXX-XXXXX-XXXXX';
-- To move a buyer to a new machine (clear the binding):
--   update public.licenses set device_id = null where key = 'HT-XXXXX-XXXXX-XXXXX';
