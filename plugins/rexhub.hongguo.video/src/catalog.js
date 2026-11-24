import {ApiError,validId} from './client.js';
import {normalizeFilters,normalizeHumanFilters} from './categories.js';
const TTL=300000, LIST_TTL=60000;
function chineseNumber(text){const digits='零一二三四五六七八九';let n=0,unit=0;for(const c of text){if(digits.includes(c))unit=digits.indexOf(c);else if(c==='十'){n+=(unit||1)*10;unit=0;}else if(c==='百'){n+=(unit||1)*100;unit=0;}else if(c==='两')unit=2;else return 0;}return n+unit;}
export function seasonOf(v){const n=Number(v.season_index||v.season||v.series_in_album_order);if(n>0)return n;const m=String(v.title||v.series_title||'').match(/第\s*([0-9零一二三四五六七八九十百两]+)\s*季/);return m?(Number(m[1])||chineseNumber(m[1])):1;}
export function card(v){const id=String(v.series_id_str||v.series_id||v.id||'');if(!/^\d{10,24}$/.test(id))return null;return {id,title:String(v.series_title||v.title||''),cover:String(v.series_cover||v.cover||''),description:String(v.series_intro||v.video_desc||v.description||''),season:seasonOf(v),episodeCount:Number(v.episode_cnt||v.episodeCount)||0};}
export function collectCards(value){
 const out=new Map();function visit(v){if(!v||typeof v!=='object')return;if(Array.isArray(v)){for(const x of v)visit(x);return;}if(v.series_id||v.series_id_str){const c=card(v);if(c&&c.title)out.set(c.id,c);return;}for(const [k,x]of Object.entries(v)){if(k==='lynx_data'&&typeof x==='string'){try{visit(JSON.parse(x));}catch{}}else if(typeof x==='object')visit(x);}}
 visit(value);return [...out.values()];
}
export class Catalog {
 constructor(client,cache){this.client=client;this.cache=cache;}
 async list(category='all',page=1,genre=''){
   const select=normalizeFilters(category),filterKey=JSON.stringify(genre?{...select,genre}:select);
   return this.cache.load(`list:fresh1:${filterKey}:${page}`,LIST_TTL,async()=>{
     const cursor=page===1?{offset:0,session_id:''}:await this.cache.get(`cursor:${filterKey}:${page}`);
     if(!cursor)throw new ApiError('CURSOR_EXPIRED','分页已过期，请刷新第一页',409);
     if(cursor.done)return {items:[],hasMore:false,nextPage:null};
     if(cursor.device&&this.client.device)Object.assign(this.client.device,{device_id:cursor.device.device_id,install_id:cursor.device.install_id});
     const device=this.client.device?{device_id:this.client.device.device_id,install_id:this.client.device.install_id}:undefined;
     const data=await this.client.list(select,cursor.offset,cursor.session_id,genre||undefined);
     if(!Array.isArray(data?.video_data))throw new ApiError('CATALOG_FORMAT','分类响应格式无效');
     const hasMore=!!data.has_more,next=Number(data.next_offset);
     if(hasMore&&(!Number.isInteger(next)||next<=cursor.offset))throw new ApiError('CATALOG_CURSOR','分类分页没有前进');
     await this.cache.put(`cursor:${filterKey}:${page+1}`,{offset:next,session_id:data.session_id||'',done:!hasMore,...(device?{device}:{})},TTL);
     return {items:collectCards(data.video_data),hasMore,nextPage:hasMore?page+1:null};
   });
 }
 async human(category='all',page=1){
   const select=normalizeHumanFilters(category),filterKey=JSON.stringify({...select,genre:'short_play'});
   return this.cache.load(`list:fresh1:${filterKey}:${page}`,LIST_TTL,async()=>{
     const cursor=page===1?{offset:0,session_id:''}:await this.cache.get(`cursor:${filterKey}:${page}`);
     if(!cursor)throw new ApiError('CURSOR_EXPIRED','分页已过期，请刷新第一页',409);
     if(cursor.done)return {items:[],hasMore:false,nextPage:null};
     if(cursor.device&&this.client.device)Object.assign(this.client.device,{device_id:cursor.device.device_id,install_id:cursor.device.install_id});
     const device=this.client.device?{device_id:this.client.device.device_id,install_id:this.client.device.install_id}:undefined;
     const data=await this.client.list(select,cursor.offset,cursor.session_id,'short_play');
     if(!Array.isArray(data?.video_data))throw new ApiError('CATALOG_FORMAT','分类响应格式无效');
     const hasMore=!!data.has_more,next=Number(data.next_offset);
     if(hasMore&&(!Number.isInteger(next)||next<=cursor.offset))throw new ApiError('CATALOG_CURSOR','分类分页没有前进');
     await this.cache.put(`cursor:${filterKey}:${page+1}`,{offset:next,session_id:data.session_id||'',done:!hasMore,...(device?{device}:{})},TTL);
     return {items:collectCards(data.video_data),hasMore,nextPage:hasMore?page+1:null};
   });
 }
 async search(query,page=1){
   if(page>1)return {items:[],hasMore:false,nextPage:null,mode:'suggestions'};
   return this.cache.load('search:'+query,60000,async()=>{
     const data=await this.client.suggest(query);
     if(!Array.isArray(data?.query_result_v2))throw new ApiError('SEARCH_FORMAT','搜索响应格式无效');
     const candidates=data.query_result_v2.map(x=>x.video_data||((x.word_type_str==='short_play_name'&&/^\d{10,24}$/.test(String(x.keyword)))?{series_id:String(x.keyword),title:x.name,description:x.sug_abstract||''}:null)).filter(Boolean);
     return {items:collectCards(candidates),hasMore:false,nextPage:null,mode:'suggestions'};
   });
 }
 async metadataSeason(albumId,slot,sourceId){
   validId(albumId);
   let directory=await this.cache.get('album:'+albumId);
   if(!directory&&sourceId){const source=await this.detail(validId(sourceId));if(source.albumId!==albumId)throw new ApiError('ALBUM_MISMATCH','季度所属系列不一致');directory=await this.cache.get('album:'+albumId);}
   if(!directory)throw new ApiError('DIRECTORY_EXPIRED','季度目录已过期，请重新打开原剧详情',409);
   const entry=directory.seasons.find(x=>x.season===slot);
   if(entry?.available&&entry.id)return this.detail(entry.id);
   if(!entry)throw new ApiError('SEASON_CHANGED','季度信息已更新，请重新打开原剧详情',409);
   return {...entry,albumId,episodeCount:0,episodes:[],...directory,complete:true};
 }
 async detail(id,episodesOnly=false){
   validId(id);
   const result=await this.cache.load('detail:'+id,TTL,async()=>{
     const data=await this.client.detail(id),v=data?.video_data;
     if(!v||String(v.series_id_str||v.series_id)!==id)throw new ApiError('DETAIL_MISSING','上游未返回目标季度详情');
     const info=card(v);const episodes=(v.video_list||[]).map((e,i)=>({id:String(e.vid||e.video_id||''),title:String(e.title||`第${i+1}集`),episode:Number(e.vid_index)||i+1,duration:Number(e.duration)||0,disabled:!!(e.disable_play||e.need_unlock)}));
     if(episodes.some(e=>!/^\d{10,24}$/.test(e.id)))throw new ApiError('EPISODE_ID','分集 ID 无效');
     if(info.episodeCount&&episodes.length<info.episodeCount)throw new ApiError('EPISODES_INCOMPLETE','当前季度剧集不完整，请稍后刷新');
     // Episode-adjacency index: lets the stream route resolve the next
     // episode for prefetch without any extra upstream call.
     for (let i = 0; i < episodes.length - 1; i++) {
       // Adjacency is optional isolate-local prefetch data, not a directory.
       // Do not spend one shared-cache subrequest per episode before responding.
       try { await this.cache.put('epnext:' + episodes[i].id, {next: episodes[i + 1].id}, TTL, {persist:false}); } catch {}
     }
     return {...info,albumId:String(v.related_album_id||''),episodes};
   });
   if(episodesOnly)return result;
   if(!result.albumId||result.albumId==='0')return {...result,seasons:[card({...result,series_id:id})],complete:true};
   const directory=await this.cache.load('album:'+result.albumId,TTL,async()=>{
     const extra=await this.client.extra(id),album=extra?.[id]?.album_info;
     const announced=Number(album?.album_serial_count);
     const total=Number(album?.real_album_serial_count)>0?Number(album.real_album_serial_count):announced;
     if(!Number.isInteger(total)||total<1||!Number.isInteger(announced)||announced<total)throw new ApiError('ALBUM_COUNT','无法确认完整季度总数');
     if(String(album.album_id)!==result.albumId)throw new ApiError('ALBUM_MISMATCH','季度所属系列不一致');
     const current={...result,season:Number(album.series_in_album_order)||result.season};delete current.episodes;
     const cards=new Map([[id,current]]),seen=new Set();let offset=0;
     for(;;){
       if(seen.has(offset))throw new ApiError('SEASON_CURSOR','季度分页游标重复');seen.add(offset);
       const response=await this.client.seasons(id,offset),cells=Array.isArray(response.data)?response.data:response.data?.cells;
       if(!Array.isArray(cells))throw new ApiError('SEASON_FORMAT','季度目录格式无效');
       const relevant=cells.filter(c=>Array.isArray(c.video_data));let hasMore=!!response.has_more,next=Number(response.next_offset)||0;
       for(const cell of relevant){for(const v of cell.video_data){const c=card(v);if(c)cards.set(c.id,c);}if(cell.has_more){hasMore=true;next=Math.max(next,Number(cell.next_offset)||0);}}
       if(!hasMore)break;
       if(next<=offset)throw new ApiError('SEASON_CURSOR','季度分页没有前进');offset=next;
     }
     if(cards.size!==total)throw new ApiError('SEASONS_INCOMPLETE',`季度目录不完整：期望 ${total} 季，实际 ${cards.size} 季`);
     const seasons=[...cards.values()].map(c=>({...c,available:true}));
     const numbers=new Set(seasons.map(c=>c.season));
     if(announced>total){
       if(numbers.size!==total||seasons.some(c=>c.season<1||c.season>announced))throw new ApiError('SEASON_ORDER','元数据季度顺序无法匹配');
       for(let slot=1;slot<=announced;slot++)if(!numbers.has(slot))seasons.push({id:null,slot,season:slot,title:`第${slot}季`,cover:result.cover,description:'未上线',available:false,sourceId:id});
     }
     seasons.sort((a,b)=>a.season-b.season||String(a.id||'').localeCompare(String(b.id||'')));
     return {seasons,sourceId:id,availableSeasonCount:total,announcedSeasonCount:announced};
   });
   const selected=directory.seasons.find(c=>c.id===id);if(!selected)throw new ApiError('SEASONS_INCOMPLETE','季度目录不完整：未包含当前季');
   await this.cache.put('detail:'+id,{...result,season:selected.season},TTL);
   return {...result,season:selected.season,...directory,complete:true};
 }
}
