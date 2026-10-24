// No page text, keystrokes, or browsing history is collected. These events wake
// the background adapter, which reads the actual selected tab through browser APIs.
(() => {
  const api = globalThis.browser || globalThis.chrome;
  const wake = () => {
    if (document.visibilityState !== 'visible' || !document.hasFocus()) return;
    api.runtime.sendMessage({type:'wake'}).catch(()=>{});
  };
  document.addEventListener('visibilitychange',wake);
  window.addEventListener('focus',wake);
  window.addEventListener('pageshow',wake);
  window.setInterval(wake,5000);
  wake();
})();
