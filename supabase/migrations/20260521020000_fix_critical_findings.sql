-- ============================================================================
-- YUMI PAY: BANK-GRADE COMPLETE HARDENING (Migration 20260521020000)
-- Audit Sécurité Bancaire Exhaustif & Modèle de Conformité BEAC / CCEI Bank
-- ============================================================================

-- 0. EXTENSIONS ET SCHÉMA INTERNE SÉCURISÉ
create extension if not exists pgcrypto with schema extensions;

create schema if not exists internal;
revoke all on schema internal from public, anon, authenticated;
grant usage on schema internal to postgres;

-- 1. NETTOYAGE ET SUPPRESSION DES ANCIENNES FONCTIONS VULNÉRABLES
drop function if exists public.send_money(text, bigint, text);
drop function if exists public.send_money_v2;
drop function if exists public.verify_and_track_pin;
drop function if exists public.request_cash_out;
drop function if exists public.agent_execute_cash_out(text);
drop function if exists public.check_user_pin_safe(uuid, text);
drop function if exists public.protect_sensitive_profile_fields() cascade;
drop trigger if exists trg_protect_profile_fields on public.profiles;

-- 2. GESTION DES COMPTES SYSTÈME BANCAIRE
create table if not exists public.system_accounts (
  id text primary key,
  name text not null,
  balance_xaf numeric not null default 0 check (balance_xaf >= 0),
  updated_at timestamptz not null default now()
);

alter table public.system_accounts enable row level security;
drop policy if exists "Admins view system accounts" on public.system_accounts;
create policy "Admins view system accounts" on public.system_accounts for select to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

insert into public.system_accounts (id, name, balance_xaf)
values 
  ('bank_fee_pool', 'Yumi Bank Revenue & Fee Pool', 0),
  ('cashout_hold', 'Yumi Cash-Out Escrow Hold', 0)
on conflict (id) do nothing;

-- 3. INTÉGRITÉ DU GRAND LIVRE COMPTABLE (DOUBLE-ENTRY LEDGER)
-- Autoriser les types de comptes personnels, agents, et système
alter table public.ledger_entries drop constraint if exists ledger_entries_wallet_type_check;
alter table public.ledger_entries add constraint ledger_entries_wallet_type_check
  check (wallet_type in ('personal', 'agent_float', 'bank_fee_pool', 'cashout_hold'));

alter table public.ledger_entries alter column account_id drop not null;
alter table public.ledger_entries add column if not exists system_account_id text references public.system_accounts(id);

-- Rétablir la clé étrangère stricte vers profiles
alter table public.ledger_entries drop constraint if exists ledger_entries_account_id_fkey;
alter table public.ledger_entries add constraint ledger_entries_account_id_fkey 
  foreign key (account_id) references public.profiles(id) on delete restrict;

-- Contrainte XOR : Exactement un des deux champs (account_id ou system_account_id) doit être non-nul
alter table public.ledger_entries drop constraint if exists ledger_account_xor;
alter table public.ledger_entries add constraint ledger_account_xor
  check ((account_id is not null and system_account_id is null) or (account_id is null and system_account_id is not null));

alter table public.ledger_entries drop constraint if exists ledger_amount_positive;
alter table public.ledger_entries add constraint ledger_amount_positive 
  check (amount_xaf > 0);

-- 4. PROTECTION NATIVE PAR COLONNE (SANS TRIGGER BLOQUANT)
-- Empêche toute modification directe des colonnes financières, PIN et rôles par l'API PostgREST
revoke update on public.profiles from anon, authenticated;
grant update (full_name) on public.profiles to authenticated;

-- Contraintes d'intégrité sur les profils et transactions
alter table public.profiles drop constraint if exists profiles_balance_positive;
alter table public.profiles add constraint profiles_balance_positive 
  check (balance_xaf >= 0 and agent_balance_xaf >= 0);

alter table public.transactions drop constraint if exists transactions_amount_positive;
alter table public.transactions add constraint transactions_amount_positive 
  check (amount_xaf > 0 and fee_xaf >= 0);

-- Unicité stricte sur idempotency_key par émetteur
drop index if exists transactions_sender_idempotency_idx;
create unique index if not exists transactions_sender_idempotency_idx 
  on public.transactions(sender_id, idempotency_key) where idempotency_key is not null;

-- Index partiel unique sur les codes de retrait actifs (pending)
drop index if exists withdrawal_codes_active_unique_idx;
create unique index if not exists withdrawal_codes_active_unique_idx 
  on public.withdrawal_codes(code) where status = 'pending';

