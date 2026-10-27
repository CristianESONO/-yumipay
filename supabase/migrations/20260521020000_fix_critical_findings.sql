-- ============================================================================
-- YUMI PAY: BANK-GRADE COMPLETE HARDENING (Fix Critical Audit Findings)
-- Résolution exhaustive des 7 points d'audit de sécurité bancaire
-- ============================================================================

-- 1. CRÉATION DU COMPTE SYSTÈME BANCAIRE POUR LES FRAIS (SYSTÈME DE LEDGER FERMÉ)
-- UUID réservé pour le compte de réserve bancaire de Yumi Pay
do $$
begin
  if not exists (select 1 from auth.users where id = '00000000-0000-0000-0000-000000000000') then
    -- On crée une entrée sécurisée pour le pool bancaire dans profiles
    insert into public.profiles (
      id, full_name, phone, role, balance_xaf, agent_balance_xaf, kyc_tier
    ) values (
      '00000000-0000-0000-0000-000000000000',
      'Yumi Bank Revenue & Fee Pool',
      '+240000000000',
      'admin',
      0,
      0,
      'tier_3'
    ) on conflict (id) do nothing;
  end if;
end;
$$;

-- 2. CONTRAINTES D'INTÉGRITÉ STRICTES (EMPÊCHER LES SOLDES NÉGATIFS ET MONTANTS INVALIDES)
alter table public.profiles drop constraint if exists profiles_balance_positive;
alter table public.profiles add constraint profiles_balance_positive 
  check (balance_xaf >= 0 and agent_balance_xaf >= 0);

alter table public.transactions drop constraint if exists transactions_amount_positive;
alter table public.transactions add constraint transactions_amount_positive 
  check (amount_xaf > 0 and fee_xaf >= 0);

alter table public.ledger_entries drop constraint if exists ledger_amount_positive;
alter table public.ledger_entries add constraint ledger_amount_positive 
  check (amount_xaf > 0);

-- Unicité stricte sur idempotency_key par utilisateur
alter table public.transactions drop constraint if exists transactions_sender_idempotency_uniq;
create unique index if not exists transactions_sender_idempotency_idx 
  on public.transactions(sender_id, idempotency_key) where idempotency_key is not null;

