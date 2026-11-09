/**
 * 色花堂论坛板块树 — 数据在 maps/sites/sehuatang-forum.json
 */

import forumJson from "@maps/sites/sehuatang-forum.json";

export type ForumRegionId = "japan" | "china" | "western" | "mixed" | "other";

export type ShtForumType = {
  key: string;
  fid: string;
  typeid: string;
  name: string;
  type_name: string;
  board_name: string;
  region?: ForumRegionId;
};

export type ShtForumBoard = {
  name: string;
  fid: string;
  types: ShtForumType[];
};

export type ShtForumCategory = {
  category: string;
  boards: ShtForumBoard[];
};

export const SEHUATANG_FORUM = forumJson as ShtForumCategory[];