-- 5. CONFIGURATION SÉCURISÉE DU CODE PIN (AVEC VÉRIFICATION DE L'ANCIEN PIN)
create or replace function public.set_transaction_pin(p_new_pin text, p_old_pin text default null)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_stored_hash text;
begin
  if v_user is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Sesión no válida');
  end if;

  if length(p_new_pin) < 4 or length(p_new_pin) > 6 or p_new_pin !~ '^[0-9]+$' then
    return json_build_object('ok', false, 'error', 'INVALID_PIN_FORMAT', 'message', 'El PIN debe contener entre 4 y 6 dígitos numéricos');
  end if;

  select transaction_pin_hash into v_stored_hash from public.profiles where id = v_user;

  -- Si un PIN est déjà configuré, l'ancien PIN doit impérativement être validé
  if v_stored_hash is not null then
    if p_old_pin is null or crypt(p_old_pin, v_stored_hash) <> v_stored_hash then
      return json_build_object('ok', false, 'error', 'OLD_PIN_INCORRECT', 'message', 'El código PIN actual es incorrecto');
    end if;
  end if;

  update public.profiles
  set transaction_pin_hash = crypt(p_new_pin, gen_salt('bf', 8)),
      failed_pin_attempts = 0,
      pin_locked_until = null
  where id = v_user;

  return json_build_object('ok', true, 'message', 'Código PIN configurado correctamente');
end;
$$;
grant execute on function public.set_transaction_pin(text, text) to authenticated;

-- 6. FONCTION DE TRANSFERT P2P ANTI-DEADLOCK, IDEMPOTENTE & SÉCURISÉE
create or replace function public.send_money_v3(
  p_recipient_phone text,
  p_amount numeric,
  p_pin text,
  p_note text default null,
  p_idempotency_key text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_sender uuid := auth.uid();
  v_recipient uuid;
  v_sender_balance numeric;
  v_recipient_balance numeric;
  v_sender_kyc text;
  v_sender_pin_hash text;
  v_sender_attempts integer;
  v_sender_locked_until timestamptz;
  v_sender_frozen boolean;
  v_recipient_frozen boolean;
  v_today_transferred numeric;
  v_daily_limit numeric;
  v_fee numeric := 0;
  v_total_deduction numeric;
  v_existing_tx public.transactions;
  v_tx_id uuid;
begin
  -- 1. Contrôle d'authentification
  if v_sender is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Sesión no válida o expirada');
  end if;

  -- 2. Validation stricte du montant
  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'Monto inválido');
  end if;

  -- 3. Idempotence préalable
  if p_idempotency_key is not null then
    select * into v_existing_tx from public.transactions 
    where sender_id = v_sender and idempotency_key = p_idempotency_key;
    if v_existing_tx.id is not null then
      return json_build_object('ok', true, 'status', 'ALREADY_PROCESSED', 'transaction', row_to_json(v_existing_tx));
    end if;
  end if;

  -- 4. Recherche préalable du destinataire
  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then
    return json_build_object('ok', false, 'error', 'RECIPIENT_NOT_FOUND', 'message', 'Destinatario no encontrado');
  end if;
  if v_recipient = v_sender then
    return json_build_object('ok', false, 'error', 'SELF_TRANSFER', 'message', 'No puedes enviarte dinero a ti mismo');
  end if;

  -- 5. VERROUILLAGE ORDONNANCÉ ABSOLU (ANTI-DEADLOCK MATHÉMATIQUE)
  if v_sender < v_recipient then
    select balance_xaf, kyc_tier, transaction_pin_hash, failed_pin_attempts, pin_locked_until, is_frozen
    into v_sender_balance, v_sender_kyc, v_sender_pin_hash, v_sender_attempts, v_sender_locked_until, v_sender_frozen
    from public.profiles where id = v_sender for update;

    select balance_xaf, is_frozen
    into v_recipient_balance, v_recipient_frozen
    from public.profiles where id = v_recipient for update;
  else
    select balance_xaf, is_frozen
    into v_recipient_balance, v_recipient_frozen
    from public.profiles where id = v_recipient for update;

    select balance_xaf, kyc_tier, transaction_pin_hash, failed_pin_attempts, pin_locked_until, is_frozen
    into v_sender_balance, v_sender_kyc, v_sender_pin_hash, v_sender_attempts, v_sender_locked_until, v_sender_frozen
    from public.profiles where id = v_sender for update;
  end if;

  -- 6. Contrôles des statuts de gel
  if v_sender_frozen then
    return json_build_object('ok', false, 'error', 'FROZEN', 'message', 'Tu cuenta está congelada preventivamente');
  end if;
  if v_recipient_frozen then
    return json_build_object('ok', false, 'error', 'RECIPIENT_FROZEN', 'message', 'La cuenta del destinatario está restringida');
  end if;

  -- 7. Vérification du PIN et persistance du verrouillage
  if v_sender_locked_until is not null and v_sender_locked_until > now() then
    return json_build_object(
      'ok', false, 'error', 'LOCKED',
      'message', 'Código PIN temporalmente bloqueado. Espera ' || round(extract(epoch from (v_sender_locked_until - now())) / 60) || ' minutos.'
    );
  end if;

  if v_sender_pin_hash is null then
    return json_build_object('ok', false, 'error', 'NO_PIN', 'message', 'Debes configurar tu código PIN antes de enviar dinero');
  end if;

  if crypt(p_pin, v_sender_pin_hash) <> v_sender_pin_hash then
    v_sender_attempts := coalesce(v_sender_attempts, 0) + 1;
    if v_sender_attempts >= 5 then
      update public.profiles 
      set failed_pin_attempts = v_sender_attempts,
          pin_locked_until = now() + interval '15 minutes'
      where id = v_sender;
      return json_build_object('ok', false, 'error', 'LOCKED', 'message', 'Has alcanzado 5 intentos fallidos. Cuenta bloqueada 15 minutos.');
    else
      update public.profiles set failed_pin_attempts = v_sender_attempts where id = v_sender;
      return json_build_object('ok', false, 'error', 'INVALID_PIN', 'message', 'Código PIN incorrecto (' || (5 - v_sender_attempts) || ' intentos restantes).');
    end if;
  else
    -- Réinitialisation du compteur sur succès
    if coalesce(v_sender_attempts, 0) > 0 or v_sender_locked_until is not null then
      update public.profiles set failed_pin_attempts = 0, pin_locked_until = null where id = v_sender;
    end if;
  end if;

  -- 8. Plafonds KYC stricts
  if v_sender_kyc = 'tier_1' then
    v_daily_limit := 200000;
  elsif v_sender_kyc = 'tier_2' then
    v_daily_limit := 2000000;
  elsif v_sender_kyc = 'tier_3' then
    v_daily_limit := 10000000;
  else
    return json_build_object('ok', false, 'error', 'INVALID_KYC', 'message', 'Nivel de verificación KYC no válido');
  end if;

  select coalesce(sum(amount_xaf), 0) into v_today_transferred
  from public.transactions
  where sender_id = v_sender 
    and status = 'completed'
    and created_at >= date_trunc('day', now() at time zone 'Africa/Malabo');

  if (v_today_transferred + p_amount) > v_daily_limit then
    return json_build_object(
      'ok', false, 'error', 'DAILY_LIMIT_EXCEEDED', 
      'message', 'Límite diario superado (' || v_daily_limit || ' XAF permitidos para tu nivel ' || v_sender_kyc || ')'
    );
  end if;

  -- 9. Calcul des frais (1% dès 1 000 XAF, min 50 XAF, max 3 000 XAF)
  if p_amount >= 1000 then
    v_fee := greatest(50, least(round(p_amount * 0.01), 3000));
  else
    v_fee := 0;
  end if;
  v_total_deduction := p_amount + v_fee;

  if v_sender_balance < v_total_deduction then
    return json_build_object(
      'ok', false, 'error', 'INSUFFICIENT_FUNDS', 
      'message', 'Saldo insuficiente (Total con comisión: ' || v_total_deduction || ' XAF)'
    );
  end if;

  -- 10. Mouvements des soldes
  update public.profiles set balance_xaf = balance_xaf - v_total_deduction where id = v_sender;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;
  
  if v_fee > 0 then
    update public.system_accounts 
    set balance_xaf = balance_xaf + v_fee, updated_at = now() 
    where id = 'bank_fee_pool';
  end if;

  -- 11. Enregistrement transactionnel protégé contre les accès concurrents
  begin
    insert into public.transactions (
      sender_id, recipient_id, amount_xaf, fee_xaf, note, type, status, idempotency_key
    ) values (
      v_sender, v_recipient, p_amount, v_fee, p_note, 'transfer', 'completed', p_idempotency_key
    ) returning id into v_tx_id;
  exception when unique_violation then
    select * into v_existing_tx from public.transactions 
    where sender_id = v_sender and idempotency_key = p_idempotency_key;
    return json_build_object('ok', true, 'status', 'ALREADY_PROCESSED', 'transaction', row_to_json(v_existing_tx));
  end;

  -- 12. GRAND LIVRE EN PARTIE DOUBLE (Balance nulle garantie)
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_sender, null, 'personal', 'debit', v_total_deduction, v_sender_balance - v_total_deduction, 'Transfert P2P vers ' || p_recipient_phone);

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_recipient, null, 'personal', 'credit', p_amount, v_recipient_balance + p_amount, 'Transfert reçu de ' || v_sender);

  if v_fee > 0 then
    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx_id, null, 'bank_fee_pool', 'bank_fee_pool', 'credit', v_fee, (select balance_xaf from public.system_accounts where id = 'bank_fee_pool'), 'Comisión transferencia P2P');
  end if;

  return json_build_object(
    'ok', true,
    'status', 'COMPLETED',
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'fee', v_fee,
    'new_balance', v_sender_balance - v_total_deduction
  );
