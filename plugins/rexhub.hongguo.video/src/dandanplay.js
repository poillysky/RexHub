import {ApiError,validId} from './client.js';
import {Catalog} from './catalog.js';
import {Danmaku,danmakuQuery} from './danmaku.js';
export const DANDAN_BASE='/v1/dandanplay/api/v2';
export function isDandanplayPath(path){return path.startsWith('/api/v2/')||path.startsWith(DANDAN_BASE+'/');}
function anime(item){return {animeId:item.id,animeTitle:item.title,type:'tv',typeDescription:'红果漫剧',imageUrl:item.cover||''};}
export async function dandanplay(url,client,cache){
  // Count actual upstream method calls, not cache hits, including comment pagination.
  let requests=0;
  const upstream=client;
  client=Object.fromEntries(['detail','suggest','comments'].map(name=>[name,(...args)=>{
    if(requests>=40)throw new ApiError('DANMAKU_REQUEST_BUDGET','本次弹幕请求达到上限，请稍后重试或按 time 分段读取',503);
    requests++;return upstream[name](...args);
  }]));
  const prefix=url.pathname.startsWith(DANDAN_BASE+'/')?DANDAN_BASE:'/api/v2';
  const path=url.pathname.slice(prefix.length).replace(/\/$/,''),catalog=new Catalog(client,cache);
  if(path==='/search/anime'){
    const q=(url.searchParams.get('keyword')||'').trim();
    if(!q||q.length>100)throw new ApiError('INVALID_QUERY','请输入 1–100 字的剧名',400);
    const result=await catalog.search(q,1);
    return {success:true,errorCode:0,animes:result.items.map(anime)};
  }
  const bangumi=path.match(/^\/bangumi\/([^/]+)$/);
  if(bangumi){
    const detail=await catalog.detail(validId(bangumi[1]),true);
    return {success:true,errorCode:0,bangumi:{...anime(detail),episodes:detail.episodes.map(e=>({
      // Self-contained IDs survive Worker/cache restarts; FW accepts string episode IDs.
      episodeId:detail.id+'_'+e.id,episodeTitle:'第'+e.episode+'集',episodeNumber:e.episode
    }))}};
  }
  const comment=path.match(/^\/comment\/(\d{10,24})_(\d{10,24})$/);
  if(comment){
    const detail=await catalog.detail(comment[1],true),episode=detail.episodes.find(e=>e.id===comment[2]);
    if(!episode)throw new ApiError('DANMAKU_EPISODE','未找到弹幕目标分集',404);
    const duration=episode.duration;
    if(!Number.isFinite(duration)||duration<=0||duration>1800)throw new ApiError('DANMAKU_DURATION','弹幕时长须在 30 分钟以内');
    const service=new Danmaku(client,cache),comments=new Map();
    const time=url.searchParams.get('time');
    const times=time===null?Array.from({length:Math.ceil(duration/30)},(_,i)=>i*30):[danmakuQuery(new URLSearchParams({time})).time];
    for(const start of times){
      const result=await service.segment(detail.id,{videoId:episode.id,episode:episode.episode,time:start});
      for(const c of result.comments){const p=c.p.split(',');comments.set(c.cid,{cid:c.cid,p:`${p[0]},1,${p[3]},[hongguo]`,m:c.m});}
    }
    const list=[...comments.values()].sort((a,b)=>parseFloat(a.p)-parseFloat(b.p));
    return {success:true,errorCode:0,count:list.length,comments:list};
  }
  throw new ApiError('NOT_FOUND','弹幕接口不存在',404);
}
