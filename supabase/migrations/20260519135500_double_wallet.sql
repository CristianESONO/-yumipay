
-- Add agent balance column
alter table public.profiles add column agent_balance_xaf numeric not null default 0;

-- Function for internal transfer between wallets
create or replace function public.internal_transfer(
  p_amount numeric,
  p_to_agent_wallet boolean -- true if Personal -> Agent, false if Agent -> Personal
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_personal_balance numeric;
  v_agent_balance numeric;
  v_role text;
begin
  -- Check if user is agent
  select role, balance_xaf, agent_balance_xaf into v_role, v_personal_balance, v_agent_balance
  from public.profiles where id = v_user;

  if v_role <> 'agent' and v_role <> 'admin' then
    raise exception 'Solo los agentes pueden gestionar una caja de efectivo';
  end if;

  if p_to_agent_wallet then
    -- Personal -> Agent
    if v_personal_balance < p_amount then
      raise exception 'Saldo personal insuficiente';
    end if;
    update public.profiles set balance_xaf = balance_xaf - p_amount, agent_balance_xaf = agent_balance_xaf + p_amount where id = v_user;
  else
    -- Agent -> Personal
    if v_agent_balance < p_amount then
      raise exception 'Saldo de caja insuficiente';
    end if;
    update public.profiles set agent_balance_xaf = agent_balance_xaf - p_amount, balance_xaf = balance_xaf + p_amount where id = v_user;
  end if;

  -- Log internal transaction? Optional, but good for history.
  -- For now we just update balances.
end;
$$;

grant execute on function public.internal_transfer(numeric, boolean) to authenticated;

-- Update agent_deposit to use agent_balance_xaf
create or replace function public.agent_deposit(
  p_recipient_phone text,
  p_amount numeric,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent_id uuid := auth.uid();
  v_recipient_id uuid;
  v_agent_balance numeric;
  v_agent_role text;
  v_agent_status text;
begin
  -- Check agent
  select role, agent_status, agent_balance_xaf into v_agent_role, v_agent_status, v_agent_balance
  from public.profiles where id = v_agent_id;

  if v_agent_role not in ('agent', 'admin') or v_agent_status <> 'approved' then
    raise exception 'No tienes permisos de agente activo';
  end if;

  if v_agent_balance < p_amount then
    raise exception 'Saldo de caja insuficiente para realizar esta recarga';
  end if;

  -- Find recipient
  select id into v_recipient_id from public.profiles where phone = p_recipient_phone;
  if v_recipient_id is null then
    raise exception 'Usuario no encontrado';
  end if;

  -- Atomic transfer
  update public.profiles set agent_balance_xaf = agent_balance_xaf - p_amount where id = v_agent_id;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient_id;

  -- Log transaction
  insert into public.transactions (sender_id, recipient_id, amount_xaf, note, type, status)
  values (v_agent_id, v_recipient_id, p_amount, p_note, 'deposit', 'completed');
end;
$$;
