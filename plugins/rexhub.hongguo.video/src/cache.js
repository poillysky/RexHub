export class Cache {
  constructor({now=Date.now,max=256,storage=null}={}){this.now=now;this.max=max;this.storage=storage;this.values=new Map();this.pending=new Map();}
  key(key){return new Request('https://hongguo-native-cache.invalid/v3/'+encodeURIComponent(key));}
  async get(key){
    let entry=this.values.get(key);
    if(entry&&entry.until>this.now())return structuredClone(entry.value);
    this.values.delete(key);
    if(this.storage){try{const r=await this.storage.match(this.key(key));if(r){entry=await r.json();if(entry.until>this.now()){this.remember(key,entry);return structuredClone(entry.value);}}}catch{}}
  }
  remember(key,entry){this.values.delete(key);this.values.set(key,entry);while(this.values.size>this.max)this.values.delete(this.values.keys().next().value);}
  async put(key,value,ttl,{persist=true}={}){
    const entry={until:this.now()+ttl,value:structuredClone(value)};this.remember(key,entry);
    if(this.storage&&persist){try{await this.storage.put(this.key(key),new Response(JSON.stringify(entry),{headers:{'content-type':'application/json','cache-control':`max-age=${Math.ceil(ttl/1000)}`}}));}catch{}}
    return value;
  }
  async load(key,ttl,loader){
    const cached=await this.get(key);if(cached!==undefined)return cached;
    // Share completed values, never I/O promises owned by another request.
    return structuredClone(await this.put(key,await loader(),ttl));
  }
}
