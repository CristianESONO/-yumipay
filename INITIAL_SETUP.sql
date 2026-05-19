--- 1. TABLAS BASE Y SEGURIDAD
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text unique not null,
  balance_xaf bigint not null default 0,
  role text not null default 'user' check (role in ('user', 'agent', 'admin')),
  agent_status text check (agent_status in ('none', 'pending', 'approved', 'rejected')),
  agent_balance_xaf numeric not null default 0,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;
create policy "Authenticated can view profiles" on public.profiles for select to authenticated using (true);
create policy "Users can update own profile" on public.profiles for update to authenticated using (auth.uid() = id);
create policy "Users can insert own profile" on public.profiles for insert to authenticated with check (auth.uid() = id);

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  amount_xaf numeric not null check (amount_xaf > 0),
  note text,
  status text not null default 'completed' check (status in ('completed', 'cancelled', 'reversal_pending')),
  type text not null default 'transfer' check (type in ('transfer', 'deposit', 'withdrawal')),
  reversal_requested_at timestamptz,
  reversal_note text,
  created_at timestamptz not null default now()
);

create index transactions_sender_idx on public.transactions(sender_id, created_at desc);
create index transactions_recipient_idx on public.transactions(recipient_id, created_at desc);
alter table public.transactions enable row level security;
create policy "Users see own transactions" on public.transactions for select to authenticated
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

--- 2. LÓGICA DE REGISTRO
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_role text;
  v_status text;
begin
  v_role := coalesce(new.raw_user_meta_data->>'role', 'user');
  if v_role = 'agent' then v_status := 'approved'; else v_status := null; end if;

  insert into public.profiles (id, full_name, phone, role, agent_status, balance_xaf, agent_balance_xaf)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', 'Usuario Yumi'),
    coalesce(new.raw_user_meta_data->>'phone', 'pending_' || new.id),
    v_role,
    v_status,
    0,
    case when v_role = 'agent' then 100000 else 0 end
  );
  return new;
end;
$$;

create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

--- 3. FUNCIONES FINANCIERAS ATÓMICAS

-- Envío P2P
create or replace function public.send_money(p_recipient_phone text, p_amount numeric, p_note text default null)
returns public.transactions
language plpgsql security definer set search_path = public
as $$
declare
  v_sender uuid := auth.uid();
  v_recipient uuid;
  v_sender_balance numeric;
  v_tx public.transactions;
begin
  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then raise exception 'Destinatario no encontrado'; end if;
  
  select balance_xaf into v_sender_balance from public.profiles where id = v_sender for update;
  if v_sender_balance < p_amount then raise exception 'Saldo insuficiente'; end if;

  update public.profiles set balance_xaf = balance_xaf - p_amount where id = v_sender;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;
  insert into public.transactions (sender_id, recipient_id, amount_xaf, note, type)
  values (v_sender, v_recipient, p_amount, p_note, 'transfer') returning * into v_tx;
  return v_tx;
end;
$$;

-- Recarga de Agente (Cash-In)
create or replace function public.agent_deposit(p_recipient_phone text, p_amount numeric, p_note text default null)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_agent_id uuid := auth.uid();
  v_recipient_id uuid;
  v_agent_balance numeric;
begin
  select agent_balance_xaf into v_agent_balance from public.profiles where id = v_agent_id;
  if v_agent_balance < p_amount then raise exception 'Saldo de caja insuficiente'; end if;

  select id into v_recipient_id from public.profiles where phone = p_recipient_phone;
  update public.profiles set agent_balance_xaf = agent_balance_xaf - p_amount where id = v_agent_id;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient_id;

  insert into public.transactions (sender_id, recipient_id, amount_xaf, note, type, status)
  values (v_agent_id, v_recipient_id, p_amount, p_note, 'deposit', 'completed');
end;
$$;

-- Traspaso Interno (Agente)
create or replace function public.internal_transfer(p_amount numeric, p_to_agent_wallet boolean)
returns void
language plpgsql security definer set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if p_to_agent_wallet then
    update public.profiles set balance_xaf = balance_xaf - p_amount, agent_balance_xaf = agent_balance_xaf + p_amount where id = v_user;
  else
    update public.profiles set agent_balance_xaf = agent_balance_xaf - p_amount, balance_xaf = balance_xaf + p_amount where id = v_user;
  end if;
end;
$$;

-- Permisos
grant execute on function public.send_money(text, numeric, text) to authenticated;
grant execute on function public.agent_deposit(text, numeric, text) to authenticated;
grant execute on function public.internal_transfer(numeric, boolean) to authenticated;