-- 3. VERROUILLAGE RLS SUR LA TABLE PROFILES (PROTECTION CONTRE L'ÉLÉVATION DE PRIVILÈGES)
-- Un utilisateur ne peut JAMAIS modifier lui-même son rôle, ses soldes, son gel ou son kyc
create or replace function public.protect_sensitive_profile_fields()
returns trigger
language plpgsql
security definer
as $$
begin
  -- Si l'appelant n'est pas admin, interdire toute modification des colonnes financières et rôles
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    if new.role <> old.role or
       new.balance_xaf <> old.balance_xaf or
       new.agent_balance_xaf <> old.agent_balance_xaf or
       new.is_frozen <> old.is_frozen or
       new.kyc_tier <> old.kyc_tier or
       new.failed_pin_attempts <> old.failed_pin_attempts or
       new.pin_locked_until <> old.pin_locked_until then
      raise exception 'SÉCURITÉ VIOLÉE : Modification non autorisée de champs sensibles du profil.';
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_protect_profile_fields on public.profiles;
create trigger trg_protect_profile_fields
before update on public.profiles
for each row execute function public.protect_sensitive_profile_fields();

-- 4. TABLE DU SÉQUESTRE DE RETRAIT D'ESPÈCES (HOLD / ESCROW TEMPORAIRE)
-- Lors de la demande de retrait, les fonds sont retirés du solde actif et placés en séquestre
alter table public.withdrawal_codes add column if not exists held_amount_xaf numeric;

-- 5. FONCTION PIN ÉTANCHE SANS ROLLBACK (PERSISTENCE DU COMPTEUR D'ÉCHECS)
create or replace function public.check_user_pin_safe(p_user_id uuid, p_pin text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_stored_hash text;
  v_attempts integer;
  v_locked_until timestamptz;
  v_is_frozen boolean;
begin
  select transaction_pin_hash, failed_pin_attempts, pin_locked_until, is_frozen
  into v_stored_hash, v_attempts, v_locked_until, v_is_frozen
  from public.profiles where id = p_user_id for update;

  if v_is_frozen then
    return json_build_object('ok', false, 'status', 'FROZEN', 'message', 'Tu cuenta ha sido congelada preventivamente.');
  end if;

  if v_locked_until is not null and v_locked_until > now() then
    return json_build_object(
      'ok', false, 
      'status', 'LOCKED', 
      'message', 'Código PIN temporalmente bloqueado. Espera ' || round(extract(epoch from (v_locked_until - now())) / 60) || ' minutos.'
    );
  end if;

  if v_stored_hash is null then
    return json_build_object('ok', false, 'status', 'NO_PIN', 'message', 'Debes configurar un código PIN antes de realizar operaciones.');
  end if;

  -- Test du code PIN
  if v_stored_hash = crypt(p_pin, v_stored_hash) then
    update public.profiles 
    set failed_pin_attempts = 0, pin_locked_until = null 
    where id = p_user_id;
    return json_build_object('ok', true, 'status', 'SUCCESS');
  else
    v_attempts := v_attempts + 1;
    if v_attempts >= 5 then
      update public.profiles 
      set failed_pin_attempts = v_attempts,
          pin_locked_until = now() + interval '15 minutes'
      where id = p_user_id;
      return json_build_object('ok', false, 'status', 'LOCKED', 'message', 'Límite de 5 intentos alcanzado: cuenta bloqueada durante 15 minutos.');
    else
      update public.profiles set failed_pin_attempts = v_attempts where id = p_user_id;
      return json_build_object('ok', false, 'status', 'INVALID', 'message', 'Código PIN incorrecto (' || (5 - v_attempts) || ' intentos restantes).');
    end if;
  end if;
end;
$$;
-- Révoquer l'accès public direct à cette fonction interne pour éviter l'énumération par un tiers
revoke execute on function public.check_user_pin_safe(uuid, text) from public, anon;

-- 6. FONCTION FINANCIÈRE DE TRANSFERT P2P ROBUSTE & ÉQUILIBRÉE EN LEDGER
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
set search_path = public, pg_temp
as $$
declare
  v_sender uuid := auth.uid();
  v_recipient uuid;
  v_sender_balance numeric;
  v_recipient_balance numeric;
  v_sender_kyc text;
  v_today_transferred numeric;
  v_daily_limit numeric;
  v_fee numeric := 0;
  v_total_deduction numeric;
  v_pin_res json;
  v_existing_tx public.transactions;
  v_tx_id uuid;
  v_system_account uuid := '00000000-0000-0000-0000-000000000000';
begin
  -- 1. Garde d'authentification impérative
  if v_sender is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Sesión no válida o expirada');
  end if;

  -- 2. Validation stricte du montant (positif, entier, non-null)
  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'Monto inválido');
  end if;

  -- 3. Gestion de l'idempotence
  if p_idempotency_key is not null then
    select * into v_existing_tx from public.transactions 
    where sender_id = v_sender and idempotency_key = p_idempotency_key;
    if v_existing_tx.id is not null then
      return json_build_object('ok', true, 'status', 'ALREADY_PROCESSED', 'transaction', row_to_json(v_existing_tx));
    end if;
  end if;

  -- 4. Vérification et comptabilisation du PIN (sans rollback des échecs)
  v_pin_res := public.check_user_pin_safe(v_sender, p_pin);
  if not (v_pin_res->>'ok')::boolean then
    return json_build_object('ok', false, 'error', v_pin_res->>'status', 'message', v_pin_res->>'message');
  end if;

  -- 5. Recherche du destinataire
  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then
    return json_build_object('ok', false, 'error', 'RECIPIENT_NOT_FOUND', 'message', 'Destinatario no encontrado con el número ' || p_recipient_phone);
  end if;
  if v_recipient = v_sender then
    return json_build_object('ok', false, 'error', 'SELF_TRANSFER', 'message', 'No puedes enviarte dinero a ti mismo');
  end if;

  -- 6. Verrouillage ordonné contre les DEADLOCKS
  if v_sender < v_recipient then
    select balance_xaf, kyc_tier into v_sender_balance, v_sender_kyc from public.profiles where id = v_sender for update;
    select balance_xaf into v_recipient_balance from public.profiles where id = v_recipient for update;
  else
    select balance_xaf into v_recipient_balance from public.profiles where id = v_recipient for update;
    select balance_xaf, kyc_tier into v_sender_balance, v_sender_kyc from public.profiles where id = v_sender for update;
  end if;

  -- 7. Plafonds KYC stricts
  if v_sender_kyc = 'tier_1' then
    v_daily_limit := 200000;
  elsif v_sender_kyc = 'tier_2' then
    v_daily_limit := 2000000;
  elsif v_sender_kyc = 'tier_3' then
    v_daily_limit := 10000000;
  else
    return json_build_object('ok', false, 'error', 'INVALID_KYC', 'message', 'Nivel de verificación no válido');
  end if;

  select coalesce(sum(amount_xaf), 0) into v_today_transferred
  from public.transactions
  where sender_id = v_sender 
    and status = 'completed'
    and created_at >= (now() at time zone 'Africa/Malabo')::date;

  if (v_today_transferred + p_amount) > v_daily_limit then
    return json_build_object(
      'ok', false, 
      'error', 'DAILY_LIMIT_EXCEEDED', 
      'message', 'Límite diario superado (' || v_daily_limit || ' XAF permitidos para tu nivel ' || v_sender_kyc || ')'
    );
  end if;

  -- 8. Calcul des frais (1% dès 1000 XAF, min 50 XAF, max 3000 XAF)
  if p_amount >= 1000 then
    v_fee := greatest(50, least(round(p_amount * 0.01), 3000));
  else
    v_fee := 0;
  end if;
  v_total_deduction := p_amount + v_fee;

  if v_sender_balance < v_total_deduction then
    return json_build_object(
      'ok', false, 
      'error', 'INSUFFICIENT_FUNDS', 
      'message', 'Saldo insuficiente (Total con comisión: ' || v_total_deduction || ' XAF)'
    );
  end if;

  -- 9. Mouvements atomiques des soldes
  update public.profiles set balance_xaf = balance_xaf - v_total_deduction where id = v_sender;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;
  if v_fee > 0 then
    update public.profiles set balance_xaf = balance_xaf + v_fee where id = v_system_account;
  end if;

  -- 10. Enregistrement de la transaction
  insert into public.transactions (
    sender_id, recipient_id, amount_xaf, fee_xaf, note, type, status, idempotency_key
  ) values (
    v_sender, v_recipient, p_amount, v_fee, p_note, 'transfer', 'completed', p_idempotency_key
  ) returning id into v_tx_id;

  -- 11. GRAND LIVRE COMPTABLE EN PARTIE DOUBLE (Écart rigoureusement égal à 0)
  -- Débit Émetteur : p_amount + v_fee
  insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_sender, 'personal', 'debit', v_total_deduction, v_sender_balance - v_total_deduction, 'Transfert P2P vers ' || p_recipient_phone);

  -- Crédit Destinataire : p_amount
  insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_recipient, 'personal', 'credit', p_amount, v_recipient_balance + p_amount, 'Transfert reçu de ' || v_sender);

  -- Crédit Compte Frais Système : v_fee (s'il y a lieu)
  if v_fee > 0 then
    insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx_id, v_system_account, 'bank_fee_pool', 'credit', v_fee, (select balance_xaf from public.profiles where id = v_system_account), 'Comisión transferencia P2P');
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

