-- Fantasy Club v6.0: funciones transaccionales y vistas para Supabase/PostgreSQL.
-- Ejecutar DESPUÉS de schema-foundation.sql. Revisar en un proyecto de pruebas antes de producción.

alter table public.rounds add column if not exists picks_unlocked boolean not null default false;
alter table public.rounds add column if not exists votes_unlocked boolean not null default false;
alter table public.player_stats add column if not exists participated boolean not null default true;
alter table public.player_stats add column if not exists previous_source jsonb;

create table if not exists public.stat_source_history(
 id bigint generated always as identity primary key,
 league_id uuid not null references public.leagues on delete cascade,
 round_id uuid not null references public.rounds on delete cascade,
 player_id uuid not null references public.players on delete cascade,
 method public.stats_method not null,
 source_snapshot jsonb not null,
 reason text not null,
 changed_by uuid references auth.users(id),
 changed_at timestamptz not null default now()
);
alter table public.stat_source_history enable row level security;
create policy "admins read source history" on public.stat_source_history for select using(public.is_admin(league_id));

-- Las selecciones/votos solo pueden leerse por su propietario antes del cierre.
drop policy if exists "users manage own picks through RLS" on public.fantasy_picks;
create policy "own picks before close and league picks after close" on public.fantasy_picks for select using (
 user_id=auth.uid() and exists(select 1 from public.rounds r where r.id=round_id and public.is_member(r.league_id))
 or exists(select 1 from public.rounds r where r.id=round_id and r.status='closed' and public.is_member(r.league_id))
);
create policy "own votes before close and all votes after close" on public.mvp_votes for select using (
 voter_id=auth.uid() and exists(select 1 from public.rounds r where r.id=round_id and public.is_member(r.league_id))
 or exists(select 1 from public.rounds r where r.id=round_id and r.status='closed' and public.is_member(r.league_id))
);

create or replace view public.player_standings with (security_invoker=true) as
select p.league_id,p.id as player_id,p.name as player_name,
 coalesce(sum(pr.final_points),0)::numeric(10,2) as total_points,
 count(*) filter(where mr.is_winner)::int as mvp_wins
from public.players p
left join public.player_round_results pr on pr.player_id=p.id
left join public.mvp_results mr on mr.player_id=p.id and mr.round_id=pr.round_id and mr.is_winner
where p.active
group by p.league_id,p.id,p.name;

create or replace view public.fantasy_standings with (security_invoker=true) as
select lm.league_id,lm.user_id,lm.display_name,
 coalesce(sum(frr.points),0)::numeric(10,2) as total_points,
 count(*) filter(where frr.selected_mvp_winner)::int as mvp_rounds,
 coalesce((select x.points from public.fantasy_round_results x join public.rounds rr on rr.id=x.round_id
  where x.user_id=lm.user_id and rr.league_id=lm.league_id and rr.status='closed'
  order by rr.number desc limit 1),0)::numeric(10,2) as last_round_points
from public.league_members lm
left join public.fantasy_round_results frr on frr.user_id=lm.user_id
left join public.rounds r on r.id=frr.round_id and r.status='closed'
where lm.active
group by lm.league_id,lm.user_id,lm.display_name;