end;
$$;
grant execute on function public.send_money_v3(text, numeric, text, text, text) to authenticated;

-- 7. DEMANDE DE RETRAIT AVEC SÉQUESTRE COMPTABLE IMMÉDIAT
create or replace function public.request_cash_out_v3(p_amount numeric, p_pin text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_balance numeric;
  v_kyc text;
  v_pin_hash text;
  v_attempts integer;
  v_locked_until timestamptz;
  v_is_frozen boolean;
  v_fee numeric;
  v_commission numeric;
  v_total numeric;
  v_code text;
  v_max_single numeric;
  v_daily_limit numeric;
  v_today_withdrawn numeric;
  v_code_record public.withdrawal_codes;
  v_tx_id uuid;
begin
  if v_user is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Sesión no válida');
  end if;

  if p_amount is null or p_amount < 500 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'El monto mínimo de retiro es de 500 XAF enteros');
  end if;

  -- 1. Verrouillage du profil utilisateur
  select balance_xaf, kyc_tier, transaction_pin_hash, failed_pin_attempts, pin_locked_until, is_frozen
  into v_balance, v_kyc, v_pin_hash, v_attempts, v_locked_until, v_is_frozen
  from public.profiles where id = v_user for update;

  if v_is_frozen then
    return json_build_object('ok', false, 'error', 'FROZEN', 'message', 'Tu cuenta está congelada preventivamente');
  end if;

  -- 2. Vérification PIN
  if v_locked_until is not null and v_locked_until > now() then
    return json_build_object(
      'ok', false, 'error', 'LOCKED',
      'message', 'Código PIN temporalmente bloqueado. Espera ' || round(extract(epoch from (v_locked_until - now())) / 60) || ' minutos.'
    );
  end if;

  if v_pin_hash is null then
    return json_build_object('ok', false, 'error', 'NO_PIN', 'message', 'Debes configurar tu código PIN antes de solicitar un retiro');
  end if;

  if crypt(p_pin, v_pin_hash) <> v_pin_hash then
    v_attempts := coalesce(v_attempts, 0) + 1;
    if v_attempts >= 5 then
      update public.profiles 
      set failed_pin_attempts = v_attempts,
          pin_locked_until = now() + interval '15 minutes'
      where id = v_user;
      return json_build_object('ok', false, 'error', 'LOCKED', 'message', 'Has alcanzado 5 intentos fallidos. Cuenta bloqueada 15 minutos.');
    else
      update public.profiles set failed_pin_attempts = v_attempts where id = v_user;
      return json_build_object('ok', false, 'error', 'INVALID_PIN', 'message', 'Código PIN incorrecto (' || (5 - v_attempts) || ' intentos restantes).');
    end if;
  else
    if coalesce(v_attempts, 0) > 0 or v_locked_until is not null then
      update public.profiles set failed_pin_attempts = 0, pin_locked_until = null where id = v_user;
    end if;
  end if;

  -- 3. Plafonds KYC pour les retraits d'espèces
  if v_kyc = 'tier_1' then
    v_max_single := 50000;
    v_daily_limit := 100000;
  elsif v_kyc = 'tier_2' then
    v_max_single := 500000;
    v_daily_limit := 1000000;
  elsif v_kyc = 'tier_3' then
    v_max_single := 2000000;
    v_daily_limit := 5000000;
  else
    return json_build_object('ok', false, 'error', 'INVALID_KYC', 'message', 'Nivel KYC no válido');
  end if;

  if p_amount > v_max_single then
    return json_build_object('ok', false, 'error', 'KYC_LIMIT_EXCEEDED', 'message', 'Monto máximo por retiro para nivel ' || v_kyc || ': ' || v_max_single || ' XAF');
  end if;

  select coalesce(sum(amount_xaf), 0) into v_today_withdrawn
  from public.withdrawal_codes
  where user_id = v_user 
    and status in ('pending', 'completed')
    and created_at >= date_trunc('day', now() at time zone 'Africa/Malabo');

  if (v_today_withdrawn + p_amount) > v_daily_limit then
    return json_build_object('ok', false, 'error', 'DAILY_LIMIT_EXCEEDED', 'message', 'Límite diario de retiros superado (' || v_daily_limit || ' XAF)');
  end if;

  -- 4. Un seul code pending à la fois
  if exists (select 1 from public.withdrawal_codes where user_id = v_user and status = 'pending' and expires_at > now()) then
    return json_build_object('ok', false, 'error', 'ACTIVE_CODE_EXISTS', 'message', 'Ya tienes un código de retiro activo. Cancélalo antes de solicitar otro.');
  end if;

  -- 5. Calcul des frais (1.5% min 100 XAF)
  v_fee := greatest(100, round(p_amount * 0.015));
  v_commission := round(v_fee * 0.65);
  v_total := p_amount + v_fee;

  if v_balance < v_total then
    return json_build_object('ok', false, 'error', 'INSUFFICIENT_FUNDS', 'message', 'Saldo insuficiente para retiro y comisión (Total: ' || v_total || ' XAF)');
  end if;

  -- 6. DÉBIT CLIENT ET CRÉDIT DU SÉQUESTRE COMPTABLE (CASHOUT_HOLD)
  update public.profiles set balance_xaf = balance_xaf - v_total where id = v_user;
  update public.system_accounts set balance_xaf = balance_xaf + v_total, updated_at = now() where id = 'cashout_hold';

  -- 7. Génération aléatoire d'un code à 6 chiffres
  v_code := lpad((abs(get_byte(gen_random_bytes(4), 0) * 65536 + get_byte(gen_random_bytes(4), 1) * 256 + get_byte(gen_random_bytes(4), 2)) % 900000 + 100000)::text, 6, '0');

  insert into public.withdrawal_codes (
    user_id, code, amount_xaf, fee_xaf, agent_commission_xaf, held_amount_xaf, status, expires_at
  ) values (
    v_user, v_code, p_amount, v_fee, v_commission, v_total, 'pending', now() + interval '15 minutes'
  ) returning * into v_code_record;

  -- 8. Écriture au Grand Livre du Séquestre
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (null, v_user, null, 'personal', 'debit', v_total, v_balance - v_total, 'Séquestre retrait espèces (Hold)');

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (null, null, 'cashout_hold', 'cashout_hold', 'credit', v_total, (select balance_xaf from public.system_accounts where id = 'cashout_hold'), 'Séquestre retenue retrait client');

  return json_build_object(
    'ok', true,
    'code', v_code,
    'amount_xaf', p_amount,
    'fee_xaf', v_fee,
    'expires_at', v_code_record.expires_at
  );
