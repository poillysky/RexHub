import {ApiError} from './client.js';
// Category dimensions observed in the native app, 2026-10-13.
export const categories={
  "cate_11": {
    "dimension": "category_dim_epoch",
    "title": "乡村"
  },
  "cate_79": {
    "dimension": "category_dim_epoch",
    "title": "年代"
  },
  "cate_4": {
    "dimension": "category_dim_epoch",
    "title": "校园"
  },
  "cate_390": {
    "dimension": "category_dim_epoch",
    "title": "民国"
  },
  "cate_1": {
    "dimension": "category_dim_epoch",
    "title": "都市"
  },
  "cate_127": {
    "dimension": "category_dim_epoch",
    "title": "职场"
  },
  "cate_452": {
    "dimension": "category_dim_epoch",
    "title": "架空"
  },
  "cate_599": {
    "dimension": "category_dim_epoch",
    "title": "异界"
  },
  "cate_758": {
    "dimension": "category_dim_epoch",
    "title": "古代"
  },
  "cate_1153": {
    "dimension": "category_dim_epoch",
    "title": "宫廷"
  },
  "cate_316": {
    "dimension": "category_dim_theme",
    "title": "剧情"
  },
  "cate_6": {
    "dimension": "category_dim_theme",
    "title": "奇幻"
  },
  "cate_7": {
    "dimension": "category_dim_theme",
    "title": "玄幻"
  },
  "cate_68": {
    "dimension": "category_dim_theme",
    "title": "末世"
  },
  "cate_755": {
    "dimension": "category_dim_theme",
    "title": "脑洞"
  },
  "cate_936": {
    "dimension": "category_dim_theme",
    "title": "豪门"
  },
  "cate_1092": {
    "dimension": "category_dim_theme",
    "title": "科幻"
  },
  "cate_1182": {
    "dimension": "category_dim_theme",
    "title": "冒险"
  },
  "cate_23": {
    "dimension": "category_dim_theme",
    "title": "种田"
  },
  "cate_425": {
    "dimension": "category_dim_theme",
    "title": "搞笑"
  },
  "cate_768": {
    "dimension": "category_dim_theme",
    "title": "日常"
  },
  "cate_10": {
    "dimension": "category_dim_theme",
    "title": "悬疑"
  },
  "cate_1334": {
    "dimension": "category_dim_theme",
    "title": "诡秘"
  },
  "cate_1333": {
    "dimension": "category_dim_theme",
    "title": "合家欢"
  },
  "cate_1183": {
    "dimension": "category_dim_theme",
    "title": "灾难"
  },
  "cate_314": {
    "dimension": "category_dim_theme",
    "title": "恐怖"
  },
  "cate_739": {
    "dimension": "category_dim_role",
    "title": "逆袭"
  },
  "cate_756": {
    "dimension": "category_dim_role",
    "title": "反转"
  },
  "cate_37": {
    "dimension": "category_dim_role",
    "title": "穿越"
  },
  "cate_36": {
    "dimension": "category_dim_role",
    "title": "重生"
  },
  "cate_29": {
    "dimension": "category_dim_role",
    "title": "总裁"
  },
  "cate_19": {
    "dimension": "category_dim_role",
    "title": "系统"
  },
  "cate_43": {
    "dimension": "category_dim_role",
    "title": "娱乐圈"
  },
  "cate_598": {
    "dimension": "category_dim_role",
    "title": "异能"
  },
  "cate_379": {
    "dimension": "category_dim_role",
    "title": "求生"
  },
  "cate_530": {
    "dimension": "category_dim_role",
    "title": "热血"
  },
  "cate_494": {
    "dimension": "category_dim_role",
    "title": "囤物资"
  },
  "cate_830": {
    "dimension": "category_dim_role",
    "title": "升级流"
  },
  "cate_1173": {
    "dimension": "category_dim_role",
    "title": "无厘头"
  },
  "cate_70": {
    "dimension": "category_dim_role",
    "title": "无限流"
  },
  "cate_1336": {
    "dimension": "category_dim_role",
    "title": "玩梗"
  }
};