-- 7. CASH-OUT BLINDÉ AVEC SÉQUESTRE IMMÉDIAT (ÉVITER LE DOUBLE RETRAIT)
create or replace function public.request_cash_out_v2(p_amount numeric, p_pin text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_balance numeric;
  v_fee numeric;
  v_commission numeric;
  v_total numeric;
  v_code text;
  v_pin_res json;
  v_code_record public.withdrawal_codes;
begin
  if v_user is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED');
  end if;

  if p_amount is null or p_amount < 500 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'El monto mínimo de retiro es de 500 XAF enteros');
  end if;

  -- 1. Un seul code de retrait actif à la fois
  if exists (select 1 from public.withdrawal_codes where user_id = v_user and status = 'pending' and expires_at > now()) then
    return json_build_object('ok', false, 'error', 'ACTIVE_CODE_EXISTS', 'message', 'Ya tienes un código de retiro activo. Cancélalo antes de solicitar otro.');
  end if;

  -- 2. Vérification PIN
  v_pin_res := public.check_user_pin_safe(v_user, p_pin);
  if not (v_pin_res->>'ok')::boolean then
    return json_build_object('ok', false, 'error', v_pin_res->>'status', 'message', v_pin_res->>'message');
  end if;

  -- 3. Frais de retrait (1.5% min 100 XAF)
  v_fee := greatest(100, round(p_amount * 0.015));
  v_commission := round(v_fee * 0.65);
  v_total := p_amount + v_fee;

  select balance_xaf into v_balance from public.profiles where id = v_user for update;
  if v_balance < v_total then
    return json_build_object('ok', false, 'error', 'INSUFFICIENT_FUNDS', 'message', 'Saldo insuficiente para retiro y comisión (Total: ' || v_total || ' XAF)');
  end if;

  -- 4. SÉQUESTRE IMMÉDIAT : Débit immédiat du solde actif
  update public.profiles set balance_xaf = balance_xaf - v_total where id = v_user;

  -- 5. Génération cryptographique aléatoire du code à 6 chiffres
  v_code := lpad((abs(get_byte(gen_random_bytes(4), 0) * 65536 + get_byte(gen_random_bytes(4), 1) * 256 + get_byte(gen_random_bytes(4), 2)) % 900000 + 100000)::text, 6, '0');

  insert into public.withdrawal_codes (
    user_id, code, amount_xaf, fee_xaf, agent_commission_xaf, held_amount_xaf, status, expires_at
  ) values (
    v_user, v_code, p_amount, v_fee, v_commission, v_total, 'pending', now() + interval '15 minutes'
  ) returning * into v_code_record;

  return json_build_object(
    'ok', true,
    'code', v_code,
    'amount_xaf', p_amount,
    'fee_xaf', v_fee,
    'expires_at', v_code_record.expires_at
  );
