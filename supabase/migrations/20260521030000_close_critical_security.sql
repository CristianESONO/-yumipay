-- ============================================================================
-- YUMI PAY: fermeture des 5 failles critiques
-- 1. Escalade de rôle / création d'argent à l'inscription
-- 2. RLS profils (plus de SELECT global)
-- 3. Codes de retrait invisibles pour les agents
-- 4. Top-up agent depuis une réserve (pas ex nihilo) + ledger
-- 5. Annulation / réversion P2P avec frais, locks et ledger
-- ============================================================================

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin'
  );
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- ----------------------------------------------------------------------------
-- 1. Inscription : rôle user uniquement, zéro float, zéro bonus
-- ----------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (
    id,
    full_name,
    phone,
    role,
    agent_status,
    balance_xaf,
    agent_balance_xaf
  )
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data->>'full_name'), ''), 'Usuario Yumi'),
    coalesce(nullif(trim(new.raw_user_meta_data->>'phone'), ''), 'pending_' || new.id),
    'user',
    'none',
    0,
    0
  );
  return new;
end;
$$;

-- ----------------------------------------------------------------------------
-- 2. Profils : colonnes sensibles + RLS propre
-- ----------------------------------------------------------------------------
alter table public.profiles
  add column if not exists pin_set boolean
  generated always as (transaction_pin_hash is not null) stored;

drop policy if exists "Authenticated can view profiles" on public.profiles;
drop policy if exists "Users can update own profile" on public.profiles;
drop policy if exists "Users can insert own profile" on public.profiles;
drop policy if exists "Users read own profile" on public.profiles;
drop policy if exists "Admins read all profiles" on public.profiles;
drop policy if exists "Users update own name" on public.profiles;

revoke all on table public.profiles from anon, authenticated;

grant select (
  id, full_name, phone, balance_xaf, agent_balance_xaf, agent_commission_earned_xaf,
  role, agent_status, kyc_tier, created_at, is_frozen, frozen_reason,
  deletion_requested, deletion_reason, pin_set
) on public.profiles to authenticated;

grant update (full_name) on public.profiles to authenticated;

create policy "Users read own profile"
  on public.profiles for select to authenticated
  using (id = auth.uid());

create policy "Admins read all profiles"
  on public.profiles for select to authenticated
  using (public.is_admin());

create policy "Users update own name"
  on public.profiles for update to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- Transactions : l'admin doit voir l'audit global
drop policy if exists "Admins read all transactions" on public.transactions;
create policy "Admins read all transactions"
  on public.transactions for select to authenticated
  using (public.is_admin());

-- ----------------------------------------------------------------------------
-- 3. Codes de retrait : uniquement le titulaire (+ admin support)
-- ----------------------------------------------------------------------------
drop policy if exists "Users see own withdrawal codes" on public.withdrawal_codes;
drop policy if exists "Users read own withdrawal codes" on public.withdrawal_codes;
drop policy if exists "Admins read withdrawal codes" on public.withdrawal_codes;

create policy "Users read own withdrawal codes"
  on public.withdrawal_codes for select to authenticated
  using (user_id = auth.uid());

create policy "Admins read withdrawal codes"
  on public.withdrawal_codes for select to authenticated
  using (public.is_admin());

-- Noms dénormalisés : l'historique n'a plus besoin de lire le profil du contreparti
alter table public.transactions add column if not exists sender_name text;
alter table public.transactions add column if not exists sender_phone text;
alter table public.transactions add column if not exists recipient_name text;
alter table public.transactions add column if not exists recipient_phone text;

update public.transactions t
set
  sender_name = s.full_name,
  sender_phone = s.phone,
  recipient_name = r.full_name,
  recipient_phone = r.phone
from public.profiles s, public.profiles r
where t.sender_id = s.id
  and t.recipient_id = r.id
  and (t.sender_name is null or t.recipient_name is null);