export const dimensions=[
  {
    "key": "background",
    "title": "全部背景",
    "dimension": "category_dim_epoch",
    "items": [
      {
        "id": "cate_11",
        "title": "乡村"
      },
      {
        "id": "cate_79",
        "title": "年代"
      },
      {
        "id": "cate_4",
        "title": "校园"
      },
      {
        "id": "cate_390",
        "title": "民国"
      },
      {
        "id": "cate_1",
        "title": "都市"
      },
      {
        "id": "cate_127",
        "title": "职场"
      },
      {
        "id": "cate_452",
        "title": "架空"
      },
      {
        "id": "cate_599",
        "title": "异界"
      },
      {
        "id": "cate_758",
        "title": "古代"
      }
    ,
      {
        "id": "cate_1153",
        "title": "宫廷"
      }]
  },
  {
    "key": "theme",
    "title": "全部主题",
    "dimension": "category_dim_theme",
    "items": [
      {
        "id": "cate_316",
        "title": "剧情"
      },
      {
        "id": "cate_6",
        "title": "奇幻"
      },
      {
        "id": "cate_7",
        "title": "玄幻"
      },
      {
        "id": "cate_68",
        "title": "末世"
      },
      {
        "id": "cate_755",
        "title": "脑洞"
      },
      {
        "id": "cate_936",
        "title": "豪门"
      },
      {
        "id": "cate_1092",
        "title": "科幻"
      },
      {
        "id": "cate_1182",
        "title": "冒险"
      }
    ,
      {
        "id": "cate_23",
        "title": "种田"
      },
      {
        "id": "cate_425",
        "title": "搞笑"
      },
      {
        "id": "cate_768",
        "title": "日常"
      },
      {
        "id": "cate_10",
        "title": "悬疑"
      },
      {
        "id": "cate_1334",
        "title": "诡秘"
      },
      {
        "id": "cate_1333",
        "title": "合家欢"
      },
      {
        "id": "cate_1183",
        "title": "灾难"
      },
      {
        "id": "cate_314",
        "title": "恐怖"
      }]
  },
  {
    "key": "setting",
    "title": "全部设定",
    "dimension": "category_dim_role",
    "items": [
      {
        "id": "cate_739",
        "title": "逆袭"
      },
      {
        "id": "cate_756",
        "title": "反转"
      },
      {
        "id": "cate_37",
        "title": "穿越"
      },
      {
        "id": "cate_36",
        "title": "重生"
      },
      {
        "id": "cate_29",
        "title": "总裁"
      },
      {
        "id": "cate_19",
        "title": "系统"
      },
      {
        "id": "cate_43",
        "title": "娱乐圈"
      },
      {
        "id": "cate_598",
        "title": "异能"
      }
    ,
      {
        "id": "cate_379",
        "title": "求生"
      },
      {
        "id": "cate_530",
        "title": "热血"
      },
      {
        "id": "cate_494",
        "title": "囤物资"
      },
      {
        "id": "cate_830",
        "title": "升级流"
      },
      {
        "id": "cate_1173",
        "title": "无厘头"
      },
      {
        "id": "cate_70",
        "title": "无限流"
      },
      {
        "id": "cate_1336",
        "title": "玩梗"
      }]
  },
  {
    "key": "gender",
    "title": "全部受众",
    "dimension": "gender",
    "items": [
      {
        "id": "1",
        "title": "男频"
      },
      {
        "id": "0",
        "title": "女频"
      }
    ]
  },
  {
    "key": "status",
    "title": "全部状态",
    "dimension": "creation_status",
    "items": [
      {
        "id": "creation_status_0",
        "title": "已完结"
      },
      {
        "id": "creation_status_1",
        "title": "连载中"
      }
    ]
  },
  {
    "key": "period",
    "title": "全部时间",
    "dimension": "online_time",
    "items": [
      {
        "id": "days_7",
        "title": "7天内上新"
      },
      {
        "id": "days_14",
        "title": "14天内上新"
      },
      {
        "id": "days_30",
        "title": "30天内上新"
      },
      {
        "id": "days_90",
        "title": "90天内上新"
      }
    ]
  },
  {
    "key": "sort",
    "title": "全部推荐",
    "dimension": "sort",
    "items": [
      {
        "id": "online_time",
        "title": "最新"
      },
      {
        "id": "hot_score",
        "title": "最热"
      }
    ]
  }
];

