import {Client,ApiError,validId} from './client.js';
import {Cache} from './cache.js';
import {Catalog} from './catalog.js';
import {Upcoming} from './upcoming.js';
import {Rankings,rankingGroups,rankingSelection} from './rankings.js';
import {categories,dimensions,humanDimensions,normalizeHumanFilters} from './categories.js';
import {play,prefetchNext} from './media.js';
import {Danmaku,danmakuQuery} from './danmaku.js';
import {dandanplay,isDandanplayPath} from './dandanplay.js';
import {widgetScript} from './widget-script.js';
import {danmakuWidgetScript} from './danmaku-widget.js';
const cors={'access-control-allow-origin':'*','access-control-allow-methods':'GET, HEAD, OPTIONS','access-control-allow-headers':'Range, Content-Type, X-HG-Trace','access-control-expose-headers':'Content-Range, Content-Length, Accept-Ranges, Content-Type'};
function json(data,status=200){return Response.json(data,{status,headers:{...cors,'cache-control':'no-store'}});}
function pageOf(u){const raw=u.searchParams.get('page')||'1';if(!/^\d+$/.test(raw)||!Number.isSafeInteger(Number(raw))||Number(raw)<1)throw new ApiError('INVALID_PAGE','页码无效',400);return Number(raw);}
export function createHandler({clientFactory=()=>new Client(),cache=new Cache(),player=play}={}){
 return async function handle(request,context){
  const waitUntil=context?.waitUntil?.bind(context);
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
  if(!['GET','HEAD'].includes(request.method))return json({error:{code:'METHOD_NOT_ALLOWED',message:'仅支持 GET / HEAD'}},405);
  const trace=request.headers.get('X-HG-Trace');
  const callback=['detail','resource','resource.directory','resource.target'].includes(trace)?trace:null;
  if(callback)console.log('HG_HISTORY',{event:'callback.enter',callback});
  try{
   const u=new URL(request.url),path=u.pathname.replace(/\/$/,'');let value;
   if(path==='/modules/hongguo-selfhost.js')return new Response(request.method==='HEAD'?null:widgetScript,{headers:{...cors,'content-type':'application/javascript; charset=utf-8','cache-control':'no-cache'}});
   if(path==='/modules/hongguo-danmaku.js'||path==='/modules/hongguo-selfhost-danmaku.js')return new Response(request.method==='HEAD'?null:danmakuWidgetScript,{headers:{...cors,'content-type':'application/javascript; charset=utf-8','cache-control':'public, max-age=300'}});
   if(path==='/modules/hongguo.js'||path==='/modules/hongguo-3.3.13.js'||path==='/modules/hongguo-3.3.14.js'||path==='/modules/hongguo-3.3.15.js'||path==='/modules/hongguo-3.3.16.js')return new Response(request.method==='HEAD'?null:widgetScript,{headers:{...cors,'content-type':'application/javascript; charset=utf-8','cache-control':path==='/modules/hongguo.js'?'no-cache':'public, max-age=300'}});
   if(isDandanplayPath(path)){
    try{value=await dandanplay(u,clientFactory(),cache);}
    catch(error){const e=error instanceof ApiError?error:new ApiError('UPSTREAM_FAILURE','弹幕上游请求失败，请稍后重试');return json({success:false,errorCode:e.code,errorMessage:e.message},e.status);}
   }
   else if(path==='/health')value={ok:true,version:'3.3.1'};
   else if(path==='/v1/categories')value={items:[{id:'all',title:'全部'},...Object.entries(categories).map(([id,v])=>({id,...v}))],dimensions};
   else if(path==='/v1/upcoming'||/^\/v1\/upcoming\/[^/]+$/.test(path)){
    for(const key of u.searchParams.keys())if(!['gender','page'].includes(key)||u.searchParams.getAll(key).length!==1)throw new ApiError('INVALID_UPCOMING_QUERY','待上线参数无效',400);
    const gender=u.searchParams.get('gender')??'2',page=pageOf(u);
    if(!['0','1','2'].includes(gender))throw new ApiError('INVALID_GENDER','待上线频道无效',400);
    const id=path==='/v1/upcoming'?null:validId(path.split('/').pop()),upcoming=new Upcoming(clientFactory(),cache);
    value=id?await upcoming.detail(id,gender,page):await upcoming.list(gender,page);
   }else if(path==='/v1/rankings'){
    if(!u.search)value={groups:rankingGroups};
    else {
     const params=u.searchParams;
     for(const key of params.keys())if(!['group','rank','filter','page'].includes(key)||params.getAll(key).length!==1)throw new ApiError('INVALID_RANK_FILTER','榜单参数无效',400);
     const {group,rank,filter}=rankingSelection(params.get('group'),params.get('rank'),params.get('filter')||'');
     const page=pageOf(u);value=await new Rankings(clientFactory(),cache).list(group,rank,filter,page);
    }
   }else if(path==='/v1/catalog'){
    const page=pageOf(u),filters=Object.fromEntries([...u.searchParams].filter(([key])=>key!=='page'));
    value=await new Catalog(clientFactory(),cache).list(filters,page);
   }else if(path==='/v1/human'){
    const page=pageOf(u),filters=Object.fromEntries([...u.searchParams].filter(([key])=>key!=='page'));
    value=await new Catalog(clientFactory(),cache).human(filters,page);
   }else if(path==='/v1/human/categories'){
    value={items:[{id:'all',title:'全部'}],dimensions:humanDimensions};
   }else if(path==='/v1/search'){
    const q=(u.searchParams.get('q')||'').trim(),page=pageOf(u);if(!q||q.length>100)throw new ApiError('INVALID_QUERY','请输入 1–100 字的关键词',400);
    value=await new Catalog(clientFactory(),cache).search(q,page);
   }else if(/^\/v1\/albums\/[^/]+\/seasons\/[^/]+$/.test(path)){
    const parts=path.split('/'),albumId=validId(parts[3]),slot=Number(parts[5]),sourceId=u.searchParams.get('source')||undefined;
    if(!/^\d+$/.test(parts[5])||!Number.isSafeInteger(slot)||slot<1)throw new ApiError('INVALID_SEASON','季度编号无效',400);
    if(sourceId)validId(sourceId);
    let native;const lazy=Object.fromEntries(['detail','extra','seasons'].map(name=>[name,(...args)=>(native||(native=clientFactory()))[name](...args)]));
    value=await new Catalog(lazy,cache).metadataSeason(albumId,slot,sourceId);
   }else if(/^\/v1\/series\/[^/]+\/danmaku$/.test(path)){
    const id=validId(path.split('/')[3]),query=danmakuQuery(u.searchParams);
    value=await new Danmaku(clientFactory(),cache).segment(id,query);
   }else if(/^\/v1\/series\/[^/]+$/.test(path)){
    const episodesOnly=u.searchParams.get('episodesOnly')==='1';
    const id=validId(path.split('/').pop());value=await new Catalog(clientFactory(),cache).detail(id,episodesOnly);
    // The detail page defaults to the first episode of the entry season:
    // warm it while the user reads the page. Same client identity, one
    // upstream call shaped like a real player start; skipped for
    // episodesOnly play-time lookups (those prefetch via the stream route).
    try {
      const first = !episodesOnly && Array.isArray(value.episodes) && value.episodes.find(e => !e.disabled);
      if (first) prefetchNext('', first.id, clientFactory(), undefined, waitUntil);
    } catch {}
   }else if(/^\/v1\/episodes\/[^/]+\/stream$/.test(path)){
    if(!request.headers.has('Range') || /^bytes=0-/.test(request.headers.get('Range')||''))console.log('HG_HISTORY',{event:'stream.start',method:request.method});
    const id=validId(path.split('/')[3]);const response=await player(request,id,clientFactory());
    // Warm the adjacent episode on the same client identity after a
    // successful stream start: one upstream call shaped like a real player,
    // best effort, never affecting the current response.
    try {
      const nextEntry = await cache.get('epnext:' + id);
      if (nextEntry && nextEntry.next && response.ok && request.headers.has('Range')) {
        prefetchNext(id, nextEntry.next, clientFactory(), undefined, waitUntil);
      }
    } catch {}
    const headers=new Headers(response.headers);for(const[k,v]of Object.entries(cors))headers.set(k,v);
    return new Response(response.body,{status:response.status,headers});
   }else return json({error:{code:'NOT_FOUND',message:'接口不存在'}},404);
   if(callback)console.log('HG_HISTORY',{event:'callback.return',callback,season:value?.season||null,episodes:Array.isArray(value?.episodes)?value.episodes.length:null,seasons:Array.isArray(value?.seasons)?value.seasons.length:null});
   const response=json(value);return request.method==='HEAD'?new Response(null,{status:response.status,headers:response.headers}):response;
  }catch(error){if(callback)console.log('HG_HISTORY',{event:'callback.error',callback,code:error instanceof ApiError?error.code:'UPSTREAM_FAILURE'});return json({error:{code:error instanceof ApiError?error.code:'UPSTREAM_FAILURE',message:error instanceof ApiError?error.message:'上游请求失败，请稍后重试'}},error instanceof ApiError?error.status:502);}
 };
}
let handle;
export default {fetch(request,env,context){if(!handle)handle=createHandler({cache:new Cache({storage:globalThis.caches?.default||null})});return handle(request,context);}};