create or replace function public.fill_transaction_party_labels()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  select full_name, phone into new.sender_name, new.sender_phone
  from public.profiles where id = new.sender_id;

  select full_name, phone into new.recipient_name, new.recipient_phone
  from public.profiles where id = new.recipient_id;

  return new;
end;
$$;

drop trigger if exists trg_fill_transaction_party_labels on public.transactions;
create trigger trg_fill_transaction_party_labels
before insert on public.transactions
for each row execute function public.fill_transaction_party_labels();

-- Oracles PIN : plus d'exécution cliente
do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'verify_user_pin'
  ) then
    execute 'revoke all on function public.verify_user_pin(uuid, text) from public, anon, authenticated';
  end if;
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'verify_and_track_pin'
  ) then
    execute 'revoke all on function public.verify_and_track_pin(uuid, text) from public, anon, authenticated';
  end if;
end $$;

-- ----------------------------------------------------------------------------
-- 4. Réserve de cantonnement + top-up agent équilibré
-- ----------------------------------------------------------------------------
alter table public.ledger_entries drop constraint if exists ledger_entries_wallet_type_check;
alter table public.ledger_entries add constraint ledger_entries_wallet_type_check
  check (wallet_type in (
    'personal', 'agent_float', 'bank_fee_pool', 'cashout_hold',
    'bank_reserve', 'external_assets'
  ));

insert into public.system_accounts (id, name, balance_xaf)
values
  ('bank_reserve', 'Reserva de float (cantonnement no distribuido)', 0),
  ('external_assets', 'Contrapartida de efectivo bancario', 0)
on conflict (id) do nothing;

do $$
declare
  r record;
begin
  for r in
    select c.conname
    from pg_constraint c
    where c.conrelid = 'public.transactions'::regclass
      and c.contype = 'c'
      and pg_get_constraintdef(c.oid) like '%deposit%withdrawal%'
  loop
    execute format('alter table public.transactions drop constraint %I', r.conname);
  end loop;
end $$;

alter table public.transactions add constraint transactions_type_check
  check (type in ('transfer', 'deposit', 'withdrawal', 'system'));

grant select on public.system_accounts to authenticated;

drop function if exists public.admin_top_up_agent(uuid, numeric);

create or replace function public.admin_fund_reserve(p_amount numeric)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_reserve numeric;
  v_assets numeric;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Solo administradores');
  end if;

  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'Monto inválido');
  end if;

  select balance_xaf into v_assets from public.system_accounts where id = 'external_assets' for update;
  select balance_xaf into v_reserve from public.system_accounts where id = 'bank_reserve' for update;

  update public.system_accounts
    set balance_xaf = balance_xaf + p_amount, updated_at = now()
    where id = 'external_assets';
  update public.system_accounts
    set balance_xaf = balance_xaf + p_amount, updated_at = now()
    where id = 'bank_reserve';

  insert into public.ledger_entries (
    transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description
  ) values
    (null, null, 'external_assets', 'external_assets', 'debit', p_amount, v_assets + p_amount, 'Entrada de efectivo al cantonnement'),
    (null, null, 'bank_reserve', 'bank_reserve', 'credit', p_amount, v_reserve + p_amount, 'Reserva de float disponible');

  return json_build_object('ok', true, 'bank_reserve', v_reserve + p_amount);
end;
$$;
grant execute on function public.admin_fund_reserve(numeric) to authenticated;

create or replace function public.admin_top_up_agent(p_agent_id uuid, p_amount numeric)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_agent_role text;
  v_agent_float numeric;
  v_reserve numeric;
  v_tx_id uuid;
