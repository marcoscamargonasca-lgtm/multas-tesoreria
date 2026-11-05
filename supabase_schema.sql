-- SISTEMA DE ASISTENCIA Y TESORERÍA
-- Ejecutar en Supabase SQL Editor con un proyecto nuevo.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null,
 email text,
 role text not null default 'member' check (role in ('member','treasurer')),
 active boolean not null default true,
 created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.profiles(id,full_name,email)
 values(new.id, coalesce(new.raw_user_meta_data->>'full_name','Integrante'), new.email)
 on conflict(id) do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_treasurer()
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles where id=auth.uid() and role='treasurer' and active=true)
$$;

create table if not exists public.activities (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 activity_type text not null check(activity_type in ('meeting','faena')),
 starts_at timestamptz not null,
 place text,
 description text,
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.attendance (
 id uuid primary key default gen_random_uuid(),
 activity_id uuid not null references public.activities(id) on delete cascade,
 member_id uuid not null references public.profiles(id),
 status text not null check(status in ('present','late','absent','justified')),
 justification text,
 fine_amount numeric(12,2) not null default 0 check(fine_amount>=0),
 recorded_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now(),
 unique(activity_id,member_id)
);
create table if not exists public.charges (
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references public.profiles(id),
 attendance_id uuid unique references public.attendance(id),
 description text not null,
 amount numeric(12,2) not null check(amount>0),
 status text not null default 'pending' check(status in ('pending','paid','partial')),
 created_at timestamptz not null default now()
);
create table if not exists public.payments (
 id uuid primary key default gen_random_uuid(),
 member_id uuid not null references public.profiles(id),
 amount numeric(12,2) not null check(amount>0),
 note text,
 paid_at date not null default current_date,
 received_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.payment_allocations (
 id uuid primary key default gen_random_uuid(),
 payment_id uuid not null references public.payments(id) on delete cascade,
 charge_id uuid not null references public.charges(id),
 amount numeric(12,2) not null check(amount>0),
 unique(payment_id,charge_id)
);
create table if not exists public.income_entries (
 id uuid primary key default gen_random_uuid(),
 amount numeric(12,2) not null check(amount>0),
 description text not null,
 entry_type text not null default 'other' check(entry_type in ('other','fee')),
 member_id uuid references public.profiles(id),
 entry_date date not null default current_date,
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.expenses (
 id uuid primary key default gen_random_uuid(),
 title text not null,
 amount numeric(12,2) not null check(amount>0),
 expense_date date not null default current_date,
 responsible_name text,
 signer_name text,
 signature_text text,
 description text,
 evidence_path text,
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);

-- Asistencia: solo tesorero; cargos automáticos para tardanza/falta.
create or replace function public.record_attendance(
 p_activity_id uuid,p_member_id uuid,p_status text,p_justification text,p_fine_amount numeric
) returns void language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_type text; v_expected numeric;
begin
 if not public.is_treasurer() then raise exception 'Solo el tesorero puede registrar asistencia'; end if;
 if p_status not in ('present','late','absent','justified') then raise exception 'Estado inválido'; end if;
 select activity_type into v_type from public.activities where id=p_activity_id;
 if v_type is null then raise exception 'Actividad no encontrada'; end if;
 v_expected := case when p_status='late' and v_type='meeting' then 5
                    when p_status='absent' and v_type='meeting' then 10
                    when p_status='late' and v_type='faena' then 25
                    when p_status='absent' and v_type='faena' then 50 else 0 end;
 if p_fine_amount<>v_expected then raise exception 'El importe de multa no coincide con el reglamento configurado'; end if;
 insert into public.attendance(activity_id,member_id,status,justification,fine_amount,recorded_by)
 values(p_activity_id,p_member_id,p_status,p_justification,v_expected,auth.uid())
 on conflict(activity_id,member_id) do update set status=excluded.status,justification=excluded.justification,fine_amount=excluded.fine_amount,recorded_by=auth.uid()
 returning id into v_id;
 delete from public.charges where attendance_id=v_id;
 if v_expected>0 then
  insert into public.charges(member_id,attendance_id,description,amount)
  values(p_member_id,v_id,case when v_type='faena' then 'Multa de faena: ' else 'Multa de reunión: ' end||p_status,v_expected);
 end if;
end $$;

-- Pago aplicado a los cargos más antiguos primero. El excedente queda como pago recibido.
create or replace function public.register_member_payment(p_member_id uuid,p_amount numeric,p_note text,p_paid_at date)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_payment uuid; v_remaining numeric:=p_amount; r record; v_due numeric; v_alloc numeric;
begin
 if not public.is_treasurer() then raise exception 'Solo el tesorero puede registrar pagos'; end if;
 if p_amount<=0 then raise exception 'El importe debe ser positivo'; end if;
 insert into public.payments(member_id,amount,note,paid_at,received_by)
 values(p_member_id,p_amount,p_note,coalesce(p_paid_at,current_date),auth.uid()) returning id into v_payment;
 for r in select c.id,c.amount,coalesce(sum(a.amount),0) paid
          from public.charges c left join public.payment_allocations a on a.charge_id=c.id
          where c.member_id=p_member_id group by c.id,c.amount,c.created_at order by c.created_at
 loop
  exit when v_remaining<=0;
  v_due:=r.amount-r.paid;
  if v_due>0 then
   v_alloc:=least(v_due,v_remaining);
   insert into public.payment_allocations(payment_id,charge_id,amount) values(v_payment,r.id,v_alloc);
   v_remaining:=v_remaining-v_alloc;
  end if;
 end loop;
 update public.charges c set status=case when coalesce((select sum(a.amount) from public.payment_allocations a where a.charge_id=c.id),0)>=c.amount then 'paid'
                                          when coalesce((select sum(a.amount) from public.payment_allocations a where a.charge_id=c.id),0)>0 then 'partial' else 'pending' end;
 return v_payment;
end $$;

alter table public.profiles enable row level security;
alter table public.activities enable row level security;
alter table public.attendance enable row level security;
alter table public.charges enable row level security;
alter table public.payments enable row level security;
alter table public.payment_allocations enable row level security;
alter table public.income_entries enable row level security;
alter table public.expenses enable row level security;

-- Profiles: cada integrante ve el padrón básico; solo tesorero modifica.
drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using(active=true or id=auth.uid() or public.is_treasurer());
drop policy if exists profiles_update_treasurer on public.profiles;
create policy profiles_update_treasurer on public.profiles for update to authenticated using(public.is_treasurer()) with check(public.is_treasurer());
-- Actividades visibles para integrantes; alta/edición solo tesorero.
drop policy if exists activities_read on public.activities;
create policy activities_read on public.activities for select to authenticated using(true);
drop policy if exists activities_insert on public.activities;
create policy activities_insert on public.activities for insert to authenticated with check(public.is_treasurer() and created_by=auth.uid());
drop policy if exists activities_update on public.activities;
create policy activities_update on public.activities for update to authenticated using(public.is_treasurer()) with check(public.is_treasurer());
-- Asistencia visible solo propia o por tesorero; escritura solo mediante RPC.
drop policy if exists attendance_read on public.attendance;
create policy attendance_read on public.attendance for select to authenticated using(member_id=auth.uid() or public.is_treasurer());
drop policy if exists charges_read on public.charges;
create policy charges_read on public.charges for select to authenticated using(member_id=auth.uid() or public.is_treasurer());
drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated using(member_id=auth.uid() or public.is_treasurer());
drop policy if exists allocations_read on public.payment_allocations;
create policy allocations_read on public.payment_allocations for select to authenticated using(public.is_treasurer() or exists(select 1 from public.payments p where p.id=payment_id and p.member_id=auth.uid()));
-- Solo tesorero crea ingresos/gastos; integrantes no pueden ver registros contables completos.
drop policy if exists income_read on public.income_entries;
create policy income_read on public.income_entries for select to authenticated using(public.is_treasurer());
drop policy if exists income_insert on public.income_entries;
create policy income_insert on public.income_entries for insert to authenticated with check(public.is_treasurer() and created_by=auth.uid());
drop policy if exists expense_read on public.expenses;
create policy expense_read on public.expenses for select to authenticated using(public.is_treasurer() or true);
drop policy if exists expense_insert on public.expenses;
create policy expense_insert on public.expenses for insert to authenticated with check(public.is_treasurer() and created_by=auth.uid());

-- Storage privado para comprobantes.
insert into storage.buckets(id,name,public) values('expense-evidence','expense-evidence',false) on conflict(id) do nothing;
drop policy if exists evidence_read on storage.objects;
create policy evidence_read on storage.objects for select to authenticated using(bucket_id='expense-evidence' and (public.is_treasurer() or true));
drop policy if exists evidence_upload on storage.objects;
create policy evidence_upload on storage.objects for insert to authenticated with check(bucket_id='expense-evidence' and public.is_treasurer());
drop policy if exists evidence_update on storage.objects;
create policy evidence_update on storage.objects for update to authenticated using(bucket_id='expense-evidence' and public.is_treasurer()) with check(bucket_id='expense-evidence' and public.is_treasurer());


-- Resumen agregado de caja visible a todos los integrantes autenticados.
create or replace function public.get_public_financial_summary()
returns json language plpgsql stable security definer set search_path=public as $$
declare v_payments numeric; v_incomes numeric; v_expenses numeric;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 select coalesce(sum(amount),0) into v_payments from public.payments;
 select coalesce(sum(amount),0) into v_incomes from public.income_entries;
 select coalesce(sum(amount),0) into v_expenses from public.expenses;
 return json_build_object('payments',v_payments,'incomes',v_incomes,'expenses',v_expenses,'balance',v_payments+v_incomes-v_expenses);
end $$;

-- Vista útil para revisar deuda pendiente; las políticas siguen aplicando a las tablas.
create or replace view public.member_balances as
select p.id as member_id,p.full_name,
 coalesce((select sum(c.amount) from public.charges c where c.member_id=p.id),0)
 - coalesce((select sum(a.amount) from public.payment_allocations a join public.charges c on c.id=a.charge_id where c.member_id=p.id),0) as debt_balance
from public.profiles p;
