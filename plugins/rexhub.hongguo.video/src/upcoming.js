import {ApiError,validId} from './client.js';
import {Catalog,seasonOf} from './catalog.js';
const TTL=300000, LIST_TTL=60000;
function validate(gender,page){
 if(!['2','1','0'].includes(gender))throw new ApiError('INVALID_GENDER','不支持的受众筛选',400);
 if(!Number.isSafeInteger(page)||page<1)throw new ApiError('INVALID_PAGE','页码无效',400);
}
function normalize(item,gender,page){
 if(!item||typeof item.item_id!=='string'||!/^\d{10,24}$/.test(item.item_id)||typeof item.name!=='string'||!item.name||typeof item.is_online!=='boolean')throw new ApiError('UPCOMING_FORMAT','待上线条目格式无效');
 const isOnline=item.is_online,title=item.name;
 return {id:item.item_id,title,cover:String(item.cover||''),description:[...(isOnline?[]:['未上线']),item.sub_info,item.item_desc].filter(Boolean).join('\n'),season:seasonOf({title}),episodeCount:0,upcoming:!isOnline,isOnline,gender,page};
}
export class Upcoming {
 constructor(client,cache){this.client=client;this.cache=cache;}
 async list(gender='2',page=1){
  validate(gender,page);
  return this.cache.load(`upcoming:fresh1:${gender}:${page}`,LIST_TTL,async()=>{
   const cursor=page===1?{offset:0,session_id:''}:await this.cache.get(`upcoming-cursor:${gender}:${page}`);
   if(!cursor)throw new ApiError('CURSOR_EXPIRED','分页已过期，请刷新第一页',409);
   if(cursor.done)return {items:[],hasMore:false,nextPage:null};
   const data=await this.client.upcoming(gender,cursor.offset,cursor.session_id);
   if(!Array.isArray(data?.subscribe_items))throw new ApiError('UPCOMING_FORMAT','待上线列表格式无效');
   const hasMore=data.has_more===true||data.has_more===1,next=Number(data.next_offset);
   if(hasMore&&(!Number.isSafeInteger(next)||next<=cursor.offset))throw new ApiError('UPCOMING_CURSOR','待上线分页没有前进');
   const items=data.subscribe_items.map(item=>normalize(item,gender,page));
   for(const item of items)await this.cache.put(`upcoming-item:${item.id}`,item,TTL);
   await this.cache.put(`upcoming-cursor:${gender}:${page+1}`,{offset:next,session_id:data.session_id||cursor.session_id,done:!hasMore},TTL);
   return {items,hasMore,nextPage:hasMore?page+1:null};
  });
 }
 async detail(id,gender='2',page=1){
  validId(id);validate(gender,page);
  let item=await this.cache.get(`upcoming-item:${id}`);
  if(!item){
   if(page>1&&!await this.cache.get(`upcoming-cursor:${gender}:${page}`))throw new ApiError('CURSOR_EXPIRED','分页已过期，请刷新第一页',409);
   const result=await this.list(gender,page);item=result.items.find(value=>value.id===id);
   if(!item)throw new ApiError('UPCOMING_EXPIRED','待上线信息已更新，请刷新第一页',409);
   await this.cache.put(`upcoming-item:${id}`,item,TTL);
  }
  if(item.isOnline)return new Catalog(this.client,this.cache).detail(id);
  const contextualItem={...item,gender,page};
  return {...contextualItem,episodes:[],seasons:[contextualItem],complete:true};
 }
}