begin
  if not public.is_admin() then
    raise exception 'Solo los administradores pueden recargar el float de un agente';
  end if;

  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
    raise exception 'El monto debe ser un entero mayor que cero';
  end if;

  select role, agent_balance_xaf
    into v_agent_role, v_agent_float
    from public.profiles where id = p_agent_id for update;

  if v_agent_role <> 'agent' then
    raise exception 'El usuario seleccionado no es un agente';
  end if;

  select balance_xaf into v_reserve
    from public.system_accounts where id = 'bank_reserve' for update;

  if v_reserve is null then
    raise exception 'Cuenta de reserva no inicializada';
  end if;

  if v_reserve < p_amount then
    raise exception 'Reserva insuficiente (% XAF disponibles). Registra primero el depósito bancario.', v_reserve;
  end if;

  update public.system_accounts
    set balance_xaf = balance_xaf - p_amount, updated_at = now()
    where id = 'bank_reserve';

  update public.profiles
    set agent_balance_xaf = agent_balance_xaf + p_amount
    where id = p_agent_id;

  insert into public.transactions (sender_id, recipient_id, amount_xaf, note, type, status)
  values (auth.uid(), p_agent_id, p_amount, 'Recarga de float desde reserva bancaria', 'system', 'completed')
  returning id into v_tx_id;

  insert into public.ledger_entries (
    transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description
  ) values
    (v_tx_id, null, 'bank_reserve', 'bank_reserve', 'debit', p_amount, v_reserve - p_amount, 'Distribución de float a agente'),
    (v_tx_id, p_agent_id, null, 'agent_float', 'credit', p_amount, v_agent_float + p_amount, 'Recarga de float agente');

  return json_build_object('ok', true, 'transaction_id', v_tx_id, 'new_float', v_agent_float + p_amount);
end;
$$;
grant execute on function public.admin_top_up_agent(uuid, numeric) to authenticated;

create or replace function public.perform_bank_reconciliation()
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_sum_users numeric;
  v_sum_agents numeric;
  v_fee_pool numeric;
  v_escrow_hold numeric;
  v_reserve numeric;
  v_assets numeric;
  v_total_liability numeric;
  v_total_debits numeric;
  v_total_credits numeric;
begin
  if not public.is_admin() then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED');
  end if;

  select coalesce(sum(balance_xaf), 0), coalesce(sum(agent_balance_xaf), 0)
    into v_sum_users, v_sum_agents
    from public.profiles;

  select coalesce(balance_xaf, 0) into v_fee_pool from public.system_accounts where id = 'bank_fee_pool';
  select coalesce(balance_xaf, 0) into v_escrow_hold from public.system_accounts where id = 'cashout_hold';
  select coalesce(balance_xaf, 0) into v_reserve from public.system_accounts where id = 'bank_reserve';
  select coalesce(balance_xaf, 0) into v_assets from public.system_accounts where id = 'external_assets';

  v_total_liability := v_sum_users + v_sum_agents + v_fee_pool + v_escrow_hold + v_reserve;

  select
    coalesce(sum(case when direction = 'debit' then amount_xaf else 0 end), 0),
    coalesce(sum(case when direction = 'credit' then amount_xaf else 0 end), 0)
    into v_total_debits, v_total_credits
    from public.ledger_entries;

  return json_build_object(
    'ok', true,
    'reconciliation_timestamp', now(),
    'users_balance_total', v_sum_users,
    'agents_float_total', v_sum_agents,
    'bank_fee_pool', v_fee_pool,
    'cashout_escrow_hold', v_escrow_hold,
    'bank_reserve', v_reserve,
    'external_assets', v_assets,
    'total_circulating_liabilities', v_total_liability,
    'ledger_total_credits', v_total_credits,
    'ledger_total_debits', v_total_debits,
    'ledger_discrepancy', v_total_credits - v_total_debits,
    'status', case
      when v_total_credits - v_total_debits <> 0 then 'DISCREPANCY_DETECTED'
      else 'BALANCED_PERFECT'
    end
  );
end;
$$;

