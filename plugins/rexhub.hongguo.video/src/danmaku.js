import {ApiError,validId} from './client.js';
import {Catalog} from './catalog.js';
const TTL=300000, WINDOW=30000;
export function danmakuQuery(params){
  for(const key of params.keys())if(!['episode','season','time','videoId'].includes(key)||params.getAll(key).length!==1)throw new ApiError('INVALID_DANMAKU_QUERY','弹幕参数无效',400);
  const number=(name,fallback,min,max)=>{const raw=params.get(name);const n=raw===null?fallback:Number(raw);if(raw===''||!Number.isFinite(n)||n<min||n>max||(name!=='time'&&!Number.isInteger(n)))throw new ApiError('INVALID_DANMAKU_QUERY','弹幕季集或时间无效',400);return n;};
  return {episode:number('episode',1,1,100000),season:number('season',0,0,10000),time:number('time',0,0,86400),videoId:params.has('videoId')?validId(params.get('videoId')):null};
}
export class Danmaku {
  constructor(client,cache){this.client=client;this.cache=cache;}
  async segment(seriesId,query){
    const catalog=new Catalog(this.client,this.cache);
    let detail=await catalog.detail(validId(seriesId),true);
    if(query.season&&detail.season!==query.season){
      const directory=await catalog.detail(seriesId);
      const targets=directory.seasons.filter(s=>s.season===query.season);
      if(targets.length!==1||!targets[0].id)throw new ApiError('DANMAKU_SEASON','未找到弹幕目标季度',404);
      detail=await catalog.detail(targets[0].id,true);
    }
    const episodes=detail.episodes.filter(e=>query.videoId?e.id===query.videoId:e.episode===query.episode);
    if(episodes.length!==1)throw new ApiError('DANMAKU_EPISODE','未找到弹幕目标分集',404);
    const episode=episodes[0],duration=Math.round(episode.duration*1000);
    if(!Number.isSafeInteger(duration)||duration<=0)throw new ApiError('DANMAKU_DURATION','分集时长无效');
    const start=Math.floor(query.time*1000/WINDOW)*WINDOW,end=Math.min(start+WINDOW,duration);
    if(start>=duration)return {count:0,comments:[],segmentStart:start/1000,segmentEnd:duration/1000};
    return this.cache.load(`danmaku:v1:${detail.id}:${episode.id}:${start}`,TTL,async()=>{
      const comments=new Map(),seen=new Set();let cursor='';
      for(let page=0;page<8;page++){
        const data=await this.client.comments(detail.id,episode.id,duration,start,cursor);
        if(!Array.isArray(data?.data_list)||typeof data?.common_list_info?.has_more!=='boolean')throw new ApiError('DANMAKU_FORMAT','弹幕响应格式无效');
        for(const item of data.data_list){
          const c=item?.comment,t=Number(c?.expand?.offset_time),text=c?.common?.content?.text,id=c?.comment_id;
          if(c?.expand?.is_force_insert_danmaku||c?.expand?.danmaku_guide_type)continue;
          if(c?.common?.group_id!=null&&String(c.common.group_id)!==episode.id)throw new ApiError('DANMAKU_MISMATCH','弹幕分集不匹配');
          if(typeof id!=='string'||!/^\d+$/.test(id)||typeof text!=='string'||!text.trim()||!Number.isFinite(t)||t<start||t>=end)continue;
          comments.set(id,{cid:id,p:`${t/1000},1,25,16777215`,m:text});
        }
        if(!data.common_list_info.has_more){
          const list=[...comments.values()].sort((a,b)=>parseFloat(a.p)-parseFloat(b.p));
          return {count:list.length,comments:list,segmentStart:start/1000,segmentEnd:end/1000};
        }
        const next=data.common_list_info.cursor;
        if(typeof next!=='string'||!next||seen.has(next))throw new ApiError('DANMAKU_CURSOR','弹幕分页没有前进');
        seen.add(next);cursor=next;
      }
      throw new ApiError('DANMAKU_INCOMPLETE','弹幕分页未完成，请稍后重试');
    });
  }
}
