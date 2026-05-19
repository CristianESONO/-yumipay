
-- Agent status for profiles
alter table public.profiles add column agent_status text not null default 'none' check (agent_status in ('none', 'pending', 'approved', 'rejected'));

-- Agent requests table
create table public.agent_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note text,
  admin_id uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.agent_requests enable row level security;

create policy "Users see own requests" on public.agent_requests for select to authenticated
  using (auth.uid() = user_id);

create policy "Admins see all requests" on public.agent_requests for select to authenticated
  using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- Function to apply to be an agent
create or replace function public.request_agent_role()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_current_status text;
begin
  select agent_status into v_current_status from public.profiles where id = v_user;
  
  if v_current_status = 'pending' then
    raise exception 'Ya tienes una solicitud pendiente';
  end if;
  
  if v_current_status = 'approved' then
    raise exception 'Ya eres un agente';
  end if;

  update public.profiles set agent_status = 'pending' where id = v_user;
  insert into public.agent_requests (user_id) values (v_user);
end;
$$;

grant execute on function public.request_agent_role() to authenticated;

-- Function for admin to approve/reject
create or replace function public.process_agent_request(
  p_request_id uuid,
  p_approve boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_admin_role text;
  v_user_id uuid;
begin
  select role into v_admin_role from public.profiles where id = v_admin;
  if v_admin_role <> 'admin' then
    raise exception 'Solo administradores pueden procesar solicitudes';
  end if;

  select user_id into v_user_id from public.agent_requests where id = p_request_id;
  
  if p_approve then
    update public.profiles set role = 'agent', agent_status = 'approved' where id = v_user_id;
    update public.agent_requests set status = 'approved', note = p_note, admin_id = v_admin where id = p_request_id;
  else
    update public.profiles set agent_status = 'rejected' where id = v_user_id;
    update public.agent_requests set status = 'rejected', note = p_note, admin_id = v_admin where id = p_request_id;
  end if;
end;
$$;

grant execute on function public.process_agent_request(uuid, boolean, text) to authenticated;
