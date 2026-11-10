-- =====================================================================
-- ARKIVA · Kujtesat 7+3 — MIGRACION 2
-- Dy kujtesa për çdo element: në ditën e 7 dhe në ditën e 3 para afatit
-- (pagesat e papaguara DHE skadimet e kontratave).
-- Ekzekuto PAS schema_kujtesa.sql. Zëvendëson logjikën «një kujtesë e vetme».
-- =====================================================================

-- ---------- Kolonat e reja: nga një shenjë për secilin nga dy çastet ----------
alter table public.contract_payments add column if not exists reminded7_at timestamptz;
alter table public.contract_payments add column if not exists reminded3_at timestamptz;
alter table public.contracts         add column if not exists end_reminded7_at timestamptz;
alter table public.contracts         add column if not exists end_reminded3_at timestamptz;

-- ---------- Kolonat e vjetra (të përdorura vetëm nga logjika e mëparshme «një herë») ----------
alter table public.contract_payments drop column if exists reminded_at;
alter table public.contracts         drop column if exists end_reminded_at;

-- ---------- Funksioni i përditësuar ----------
create or replace function public.dergo_kujtesa(te_test boolean default false)
returns jsonb language plpgsql security definer set search_path=public,net as $function$
declare
  k text; snd_e text; snd_n text;
  marrsit jsonb; lista text; n_sms int; sms_text text; r record;
