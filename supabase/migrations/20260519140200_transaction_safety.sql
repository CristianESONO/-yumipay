
-- Update transaction types/statuses
alter table public.transactions add column reversal_requested_at timestamptz;
alter table public.transactions add column reversal_note text;

-- Function to check if a transaction can be cancelled (sender only, < 24h)
create or replace function public.cancel_transaction(p_transaction_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_sender_id uuid;
  v_recipient_id uuid;
  v_amount numeric;
  v_created_at timestamptz;
  v_status text;
  v_recipient_balance numeric;
begin
  select sender_id, recipient_id, amount_xaf, created_at, status 
  into v_sender_id, v_recipient_id, v_amount, v_created_at, v_status
  from public.transactions where id = p_transaction_id;

  if v_sender_id <> v_user then
    raise exception 'Solo el remitente puede anular la transacción';
  end if;

  if v_status <> 'completed' then
    raise exception 'La transacción no se puede anular en su estado actual';
  end if;

  if v_created_at < now() - interval '24 hours' then
    raise exception 'El plazo de 24 horas para anulación directa ha expirado. Por favor, solicita una reversión al banco.';
  end if;

  -- Check if recipient has enough balance to return
  select balance_xaf into v_recipient_balance from public.profiles where id = v_recipient_id;
  if v_recipient_balance < v_amount then
    raise exception 'El destinatario ya ha usado los fondos. Por favor, contacta con el soporte del banco.';
  end if;

  -- Atomic Reversal
  update public.profiles set balance_xaf = balance_xaf - v_amount where id = v_recipient_id;
  update public.profiles set balance_xaf = balance_xaf + v_amount where id = v_sender_id;
  update public.transactions set status = 'cancelled', note = 'Anulada por el remitente (<24h)' where id = p_transaction_id;
end;
$$;

grant execute on function public.cancel_transaction(uuid) to authenticated;

-- Function to request reversal (> 24h)
create or replace function public.request_reversal(p_transaction_id uuid, p_note text)
returns void
language plpgsql
security definer
as $$
begin
  if not exists (select 1 from public.transactions where id = p_transaction_id and sender_id = auth.uid()) then
    raise exception 'Transacción no encontrada';
  end if;

  update public.transactions 
  set reversal_requested_at = now(), 
      reversal_note = p_note,
      status = 'reversal_pending'
  where id = p_transaction_id;
end;
$$;

grant execute on function public.request_reversal(uuid, text) to authenticated;

-- Admin function to process reversal
create or replace function public.process_reversal(
  p_transaction_id uuid,
  p_approve boolean,
  p_admin_note text
)
returns void
language plpgsql
security definer
as $$
declare
  v_admin_role text;
  v_sender_id uuid;
  v_recipient_id uuid;
  v_amount numeric;
begin
  select role into v_admin_role from public.profiles where id = auth.uid();
  if v_admin_role <> 'admin' then
    raise exception 'Acceso denegado';
  end if;

  select sender_id, recipient_id, amount_xaf into v_sender_id, v_recipient_id, v_amount
  from public.transactions where id = p_transaction_id;

  if p_approve then
    update public.profiles set balance_xaf = balance_xaf - v_amount where id = v_recipient_id;
    update public.profiles set balance_xaf = balance_xaf + v_amount where id = v_sender_id;
    update public.transactions set status = 'cancelled', note = 'Reversión aprobada por Administrador: ' || p_admin_note where id = p_transaction_id;
  else
    update public.transactions set status = 'completed', note = 'Reversión rechazada: ' || p_admin_note where id = p_transaction_id;
  end if;
end;
$$;

grant execute on function public.process_reversal(uuid, boolean, text) to authenticated;
