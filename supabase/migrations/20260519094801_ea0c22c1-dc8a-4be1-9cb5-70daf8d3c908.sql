
-- Profiles table
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  phone text unique not null,
  balance_xaf bigint not null default 50000,
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

-- Anyone authenticated can look up profiles by phone (needed to send money), but only see safe fields via column-level grants is complex; allow full select for authenticated.
create policy "Authenticated can view profiles" on public.profiles for select to authenticated using (true);
create policy "Users can update own profile" on public.profiles for update to authenticated using (auth.uid() = id);
create policy "Users can insert own profile" on public.profiles for insert to authenticated with check (auth.uid() = id);

-- Transactions
create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  amount_xaf bigint not null check (amount_xaf > 0),
  note text,
  status text not null default 'completed',
  created_at timestamptz not null default now()
);

create index transactions_sender_idx on public.transactions(sender_id, created_at desc);
create index transactions_recipient_idx on public.transactions(recipient_id, created_at desc);

alter table public.transactions enable row level security;

create policy "Users see own transactions" on public.transactions for select to authenticated
  using (auth.uid() = sender_id or auth.uid() = recipient_id);

-- Trigger to create profile on signup
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', 'Usuario'),
    coalesce(new.raw_user_meta_data->>'phone', new.id::text)
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Transfer function (atomic)
create or replace function public.send_money(
  p_recipient_phone text,
  p_amount numeric,
  p_note text default null
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
  v_tx public.transactions;
begin
  if v_sender is null then
    raise exception 'No autenticado';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Cantidad inválida';
  end if;

  select id into v_recipient from public.profiles where phone = p_recipient_phone;
  if v_recipient is null then
    raise exception 'Destinatario no encontrado';
  end if;
  if v_recipient = v_sender then
    raise exception 'No puedes enviarte dinero a ti mismo';
  end if;

  select balance_xaf into v_sender_balance from public.profiles where id = v_sender for update;
  if v_sender_balance < p_amount then
    raise exception 'Saldo insuficiente';
  end if;

  update public.profiles set balance_xaf = balance_xaf - p_amount where id = v_sender;
  update public.profiles set balance_xaf = balance_xaf + p_amount where id = v_recipient;

  insert into public.transactions (sender_id, recipient_id, amount_xaf, note)
  values (v_sender, v_recipient, p_amount, p_note)
  returning * into v_tx;

  return v_tx;
end;
$$;

grant execute on function public.send_money(text, numeric, text) to authenticated;