end;
$$;
grant execute on function public.request_cash_out_v3(numeric, text) to authenticated;

-- 8. VALIDATION DU RETRAIT PAR L'AGENT AVEC DÉNOUEMENT DU SÉQUESTRE
create or replace function public.agent_execute_cash_out_v3(p_code text, p_client_phone text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_agent_id uuid := auth.uid();
  v_agent_role text;
  v_agent_float numeric;
  v_wcode public.withdrawal_codes;
  v_client_id uuid;
  v_client_name text;
  v_client_frozen boolean;
  v_bank_fee numeric;
  v_tx_id uuid;
begin
  -- 1. Contrôle d'authentification agent
  if v_agent_id is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Sesión no válida');
  end if;

  select role, agent_balance_xaf into v_agent_role, v_agent_float
  from public.profiles where id = v_agent_id for update;

  if v_agent_role <> 'agent' and v_agent_role <> 'admin' then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Solo agentes autorizados pueden validar retiros');
  end if;

  -- 2. Recherche du code actif (pending)
  select * into v_wcode 
  from public.withdrawal_codes 
  where code = p_code and status = 'pending' 
  for update;

  if v_wcode.id is null then
    return json_build_object('ok', false, 'error', 'INVALID_CODE', 'message', 'Código inválido o ya procesado');
  end if;

  -- 3. Interdiction d'auto-encaissement (un agent ne peut pas valider son propre code)
  if v_wcode.user_id = v_agent_id then
    return json_build_object('ok', false, 'error', 'SELF_CASHOUT', 'message', 'Un agente no puede validar su propio código de retiro');
  end if;

  -- 4. Vérification d'association avec le numéro de téléphone du client (anti brute-force)
  select id, full_name, is_frozen into v_client_id, v_client_name, v_client_frozen
  from public.profiles where id = v_wcode.user_id and phone = p_client_phone;

  if v_client_id is null then
    return json_build_object('ok', false, 'error', 'PHONE_MISMATCH', 'message', 'El número de teléfono no coincide con el código de retiro');
  end if;

  if v_client_frozen then
    return json_build_object('ok', false, 'error', 'CLIENT_FROZEN', 'message', 'La cuenta del cliente está bloqueada');
  end if;

  -- 5. Gestion de l'expiration
  if v_wcode.expires_at < now() then
    -- Remboursement du client depuis le séquestre
    update public.system_accounts set balance_xaf = balance_xaf - v_wcode.held_amount_xaf, updated_at = now() where id = 'cashout_hold';
    update public.profiles set balance_xaf = balance_xaf + v_wcode.held_amount_xaf where id = v_wcode.user_id;
    update public.withdrawal_codes set status = 'expired' where id = v_wcode.id;

    -- Écritures au ledger
    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (null, null, 'cashout_hold', 'cashout_hold', 'debit', v_wcode.held_amount_xaf, (select balance_xaf from public.system_accounts where id = 'cashout_hold'), 'Restitution séquestre code expiré');

    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (null, v_wcode.user_id, null, 'personal', 'credit', v_wcode.held_amount_xaf, (select balance_xaf from public.profiles where id = v_wcode.user_id), 'Remboursement retrait expiré');

    return json_build_object('ok', false, 'error', 'EXPIRED_CODE', 'message', 'El código ha expirado y los fondos han sido devueltos al cliente');
  end if;

  v_bank_fee := v_wcode.fee_xaf - v_wcode.agent_commission_xaf;

  -- 6. Débit du compte séquestre
  update public.system_accounts 
  set balance_xaf = balance_xaf - v_wcode.held_amount_xaf, updated_at = now() 
  where id = 'cashout_hold';

  -- 7. Crédit du Float de l'agent (+ sa commission gagnée)
  update public.profiles
  set agent_balance_xaf = agent_balance_xaf + v_wcode.amount_xaf + v_wcode.agent_commission_xaf,
      agent_commission_earned_xaf = agent_commission_earned_xaf + v_wcode.agent_commission_xaf
  where id = v_agent_id;

  -- 8. Crédit de la commission banque
  if v_bank_fee > 0 then
    update public.system_accounts 
    set balance_xaf = balance_xaf + v_bank_fee, updated_at = now() 
    where id = 'bank_fee_pool';
  end if;

  -- 9. Mise à jour statut code
  update public.withdrawal_codes set status = 'completed' where id = v_wcode.id;

  -- 10. Enregistrement transactionnel
  insert into public.transactions (
    sender_id, recipient_id, amount_xaf, fee_xaf, agent_commission_xaf, note, type, status
  ) values (
    v_wcode.user_id, v_agent_id, v_wcode.amount_xaf, v_wcode.fee_xaf, v_wcode.agent_commission_xaf,
    'Retiro en efectivo en agente Yumi', 'withdrawal', 'completed'
  ) returning id into v_tx_id;

  -- 11. Grand Livre en partie double parfait
  -- Débit Séquestre
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, null, 'cashout_hold', 'cashout_hold', 'debit', v_wcode.held_amount_xaf, (select balance_xaf from public.system_accounts where id = 'cashout_hold'), 'Dénouement séquestre retrait espèces');

  -- Crédit Float Agent (montant remis en espèces + commission agent)
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_agent_id, null, 'agent_float', 'credit', v_wcode.amount_xaf + v_wcode.agent_commission_xaf, v_agent_float + v_wcode.amount_xaf + v_wcode.agent_commission_xaf, 'Recouvrement retrait espèces + commission agent');

  -- Crédit Banque
  if v_bank_fee > 0 then
    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx_id, null, 'bank_fee_pool', 'bank_fee_pool', 'credit', v_bank_fee, (select balance_xaf from public.system_accounts where id = 'bank_fee_pool'), 'Part frais retrait banque');
  end if;

  return json_build_object(
    'ok', true,
    'client_name', v_client_name,
    'amount_to_hand_out', v_wcode.amount_xaf,
    'agent_commission_earned', v_wcode.agent_commission_xaf
  );
