-- =====================================================================
-- 1-قاعدة-البيانات.sql — شغّله مرة واحدة: Supabase > SQL Editor > New query > الصق > Run
-- ينشئ كل الجداول والصلاحيات والدوال (المشرفون، المعلمون، الأسر، الطلاب، الحصص، المالية).
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

-- ---------- الجداول ----------
create table if not exists public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('admin','teacher')),
  display_name text, active boolean not null default true,
  deleted_at timestamptz, created_at timestamptz not null default now());

create table if not exists public.teachers(
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique references auth.users(id) on delete set null,
  name text not null check (btrim(name) <> ''),
  username text not null unique check (username ~ '^[a-z0-9_-]{3,30}$'),
  hourly_rate_usd numeric(10,2) not null default 0 check (hourly_rate_usd >= 0),
  active boolean not null default true, deleted_at timestamptz,
  created_at timestamptz not null default now());

create table if not exists public.families(
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  teacher_id uuid not null references public.teachers(id) on delete restrict,
  created_at timestamptz not null default now());
create unique index if not exists families_uq on public.families(teacher_id, lower(btrim(name)));

create table if not exists public.students(
  id uuid primary key default gen_random_uuid(),
  name text not null check (btrim(name) <> ''),
  teacher_id uuid not null references public.teachers(id) on delete restrict,
  family_id uuid references public.families(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now());
create unique index if not exists students_uq on public.students
  (teacher_id, coalesce(family_id, '00000000-0000-0000-0000-000000000000'::uuid), lower(btrim(name)));

-- سعر الطالب بالدولار: جدول للمشرف فقط (سرّي عن المعلم)
create table if not exists public.student_pricing(
  student_id uuid primary key references public.students(id) on delete cascade,
  rate_usd numeric(10,2) not null default 0 check (rate_usd >= 0),
  updated_at timestamptz not null default now());

create table if not exists public.lessons(
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references public.teachers(id) on delete restrict,
  student_id uuid not null references public.students(id) on delete restrict,
  lesson_date date not null,
  status text not null check (status in ('present','absent')),
  duration_minutes int not null check (duration_minutes in
    (15,20,30,40,45,60,75,90,105,120,135,150,165,180,195,210,225,240)),
  note text,
  teacher_rate_usd numeric(10,2),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  edited_at timestamptz, deleted_at timestamptz, seen_by_admin_at timestamptz);
create index if not exists lessons_date_idx on public.lessons(lesson_date);
create index if not exists lessons_teacher_idx on public.lessons(teacher_id, lesson_date);
create index if not exists lessons_student_idx on public.lessons(student_id, lesson_date);

create table if not exists public.lesson_pricing(
  lesson_id uuid primary key references public.lessons(id) on delete cascade,
  student_rate_usd numeric(10,2) not null default 0 check (student_rate_usd >= 0));

create table if not exists public.exchange_rates(
  id int primary key check (id = 1),
  usd_to_egp numeric(10,4) not null check (usd_to_egp > 0),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null);
insert into public.exchange_rates(id, usd_to_egp) values (1, 50) on conflict (id) do nothing;

-- ---------- دوال مساعدة ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists(select 1 from profiles where id = auth.uid() and role = 'admin' and active and deleted_at is null) $$;

create or replace function public.my_teacher_id() returns uuid
language sql stable security definer set search_path = public as $$
  select id from teachers where auth_user_id = auth.uid() and active and deleted_at is null limit 1 $$;

create or replace function public.get_exchange_rate() returns numeric
language sql stable security definer set search_path = public as $$
  select usd_to_egp from exchange_rates where id = 1 $$;

-- ---------- حارس: لا يُترك الموقع بلا مشرف ----------
create or replace function public.guard_last_admin() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.role = 'admin' and old.active and old.deleted_at is null and
     (tg_op = 'DELETE' or new.role <> 'admin' or not new.active or new.deleted_at is not null) then
    perform pg_advisory_xact_lock(1001);
    if not exists (select 1 from profiles where role = 'admin' and active and deleted_at is null and id <> old.id) then
      raise exception 'LAST_ADMIN';
    end if;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end $$;
drop trigger if exists trg_guard_last_admin on public.profiles;
create trigger trg_guard_last_admin before update or delete on public.profiles
  for each row execute function public.guard_last_admin();

-- ---------- الحصص: المعلم وأجره يُشتقان من الطالب، وسعر الطالب يُثبَّت سرّياً ----------
create or replace function public.lessons_biu() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record;
begin
  if tg_op = 'INSERT' or new.student_id is distinct from old.student_id then
    select st.teacher_id, t.hourly_rate_usd into s
      from students st join teachers t on t.id = st.teacher_id where st.id = new.student_id;
    if not found then raise exception 'STUDENT_NOT_FOUND'; end if;
    new.teacher_id := s.teacher_id; new.teacher_rate_usd := s.hourly_rate_usd;
  end if;
  if tg_op = 'INSERT' then
    new.created_by := auth.uid(); new.seen_by_admin_at := null;
  else
    if not is_admin() and (new.created_by is distinct from old.created_by
       or new.seen_by_admin_at is distinct from old.seen_by_admin_at
       or new.teacher_rate_usd is distinct from old.teacher_rate_usd) and new.student_id = old.student_id then
      raise exception 'FORBIDDEN_FIELDS';
    end if;
    new.updated_at := now();
    if (new.lesson_date, new.duration_minutes, new.status, new.note, new.student_id)
       is distinct from (old.lesson_date, old.duration_minutes, old.status, old.note, old.student_id) then
      new.edited_at := now();
    end if;
  end if;
  return new;
end $$;
drop trigger if exists trg_lessons_biu on public.lessons;
create trigger trg_lessons_biu before insert or update on public.lessons
  for each row execute function public.lessons_biu();

create or replace function public.lessons_pricing_aiu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.student_id is distinct from old.student_id then
    insert into lesson_pricing(lesson_id, student_rate_usd)
    values (new.id, coalesce((select rate_usd from student_pricing where student_id = new.student_id), 0))
    on conflict (lesson_id) do update set student_rate_usd = excluded.student_rate_usd;
  end if;
  return null;
end $$;
drop trigger if exists trg_lessons_pricing on public.lessons;
create trigger trg_lessons_pricing after insert or update of student_id on public.lessons
  for each row execute function public.lessons_pricing_aiu();

create or replace function public.students_pricing_ai() returns trigger
language plpgsql security definer set search_path = public as $$
begin insert into student_pricing(student_id) values (new.id) on conflict do nothing; return null; end $$;
drop trigger if exists trg_students_pricing on public.students;
create trigger trg_students_pricing after insert on public.students
  for each row execute function public.students_pricing_ai();

-- ---------- RLS ----------
alter table public.profiles enable row level security;
alter table public.teachers enable row level security;
alter table public.families enable row level security;
alter table public.students enable row level security;
alter table public.student_pricing enable row level security;
alter table public.lessons enable row level security;
alter table public.lesson_pricing enable row level security;
alter table public.exchange_rates enable row level security;

drop policy if exists profiles_sel on public.profiles;
create policy profiles_sel on public.profiles for select using (id = auth.uid() or is_admin());
drop policy if exists teachers_admin on public.teachers;
create policy teachers_admin on public.teachers for all using (is_admin()) with check (is_admin());
drop policy if exists teachers_self on public.teachers;
create policy teachers_self on public.teachers for select using (id = my_teacher_id());
drop policy if exists families_admin on public.families;
create policy families_admin on public.families for all using (is_admin()) with check (is_admin());
drop policy if exists families_self on public.families;
create policy families_self on public.families for select using (teacher_id = my_teacher_id());
drop policy if exists students_admin on public.students;
create policy students_admin on public.students for all using (is_admin()) with check (is_admin());
drop policy if exists students_self on public.students;
create policy students_self on public.students for select using (teacher_id = my_teacher_id() and active);
drop policy if exists pricing_admin on public.student_pricing;
create policy pricing_admin on public.student_pricing for all using (is_admin()) with check (is_admin());
drop policy if exists lessons_admin on public.lessons;
create policy lessons_admin on public.lessons for all using (is_admin()) with check (is_admin());
drop policy if exists lessons_t_sel on public.lessons;
create policy lessons_t_sel on public.lessons for select using (teacher_id = my_teacher_id() and deleted_at is null);
drop policy if exists lessons_t_ins on public.lessons;
create policy lessons_t_ins on public.lessons for insert with check (teacher_id = my_teacher_id());
drop policy if exists lpricing_admin on public.lesson_pricing;
create policy lpricing_admin on public.lesson_pricing for all using (is_admin()) with check (is_admin());
drop policy if exists rates_admin on public.exchange_rates;
create policy rates_admin on public.exchange_rates for all using (is_admin()) with check (is_admin());

-- =====================================================================
-- إدارة الحسابات من داخل الموقع (بدون أي خادم خارجي)
-- =====================================================================
-- دالة داخلية: تنشئ مستخدم دخول كاملاً (لا يستدعيها أحد مباشرة)
create or replace function public._mk_user(p_email text, p_pw text, p_role text, p_name text) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare uid uuid := gen_random_uuid(); c text;
begin
  if length(coalesce(p_pw,'')) < 8 then raise exception 'WEAK_PASSWORD'; end if;
  if exists(select 1 from auth.users where lower(email) = lower(p_email)) then raise exception 'USERNAME_TAKEN'; end if;
  insert into auth.users(instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                         raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  values ('00000000-0000-0000-0000-000000000000', uid, 'authenticated', 'authenticated', lower(p_email),
          crypt(p_pw, gen_salt('bf')), now(), '{"provider":"email","providers":["email"]}', '{}', now(), now());
  -- بعض أعمدة الرموز يجب ألا تكون NULL حتى يعمل تسجيل الدخول
  for c in select column_name from information_schema.columns
           where table_schema = 'auth' and table_name = 'users' and data_type in ('text','character varying')
             and column_name in ('confirmation_token','recovery_token','email_change','email_change_token_new',
                                 'email_change_token_current','phone_change','phone_change_token','reauthentication_token')
  loop
    execute format('update auth.users set %I = coalesce(%I, '''') where id = $1', c, c) using uid;
  end loop;
  insert into auth.identities(id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), uid, uid::text,
          jsonb_build_object('sub', uid::text, 'email', lower(p_email), 'email_verified', true, 'phone_verified', false),
          'email', now(), now(), now());
  insert into profiles(id, role, display_name) values (uid, p_role, btrim(p_name));
  return uid;
end $$;

create or replace function public.admin_create_teacher(p_name text, p_username text, p_password text, p_rate numeric) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare u text := lower(btrim(p_username)); uid uuid; tid uuid;
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  if btrim(coalesce(p_name,'')) = '' or p_rate < 0 then raise exception 'INVALID'; end if;
  if u !~ '^[a-z0-9_-]{3,30}$' then raise exception 'INVALID_USERNAME'; end if;
  if exists(select 1 from teachers where username = u) then raise exception 'USERNAME_TAKEN'; end if;
  uid := _mk_user(u || '@quran.arabic.academy', p_password, 'teacher', p_name);
  insert into teachers(auth_user_id, name, username, hourly_rate_usd) values (uid, btrim(p_name), u, p_rate) returning id into tid;
  return tid;
end $$;

create or replace function public.admin_update_teacher(p_id uuid, p_name text, p_username text, p_rate numeric) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare t record; u text := lower(btrim(p_username));
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into t from teachers where id = p_id and deleted_at is null;
  if not found then raise exception 'NOT_FOUND'; end if;
  if btrim(coalesce(p_name,'')) = '' or p_rate < 0 then raise exception 'INVALID'; end if;
  if u <> t.username then
    if u !~ '^[a-z0-9_-]{3,30}$' then raise exception 'INVALID_USERNAME'; end if;
    if exists(select 1 from teachers where username = u and id <> p_id) then raise exception 'USERNAME_TAKEN'; end if;
    if t.auth_user_id is not null then
      update auth.users set email = u || '@quran.arabic.academy', updated_at = now() where id = t.auth_user_id;
      update auth.identities set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(u || '@quran.arabic.academy')),
             updated_at = now() where user_id = t.auth_user_id and provider = 'email';
    end if;
  end if;
  update teachers set name = btrim(p_name), username = u, hourly_rate_usd = p_rate where id = p_id;
end $$;

create or replace function public.admin_set_teacher_password(p_teacher uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare v uuid;
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  select auth_user_id into v from teachers where id = p_teacher;
  if v is null then raise exception 'NOT_FOUND'; end if;
  if length(coalesce(p_password,'')) < 8 then raise exception 'WEAK_PASSWORD'; end if;
  update auth.users set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now() where id = v;
  delete from auth.sessions where user_id = v;
end $$;

create or replace function public.admin_set_teacher_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare v uuid;
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  select auth_user_id into v from teachers where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  update teachers set active = p_active where id = p_id;
  if v is not null then
    update profiles set active = p_active where id = v;
    update auth.users set banned_until = case when p_active then null else now() + interval '100 years' end where id = v;
    if not p_active then delete from auth.sessions where user_id = v; end if;
  end if;
end $$;

-- p_mode: del = حذف نهائي (فقط بلا بيانات) | stop = إيقاف | arch = أرشفة (إخفاء مع بقاء كل السجلات)
create or replace function public.admin_delete_teacher(p_id uuid, p_mode text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
declare t record;
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  select * into t from teachers where id = p_id;
  if not found then raise exception 'NOT_FOUND'; end if;
  if p_mode = 'del' then
    if exists(select 1 from students where teacher_id = p_id) or exists(select 1 from families where teacher_id = p_id)
       or exists(select 1 from lessons where teacher_id = p_id) then raise exception 'HAS_DATA'; end if;
    delete from teachers where id = p_id;
    if t.auth_user_id is not null then delete from auth.users where id = t.auth_user_id; end if;
  elsif p_mode = 'stop' then
    perform admin_set_teacher_active(p_id, false);
  elsif p_mode = 'arch' then
    perform admin_set_teacher_active(p_id, false);
    update teachers set deleted_at = now() where id = p_id;
    if t.auth_user_id is not null then update profiles set deleted_at = now() where id = t.auth_user_id; end if;
  else raise exception 'INVALID'; end if;
end $$;

create or replace function public.admin_create_admin(p_name text, p_username text, p_password text) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare u text := lower(btrim(p_username));
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  if btrim(coalesce(p_name,'')) = '' then raise exception 'INVALID'; end if;
  if u !~ '^[a-z0-9_-]{3,30}$' then raise exception 'INVALID_USERNAME'; end if;
  return _mk_user(u || '@admin.quran.arabic.academy', p_password, 'admin', p_name);
end $$;

-- يعيد true إذا أزال المشرف نفسه (فيسجّل الموقع خروجه). الحارس يمنع إزالة المشرف الوحيد.
create or replace function public.admin_remove_admin(p_id uuid) returns boolean
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  if not exists(select 1 from profiles where id = p_id and role = 'admin') then raise exception 'NOT_FOUND'; end if;
  delete from auth.users where id = p_id;
  return p_id = auth.uid();
end $$;

create or replace function public.admin_list_admins()
returns table(id uuid, display_name text, email text, active boolean, created_at timestamptz)
language plpgsql stable security definer set search_path = public, auth as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  return query select p.id, p.display_name, u.email::text, p.active, p.created_at
    from profiles p join auth.users u on u.id = p.id
    where p.role = 'admin' and p.deleted_at is null order by p.created_at;
end $$;

-- أول مشرف: يُشغَّل يدوياً من SQL Editor فقط (ملف 2) ولا يعمل إلا إن لم يوجد أي مشرف
create or replace function public.setup_first_admin(p_name text, p_username text, p_password text) returns uuid
language plpgsql security definer set search_path = public, extensions, auth as $$
declare u text := lower(btrim(p_username));
begin
  if exists(select 1 from profiles where role = 'admin' and active and deleted_at is null) then raise exception 'ALREADY_SETUP'; end if;
  if u !~ '^[a-z0-9_-]{3,30}$' then raise exception 'INVALID_USERNAME'; end if;
  return _mk_user(u || '@admin.quran.arabic.academy', p_password, 'admin', p_name);
end $$;

-- ---------- الحذف والنقل (مشرف فقط) ----------
create or replace function public.admin_delete_student(p_id uuid, p_with_lessons boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_with_lessons then delete from lessons where student_id = p_id;
  elsif exists (select 1 from lessons where student_id = p_id) then raise exception 'HAS_LESSONS'; end if;
  delete from students where id = p_id;
end $$;

create or replace function public.admin_delete_family(p_id uuid, p_with_students boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  if p_with_students then
    delete from lessons where student_id in (select id from students where family_id = p_id);
    delete from students where family_id = p_id;
  end if;
  delete from families where id = p_id;
end $$;

create or replace function public.admin_move_family(p_id uuid, p_teacher uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  update families set teacher_id = p_teacher where id = p_id;
  update students set teacher_id = p_teacher where family_id = p_id;
end $$;

create or replace function public.admin_mark_lessons_seen(p_ids uuid[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'FORBIDDEN'; end if;
  update lessons set seen_by_admin_at = now() where id = any(p_ids) and seen_by_admin_at is null;
end $$;

-- ---------- الصلاحيات النهائية ----------
revoke all on all tables in schema public from anon;
revoke execute on all functions in schema public from anon, public;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on function public._mk_user(text,text,text,text) from authenticated;
revoke execute on function public.setup_first_admin(text,text,text) from authenticated;