begin
  select value into k from public.settings where key='brevo_api_key';
  if coalesce(k,'')='' then
    return jsonb_build_object('gabim','Mungon «brevo_api_key» në public.settings.');
  end if;
  select coalesce(value,'elektronikearkiva@gmail.com') into snd_e from public.settings where key='brevo_sender_email';
  select coalesce(value,'Arkiva Elektronike') into snd_n from public.settings where key='brevo_sender_name';
  select coalesce(jsonb_agg(jsonb_build_object('email', u.email)), '[]'::jsonb) into marrsit
  from public.profiles p join auth.users u on u.id = p.id
  where p.active and u.email_confirmed_at is not null;
  if jsonb_array_length(marrsit) = 0 then
    return jsonb_build_object('gabim','S''ka përdorues aktivë për t''u njoftuar.');
  end if;
  n_sms := 0;
  if te_test then
    lista := '<li>Ky është një <b>email prove</b> nga kujtesa e arkivës — çelësi i Brevo-s punon.</li>';
  else
    select string_agg('<li>'||txt||'</li>', chr(10) order by rend) into lista from (
      select '<b>'||public.htmlesc(c.contract_no)||'</b> — pagesë <b>'||to_char(p.amount,'FM999G999G990D00')||' LEK</b>'
             ||case when coalesce(p.description,'')<>'' then ' ('||public.htmlesc(p.description)||')' else '' end
             ||' · afati <b>'||to_char(p.due_date,'DD/MM/YYYY')||'</b> '
             ||case when p.due_date < current_date then '<span style="color:#b91c1c"><b>ME VONESË</b></span>'
                    when p.due_date <= current_date+3 then '<span style="color:#b91c1c"><b>3 ditë para afatit</b> — kujtesa e fundit</span>'
                    else '(pas '||(p.due_date-current_date)||' ditësh)' end as txt,
             p.due_date as rend
      from public.contract_payments p join public.contracts c on c.id=p.contract_id
      where not p.paid and c.deleted_at is null
        and ( (p.due_date <= current_date+7 and p.reminded7_at is null)
           or (p.due_date <= current_date+3 and p.reminded3_at is null) )
      union all
      select '<b>'||public.htmlesc(c.contract_no)||'</b> — kontrata skadon më <b>'||to_char(c.end_date,'DD/MM/YYYY')||'</b> '
             ||case when c.end_date <= current_date+3 then '<span style="color:#b91c1c"><b>3 ditë para afatit</b> — kujtesa e fundit</span>'
                    else '(pas '||(c.end_date-current_date)||' ditësh)' end
             ||case when coalesce(c.title,'')<>'' then '<br><span style="color:#666">'||public.htmlesc(c.title)||'</span>' else '' end,
             c.end_date
      from public.contracts c
      where c.deleted_at is null and c.end_date >= current_date
        and ( (c.end_date <= current_date+7 and c.end_reminded7_at is null)
           or (c.end_date <= current_date+3 and c.end_reminded3_at is null) )
    ) x;
    select count(*) into n_sms
    from public.contract_payments p join public.contracts c on c.id=p.contract_id
    where not p.paid and c.deleted_at is null
      and ( (p.due_date <= current_date+7 and p.reminded7_at is null)
         or (p.due_date <= current_date+3 and p.reminded3_at is null) );
  end if;
  if te_test or (lista is not null and lista <> '') then
    perform net.http_post(
      url := 'https://api.brevo.com/v3/smtp/email',
      body := jsonb_build_object(
        'sender', jsonb_build_object('name', snd_n, 'email', snd_e),
        'to', marrsit,
        'subject', case when te_test then 'Arkiva — email prove i kujtesës' else '⚠ Arkiva: kujtesë — pagesa dhe afate (7 dhe 3 ditë para)' end,
        'htmlContent',
          '<html><body style="font-family:Arial,Helvetica,sans-serif;font-size:14px;color:#222;max-width:560px;margin:0 auto">'
          ||'<div style="background:#b91c1c;color:#fff;padding:12px 18px;border-radius:8px 8px 0 0;font-weight:bold">⚠ KUJTESA E ARKIVËS</div>'
          ||'<div style="border:1px solid #e5e5ea;border-top:0;border-radius:0 0 8px 8px;padding:16px 18px">'
          ||case when te_test then '<p>Sistemi i kujtesave automatike punon.</p>' else '<p>Elementet që afrohen me afat:</p>' end
          ||'<ul style="padding-left:18px;line-height:1.8">'||coalesce(lista,'')||'</ul>'
          ||'<p style="margin-top:18px"><a href="https://genilufra-droid.github.io/arkiva/#/kontratat?k=1" style="background:#b91c1c;color:#fff;padding:10px 16px;border-radius:8px;text-decoration:none">Hap Kontratat</a></p>'
          ||'</div><p style="color:#999;font-size:11px">Email automatik i Arkivës Elektronike · dërgohen 2 kujtesa për çdo element: 7 ditë dhe 3 ditë para afatit.</p></body></html>'
      )::text,
      headers := jsonb_build_object('api-key', k, 'content-type','application/json', 'accept','application/json')
    );
    if not te_test then
      update public.contract_payments p set
        reminded7_at = case when p.due_date <= current_date+7 then now() else p.reminded7_at end,
        reminded3_at = case when p.due_date <= current_date+3 then now() else p.reminded3_at end
      from public.contracts c
      where c.id = p.contract_id and not p.paid and c.deleted_at is null
        and ( (p.due_date <= current_date+7 and p.reminded7_at is null)
           or (p.due_date <= current_date+3 and p.reminded3_at is null) );
      update public.contracts set
        end_reminded7_at = case when end_date <= current_date+7 then now() else end_reminded7_at end,
        end_reminded3_at = case when end_date <= current_date+3 then now() else end_reminded3_at end
      where deleted_at is null and end_date >= current_date
        and ( (end_date <= current_date+7 and end_reminded7_at is null)
           or (end_date <= current_date+3 and end_reminded3_at is null) );
    end if;
  end if;
  if not te_test and exists(select 1 from public.settings where key='brevo_sms' and value='1') and n_sms > 0 then
    sms_text := 'ARKIVA: kujtesë për '||n_sms||' pagesë/a (7 ose 3 ditë para afatit). Hap arkiven.';
    for r in select p.phone from public.profiles p where p.active and coalesce(p.phone,'')<>'' loop
      perform net.http_post(
        url := 'https://api.brevo.com/v3/transactionalSMS/sms',
        body := jsonb_build_object('sender','Arkiva','recipient',r.phone,'content',sms_text)::text,
        headers := jsonb_build_object('api-key', k, 'content-type','application/json', 'accept','application/json')
      );
    end loop;
  end if;
  return jsonb_build_object(
    'email_derguar', (te_test or coalesce(lista,'')<>''),
    'marrsit', marrsit,
    'sms_derguar', (not te_test and exists(select 1 from public.settings where key='brevo_sms' and value='1') and n_sms > 0)
  );
end $function$;