-- Cash-in : toujours la version ledger (l'UI et les anciens clients)
drop function if exists public.agent_deposit(text, bigint, text);
drop function if exists public.agent_deposit(text, numeric, text);

create or replace function public.agent_deposit(
  p_recipient_phone text,
  p_amount numeric,
  p_note text default null
)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public.agent_deposit_v2(p_recipient_phone, p_amount, p_note);
end;
$$;
grant execute on function public.agent_deposit(text, numeric, text) to authenticated;

-- ----------------------------------------------------------------------------
-- P2P : insert idempotent AVANT mouvement de fonds
-- ----------------------------------------------------------------------------
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
  v_fee_pool numeric;
begin
  if v_sender is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED', 'message', 'Sesión no válida o expirada');
  end if;

  if p_amount is null or p_amount <= 0 or p_amount <> trunc(p_amount) then
    return json_build_object('ok', false, 'error', 'INVALID_AMOUNT', 'message', 'Monto inválido');
  end if;

  if p_idempotency_key is not null then
    select * into v_existing_tx from public.transactions
    where sender_id = v_sender and idempotency_key = p_idempotency_key;
    if v_existing_tx.id is not null then
      return json_build_object('ok', true, 'status', 'ALREADY_PROCESSED', 'transaction', row_to_json(v_existing_tx));
    end if;
  end if;

  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then
    return json_build_object('ok', false, 'error', 'RECIPIENT_NOT_FOUND', 'message', 'Destinatario no encontrado');
  end if;
  if v_recipient = v_sender then
    return json_build_object('ok', false, 'error', 'SELF_TRANSFER', 'message', 'No puedes enviarte dinero a ti mismo');
  end if;

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

  if v_sender_frozen then
    return json_build_object('ok', false, 'error', 'FROZEN', 'message', 'Tu cuenta está congelada preventivamente');
  end if;
  if v_recipient_frozen then
    return json_build_object('ok', false, 'error', 'RECIPIENT_FROZEN', 'message', 'La cuenta del destinatario está restringida');
  end if;

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
    if coalesce(v_sender_attempts, 0) > 0 or v_sender_locked_until is not null then
      update public.profiles set failed_pin_attempts = 0, pin_locked_until = null where id = v_sender;
    end if;
  end if;

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
    and type = 'transfer'
    and created_at >= date_trunc('day', now() at time zone 'Africa/Malabo');

  if (v_today_transferred + p_amount) > v_daily_limit then
    return json_build_object(
      'ok', false, 'error', 'DAILY_LIMIT_EXCEEDED',
      'message', 'Límite diario superado (' || v_daily_limit || ' XAF permitidos para tu nivel ' || v_sender_kyc || ')'
    );
  end if;

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

  if v_fee > 0 then
    select balance_xaf into v_fee_pool from public.system_accounts where id = 'bank_fee_pool' for update;
  end if;

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

  update public.profiles set balance_xaf = balance_xaf - v_total_deduction where id = v_sender;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;

  if v_fee > 0 then
    update public.system_accounts
    set balance_xaf = balance_xaf + v_fee, updated_at = now()
    where id = 'bank_fee_pool';
  end if;

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_sender, null, 'personal', 'debit', v_total_deduction, v_sender_balance - v_total_deduction, 'Transfert P2P vers ' || p_recipient_phone);

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (v_tx_id, v_recipient, null, 'personal', 'credit', p_amount, v_recipient_balance + p_amount, 'Transfert reçu de ' || v_sender);

  if v_fee > 0 then
    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx_id, null, 'bank_fee_pool', 'bank_fee_pool', 'credit', v_fee, coalesce(v_fee_pool, 0) + v_fee, 'Comisión transferencia P2P');
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

-- ----------------------------------------------------------------------------
-- 5. Annulation < 24h et réversion admin
-- ----------------------------------------------------------------------------
create or replace function public.cancel_transaction(p_transaction_id uuid)
returns json
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_tx public.transactions;
  v_sender_bal numeric;
  v_recipient_bal numeric;
  v_fee_pool numeric;
  v_refund numeric;
  v_first uuid;
  v_second uuid;
