-- ============================================================================
-- YUMI PAY: BANK-GRADE HARDENING & AUDIT RECONCILIATION ENGINE
-- Répond aux exigences strictes d'un audit bancaire (COBAC / CCEI Bank)
-- ============================================================================

-- 1. DURCISSEMENT DU GRAND LIVRE (IMMUABILITÉ ABSOLUE)
-- Interdiction formelle de tout UPDATE ou DELETE sur la table ledger_entries
create or replace function public.prevent_ledger_tampering()
returns trigger
language plpgsql
as $$
begin
  raise exception 'OPÉRATION INTERDITE : Le Grand Livre (ledger_entries) est strictement immuable. Les corrections doivent se faire par écriture de contre-passation.';
end;
$$;

drop trigger if exists trg_protect_ledger on public.ledger_entries;
create trigger trg_protect_ledger
before update or delete on public.ledger_entries
for each row execute function public.prevent_ledger_tampering();

-- 2. SÉCURITÉ DU CODE PIN : PROTECTION CONTRE LE BRUTE-FORCE
alter table public.profiles add column if not exists failed_pin_attempts integer not null default 0;
alter table public.profiles add column if not exists pin_locked_until timestamptz;
alter table public.profiles add column if not exists is_frozen boolean not null default false;
alter table public.profiles add column if not exists frozen_reason text;

-- Fonction durcie de vérification du PIN avec limitation à 5 essais et verrouillage
create or replace function public.verify_and_track_pin(p_user_id uuid, p_pin text)
returns boolean
language plpgsql
security definer
set search_path = public
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
    raise exception 'Este compte ha sido congelado preventivamente por el departamento de riesgos. Contacta a soporte.';
  end if;

  if v_locked_until is not null and v_locked_until > now() then
    raise exception 'Código PIN temporalmente bloqueado tras múltiples intentos fallidos. Vuelve a intentarlo en % minutos.', 
      round(extract(epoch from (v_locked_until - now())) / 60);
  end if;

  if v_stored_hash is null then
    return true; -- Pas encore de PIN configuré
  end if;

  if v_stored_hash = crypt(p_pin, v_stored_hash) then
    -- PIN correct : réinitialiser le compteur d'échecs
    update public.profiles 
    set failed_pin_attempts = 0, pin_locked_until = null 
    where id = p_user_id;
    return true;
  else
    -- PIN incorrect : incrémenter et verrouiller si >= 5
    v_attempts := v_attempts + 1;
    if v_attempts >= 5 then
      update public.profiles 
      set failed_pin_attempts = v_attempts,
          pin_locked_until = now() + interval '15 minutes'
      where id = p_user_id;
      raise exception 'Código PIN incorrecto. Límite de 5 intentos alcanzado: cuenta bloqueada temporalmente durante 15 minutos.';
    else
      update public.profiles 
      set failed_pin_attempts = v_attempts 
      where id = p_user_id;
      raise exception 'Código PIN incorrecto (% de 5 intentos antes del bloqueo temporal).', v_attempts;
    end if;
  end if;
end;
$$;