// Human-drama (short_play) catalog dimensions, probed against the upstream landpage feed 2026-10-14.
// Every id below returned live rows on the comic_series landpage with genre:['short_play'].
export const humanDimensions=[
  {
    "key": "background",
    "title": "全部背景",
    "dimension": "category_dim_epoch",
    "items": [
      {"id": "cate_757", "title": "现代"},
      {"id": "cate_1", "title": "都市"},
      {"id": "cate_11", "title": "乡村"},
      {"id": "cate_758", "title": "古代"},
      {"id": "cate_79", "title": "年代"},
      {"id": "cate_452", "title": "架空"},
      {"id": "cate_127", "title": "职场"},
      {"id": "cate_390", "title": "民国"},
      {"id": "cate_4", "title": "校园"},
      {"id": "cate_1153", "title": "宫廷"},
      {"id": "cate_1162", "title": "荒岛"},
      {"id": "cate_599", "title": "异界"}
    ]
  },
  {
    "key": "theme",
    "title": "全部主题",
    "dimension": "category_dim_theme",
    "items": [
      {"id": "cate_1021", "title": "现言"},
      {"id": "cate_1048", "title": "女性成长"},
      {"id": "cate_439", "title": "古言"},
      {"id": "cate_1038", "title": "战神"},
      {"id": "cate_246", "title": "宫斗"},
      {"id": "cate_1013", "title": "仙侠"},
      {"id": "cate_1047", "title": "权谋"},
      {"id": "cate_1180", "title": "种田"},
      {"id": "cate_1022", "title": "年代爱情"},
      {"id": "cate_1025", "title": "民国爱情"},
      {"id": "cate_1240", "title": "民国传奇"},
      {"id": "cate_303", "title": "喜剧"},
      {"id": "cate_165", "title": "悬疑"},
      {"id": "cate_297", "title": "青春"},
      {"id": "cate_1027", "title": "志怪"},
      {"id": "cate_751", "title": "灵异"},
      {"id": "cate_262", "title": "脑洞"},
      {"id": "cate_1020", "title": "奇幻"},
      {"id": "cate_1019", "title": "玄幻"},
      {"id": "cate_1235", "title": "家国情怀"},
      {"id": "cate_1136", "title": "法律"},
      {"id": "cate_1148", "title": "刑侦"},
      {"id": "cate_504", "title": "抗战"},
      {"id": "cate_1172", "title": "武侠"},
      {"id": "cate_302", "title": "动作"},
      {"id": "cate_1168", "title": "求生"},
      {"id": "cate_1219", "title": "恐怖"},
      {"id": "cate_1225", "title": "商战"},
      {"id": "cate_1092", "title": "科幻"},
      {"id": "cate_936", "title": "豪门"},
      {"id": "cate_316", "title": "剧情"}
    ]
  },
  {
    "key": "setting",
    "title": "全部设定",
    "dimension": "category_dim_role",
    "items": [
      {"id": "cate_1051", "title": "打脸虐渣"},
      {"id": "cate_760", "title": "大女主"},
      {"id": "cate_1207", "title": "大男主"},
      {"id": "cate_266", "title": "马甲"},
      {"id": "cate_739", "title": "逆袭"},
      {"id": "cate_36", "title": "重生"},
      {"id": "cate_37", "title": "穿越"},
      {"id": "cate_19", "title": "系统"},
      {"id": "cate_265", "title": "先婚后爱"},
      {"id": "cate_862", "title": "家长里短"},
      {"id": "cate_1010", "title": "小人物"},
      {"id": "cate_475", "title": "破镜重圆"},
      {"id": "cate_20", "title": "神豪"},
      {"id": "cate_1045", "title": "强者回归"},
      {"id": "cate_1008", "title": "虐恋"},
      {"id": "cate_1044", "title": "赘婿逆袭"},
      {"id": "cate_96", "title": "甜宠"},
      {"id": "cate_26", "title": "神医"},
      {"id": "cate_387", "title": "青梅竹马"},
      {"id": "cate_762", "title": "姐弟恋"},
      {"id": "cate_929", "title": "玄学"},
      {"id": "cate_616", "title": "追妻火葬场"},
      {"id": "cate_29", "title": "总裁"},
      {"id": "cate_756", "title": "反转"},
      {"id": "cate_43", "title": "娱乐圈"},
      {"id": "cate_598", "title": "异能"},
      {"id": "cate_28", "title": "萌宝"},
      {"id": "cate_487", "title": "医生"},
      {"id": "cate_1049", "title": "强强联合"},
      {"id": "cate_1007", "title": "传承觉醒"},
      {"id": "cate_1293", "title": "业界精英"},
      {"id": "cate_477", "title": "一见钟情"},
      {"id": "cate_1291", "title": "福宝"},
      {"id": "cate_1287", "title": "捞偏门"},
      {"id": "cate_1042", "title": "反派主角"},
      {"id": "cate_428", "title": "萌宠"},
      {"id": "cate_1255", "title": "方言"},
      {"id": "cate_1200", "title": "双向救赎"},
      {"id": "cate_615", "title": "白月光"},
      {"id": "cate_831", "title": "灵魂互换"},
      {"id": "cate_380", "title": "病娇"},
      {"id": "cate_1191", "title": "暴富"},
      {"id": "cate_826", "title": "黑道"},
      {"id": "cate_582", "title": "丧尸"},
      {"id": "cate_375", "title": "特种兵"},
      {"id": "cate_936", "title": "豪门"}
    ]
  },
  {
    "key": "gender",
    "title": "全部受众",
    "dimension": "category_dim_gender",
    "items": [
      {"id": "1", "title": "男频"},
      {"id": "0", "title": "女频"}
    ]
  }
];