end;
$$;
grant execute on function public.agent_execute_cash_out_v3(text, text) to authenticated;

-- 9. FONCTION D'ANNULATION MANUELLE D'UN CODE DE RETRAIT PAR LE CLIENT
create or replace function public.cancel_cash_out(p_code text)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_wcode public.withdrawal_codes;
  v_new_balance numeric;
begin
  if v_user is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED');
  end if;

  select * into v_wcode 
  from public.withdrawal_codes 
  where code = p_code and user_id = v_user and status = 'pending'
  for update;

  if v_wcode.id is null then
    return json_build_object('ok', false, 'error', 'NOT_FOUND', 'message', 'Código no encontrado o ya procesado');
  end if;

  -- Débit Séquestre & Restitution au client
  update public.system_accounts set balance_xaf = balance_xaf - v_wcode.held_amount_xaf, updated_at = now() where id = 'cashout_hold';
  update public.profiles set balance_xaf = balance_xaf + v_wcode.held_amount_xaf where id = v_user returning balance_xaf into v_new_balance;
  update public.withdrawal_codes set status = 'cancelled' where id = v_wcode.id;

  -- Écritures au Grand Livre
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (null, null, 'cashout_hold', 'cashout_hold', 'debit', v_wcode.held_amount_xaf, (select balance_xaf from public.system_accounts where id = 'cashout_hold'), 'Annulation séquestre retrait');

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (null, v_user, null, 'personal', 'credit', v_wcode.held_amount_xaf, v_new_balance, 'Remboursement annulation retrait');

  return json_build_object('ok', true, 'message', 'Retiro cancelado y fondos devueltos a tu cuenta', 'balance_xaf', v_new_balance);
