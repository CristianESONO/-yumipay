
-- 1. Soporte para eliminación de cuentas
alter table public.profiles add column deletion_requested boolean not null default false;
alter table public.profiles add column deletion_reason text;

-- Función para que un usuario solicite borrar su cuenta
create or replace function public.request_account_deletion(p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles 
  set deletion_requested = true, 
      deletion_reason = p_reason 
  where id = auth.uid();
end;
$$;

-- Función para que el admin procese la baja (borre el perfil)
create or replace function public.admin_process_deletion(p_user_id uuid, p_accept boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and role = 'admin') then
    raise exception 'Solo administradores pueden borrar cuentas';
  end if;

  if p_accept then
    -- Borramos el perfil (esto borrará en cascada en auth.users si está configurado, 
    -- o podemos borrar directamente de auth.users si tenemos permisos)
    delete from public.profiles where id = p_user_id;
    -- Nota: En Supabase, para borrar de auth.users desde SQL definer, 
    -- a veces se requiere llamar a service_role o un trigger especial.
    -- Aquí marcamos como procesado si no aceptamos.
  else
    update public.profiles set deletion_requested = false, deletion_reason = null where id = p_user_id;
  end if;
end;
$$;

grant execute on function public.request_account_deletion(text) to authenticated;
grant execute on function public.admin_process_deletion(uuid, boolean) to authenticated;

-- 2. Asegurar que request_agent_role funcione correctamente
-- Re-instalar por si acaso hubo algún fallo en el despliegue previo
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
    return; -- Ya está pendiente, no hacemos nada
  end if;
  
  if v_current_status = 'approved' then
    raise exception 'Ya eres un agente';
  end if;

  update public.profiles set agent_status = 'pending' where id = v_user;
  
  -- Insertar en la tabla de solicitudes para que el admin lo vea
  insert into public.agent_requests (user_id, status) 
  values (v_user, 'pending')
  on conflict do nothing;
end;
$$;

grant execute on function public.request_agent_role() to authenticated;
