import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  globalIgnores([
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
  ]),
  {
    rules: {
      /**
       * 封面 / 头像 / 二维码都来自代理接口或用户数据，尺寸不定且没有固定
       * remotePatterns，next/image 无法代管；统一用原生 img + SoftImg 控制。
       */
      "@next/next/no-img-element": "off",
    },
  },
]);

export default eslintConfig;