-- 3. TABLE DES RAPPORTS DE RÉCONCILIATION QUOTIDIENNE (POUR L'AUDIT BANCAIRE)
create table if not exists public.daily_reconciliations (
  id uuid primary key default gen_random_uuid(),
  reconciliation_date date not null unique default current_date,
  total_user_balance_xaf numeric not null,
  total_agent_float_xaf numeric not null,
  total_circulating_xaf numeric not null,
  total_ledger_debits_xaf numeric not null,
  total_ledger_credits_xaf numeric not null,
  ledger_variance_xaf numeric not null, -- Doit être exactement 0
  is_balanced boolean not null,
  verified_at timestamptz not null default now(),
  notes text
);

alter table public.daily_reconciliations enable row level security;
create policy "Admins view reconciliations" on public.daily_reconciliations for select to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- Fonction de réconciliation quotidienne
create or replace function public.run_daily_reconciliation()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_users_total numeric := 0;
  v_agents_total numeric := 0;
  v_circulating numeric := 0;
  v_debits numeric := 0;
  v_credits numeric := 0;
  v_variance numeric := 0;
  v_balanced boolean := false;
  v_report public.daily_reconciliations;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Solo administradores pueden ejecutar la conciliación contable';
  end if;

  -- 1. Calcul de la masse monétaire en circulation
  select coalesce(sum(balance_xaf), 0), coalesce(sum(agent_balance_xaf), 0)
  into v_users_total, v_agents_total
  from public.profiles;

  v_circulating := v_users_total + v_agents_total;

  -- 2. Audit du Grand Livre (Somme des débits et crédits)
  select 
    coalesce(sum(case when direction = 'debit' then amount_xaf else 0 end), 0),
    coalesce(sum(case when direction = 'credit' then amount_xaf else 0 end), 0)
  into v_debits, v_credits
  from public.ledger_entries;

  v_variance := v_debits - v_credits;
  v_balanced := (v_variance = 0);

  -- 3. Enregistrement du rapport journalier
  insert into public.daily_reconciliations (
    reconciliation_date,
    total_user_balance_xaf,
    total_agent_float_xaf,
    total_circulating_xaf,
    total_ledger_debits_xaf,
    total_ledger_credits_xaf,
    ledger_variance_xaf,
    is_balanced,
    notes
  ) values (
    current_date,
    v_users_total,
    v_agents_total,
    v_circulating,
    v_debits,
    v_credits,
    v_variance,
    v_balanced,
    case when v_balanced then 'Conciliación contable perfecta: Débitos = Créditos' else 'ANOMALÍA DETECTADA: Descuadre en el gran libro' end
  )
  on conflict (reconciliation_date) do update set
    total_user_balance_xaf = excluded.total_user_balance_xaf,
    total_agent_float_xaf = excluded.total_agent_float_xaf,
    total_circulating_xaf = excluded.total_circulating_xaf,
    total_ledger_debits_xaf = excluded.total_ledger_debits_xaf,
    total_ledger_credits_xaf = excluded.total_ledger_credits_xaf,
    ledger_variance_xaf = excluded.ledger_variance_xaf,
    is_balanced = excluded.is_balanced,
    verified_at = now()
  returning * into v_report;

  return json_build_object(
    'date', v_report.reconciliation_date,
    'total_circulating_xaf', v_report.total_circulating_xaf,
    'total_user_balance_xaf', v_report.total_user_balance_xaf,
    'total_agent_float_xaf', v_report.total_agent_float_xaf,
    'is_balanced', v_report.is_balanced,
    'variance', v_report.ledger_variance_xaf
  );
end;
$$;
grant execute on function public.run_daily_reconciliation() to authenticated;

-- 4. GESTION DES RISQUES : GEL ET DÉGEL CONSERVATOIRE DE COMPTES
create or replace function public.admin_freeze_account(p_user_id uuid, p_freeze boolean, p_reason text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Solo administradores bancarios pueden congelar cuentas';
  end if;

  update public.profiles
  set is_frozen = p_freeze,
      frozen_reason = case when p_freeze then p_reason else null end
  where id = p_user_id;
end;
$$;
grant execute on function public.admin_freeze_account(uuid, boolean, text) to authenticated;

-- 5. JOURNAL D'AUDIT DES ACTIONS ADMINISTRATEURS
create table if not exists public.admin_audit_logs (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references public.profiles(id),
  action text not null,
  target_id uuid,
  details jsonb,
  created_at timestamptz not null default now()
);

alter table public.admin_audit_logs enable row level security;
create policy "Admins see audit logs" on public.admin_audit_logs for select to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- 6. CONNEXION DU CONTRÔLE PIN DURCI AUX FONCTIONS FINANCIÈRES
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

  -- Vérification du code PIN avec limitation anti-brute-force (5 tentatives max) et vérification de gel
  perform public.verify_and_track_pin(v_sender, p_pin);

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
    v_daily_limit := 200000;
  elsif v_sender_kyc = 'tier_2' then
    v_daily_limit := 2000000;
  else
    v_daily_limit := 10000000;
  end if;

  select coalesce(sum(amount_xaf), 0) into v_today_transferred
  from public.transactions
  where sender_id = v_sender and created_at >= current_date;

  if (v_today_transferred + p_amount) > v_daily_limit then
    raise exception 'Límite diario superado (% XAF permitidos para tu nivel KYC %)', v_daily_limit, v_sender_kyc;
  end if;

  -- Calcul des frais (1% min 50 XAF pour montants >= 1000 XAF)
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

  -- Vérification PIN avec limitation de tentatives
  perform public.verify_and_track_pin(v_user, p_pin);

  v_fee := greatest(100, round(p_amount * 0.015));
  v_commission := round(v_fee * 0.65);
  v_total := p_amount + v_fee;

  select balance_xaf into v_balance from public.profiles where id = v_user;
  if v_balance < v_total then
    raise exception 'Saldo insuficiente para retiro y comisión (Total requerido: % XAF)', v_total;
  end if;

  v_code := lpad(floor(random() * 900000 + 100000)::text, 6, '0');

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