end;
$$;
grant execute on function public.cancel_cash_out(text) to authenticated;

-- 10. EXPIRATION PLANIFIABLE DES CODES PÉRIMÉS
create or replace function public.expire_pending_cash_outs()
returns integer
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_record record;
  v_count integer := 0;
  v_new_balance numeric;
begin
  for v_record in 
    select * from public.withdrawal_codes 
    where status = 'pending' and expires_at < now() 
    for update skip locked
  loop
    update public.system_accounts 
    set balance_xaf = balance_xaf - v_record.held_amount_xaf, updated_at = now() 
    where id = 'cashout_hold';

    update public.profiles 
    set balance_xaf = balance_xaf + v_record.held_amount_xaf 
    where id = v_record.user_id 
    returning balance_xaf into v_new_balance;

    update public.withdrawal_codes set status = 'expired' where id = v_record.id;

    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (null, null, 'cashout_hold', 'cashout_hold', 'debit', v_record.held_amount_xaf, (select balance_xaf from public.system_accounts where id = 'cashout_hold'), 'Expiration automatique séquestre');

    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (null, v_record.user_id, null, 'personal', 'credit', v_record.held_amount_xaf, v_new_balance, 'Remboursement automatique code expiré');

    v_count := v_count + 1;
  end loop;

  return v_count;
