import {signRequest} from './hongguo-signing.js';
export class ApiError extends Error {
  constructor(code,message,status=502){super(message);this.code=code;this.status=status;}
}
export function parseJSON64(text){
  // A token scanner prevents 64-bit IDs rounding before normalization.
  const safe=text.replace(/"(?:\\.|[^"\\])*"|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/g,t=>{
    if(t[0]==='"'||/[.eE]/.test(t))return t;
    return Number.isSafeInteger(Number(t))?t:JSON.stringify(t);
  });
  return JSON.parse(safe);
}
export function createDevice(){
  const id=()=>String(7000000000000000000n+BigInt('0x'+Array.from(crypto.getRandomValues(new Uint8Array(8)),x=>x.toString(16).padStart(2,'0')).join(''))%999999999999999999n);
  return {device_id:id(),install_id:id(),device_model:'23013RK75C',device_type:'23013RK75C',device_brand:'Redmi',device_manufacturer:'Xiaomi',os_version:'13',version_name:'7.1.3.32',ua:'com.phoenix.read/71332 (Linux; U; Android 13; zh_CN; 23013RK75C; Build/TP1A.220624.014; Cronet/TTNetVersion:dfc7cb8b 2024-01-16 QuicVersion:47946d2a 2023-10-24)'};
}
export function validId(id){if(!/^\d{10,24}$/.test(String(id)))throw new ApiError('INVALID_ID','无效剧集 ID',400);return String(id);}
export class Client {
  constructor({fetcher=globalThis.fetch.bind(globalThis),device=createDevice()}={}){this.fetcher=fetcher;this.device=device;this.requests=0;}
  async request(path,params={},body,signal){
    const d=this.device,now=Date.now();
    const q=new URLSearchParams({aid:'8662',app_name:'novelread',version_code:'71332',version_name:d.version_name,device_platform:'android',device_type:d.device_type,device_brand:d.device_brand,device_id:d.device_id,iid:d.install_id,os:'android',os_version:'13',os_api:'33',channel:'update_64',ac:'wifi',ssmix:'a',language:'zh',...params,_rticket:String(now)}).toString();
    const payload=body===undefined?'':typeof body==='string'?body:JSON.stringify(body);
    this.requests++;
    const timeout=AbortSignal.timeout(20000);
    const r=await this.fetcher('https://api5-normal-sinfonlineb.fqnovel.com'+path+'?'+q,{method:body===undefined?'GET':'POST',headers:{...signRequest(q,payload,Math.floor(now/1000),d),'sdk-version':'2',...(body===undefined?{}:{'content-type':'application/json'})},...(body===undefined?{}:{body:payload}),signal:signal?AbortSignal.any([signal,timeout]):timeout});
    if(!r.ok)throw new ApiError('UPSTREAM_HTTP',`上游 HTTP ${r.status}`);
    const text=await r.text();if(!text.trim())throw new ApiError('UPSTREAM_EMPTY','Upstream empty response，请稍后重试');
    let value;try{value=parseJSON64(text);}catch{throw new ApiError('UPSTREAM_JSON','上游响应格式无效');}
    if(String(value.code??value.BaseResp?.StatusCode??0)!=='0')throw new ApiError('UPSTREAM_REJECTED',`上游拒绝请求 (${value.code??value.BaseResp?.StatusCode})`);
    return value;
  }
  async list(select_items,offset=0,session_id='',genre){
    const scene='comic_series',items=genre?{...select_items,genre:[genre]}:select_items;
    return (await this.request('/reading/distribution/category/landpage/v:version/',{req_scene:scene,req_type:'only_content',need_selector_panel:false,offset,limit:18,client_req_type:3},{select_items:items,session_id,req_scene:scene,req_type:'only_content',need_selector_panel:false,offset,limit:18,client_req_type:3})).data;
  }
  async rank(group,rank,filter='',offset=0,session_id='',rank_version=''){
    return (await this.request('/reading/bookapi/bookmall/cell/change/v:version/',{cell_id:'7470092475068071998',tab_type:26,selected_items:group,sub_selected_items:rank,panel_selected_items:filter||'',offset,limit:0,client_req_type:2,client_template:2,unlimited_selector_change_type:offset===0?2:1,session_id,rank_version,aid:'8704',app_name:'kylin_read',version_code:74032,version_name:'7.4.0.32',channel:'oppo_8704_64',update_version_code:74032,manifest_version_code:74032})).data;
  }
  async upcoming(gender='2',offset=0,session_id=''){
    return (await this.request('/reading/user/subscribe/list/v:version/',{offset,tab_type:2,limit:10,version:0,gender_type:gender,session_id,aid:'8704',app_name:'kylin_read',version_code:74032,version_name:'7.4.0.32',channel:'oppo_8704_64',update_version_code:74032,manifest_version_code:74032})).data;
  }
  async suggest(q){return (await this.request('/reading/bookapi/search/suggest/v:version/',{q,bookshelf_search_plan:4,search_source:1,tab_name:'feed',bookstore_tab:16,user_is_login:0,client_ab_info:JSON.stringify({short_series_tab_new_search_page:false,book_store_tab_new_search_page:false,new_sug_page:false,short_play_sug:false,middle_style_from_video:false,result_style_from_video:false,search_middle_rank_style:0})})).data;}
  async detail(id){return (await this.request('/novel/player/video_detail/v1/',{}, {series_id:validId(id),biz_param:{detail_page_version:1,source:5,video_id_type:1}})).data;}
  async extra(id){return (await this.request('/reading/distribution/book_pack_fields/inner_feed_detail/v1/',{},`{"req_fields":["album_id","album_serial_count","real_album_serial_count","series_in_album_order"],"req_ids":[${validId(id)}]}`)).data;}
  async seasons(id,offset=0){return this.request('/reading/bookapi/plan/v1/',{book_id:validId(id),from:'series_short_play_info',scene:10,filter_ids:id,offset,limit:0});}
  async play(id,signal){return (await this.request('/novel/player/video_model/v1/',{}, {video_id:validId(id),content_type:1004,biz_param:{source:4,video_platform:3,need_all_video_definition:true,use_os_player:false}},signal)).data;}
  async comments(seriesId,videoId,durationMs,startMs,cursor=''){
    const result=await this.request(`/novel/commentapi/comment/list/${validId(videoId)}/v1/`,{}, {
      comment_source:601,server_channel:1000,group_id:validId(videoId),group_type:30,comment_type:20,sort:1,
      business_param:{book_id:validId(seriesId),start_offset_time:startMs,playlet_item_duration:durationMs,need_danmaku_guide_type:[2]},
      count:90,cursor,aid:8662,compliance_status:0
    });
    if(String(result.BaseResp?.StatusCode??0)!=='0')throw new ApiError('UPSTREAM_REJECTED',`上游拒绝请求 (${result.BaseResp.StatusCode})`);
    return result.data;
  }
}