begin
  if v_user is null then
    raise exception 'Sesión no válida';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'Transacción no encontrada';
  end if;
  if v_tx.sender_id <> v_user then
    raise exception 'Solo el remitente puede anular la transacción';
  end if;
  if v_tx.type is distinct from 'transfer' then
    raise exception 'Solo se pueden anular transferencias P2P';
  end if;
  if v_tx.status <> 'completed' then
    raise exception 'La transacción no se puede anular en su estado actual';
  end if;
  if v_tx.created_at < now() - interval '24 hours' then
    raise exception 'El plazo de 24 horas para anulación directa ha expirado. Por favor, solicita una reversión al banco.';
  end if;

  v_refund := v_tx.amount_xaf + coalesce(v_tx.fee_xaf, 0);

  if v_tx.sender_id < v_tx.recipient_id then
    v_first := v_tx.sender_id; v_second := v_tx.recipient_id;
  else
    v_first := v_tx.recipient_id; v_second := v_tx.sender_id;
  end if;

  perform 1 from public.profiles where id = v_first for update;
  perform 1 from public.profiles where id = v_second for update;

  select balance_xaf into v_sender_bal from public.profiles where id = v_tx.sender_id;
  select balance_xaf into v_recipient_bal from public.profiles where id = v_tx.recipient_id;

  if v_recipient_bal < v_tx.amount_xaf then
    raise exception 'El destinatario ya ha usado los fondos. Por favor, contacta con el soporte del banco.';
  end if;

  if coalesce(v_tx.fee_xaf, 0) > 0 then
    select balance_xaf into v_fee_pool from public.system_accounts where id = 'bank_fee_pool' for update;
    if v_fee_pool < v_tx.fee_xaf then
      raise exception 'No se puede anular: el pool de comisiones es insuficiente. Contacta con el banco.';
    end if;
  end if;

  update public.profiles set balance_xaf = balance_xaf - v_tx.amount_xaf where id = v_tx.recipient_id;
  update public.profiles set balance_xaf = balance_xaf + v_refund where id = v_tx.sender_id;

  if coalesce(v_tx.fee_xaf, 0) > 0 then
    update public.system_accounts
      set balance_xaf = balance_xaf - v_tx.fee_xaf, updated_at = now()
      where id = 'bank_fee_pool';
  end if;

  update public.transactions
    set status = 'cancelled',
        note = trim(both from coalesce(note || ' | ', '') || 'Anulada por el remitente (<24h)')
    where id = v_tx.id;

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values
    (v_tx.id, v_tx.recipient_id, null, 'personal', 'debit', v_tx.amount_xaf, v_recipient_bal - v_tx.amount_xaf, 'Anulación P2P (débito destinatario)'),
    (v_tx.id, v_tx.sender_id, null, 'personal', 'credit', v_refund, v_sender_bal + v_refund, 'Anulación P2P (reembolso + comisión)');

  if coalesce(v_tx.fee_xaf, 0) > 0 then
    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx.id, null, 'bank_fee_pool', 'bank_fee_pool', 'debit', v_tx.fee_xaf, v_fee_pool - v_tx.fee_xaf, 'Reembolso comisión anulación P2P');
  end if;

  return json_build_object('ok', true, 'status', 'cancelled');
end;
$$;

create or replace function public.request_reversal(p_transaction_id uuid, p_note text)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tx public.transactions;
begin
  select * into v_tx from public.transactions where id = p_transaction_id for update;

  if v_tx.id is null or v_tx.sender_id <> auth.uid() then
    raise exception 'Transacción no encontrada';
  end if;
  if v_tx.type is distinct from 'transfer' then
    raise exception 'Solo se pueden reclamar transferencias P2P';
  end if;
  if v_tx.status <> 'completed' then
    raise exception 'La transacción no admite una reclamación en su estado actual';
  end if;
  if coalesce(trim(p_note), '') = '' then
    raise exception 'Debes indicar el motivo de la reclamación';
  end if;

  update public.transactions
  set reversal_requested_at = now(),
      reversal_note = p_note,
      status = 'reversal_pending'
  where id = p_transaction_id;
