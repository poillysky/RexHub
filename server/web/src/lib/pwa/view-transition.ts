/**
 * Utility for the View Transitions API (Safari 18+, Chrome 111+).
 * Falls back to immediate navigation when the API isn't available.
 */

type ViewTransitionDocument = Document & {
  startViewTransition?: (callback: () => void | Promise<void>) => unknown;
};

export function startViewTransition(callback: () => void | Promise<void>): void {
  if (typeof document === 'undefined') {
    callback();
    return;
  }
  const doc = document as ViewTransitionDocument;
  if (typeof doc.startViewTransition === 'function') {
    doc.startViewTransition(callback);
  } else {
    callback();
  }
}
