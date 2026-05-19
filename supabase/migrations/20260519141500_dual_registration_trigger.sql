
-- Update the handle_new_user trigger to support initial role and auto-approval
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
  
  -- If they choose agent from the start, we auto-approve them
  if v_role = 'agent' then
    v_status := 'approved';
  else
    v_status := null;
  end if;

  insert into public.profiles (
    id, 
    full_name, 
    phone, 
    role, 
    agent_status,
    balance_xaf,
    agent_balance_xaf
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', 'Usuario Yumi'),
    coalesce(new.raw_user_meta_data->>'phone', 'pending_' || new.id),
    v_role,
    v_status,
    0, -- Initial personal balance
    case when v_role = 'agent' then 100000 else 0 end -- Initial agent float bonus for testing
  );
  return new;
end;
$$;