end;
$$;

create or replace function public.process_reversal(
  p_transaction_id uuid,
  p_approve boolean,
  p_admin_note text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_tx public.transactions;
  v_sender_bal numeric;
  v_recipient_bal numeric;
  v_fee_pool numeric;
  v_refund numeric;
  v_first uuid;
  v_second uuid;
begin
  if not public.is_admin() then
    raise exception 'Acceso denegado';
  end if;

  select * into v_tx from public.transactions where id = p_transaction_id for update;
  if v_tx.id is null then
    raise exception 'Transacción no encontrada';
  end if;
  if v_tx.status <> 'reversal_pending' then
    raise exception 'No hay una reclamación pendiente para esta transacción';
  end if;

  if not p_approve then
    update public.transactions
      set status = 'completed',
          note = trim(both from coalesce(note || ' | ', '') || 'Reversión rechazada: ' || coalesce(p_admin_note, ''))
      where id = v_tx.id;
    return;
  end if;

  if v_tx.type is distinct from 'transfer' then
    raise exception 'Solo se pueden revertir transferencias P2P';
  end if;

  v_refund := v_tx.amount_xaf + coalesce(v_tx.fee_xaf, 0);

  if v_tx.sender_id < v_tx.recipient_id then
    v_first := v_tx.sender_id; v_second := v_tx.recipient_id;
  else
    v_first := v_tx.recipient_id; v_second := v_tx.sender_id;
  end if;

  perform 1 from public.profiles where id = v_first for update;
  perform 1 from public.profiles where id = v_second for update;

  select balance_xaf into v_sender_bal from public.profiles where id = v_tx.sender_id;
  select balance_xaf into v_recipient_bal from public.profiles where id = v_tx.recipient_id;

  if v_recipient_bal < v_tx.amount_xaf then
    raise exception 'El destinatario ya no tiene saldo suficiente para revertir';
  end if;

  if coalesce(v_tx.fee_xaf, 0) > 0 then
    select balance_xaf into v_fee_pool from public.system_accounts where id = 'bank_fee_pool' for update;
    if v_fee_pool < v_tx.fee_xaf then
      raise exception 'Pool de comisiones insuficiente para revertir';
    end if;
  end if;

  update public.profiles set balance_xaf = balance_xaf - v_tx.amount_xaf where id = v_tx.recipient_id;
  update public.profiles set balance_xaf = balance_xaf + v_refund where id = v_tx.sender_id;

  if coalesce(v_tx.fee_xaf, 0) > 0 then
    update public.system_accounts
      set balance_xaf = balance_xaf - v_tx.fee_xaf, updated_at = now()
      where id = 'bank_fee_pool';
  end if;

  update public.transactions
    set status = 'cancelled',
        note = trim(both from coalesce(note || ' | ', '') || 'Reversión aprobada: ' || coalesce(p_admin_note, ''))
    where id = v_tx.id;

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values
    (v_tx.id, v_tx.recipient_id, null, 'personal', 'debit', v_tx.amount_xaf, v_recipient_bal - v_tx.amount_xaf, 'Reversión admin (débito destinatario)'),
    (v_tx.id, v_tx.sender_id, null, 'personal', 'credit', v_refund, v_sender_bal + v_refund, 'Reversión admin (reembolso + comisión)');

  if coalesce(v_tx.fee_xaf, 0) > 0 then
    insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
    values (v_tx.id, null, 'bank_fee_pool', 'bank_fee_pool', 'debit', v_tx.fee_xaf, v_fee_pool - v_tx.fee_xaf, 'Reembolso comisión reversión admin');
  end if;
end;
$$;
