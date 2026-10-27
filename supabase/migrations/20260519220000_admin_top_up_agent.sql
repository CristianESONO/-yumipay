-- Admin function to top-up an agent's float (agent_balance_xaf)
-- Only admins can call this function (enforced by security definer + role check)

create or replace function public.admin_top_up_agent(
  p_agent_id uuid,
  p_amount numeric
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_role text;
  v_agent_role text;
begin
  -- Verify caller is admin
  select role into v_caller_role from public.profiles where id = auth.uid();
  if v_caller_role <> 'admin' then
    raise exception 'Solo los administradores pueden recargar el float de un agente';
  end if;

  -- Verify target is an agent
  select role into v_agent_role from public.profiles where id = p_agent_id;
  if v_agent_role not in ('agent', 'admin') then
    raise exception 'El usuario seleccionado no es un agente';
  end if;

  if p_amount <= 0 then
    raise exception 'El monto debe ser mayor que cero';
  end if;

  -- Credit the agent's float wallet
  update public.profiles
    set agent_balance_xaf = agent_balance_xaf + p_amount
    where id = p_agent_id;

  -- Log the transaction for audit
  insert into public.transactions (sender_id, recipient_id, amount_xaf, note, type, status)
  values (auth.uid(), p_agent_id, p_amount, 'Recarga de float por administrador', 'system', 'completed');
end;
$$;

grant execute on function public.admin_top_up_agent(uuid, numeric) to authenticated;
