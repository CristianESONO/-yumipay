-- ============================================================================
-- YUMI PAY: FULL BANKING COMPLIANCE, KYC, SECURITY & CASH-OUT ENGINE
-- Conforme aux exigences BEAC / COBAC (CEMAC) & Modèle Bancaire CCEI Bank
-- ============================================================================

-- 1. EXTENSIONS
create extension if not exists pgcrypto;

-- 2. ENRICHISSEMENT DES PROFILS
alter table public.profiles add column if not exists transaction_pin_hash text;
alter table public.profiles add column if not exists kyc_tier text not null default 'tier_1' check (kyc_tier in ('tier_1', 'tier_2', 'tier_3'));
alter table public.profiles add column if not exists agent_commission_earned_xaf numeric not null default 0;

-- 3. JOURNAL COMPTABLE EN PARTIE DOUBLE (DOUBLE-ENTRY LEDGER)
create table if not exists public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid references public.transactions(id) on delete set null,
  account_id uuid not null references public.profiles(id) on delete cascade,
  wallet_type text not null check (wallet_type in ('personal', 'agent_float', 'bank_fee_pool')),
  direction text not null check (direction in ('debit', 'credit')),
  amount_xaf numeric not null check (amount_xaf >= 0),
  balance_after numeric not null,
  description text,
  created_at timestamptz not null default now()
);

alter table public.ledger_entries enable row level security;
create policy "Users see own ledger" on public.ledger_entries for select to authenticated
  using (account_id = auth.uid() or exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- 4. VÉRIFICATIONS KYC & DOCUMENTS OFFICIELS (BEAC / COBAC)
create table if not exists public.kyc_verifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  doc_type text not null check (doc_type in ('DIP', 'passport', 'residence_card', 'tax_id')),
  doc_number text not null,
  doc_image_url text,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  admin_notes text,
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz
);

alter table public.kyc_verifications enable row level security;
create policy "Users see own KYC" on public.kyc_verifications for select to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
create policy "Users insert own KYC" on public.kyc_verifications for insert to authenticated
  with check (user_id = auth.uid());
create policy "Admins manage KYC" on public.kyc_verifications for update to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- 5. WORKFLOW CASH-OUT (RETRAIT D'ESPÈCES VIA AGENT)
create table if not exists public.withdrawal_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  code text not null unique,
  amount_xaf numeric not null check (amount_xaf > 0),
  fee_xaf numeric not null default 0,
  agent_commission_xaf numeric not null default 0,
  status text not null default 'pending' check (status in ('pending', 'completed', 'cancelled', 'expired')),
  expires_at timestamptz not null default (now() + interval '15 minutes'),
  created_at timestamptz not null default now()
);

alter table public.withdrawal_codes enable row level security;
create policy "Users see own withdrawal codes" on public.withdrawal_codes for select to authenticated
  using (user_id = auth.uid() or exists (select 1 from public.profiles where id = auth.uid() and (role = 'agent' or role = 'admin')));

-- 6. AMÉLIORATION DE LA TABLE TRANSACTIONS
alter table public.transactions add column if not exists fee_xaf numeric not null default 0;
alter table public.transactions add column if not exists agent_commission_xaf numeric not null default 0;
alter table public.transactions add column if not exists idempotency_key text unique;

