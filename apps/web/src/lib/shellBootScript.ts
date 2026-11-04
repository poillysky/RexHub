/**
 * 首帧前写入 data-shell：真机 / 窄屏 / standalone = native，
 * 其余浏览器 = browser（直接铺满视口，不再模拟 iPhone 外框）。
 */
export const SHELL_BOOT_SCRIPT = `(function(){try{var d=document.documentElement;var alone=window.matchMedia("(display-mode: standalone)").matches||!!(navigator.standalone);var narrow=window.matchMedia("(max-width: 480px)").matches;var dark=window.matchMedia("(prefers-color-scheme: dark)").matches;d.dataset.shell=(alone||narrow)?"native":"browser";d.dataset.standalone=alone?"1":"0";d.dataset.theme=dark?"dark":"light";d.style.colorScheme=dark?"dark":"light";if(alone){d.style.setProperty("--app-height","100vh");}else{d.style.removeProperty("--app-height");}if(dark){d.style.backgroundColor="#000000";}else{d.style.backgroundColor="#f2f2f7";}}catch(e){document.documentElement.dataset.shell="native";}})();`;
