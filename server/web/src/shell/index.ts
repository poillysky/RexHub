/** iOS standalone PWA shell — keep stable; swap features instead. */
export { AppShell } from './AppShell';
export {
  TabProvider,
  useTabNavigation,
  TAB_ROUTES,
  type TabRoute,
} from './TabContext';
export { TabPane, useTabPaneVisible } from './TabPane';
export { HapticsProvider, useHaptics } from './HapticsProvider';