export function normalizeHumanFilters(input='all'){
 const filters=typeof input==='string'?{category:input}:input;
 if(!filters||typeof filters!=='object'||Array.isArray(filters))throw new ApiError('INVALID_FILTER','分类筛选无效',400);
 const allowed=new Set(humanDimensions.map(d=>d.key));
 const omitted=value=>value===undefined||value===null||value===''||value==='all';
 const select={};
 for(const [key,value] of Object.entries(filters)){
  if(omitted(value))continue;
  const row=humanDimensions.find(d=>d.key===key);
  if(!row)throw new ApiError('INVALID_FILTER','不支持的筛选维度',400);
  if(typeof value!=='string'||!row.items.some(item=>item.id===value))throw new ApiError('INVALID_FILTER','不支持的分类筛选',400);
  select[row.dimension]=[value];
 }
 return select;
}

// Iterate the captured row order so equivalent inputs share one cache/cursor key.
export function normalizeFilters(input='all'){
 const filters=typeof input==='string'?{category:input}:input;
 if(!filters||typeof filters!=='object'||Array.isArray(filters))throw new ApiError('INVALID_FILTER','分类筛选无效',400);
 const allowed=new Set(['category',...dimensions.map(d=>d.key)]);
 for(const key of Object.keys(filters))if(!allowed.has(key))throw new ApiError('INVALID_FILTER','不支持的筛选维度',400);
 const omitted=value=>value===undefined||value===null||value===''||value==='all';
 const legacy=filters.category;
 if(!omitted(legacy)&&(typeof legacy!=='string'||!Object.hasOwn(categories,legacy)))throw new ApiError('INVALID_CATEGORY','不支持的分类',400);
 const select={};
 for(const row of dimensions){
  let value=filters[row.key];
  if(!omitted(value)&&(typeof value!=='string'||!row.items.some(item=>item.id===value)))throw new ApiError('INVALID_FILTER','不支持的分类筛选',400);
  if(!omitted(legacy)&&categories[legacy].dimension===row.dimension){
   if(!omitted(value)&&value!==legacy)throw new ApiError('INVALID_FILTER','分类与筛选维度冲突',400);
   value=legacy;
  }
  if(!omitted(value))select[row.dimension]=[value];
 }
 return select;
}
