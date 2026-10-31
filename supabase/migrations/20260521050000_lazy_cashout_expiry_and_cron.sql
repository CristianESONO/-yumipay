-- ============================================================================
-- YUMI PAY: Automatisation de l'expiration des cashouts et auto-libération
-- 1. Exécution paresseuse (lazy) de l'expiration lors d'une nouvelle demande
-- 2. Fonction publique pour actualiser ses codes et débloquer les fonds expirés
-- 3. Inscription pg_cron si disponible
-- ============================================================================

-- Fonction pour rafraîchir et libérer ses fonds de retrait expirés à la demande
create or replace function public.refresh_my_cash_outs()
returns json
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_user uuid := auth.uid();
  v_expired_count integer := 0;
begin
  if v_user is null then
    return json_build_object('ok', false, 'error', 'UNAUTHORIZED');
  end if;

  -- Débloquer tous les codes expirés
  v_expired_count := public.expire_pending_cash_outs();

  return json_build_object(
    'ok', true,
    'expired_processed', v_expired_count,
    'balance_xaf', (select balance_xaf from public.profiles where id = v_user)
  );
end;
$$;
grant execute on function public.refresh_my_cash_outs() to authenticated;

-- Mise à jour de request_cash_out_v3 pour purger d'abord les codes expirés
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

  -- Libérer automatiquement les codes expirés AVANT de vérifier le solde
  perform public.expire_pending_cash_outs();

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
    return json_build_object('ok', false, 'error', 'NO_PIN_CONFIGURED', 'message', 'Debes configurar tu código PIN antes de realizar un retiro');
  end if;

  if crypt(p_pin, v_pin_hash) <> v_pin_hash then
    v_attempts := coalesce(v_attempts, 0) + 1;
    if v_attempts >= 3 then
      update public.profiles
      set failed_pin_attempts = v_attempts,
          pin_locked_until = now() + interval '15 minutes'
      where id = v_user;
      return json_build_object('ok', false, 'error', 'PIN_LOCKED', 'message', 'Código PIN bloqueado por 15 minutos (3 intentos fallidos)');
    else
      update public.profiles set failed_pin_attempts = v_attempts where id = v_user;
      return json_build_object('ok', false, 'error', 'INVALID_PIN', 'message', 'Código PIN incorrecto. Intentos restantes: ' || (3 - v_attempts));
    end if;
  end if;

  -- Reset des tentatives en cas de succès
  update public.profiles set failed_pin_attempts = 0, pin_locked_until = null where id = v_user;

  -- 3. Vérification des plafonds KYC
  case coalesce(v_kyc, 'tier1')
    when 'tier1' then v_daily_limit := 200000; v_max_single := 100000;
    when 'tier2' then v_daily_limit := 2000000; v_max_single := 1000000;
    else v_daily_limit := 10000000; v_max_single := 5000000;
  end case;

  if p_amount > v_max_single then
    return json_build_object(
      'ok', false, 'error', 'EXCEEDS_SINGLE_LIMIT',
      'message', 'El monto supera el límite por retiro de tu nivel KYC (' || v_max_single || ' XAF)'
    );
  end if;

  select coalesce(sum(amount_xaf), 0) into v_today_withdrawn
  from public.transactions
  where sender_id = v_user
    and type = 'withdrawal'
    and created_at >= date_trunc('day', now());

  if (v_today_withdrawn + p_amount) > v_daily_limit then
    return json_build_object(
      'ok', false, 'error', 'EXCEEDS_DAILY_LIMIT',
      'message', 'Límite diario de retiros alcanzado (' || v_daily_limit || ' XAF). Retirado hoy: ' || v_today_withdrawn || ' XAF'
    );
  end if;

  -- 4. Calcul des commissions (1.5% dont 1% pour l'agent et 0.5% pour la plateforme, min 100 XAF)
  v_fee := greatest(100, round(p_amount * 0.015));
  v_commission := round(p_amount * 0.01);
  v_total := p_amount + v_fee;

  if v_balance < v_total then
    return json_build_object(
      'ok', false, 'error', 'INSUFFICIENT_FUNDS',
      'message', 'Saldo insuficiente. Requiere ' || v_total || ' XAF (monto: ' || p_amount || ' + comisión: ' || v_fee || ')'
    );
  end if;

  -- 5. Génération d'un code OTP cryptographiquement aléatoire à 6 chiffres
  loop
    v_code := lpad((floor(random() * 900000) + 100000)::text, 6, '0');
    exit when not exists (select 1 from public.withdrawal_codes where code = v_code and status = 'pending');
  end loop;

  -- 6. Débit immédiat du solde utilisateur et mise en séquestre
  update public.profiles
  set balance_xaf = balance_xaf - v_total
  where id = v_user;

  update public.system_accounts
  set balance_xaf = balance_xaf + v_total, updated_at = now()
  where id = 'cashout_hold';

  -- 7. Écritures comptables en partie double
  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (null, v_user, null, 'personal', 'debit', v_total, v_balance - v_total, 'Séquestre pour code de retrait éphémère');

  insert into public.ledger_entries (transaction_id, account_id, system_account_id, wallet_type, direction, amount_xaf, balance_after, description)
  values (null, null, 'cashout_hold', 'cashout_hold', 'credit', v_total, (select balance_xaf from public.system_accounts where id = 'cashout_hold'), 'Entrée en séquestre retrait');

  -- 8. Insertion du code avec expiration à 15 minutes
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
    'expires_at', v_code_record.expires_at,
    'balance_xaf', v_balance - v_total
  );
end;
$$;
grant execute on function public.request_cash_out_v3(numeric, text) to authenticated;

-- Tentative de configuration pg_cron
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('expire_cashouts_cron', '*/5 * * * *', 'select public.expire_pending_cash_outs()');
  end if;
exception when others then
  null;
end $$;