-- 7. FONCTION: CONFIGURER OU MODIFIER LE CODE PIN DE TRANSACTION
create or replace function public.set_transaction_pin(p_pin text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if length(p_pin) < 4 or length(p_pin) > 6 or p_pin !~ '^[0-9]+$' then
    raise exception 'El PIN debe contener entre 4 y 6 dígitos numéricos';
  end if;

  update public.profiles
  set transaction_pin_hash = crypt(p_pin, gen_salt('bf', 8))
  where id = v_user;
end;
$$;
grant execute on function public.set_transaction_pin(text) to authenticated;

-- 8. FONCTION INTERNE: VÉRIFIER LE CODE PIN
create or replace function public.verify_user_pin(p_user_id uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_stored_hash text;
begin
  select transaction_pin_hash into v_stored_hash from public.profiles where id = p_user_id;
  if v_stored_hash is null then
    -- Si l'utilisateur n'a pas encore configuré de PIN, on tolère temporairement
    return true;
  end if;
  return v_stored_hash = crypt(p_pin, v_stored_hash);
end;
$$;

-- 9. FONCTION: CALCULATE TRANSACTION FEES (MOTEUR DE FRAIS)
create or replace function public.calculate_fees(p_type text, p_amount numeric)
returns json
language plpgsql
security definer
as $$
declare
  v_fee numeric := 0;
  v_agent_commission numeric := 0;
begin
  if p_type = 'transfer' then
    -- Transfert P2P: 1% pour les montants > 1000 XAF, gratuit en dessous. Max 3 000 XAF.
    if p_amount >= 1000 then
      v_fee := greatest(50, least(round(p_amount * 0.01), 3000));
    else
      v_fee := 0;
    end if;
  elsif p_type = 'withdrawal' then
    -- Retrait d'espèces (Cash-out): 1.5% (1% pour l'agent, 0.5% pour la plateforme)
    v_fee := greatest(100, round(p_amount * 0.015));
    v_agent_commission := round(v_fee * 0.65); -- ~1% pour l'agent
  elsif p_type = 'deposit' then
    -- Dépôt d'espèces (Cash-in): Gratuit pour le client, bonus fixe de 100 XAF pour l'agent
    v_fee := 0;
    v_agent_commission := 100;
  end if;

  return json_build_object(
    'fee_xaf', v_fee,
    'agent_commission_xaf', v_agent_commission,
    'total_amount', p_amount + v_fee
  );
end;
$$;
grant execute on function public.calculate_fees(text, numeric) to authenticated;

-- 10. FONCTION: ENVOI SÉCURISÉ P2P AVEC PIN, IDEMPOTENCE & CONTRÔLE KYC
create or replace function public.send_money_v2(
  p_recipient_phone text,
  p_amount numeric,
  p_pin text default null,
  p_note text default null,
  p_idempotency_key text default null
)
returns public.transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_recipient uuid;
  v_sender_balance numeric;
  v_sender_kyc text;
  v_today_transferred numeric;
  v_daily_limit numeric;
  v_fee numeric := 0;
  v_total_deduction numeric;
  v_tx public.transactions;
begin
  -- Idempotence: si la transaction existe déjà avec cette clé, la retourner
  if p_idempotency_key is not null then
    select * into v_tx from public.transactions where idempotency_key = p_idempotency_key;
    if v_tx.id is not null then
      return v_tx;
    end if;
  end if;

  -- Vérification du code PIN
  if not public.verify_user_pin(v_sender, p_pin) then
    raise exception 'Código PIN incorrecto';
  end if;

  -- Trouver le destinataire
  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then
    raise exception 'Destinatario no encontrado con el número %', p_recipient_phone;
  end if;
  if v_recipient = v_sender then
    raise exception 'No puedes enviarte dinero a ti mismo';
  end if;

  -- Récupérer le solde et KYC avec verrouillage (FOR UPDATE)
  select balance_xaf, kyc_tier into v_sender_balance, v_sender_kyc 
  from public.profiles where id = v_sender for update;

  -- Contrôle des plafonds journaliers selon le niveau KYC (Réglementation BEAC)
  if v_sender_kyc = 'tier_1' then
    v_daily_limit := 200000; -- 200 000 XAF/jour pour compte standard non vérifié
  elsif v_sender_kyc = 'tier_2' then
    v_daily_limit := 2000000; -- 2 000 000 XAF/jour pour compte KYC vérifié
  else
    v_daily_limit := 10000000; -- 10 000 000 XAF pour compte Tier 3 Pro
  end if;

  select coalesce(sum(amount_xaf), 0) into v_today_transferred
  from public.transactions
  where sender_id = v_sender and created_at >= current_date;

  if (v_today_transferred + p_amount) > v_daily_limit then
    raise exception 'Límite diario superado (% XAF permitidos para tu nivel KYC %)', v_daily_limit, v_sender_kyc;
  end if;

  -- Calcul des frais
  if p_amount >= 1000 then
    v_fee := greatest(50, least(round(p_amount * 0.01), 3000));
  else
    v_fee := 0;
  end if;
  v_total_deduction := p_amount + v_fee;

  if v_sender_balance < v_total_deduction then
    raise exception 'Saldo insuficiente (Total con comisión: % XAF)', v_total_deduction;
  end if;

  -- Mouvements de soldes
  update public.profiles set balance_xaf = balance_xaf - v_total_deduction where id = v_sender;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;

  -- Création de la transaction
  insert into public.transactions (
    sender_id, recipient_id, amount_xaf, fee_xaf, note, type, status, idempotency_key
  ) values (
    v_sender, v_recipient, p_amount, v_fee, p_note, 'transfer', 'completed', p_idempotency_key
  ) returning * into v_tx;

  -- Écritures du Grand Livre (Double-Entry Ledger)
  insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values 
    (v_tx.id, v_sender, 'personal', 'debit', v_total_deduction, v_sender_balance - v_total_deduction, 'Transfert P2P vers ' || p_recipient_phone),
    (v_tx.id, v_recipient, 'personal', 'credit', p_amount, (select balance_xaf from public.profiles where id = v_recipient), 'Transfert reçu de ' || v_sender);

  return v_tx;
end;
$$;
grant execute on function public.send_money_v2(text, numeric, text, text, text) to authenticated;

-- 11. FONCTION: CRÉER UNE DEMANDE DE RETRAIT (CASH-OUT CLIENT)
create or replace function public.request_cash_out(p_amount numeric, p_pin text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_balance numeric;
  v_fee numeric;
  v_commission numeric;
  v_total numeric;
  v_code text;
  v_record public.withdrawal_codes;
begin
  if p_amount < 500 then
    raise exception 'El monto mínimo de retiro es de 500 XAF';
  end if;

  if not public.verify_user_pin(v_user, p_pin) then
    raise exception 'Código PIN incorrecto';
  end if;

  -- Calcul des frais de retrait (1.5%)
  v_fee := greatest(100, round(p_amount * 0.015));
  v_commission := round(v_fee * 0.65);
  v_total := p_amount + v_fee;

  select balance_xaf into v_balance from public.profiles where id = v_user;
  if v_balance < v_total then
    raise exception 'Saldo insuficiente para retiro y comisión (Total requerido: % XAF)', v_total;
  end if;

  -- Génération d'un code à 6 chiffres unique
  v_code := lpad(floor(random() * 900000 + 100000)::text, 6, '0');

  -- Insérer le code de retrait
  insert into public.withdrawal_codes (user_id, code, amount_xaf, fee_xaf, agent_commission_xaf, status, expires_at)
  values (v_user, v_code, p_amount, v_fee, v_commission, 'pending', now() + interval '15 minutes')
  returning * into v_record;

  return json_build_object(
    'code', v_code,
    'amount_xaf', p_amount,
    'fee_xaf', v_fee,
    'agent_commission_xaf', v_commission,
    'expires_at', v_record.expires_at
  );
end;
$$;
grant execute on function public.request_cash_out(numeric, text) to authenticated;

-- 12. FONCTION: AGENT EXÉCUTE LE RETRAIT D'ESPÈCES (CASH-OUT REMISE D'ARGENT)
create or replace function public.agent_execute_cash_out(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent_id uuid := auth.uid();
  v_agent_role text;
  v_agent_float numeric;
  v_wcode public.withdrawal_codes;
  v_client_balance numeric;
  v_client_id uuid;
  v_total_deduction numeric;
  v_tx_id uuid;
  v_client_name text;
begin
  -- Vérifier le rôle de l'agent
  select role, agent_balance_xaf into v_agent_role, v_agent_float
  from public.profiles where id = v_agent_id for update;

  if v_agent_role <> 'agent' and v_agent_role <> 'admin' then
    raise exception 'Solo agentes autorizados pueden procesar retiros en efectivo';
  end if;

  -- Récupérer et verrouiller le code de retrait
  select * into v_wcode from public.withdrawal_codes where code = p_code for update;

  if v_wcode.id is null then
    raise exception 'Código de retiro no encontrado';
  end if;
  if v_wcode.status <> 'pending' then
    raise exception 'Este código ya ha sido utilizado o cancelado';
  end if;
  if v_wcode.expires_at < now() then
    update public.withdrawal_codes set status = 'expired' where id = v_wcode.id;
    raise exception 'El código ha expirado (validez de 15 minutos)';
  end if;

  v_client_id := v_wcode.user_id;
  v_total_deduction := v_wcode.amount_xaf + v_wcode.fee_xaf;

  -- Vérifier le solde du client
  select balance_xaf, full_name into v_client_balance, v_client_name
  from public.profiles where id = v_client_id for update;

  if v_client_balance < v_total_deduction then
    raise exception 'El cliente ya no dispone del saldo suficiente';
  end if;

  -- 1. Débiter le client
  update public.profiles set balance_xaf = balance_xaf - v_total_deduction where id = v_client_id;

  -- 2. Créditer la caisse de travail de l'agent (récupère l'argent physique remis) + sa commission
  update public.profiles
  set agent_balance_xaf = agent_balance_xaf + v_wcode.amount_xaf + v_wcode.agent_commission_xaf,
      agent_commission_earned_xaf = agent_commission_earned_xaf + v_wcode.agent_commission_xaf
  where id = v_agent_id;

  -- 3. Marquer le code comme terminé
  update public.withdrawal_codes set status = 'completed' where id = v_wcode.id;

  -- 4. Insérer dans l'historique des transactions
  insert into public.transactions (
    sender_id, recipient_id, amount_xaf, fee_xaf, agent_commission_xaf,
    note, type, status
  ) values (
    v_client_id, v_agent_id, v_wcode.amount_xaf, v_wcode.fee_xaf, v_wcode.agent_commission_xaf,
    'Retiro de efectivo en agente Yumi', 'withdrawal', 'completed'
  ) returning id into v_tx_id;

  -- 5. Écritures du grand livre
  insert into public.ledger_entries (transaction_id, account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values
    (v_tx_id, v_client_id, 'personal', 'debit', v_total_deduction, v_client_balance - v_total_deduction, 'Retrait espèces chez agent'),
    (v_tx_id, v_agent_id, 'agent_float', 'credit', v_wcode.amount_xaf + v_wcode.agent_commission_xaf, v_agent_float + v_wcode.amount_xaf + v_wcode.agent_commission_xaf, 'Recouvrement retrait espèces + commission');

  return json_build_object(
    'success', true,
    'amount_to_hand_out', v_wcode.amount_xaf,
    'agent_commission_earned', v_wcode.agent_commission_xaf,
    'client_name', v_client_name
  );
end;
$$;
grant execute on function public.agent_execute_cash_out(text) to authenticated;

-- 13. FONCTION: SOUMETTRE DOSSIER KYC
create or replace function public.submit_kyc(p_doc_type text, p_doc_number text, p_doc_image_url text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.kyc_verifications (user_id, doc_type, doc_number, doc_image_url, status)
  values (auth.uid(), p_doc_type, p_doc_number, p_doc_image_url, 'pending');
end;
$$;
grant execute on function public.submit_kyc(text, text, text) to authenticated;

-- 14. FONCTION: ADMIN EXAMINE KYC
create or replace function public.admin_review_kyc(
  p_kyc_id uuid,
  p_approve boolean,
  p_new_tier text default 'tier_2',
  p_notes text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Solo administradores pueden validar expedientes KYC';
  end if;

  select user_id into v_user_id from public.kyc_verifications where id = p_kyc_id;

  if p_approve then
    update public.kyc_verifications
    set status = 'approved', admin_notes = p_notes, reviewed_at = now()
    where id = p_kyc_id;

    update public.profiles set kyc_tier = p_new_tier where id = v_user_id;
  else
    update public.kyc_verifications
    set status = 'rejected', admin_notes = p_notes, reviewed_at = now()
    where id = p_kyc_id;
  end if;
end;
$$;
grant execute on function public.admin_review_kyc(uuid, boolean, text, text) to authenticated;
