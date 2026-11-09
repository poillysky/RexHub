import type { Metadata, Viewport } from 'next';
import { DM_Serif_Text, Geist_Mono } from 'next/font/google';
import { Providers } from './providers';
import { ShellBoot } from '@/components/layout/ShellBoot';
import { THEME_COLOR, THEME_KEY } from '@/lib/theme';
import './globals.css';

const dmSerif = DM_Serif_Text({
  variable: '--font-display',
  weight: '400',
  subsets: ['latin'],
  display: 'swap',
  // 界面实际用系统字体；关闭预加载，避免首屏预载后未使用导致的控制台告警
  preload: false,
});

const geistMono = Geist_Mono({
  variable: '--font-geist-mono',
  subsets: ['latin'],
  preload: false,
});

export const metadata: Metadata = {
  title: 'RexHub',
  description: 'RexHub PWA + FastAPI 资源检索',
  manifest: '/manifest.json',
  icons: {
    icon: [
      { url: '/favicon.ico', sizes: '32x32' },
      { url: '/icon-192.png', sizes: '192x192', type: 'image/png' },
      { url: '/icon-512.png', sizes: '512x512', type: 'image/png' },
    ],
    apple: [{ url: '/apple-touch-icon.png', sizes: '180x180', type: 'image/png' }],
  },
  appleWebApp: {
    capable: true,
    statusBarStyle: 'black-translucent',
    title: 'RexHub',
  },
};

export const viewport: Viewport = {
  width: 'device-width',
  initialScale: 1,
  maximumScale: 1,
  userScalable: false,
  viewportFit: 'cover',
  // 键盘覆盖内容，不挤缩布局视口（Chrome / Android；iOS 常忽略但仍声明）
  interactiveWidget: 'overlays-content',
  themeColor: [
    { media: '(prefers-color-scheme: light)', color: THEME_COLOR.light },
    { media: '(prefers-color-scheme: dark)', color: THEME_COLOR.dark },
  ],
};

// 首帧同步落类，避免先渲染错误主题再跳变（颜色与 lib/theme.ts 共用同一份常量）
const THEME_SCRIPT = `(function(){try{var t=localStorage.getItem('${THEME_KEY}');var d=t==='dark'||(t!=='light'&&matchMedia('(prefers-color-scheme:dark)').matches);var c=d?'${THEME_COLOR.dark}':'${THEME_COLOR.light}';var h=document.documentElement;h.classList.toggle('dark',d);h.classList.toggle('theme-dark',d);h.style.colorScheme=d?'dark':'light';h.style.backgroundColor=c;document.querySelectorAll('meta[name="theme-color"]').forEach(function(m){m.setAttribute('content',c)})}catch(e){}})()`;

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="zh-CN" suppressHydrationWarning>
      <head>
        <ShellBoot />
        {/* Apply theme synchronously to prevent flash of wrong theme */}
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
        <link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />
      </head>
      <body
        className={`${dmSerif.variable} ${geistMono.variable} font-sans antialiased`}
      >
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