end;
$$;

-- 11. DÉPÔT D'ESPÈCES SÉCURISÉ (CASH-IN VIA AGENT)
create or replace function public.agent_deposit_v2(
  p_recipient_phone text,
  p_amount numeric,
  p_note text default null
)
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_agent_id uuid := auth.uid();
  v_agent_role text;
  v_agent_balance numeric;
  v_recipient_id uuid;
  v_recipient_balance numeric;
  v_recipient_frozen boolean;
  v_tx_id uuid;
begin
  if v_agent_id is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED');
  end if;

  select role, agent_balance_xaf into v_agent_role, v_agent_balance
  from public.profiles where id = v_agent_id for update;

  if v_agent_role <> 'agent' and v_agent_role <> 'admin' then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Solo agentes autorizados pueden realizar depósitos');
  end if;

  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'Monto inválido');
  end if;

  select id, balance_xaf, is_frozen into v_recipient_id, v_recipient_balance, v_recipient_frozen
  from public.profiles where phone = p_recipient_phone for update;

  if v_recipient_id is null then
    return json_build_object('ok', false, 'error', 'NOT_FOUND', 'message', 'Cliente no encontrado');
  end if;

  if v_recipient_frozen then
    return json_build_object('ok', false, 'error', 'CLIENT_FROZEN', 'message', 'La cuenta del cliente está bloqueada');
  end if;

  if v_agent_balance < p_amount then
    return json_build_object('ok', false, 'error', 'INSUFFICIENT_FLOAT', 'message', 'Saldo de agente insuficiente para este depósito');
  end if;

  -- Débit Float Agent & Crédit Solde Client
  update public.profiles set agent_balance_xaf = agent_balance_xaf - p_amount where id = v_agent_id;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient_id;

  insert into public.transactions (
    sender_id, recipient_id, amount_xaf, fee_xaf, note, type, status
  ) values (
    v_agent_id, v_recipient_id, p_amount, 0, coalesce(p_note, 'Depósito en efectivo'), 'deposit', 'completed'
  ) returning id into v_tx_id;

  -- Grand Livre en partie double
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_agent_id, null, 'agent_float', 'debit', p_amount, v_agent_balance - p_amount, 'Dépôt client (débit float)');

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_recipient_id, null, 'personal', 'credit', p_amount, v_recipient_balance + p_amount, 'Crédit dépôt espèces reçu de l''agent');

  return json_build_object(
    'ok', true,
    'transaction_id', v_tx_id,
    'amount', p_amount,
    'new_agent_balance', v_agent_balance - p_amount
  );
