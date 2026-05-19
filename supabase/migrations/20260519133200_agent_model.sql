
-- Add role to profiles
alter table public.profiles add column role text not null default 'user' check (role in ('user', 'agent', 'admin'));

-- Add type to transactions
alter table public.transactions add column type text not null default 'transfer' check (type in ('transfer', 'deposit', 'withdrawal'));

-- RPC for Agent Deposit (Cash-in)
create or replace function public.agent_deposit(
  p_recipient_phone text,
  p_amount bigint,
  p_note text default null
)
returns public.transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_agent uuid := auth.uid();
  v_agent_role text;
  v_recipient uuid;
  v_tx public.transactions;
begin
  -- Check if sender is an agent
  select role into v_agent_role from public.profiles where id = v_agent;
  if v_agent_role not in ('agent', 'admin') then
    raise exception 'Solo los agentes pueden realizar depósitos';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Cantidad inválida';
  end if;

  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then
    raise exception 'Destinatario no encontrado';
  end if;

  -- Update recipient balance (Agent cash-in doesn't subtract from agent's digital balance in some models,
  -- but here we'll assume the system "mints" the balance based on physical cash received by the agent).
  -- In a more strict model, we might subtract from an Agent's own system balance.
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;

  insert into public.transactions (sender_id, recipient_id, amount_xaf, note, type)
  values (v_agent, v_recipient, p_amount, p_note, 'deposit')
  returning * into v_tx;

  return v_tx;
end;
$$;

grant execute on function public.agent_deposit(text, bigint, text) to authenticated;

-- Create contacts table
create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  contact_id uuid not null references public.profiles(id) on delete cascade,
  alias text,
  created_at timestamptz not null default now(),
  unique(user_id, contact_id)
);

alter table public.contacts enable row level security;

create policy "Users see own contacts" on public.contacts for select to authenticated
  using (auth.uid() = user_id);

create policy "Users manage own contacts" on public.contacts for all to authenticated
  using (auth.uid() = user_id);