end;
$$;
grant execute on function public.request_cash_out_v2(numeric, text) to authenticated;

-- 8. VALIDATION DU RETRAIT PAR L'AGENT AVEC DÉNOUEMENT DU SÉQUESTRE
create or replace function public.agent_execute_cash_out_v2(p_code text)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_agent_id uuid := auth.uid();
  v_agent_role text;
  v_agent_float numeric;
  v_wcode public.withdrawal_codes;
  v_tx_id uuid;
  v_client_name text;
  v_system_account uuid := '00000000-0000-0000-0000-000000000000';
  v_bank_fee numeric;
begin
  select role, agent_balance_xaf into v_agent_role, v_agent_float
  from public.profiles where id = v_agent_id for update;

  if v_agent_role <> 'agent' and v_agent_role <> 'admin' then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Solo agentes autorizados pueden validar retiros');
  end if;

  select * into v_wcode from public.withdrawal_codes where code = p_code for update;

  if v_wcode.id is null or v_wcode.status <> 'pending' then
    return json_build_object('ok', false, 'error', 'INVALID_CODE', 'message', 'Código no válido o ya utilizado');
  end if;

  if v_wcode.expires_at < now() then
    -- Si expiré, rembourser automatiquement le client depuis le séquestre
    update public.profiles set balance_xaf = balance_xaf + v_wcode.held_amount_xaf where id = v_wcode.user_id;
    update public.withdrawal_codes set status = 'expired' where id = v_wcode.id;
    return json_build_object('ok', false, 'error', 'EXPIRED_CODE', 'message', 'El código ha expirado y los fondos han sido devueltos al cliente');
  end if;

  select full_name into v_client_name from public.profiles where id = v_wcode.user_id;
  v_bank_fee := v_wcode.fee_xaf - v_wcode.agent_commission_xaf;

  -- 1. Créditer le Float de l'agent (+ sa commission gagnée)
  update public.profiles
  set agent_balance_xaf = agent_balance_xaf + v_wcode.amount_xaf + v_wcode.agent_commission_xaf,
      agent_commission_earned_xaf = agent_commission_earned_xaf + v_wcode.agent_commission_xaf
  where id = v_agent_id;

  -- 2. Créditer la part de commission banque
  if v_bank_fee > 0 then
    update public.profiles set balance_xaf = balance_xaf + v_bank_fee where id = v_system_account;
  end if;

  -- 3. Marquer le code comme terminé
  update public.withdrawal_codes set status = 'completed' where id = v_wcode.id;

  -- 4. Insérer dans les transactions
  insert into public.transactions (
    sender_id, recipient_id, amount_xaf, fee_xaf, agent_commission_xaf, note, type, status
  ) values (
    v_wcode.user_id, v_agent_id, v_wcode.amount_xaf, v_wcode.fee_xaf, v_wcode.agent_commission_xaf,
    'Retiro en efectivo en agente Yumi', 'withdrawal', 'completed'
  ) returning id into v_tx_id;

  -- 5. Grand livre en partie double parfait
  -- Débit client (séquestré) : amount + fee
  insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_wcode.user_id, 'personal', 'debit', v_wcode.held_amount_xaf, (select balance_xaf from public.profiles where id = v_wcode.user_id), 'Retrait espèces chez agent');

  -- Crédit Float Agent : amount + commission
  insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_agent_id, 'agent_float', 'credit', v_wcode.amount_xaf + v_wcode.agent_commission_xaf, v_agent_float + v_wcode.amount_xaf + v_wcode.agent_commission_xaf, 'Recouvrement retrait + commission');

  -- Crédit Banque : commission restante
  if v_bank_fee > 0 then
    insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx_id, v_system_account, 'bank_fee_pool', 'credit', v_bank_fee, (select balance_xaf from public.profiles where id = v_system_account), 'Part frais retrait Yumi Bank');
  end if;

  return json_build_object(
    'ok', true,
    'client_name', v_client_name,
    'amount_to_hand_out', v_wcode.amount_xaf,
    'agent_commission_earned', v_wcode.agent_commission_xaf
  );
end;
$$;
grant execute on function public.agent_execute_cash_out_v2(text) to authenticated;