end;
$$;
grant execute on function public.agent_deposit_v2(text, numeric, text) to authenticated;

-- 12. AUDIT DE RÉCONCILIATION BANCAIRE QUOTIDIENNE (CEMAC / COBAC COMPLIANT)
create or replace function public.perform_bank_reconciliation()
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_caller uuid := auth.uid();
  v_role text;
  v_sum_users numeric;
  v_sum_agents numeric;
  v_fee_pool numeric;
  v_escrow_hold numeric;
  v_total_system_liability numeric;
  v_total_debits numeric;
  v_total_credits numeric;
  v_discrepancy numeric;
begin
  select role into v_role from public.profiles where id = v_caller;
  if v_role <> 'admin' then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED');
  end if;

  select coalesce(sum(balance_xaf), 0), coalesce(sum(agent_balance_xaf), 0)
  into v_sum_users, v_sum_agents
  from public.profiles;

  select coalesce(balance_xaf, 0) into v_fee_pool from public.system_accounts where id = 'bank_fee_pool';
  select coalesce(balance_xaf, 0) into v_escrow_hold from public.system_accounts where id = 'cashout_hold';

  v_total_system_liability := v_sum_users + v_sum_agents + v_fee_pool + v_escrow_hold;

  select coalesce(sum(case when direction = 'debit' then amount_xaf else 0 end), 0),
         coalesce(sum(case when direction = 'credit' then amount_xaf else 0 end), 0)
  into v_total_debits, v_total_credits
  from public.ledger_entries;

  v_discrepancy := v_total_credits - v_total_debits;

  return json_build_object(
    'ok', true,
    'reconciliation_timestamp', now(),
    'users_balance_total', v_sum_users,
    'agents_float_total', v_sum_agents,
    'bank_fee_pool', v_fee_pool,
    'cashout_escrow_hold', v_escrow_hold,
    'total_circulating_liabilities', v_total_system_liability,
    'ledger_total_credits', v_total_credits,
    'ledger_total_debits', v_total_debits,
    'ledger_discrepancy', v_discrepancy,
    'status', case when v_discrepancy = 0 then 'BALANCED_PERFECT' else 'DISCREPANCY_DETECTED' end
  );
end;
$$;
grant execute on function public.perform_bank_reconciliation() to authenticated;

-- 13. WRAPPERS DE COMPATIBILITÉ (POUR GARANTIR L'INTEROPÉRABILITÉ DES ANCIENS APPELS)
create or replace function public.send_money_v2(
  p_recipient_phone text,
  p_amount numeric,
  p_pin text,
  p_note text default null,
  p_idempotency_key text default null
)
returns json
language plpgsql
security definer
as $$
begin
  return public.send_money_v3(p_recipient_phone, p_amount, p_pin, p_note, p_idempotency_key);
end;
$$;
grant execute on function public.send_money_v2(text, numeric, text, text, text) to authenticated;

create or replace function public.request_cash_out(p_amount numeric, p_pin text)
returns json
language plpgsql
security definer
as $$
begin
  return public.request_cash_out_v3(p_amount, p_pin);
end;
$$;
grant execute on function public.request_cash_out(numeric, text) to authenticated;

create or replace function public.agent_execute_cash_out(p_code text, p_client_phone text default '')
returns json
language plpgsql
security definer
as $$
begin
  return public.agent_execute_cash_out_v3(p_code, p_client_phone);
end;
$$;
grant execute on function public.agent_execute_cash_out(text, text) to authenticated;

