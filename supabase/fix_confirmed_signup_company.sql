-- PetFlow: provisiona empresa e vínculo somente após a confirmação do e-mail.
-- Também recupera usuários já confirmados que ficaram sem empresa.

create or replace function public.petflow_provision_user(
  p_user_id uuid,
  p_email text,
  p_metadata jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id public.companies.id%type;
  v_company_name text := nullif(trim(coalesce(p_metadata ->> 'company_name', '')), '');
  v_invite_code text := nullif(trim(coalesce(p_metadata ->> 'invite_code', '')), '');
  v_full_name text := coalesce(
    nullif(trim(coalesce(p_metadata ->> 'full_name', '')), ''),
    split_part(coalesce(p_email, 'Usuário'), '@', 1)
  );
begin
  insert into public.profiles (id, full_name, email)
  values (p_user_id, v_full_name, p_email)
  on conflict (id) do update
    set full_name = excluded.full_name,
        email = excluded.email;

  if exists (
    select 1
      from public.memberships
     where user_id = p_user_id
  ) then
    return;
  end if;

  if v_invite_code is not null then
    select id
      into v_company_id
      from public.companies
     where upper(invite_code) = upper(v_invite_code)
       and active = true
     limit 1;

    if v_company_id is null then
      raise exception 'Código da empresa inválido ou empresa inativa.';
    end if;

    insert into public.memberships (company_id, user_id, role)
    values (v_company_id, p_user_id, 'reception')
    on conflict do nothing;

    return;
  end if;

  if v_company_name is null then
    return;
  end if;

  insert into public.companies (
    name,
    invite_code,
    active,
    monthly_fee,
    billing_due_day,
    billing_grace_days,
    max_users,
    payment_status,
    access_until
  )
  values (
    v_company_name,
    upper(substr(md5(random()::text || p_user_id::text || clock_timestamp()::text), 1, 8)),
    true,
    0,
    10,
    0,
    5,
    'pending',
    current_date + 7
  )
  returning id into v_company_id;

  insert into public.memberships (company_id, user_id, role)
  values (v_company_id, p_user_id, 'owner')
  on conflict do nothing;
end;
$$;

create or replace function public.petflow_handle_confirmed_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.petflow_provision_user(
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data, '{}'::jsonb)
  );
  return new;
end;
$$;

drop trigger if exists petflow_provision_confirmed_user on auth.users;

create trigger petflow_provision_confirmed_user
after insert or update of email_confirmed_at on auth.users
for each row
when (new.email_confirmed_at is not null)
execute function public.petflow_handle_confirmed_user();

-- Recupera cadastros antigos já confirmados que ainda não possuem vínculo.
do $$
declare
  v_user record;
begin
  for v_user in
    select u.id, u.email, coalesce(u.raw_user_meta_data, '{}'::jsonb) as metadata
      from auth.users u
     where u.email_confirmed_at is not null
       and not exists (
         select 1
           from public.memberships m
          where m.user_id = u.id
       )
       and (
         nullif(trim(coalesce(u.raw_user_meta_data ->> 'company_name', '')), '') is not null
         or nullif(trim(coalesce(u.raw_user_meta_data ->> 'invite_code', '')), '') is not null
       )
  loop
    perform public.petflow_provision_user(v_user.id, v_user.email, v_user.metadata);
  end loop;
end;
$$;