create or replace function public.join_league_by_code(p_code text,p_display_name text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 if length(trim(coalesce(p_display_name,'')))<1 then raise exception 'El nombre visible es obligatorio'; end if;
 select id into v_league from public.leagues where invite_code=upper(trim(p_code));
 if v_league is null then raise exception 'Código de invitación no válido'; end if;
 insert into public.league_members(league_id,user_id,display_name,role,active)
 values(v_league,auth.uid(),trim(p_display_name),'participant',true)
 on conflict(league_id,user_id) do update set display_name=excluded.display_name,active=true;
 return v_league;
end $$;

create or replace function public.admin_create_league(p_name text,p_display_name text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 if length(trim(coalesce(p_name,'')))<2 then raise exception 'El nombre de la liga es obligatorio'; end if;
 insert into public.leagues(name,created_by) values(trim(p_name),auth.uid()) returning id into v_league;
 insert into public.league_members(league_id,user_id,display_name,role,active) values(v_league,auth.uid(),coalesce(nullif(trim(p_display_name),''),'Admin'),'admin',true);
 insert into public.audit_log(league_id,actor_id,action,reason,new_values) values(v_league,auth.uid(),'league_created','Creación inicial de la liga',jsonb_build_object('name',p_name));
 return v_league;
end $$;

create or replace function public.save_fantasy_picks(p_round_id uuid,p_player_ids uuid[])
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid; v_status public.round_status; v_unlock boolean; v_prev uuid; v_count int;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 select league_id,status,picks_unlocked into v_league,v_status,v_unlock from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_member(v_league) then raise exception 'No perteneces a esta liga'; end if;
 if not (v_status='open' or (v_status='reopened' and v_unlock)) then raise exception 'Las selecciones están bloqueadas'; end if;
 if coalesce(array_length(p_player_ids,1),0)<>3 or (select count(distinct x) from unnest(p_player_ids) x)<>3 then raise exception 'Debes seleccionar exactamente tres jugadores distintos'; end if;
 if exists(select 1 from unnest(p_player_ids) x left join public.round_availability a on a.round_id=p_round_id and a.player_id=x where a.available is distinct from true) then raise exception 'Todos los jugadores deben estar disponibles al abrir la jornada'; end if;
 select r.id into v_prev from public.rounds r where r.league_id=v_league and r.status='closed' and r.number<(select number from public.rounds where id=p_round_id) order by r.number desc limit 1;
 if v_prev is not null and exists(select 1 from public.fantasy_picks fp where fp.round_id=v_prev and fp.user_id=auth.uid() and fp.player_id=any(p_player_ids)) then raise exception 'No puedes repetir jugadores de la última jornada oficial disputada'; end if;
 if exists(select 1 from unnest(p_player_ids) x join public.players p on p.id=x where p.league_id<>v_league or not p.active) then raise exception 'Jugador no válido para esta liga'; end if;
 delete from public.fantasy_picks where round_id=p_round_id and user_id=auth.uid();
 insert into public.fantasy_picks(round_id,user_id,player_id) select p_round_id,auth.uid(),x from unnest(p_player_ids) x;
 insert into public.audit_log(league_id,actor_id,action,reason,new_values) values(v_league,auth.uid(),'fantasy_picks_saved','Selección del participante',jsonb_build_object('round_id',p_round_id,'count',3));
end $$;

create or replace function public.save_mvp_vote(p_round_id uuid,p_player_ids uuid[])
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid; v_status public.round_status; v_unlock boolean;
begin
 if auth.uid() is null then raise exception 'Debes iniciar sesión'; end if;
 select league_id,status,votes_unlocked into v_league,v_status,v_unlock from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_member(v_league) then raise exception 'No perteneces a esta liga'; end if;
 if not (v_status='open' or (v_status='reopened' and v_unlock)) then raise exception 'Los votos están bloqueados'; end if;
 if coalesce(array_length(p_player_ids,1),0)<>3 or (select count(distinct x) from unnest(p_player_ids) x)<>3 then raise exception 'Debes ordenar exactamente tres candidatos distintos'; end if;
 if exists(select 1 from unnest(p_player_ids) x left join public.round_availability a on a.round_id=p_round_id and a.player_id=x where a.available is distinct from true) then raise exception 'Solo puedes votar por candidatos disponibles al abrir la jornada'; end if;
 if exists(select 1 from unnest(p_player_ids) x join public.players p on p.id=x where p.league_id<>v_league or not p.active) then raise exception 'Candidato no válido'; end if;
 delete from public.mvp_votes where round_id=p_round_id and voter_id=auth.uid();
 insert into public.mvp_votes(round_id,voter_id,player_id,rank) select p_round_id,auth.uid(),x,ord::int from unnest(p_player_ids) with ordinality as q(x,ord);
 insert into public.audit_log(league_id,actor_id,action,reason,new_values) values(v_league,auth.uid(),'mvp_vote_saved','Voto MVP del participante',jsonb_build_object('round_id',p_round_id,'count',3));
end $$;

create or replace function public.admin_open_round(p_league_id uuid,p_number int,p_reason text)
returns uuid language plpgsql security definer set search_path=public,auth as $$
declare v_round uuid; v_count int;
begin
 if not public.is_admin(p_league_id) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 if p_number<1 then raise exception 'Número de jornada no válido'; end if;
 select count(*) into v_count from public.players where league_id=p_league_id and active;
 if v_count<3 then raise exception 'Debe haber al menos tres jugadores activos antes de abrir la jornada'; end if;
 if exists(select 1 from public.rounds where league_id=p_league_id and status in ('open','reopened')) then raise exception 'Ya hay una jornada abierta'; end if;
 if exists(
   select 1 from public.league_members lm where lm.league_id=p_league_id and lm.active and
   (select count(*) from public.players pl where pl.league_id=p_league_id and pl.active and not exists(
      select 1 from public.fantasy_picks fp join public.rounds prev on prev.id=fp.round_id
      where fp.user_id=lm.user_id and fp.player_id=pl.id and prev.league_id=p_league_id and prev.status='closed' and prev.number<p_number
      and prev.number=(select max(r2.number) from public.rounds r2 where r2.league_id=p_league_id and r2.status='closed' and r2.number<p_number)
   ))<3
 ) then raise exception 'Algún participante no tendría tres jugadores elegibles por la restricción de repetición'; end if;
 insert into public.rounds(league_id,number,status,opened_at,reason,created_by) values(p_league_id,p_number,'open',now(),trim(p_reason),auth.uid()) returning id into v_round;
 insert into public.round_availability(round_id,player_id,available,reason,updated_by)
 select v_round,id,active,'Disponibilidad fijada al abrir la jornada',auth.uid() from public.players where league_id=p_league_id;
 insert into public.audit_log(league_id,actor_id,action,reason,new_values) values(p_league_id,auth.uid(),'round_opened',trim(p_reason),jsonb_build_object('round_id',v_round,'number',p_number));
 return v_round;
end $$;

create or replace function public.admin_set_manual_stats(p_league_id uuid,p_round_id uuid,p_player_id uuid,p_goals int,p_assists int,p_wins int,p_losses int,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_old jsonb; v_round_league uuid; v_status public.round_status;
begin
 if not public.is_admin(p_league_id) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 if least(p_goals,p_assists,p_wins,p_losses)<0 then raise exception 'Las estadísticas no pueden ser negativas'; end if;
 select league_id,status into v_round_league,v_status from public.rounds where id=p_round_id;
 if v_round_league is distinct from p_league_id then raise exception 'Jornada de otra liga'; end if;
 select jsonb_build_object('stats',to_jsonb(s),'events',(select coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb) from public.stat_events e where e.round_id=p_round_id and e.player_id=p_player_id)) into v_old from public.player_stats s where round_id=p_round_id and player_id=p_player_id;
 if v_old is not null then insert into public.stat_source_history(league_id,round_id,player_id,method,source_snapshot,reason,changed_by) values(p_league_id,p_round_id,p_player_id,(v_old->'stats'->>'method')::public.stats_method,v_old,trim(p_reason),auth.uid()); end if;
 insert into public.player_stats(league_id,round_id,player_id,method,goals,assists,wins,draws,losses,confirmed,source_label,reason,updated_by,participated)
 values(p_league_id,p_round_id,p_player_id,'manual',p_goals,p_assists,p_wins,0,p_losses,true,'manual',trim(p_reason),auth.uid(),true)
 on conflict(round_id,player_id) do update set method='manual',goals=excluded.goals,assists=excluded.assists,wins=excluded.wins,draws=0,losses=excluded.losses,confirmed=true,source_label='manual',reason=excluded.reason,updated_by=auth.uid(),updated_at=now(),participated=true;
 insert into public.audit_log(league_id,actor_id,action,reason,old_values,new_values) values(p_league_id,auth.uid(),'manual_stats_updated',trim(p_reason),v_old,jsonb_build_object('player_id',p_player_id,'goals',p_goals,'assists',p_assists,'wins',p_wins,'losses',p_losses));
 if v_status='closed' then perform public.admin_close_round(p_round_id,'Recalculo por corrección: '||trim(p_reason)); end if;
end $$;

create or replace function public.admin_confirm_stats(p_round_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid;
begin
 select league_id into v_league from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_admin(v_league) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 update public.rounds set stats_confirmed=true where id=p_round_id;
 update public.player_stats set confirmed=true where round_id=p_round_id;
 insert into public.audit_log(league_id,actor_id,action,reason,new_values) values(v_league,auth.uid(),'stats_confirmed',trim(p_reason),jsonb_build_object('round_id',p_round_id));
end $$;

create or replace function public.admin_set_availability(p_round_id uuid,p_player_id uuid,p_available boolean,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid; v_old boolean; v_status public.round_status;
begin
 select league_id,status into v_league,v_status from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_admin(v_league) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 select available into v_old from public.round_availability where round_id=p_round_id and player_id=p_player_id;
 update public.round_availability set available=p_available,reason=trim(p_reason),updated_by=auth.uid(),updated_at=now() where round_id=p_round_id and player_id=p_player_id;
 if not found then raise exception 'No existe disponibilidad congelada para ese jugador'; end if;
 insert into public.audit_log(league_id,actor_id,action,reason,old_values,new_values) values(v_league,auth.uid(),'availability_corrected',trim(p_reason),jsonb_build_object('player_id',p_player_id,'available',v_old),jsonb_build_object('player_id',p_player_id,'available',p_available));
 if v_status='closed' then perform public.admin_close_round(p_round_id,'Recalculo por corrección de disponibilidad: '||trim(p_reason)); end if;
end $$;

create or replace function public.admin_cancel_round(p_round_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid; v_old public.round_status;
begin
 select league_id,status into v_league,v_old from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_admin(v_league) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 update public.rounds set status='cancelled',cancelled_at=now(),reason=trim(p_reason),picks_unlocked=false,votes_unlocked=false where id=p_round_id;
 delete from public.player_round_results where round_id=p_round_id;
 delete from public.fantasy_round_results where round_id=p_round_id;
 delete from public.mvp_results where round_id=p_round_id;
 insert into public.audit_log(league_id,actor_id,action,reason,old_values,new_values) values(v_league,auth.uid(),'round_cancelled',trim(p_reason),jsonb_build_object('status',v_old),jsonb_build_object('status','cancelled'));
end $$;

create or replace function public.admin_reopen_round(p_round_id uuid,p_unlock_picks boolean,p_unlock_votes boolean,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid; v_old public.round_status;
begin
 select league_id,status into v_league,v_old from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_admin(v_league) then raise exception 'Solo admin'; end if;
 if v_old<>'closed' then raise exception 'Solo se puede reabrir una jornada cerrada'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 update public.rounds set status='reopened',picks_unlocked=p_unlock_picks,votes_unlocked=p_unlock_votes,reason=trim(p_reason) where id=p_round_id;
 insert into public.audit_log(league_id,actor_id,action,reason,old_values,new_values) values(v_league,auth.uid(),'round_reopened',trim(p_reason),jsonb_build_object('status',v_old),jsonb_build_object('status','reopened','picks_unlocked',p_unlock_picks,'votes_unlocked',p_unlock_votes));
end $$;

create or replace function public.admin_close_round(p_round_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_league uuid; v_status public.round_status; v_num int; p record; s record; v_base numeric; v_vote int; v_first int; v_maxvote int; v_maxfirst int; v_maxbase numeric; v_winners uuid[]; v_id uuid; v_points numeric; v_has boolean;
begin
 select league_id,status,number into v_league,v_status,v_num from public.rounds where id=p_round_id for update;
 if v_league is null or not public.is_admin(v_league) then raise exception 'Solo admin'; end if;
 if v_status not in ('open','reopened','closed') then raise exception 'La jornada no se puede cerrar o recalcular'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 if not exists(select 1 from public.rounds where id=p_round_id and stats_confirmed) then raise exception 'Confirma que las estadísticas están completas antes del cierre'; end if;
 if (select count(*) from public.round_availability where round_id=p_round_id and available)<3 then raise exception 'Se necesitan al menos tres jugadores disponibles'; end if;
 delete from public.player_round_results where round_id=p_round_id;
 delete from public.mvp_results where round_id=p_round_id;
 delete from public.fantasy_round_results where round_id=p_round_id;
 -- Una fila de resultado por jugador activo; la fuente manual o los eventos se excluyen mutuamente.
 for p in select id from public.players where league_id=v_league and active loop
   select * into s from public.player_stats where round_id=p_round_id and player_id=p.id;
   if not found then v_base:=0;
   elsif s.method='manual' then v_base:=floor(s.goals/5.0)+floor(s.assists/3.0)+s.wins-floor(s.losses/2.0);
   else
     select floor(coalesce(sum(quantity) filter(where event_type='goal'),0)/5.0)+floor(coalesce(sum(quantity) filter(where event_type='assist'),0)/3.0)+coalesce(sum(quantity) filter(where event_type='win'),0)-floor(coalesce(sum(quantity) filter(where event_type='loss'),0)/2.0)
     into v_base from public.stat_events where round_id=p_round_id and player_id=p.id;
   end if;
   insert into public.player_round_results(round_id,player_id,base_points,final_points) values(p_round_id,p.id,v_base,v_base);
   select coalesce(sum(case rank when 1 then 3 when 2 then 2 else 1 end),0),count(*) filter(where rank=1) into v_vote,v_first from public.mvp_votes where round_id=p_round_id and player_id=p.id;
   if exists(select 1 from public.round_availability a where a.round_id=p_round_id and a.player_id=p.id and a.available) then
     insert into public.mvp_results(round_id,player_id,vote_points,first_place_votes,base_points,final_points) values(p_round_id,p.id,v_vote,v_first,v_base,v_base);
   end if;
 end loop;
 select max(vote_points) into v_maxvote from public.mvp_results;
 select max(first_place_votes) into v_maxfirst from public.mvp_results where vote_points=v_maxvote;
 select max(base_points) into v_maxbase from public.mvp_results where vote_points=v_maxvote and first_place_votes=v_maxfirst;
 select array_agg(player_id) into v_winners from public.mvp_results where vote_points=v_maxvote and first_place_votes=v_maxfirst and base_points=v_maxbase;
 update public.mvp_results set is_winner=(player_id=any(coalesce(v_winners,'{}'::uuid[]))),final_points=case when player_id=any(coalesce(v_winners,'{}'::uuid[])) and base_points>0 then base_points*1.5 else base_points end where round_id=p_round_id;
 update public.player_round_results pr set final_points=mr.final_points from public.mvp_results mr where pr.round_id=p_round_id and mr.round_id=pr.round_id and mr.player_id=pr.player_id;
 -- Cada miembro recibe resultado: sin selección válida, 0. Jugador no participante, 0.
 for p in select user_id from public.league_members where league_id=v_league and active loop
   select count(*)=3 into v_has from public.fantasy_picks where round_id=p_round_id and user_id=p.user_id;
   if v_has then
     select coalesce(sum(case when coalesce(ps.participated,true) then pr.final_points else 0 end),0),coalesce(bool_or(mr.is_winner),false)
       into v_points,v_has
       from public.fantasy_picks fp join public.player_round_results pr on pr.round_id=fp.round_id and pr.player_id=fp.player_id
       left join public.player_stats ps on ps.round_id=fp.round_id and ps.player_id=fp.player_id
       left join public.mvp_results mr on mr.round_id=fp.round_id and mr.player_id=fp.player_id
       where fp.round_id=p_round_id and fp.user_id=p.user_id;
     insert into public.fantasy_round_results(round_id,user_id,points,selected_mvp_winner,valid_selection) values(p_round_id,p.user_id,coalesce(v_points,0),coalesce(v_has,false),true);
   else insert into public.fantasy_round_results(round_id,user_id,points,selected_mvp_winner,valid_selection) values(p_round_id,p.user_id,0,false,false); end if;
 end loop;
 update public.rounds set status='closed',closed_at=now(),reason=trim(p_reason),picks_unlocked=false,votes_unlocked=false where id=p_round_id;
 insert into public.audit_log(league_id,actor_id,action,reason,new_values) values(v_league,auth.uid(),'round_closed_and_calculated',trim(p_reason),jsonb_build_object('round_id',p_round_id,'number',v_num,'mvp_winners',coalesce(v_winners,'{}'::uuid[])));
end $$;

-- Deshabilita mutaciones directas sensibles: las operaciones deben pasar por RPC.
revoke insert,update,delete on public.fantasy_picks from anon,authenticated;
revoke insert,update,delete on public.mvp_votes from anon,authenticated;
revoke insert,update,delete on public.player_round_results from anon,authenticated;
revoke insert,update,delete on public.fantasy_round_results from anon,authenticated;
revoke insert,update,delete on public.mvp_results from anon,authenticated;
revoke insert,update,delete on public.audit_log from anon,authenticated;
revoke all on function public.join_league_by_code(text,text) from public;
revoke all on function public.admin_create_league(text,text) from public;
revoke all on function public.save_fantasy_picks(uuid,uuid[]) from public;
revoke all on function public.save_mvp_vote(uuid,uuid[]) from public;
revoke all on function public.admin_open_round(uuid,int,text) from public;
revoke all on function public.admin_set_manual_stats(uuid,uuid,uuid,int,int,int,int,text) from public;
revoke all on function public.admin_confirm_stats(uuid,text) from public;
revoke all on function public.admin_set_availability(uuid,uuid,boolean,text) from public;
revoke all on function public.admin_cancel_round(uuid,text) from public;
revoke all on function public.admin_reopen_round(uuid,boolean,boolean,text) from public;
revoke all on function public.admin_close_round(uuid,text) from public;
grant execute on function public.join_league_by_code(text,text) to authenticated;
grant execute on function public.admin_create_league(text,text) to authenticated;
grant execute on function public.save_fantasy_picks(uuid,uuid[]) to authenticated;
grant execute on function public.save_mvp_vote(uuid,uuid[]) to authenticated;
grant execute on function public.admin_open_round(uuid,int,text) to authenticated;
grant execute on function public.admin_set_manual_stats(uuid,uuid,uuid,int,int,int,int,text) to authenticated;
grant execute on function public.admin_confirm_stats(uuid,text) to authenticated;
grant execute on function public.admin_set_availability(uuid,uuid,boolean,text) to authenticated;
grant execute on function public.admin_cancel_round(uuid,text) to authenticated;
grant execute on function public.admin_reopen_round(uuid,boolean,boolean,text) to authenticated;
grant execute on function public.admin_close_round(uuid,text) to authenticated;

create or replace function public.admin_replace_events(p_league_id uuid,p_round_id uuid,p_player_id uuid,p_events jsonb,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_old jsonb; v_method public.stats_method; e record; v_round_league uuid; v_status public.round_status;
begin
 if not public.is_admin(p_league_id) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 if jsonb_typeof(coalesce(p_events,'[]'::jsonb))<>'array' then raise exception 'Los eventos deben ser una lista'; end if;
 if exists(select 1 from jsonb_to_recordset(coalesce(p_events,'[]'::jsonb)) as x(event_type text,quantity int) where event_type not in ('goal','assist','win','draw','loss') or quantity is null or quantity<1) then raise exception 'Evento o cantidad no válidos'; end if;
 select league_id,status into v_round_league,v_status from public.rounds where id=p_round_id;
 if v_round_league is distinct from p_league_id then raise exception 'Jornada de otra liga'; end if;
 select jsonb_build_object('stats',to_jsonb(s),'events',(select coalesce(jsonb_agg(to_jsonb(e)),'[]'::jsonb) from public.stat_events e where e.round_id=p_round_id and e.player_id=p_player_id)),s.method into v_old,v_method from public.player_stats s where round_id=p_round_id and player_id=p_player_id;
 if v_old is not null then insert into public.stat_source_history(league_id,round_id,player_id,method,source_snapshot,reason,changed_by) values(p_league_id,p_round_id,p_player_id,v_method,v_old,trim(p_reason),auth.uid()); end if;
 delete from public.stat_events where round_id=p_round_id and player_id=p_player_id;
 insert into public.stat_events(league_id,round_id,player_id,event_type,quantity,source_label,created_by)
 select p_league_id,p_round_id,p_player_id,x.event_type,x.quantity,'event-entry',auth.uid()
 from jsonb_to_recordset(coalesce(p_events,'[]'::jsonb)) as x(event_type text,quantity int);
 insert into public.player_stats(league_id,round_id,player_id,method,goals,assists,wins,draws,losses,confirmed,source_label,reason,updated_by,participated)
 values(p_league_id,p_round_id,p_player_id,'events',0,0,0,0,0,true,'events',trim(p_reason),auth.uid(),true)
 on conflict(round_id,player_id) do update set method='events',goals=0,assists=0,wins=0,draws=0,losses=0,confirmed=true,source_label='events',reason=excluded.reason,updated_by=auth.uid(),updated_at=now(),participated=true;
 insert into public.audit_log(league_id,actor_id,action,reason,old_values,new_values) values(p_league_id,auth.uid(),'event_stats_replaced',trim(p_reason),v_old,jsonb_build_object('player_id',p_player_id,'events',p_events));
 if v_status='closed' then perform public.admin_close_round(p_round_id,'Recalculo por sustitución de fuente: '||trim(p_reason)); end if;
end $$;
revoke all on function public.admin_replace_events(uuid,uuid,uuid,jsonb,text) from public;
grant execute on function public.admin_replace_events(uuid,uuid,uuid,jsonb,text) to authenticated;

create or replace function public.admin_set_participation(p_league_id uuid,p_round_id uuid,p_player_id uuid,p_participated boolean,p_reason text)
returns void language plpgsql security definer set search_path=public,auth as $$
declare v_status public.round_status; v_old boolean;
begin
 if not public.is_admin(p_league_id) then raise exception 'Solo admin'; end if;
 if length(trim(coalesce(p_reason,'')))=0 then raise exception 'El motivo es obligatorio'; end if;
 select status into v_status from public.rounds where id=p_round_id and league_id=p_league_id for update;
 if v_status is null then raise exception 'Jornada no válida'; end if;
 select participated into v_old from public.player_stats where round_id=p_round_id and player_id=p_player_id;
 if not found then
   insert into public.player_stats(league_id,round_id,player_id,method,goals,assists,wins,draws,losses,confirmed,source_label,reason,updated_by,participated)
   values(p_league_id,p_round_id,p_player_id,'manual',0,0,0,0,0,false,'participation-only',trim(p_reason),auth.uid(),p_participated);
 else
   update public.player_stats set participated=p_participated,reason=trim(p_reason),updated_by=auth.uid(),updated_at=now() where round_id=p_round_id and player_id=p_player_id;
 end if;
 insert into public.audit_log(league_id,actor_id,action,reason,old_values,new_values) values(p_league_id,auth.uid(),'participation_corrected',trim(p_reason),jsonb_build_object('player_id',p_player_id,'participated',v_old),jsonb_build_object('player_id',p_player_id,'participated',p_participated));
 if v_status='closed' then perform public.admin_close_round(p_round_id,'Recalculo por corrección de participación: '||trim(p_reason)); end if;
end $$;
revoke all on function public.admin_set_participation(uuid,uuid,uuid,boolean,text) from public;
grant execute on function public.admin_set_participation(uuid,uuid,uuid,boolean,text) to authenticated;
