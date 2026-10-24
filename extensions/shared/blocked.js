(() => {
  const api = globalThis.browser || globalThis.chrome;
  const serviceId = new URL(location.href).searchParams.get('service') || '';
  const byId = id => document.getElementById(id);
  let returnURL = null;
  async function refresh() {
    try {
      const response = await api.runtime.sendMessage({type:'blockedInfo',serviceId});
      const rule = response?.rule;
      returnURL = null;
      if (!rule) {
        byId('title').textContent='Website status unavailable';
        byId('message').textContent='Open Kids Quota on this Mac to check setup. You can also enter a website address in your browser.';
        byId('reset').textContent='';
      } else if (!response.connected || rule.reason === 'unavailable') {
        byId('title').textContent='Waiting for Kids Quota';
        byId('message').textContent='This restricted website is paused while the quota service reconnects.';
        byId('reset').textContent='Your saved allowance has not been reset.';
      } else if (rule.blocked) {
        byId('title').textContent=`${rule.name || 'This website'}: weekly limit reached`;
        byId('message').textContent='The website and its selected Mac app share one weekly allowance.';
        byId('reset').textContent=`Resets ${new Date(rule.resetAt).toLocaleString([], {weekday:'long',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})}`;
      } else {
        byId('title').textContent='Your allowance is available';
        byId('message').textContent='You can return to the website.';
        byId('reset').textContent='';
        if (rule.domains[0]) returnURL=`https://${rule.domains[0].hostname}/`;
      }
      byId('retry').disabled=!returnURL;
    } catch {
      byId('title').textContent='Kids Quota needs attention';
      byId('message').textContent='Open the Kids Quota app to reconnect browser protection.';
      byId('retry').disabled=true;
    }
  }
  byId('refresh').addEventListener('click',refresh);
  byId('retry').addEventListener('click',()=>{if(returnURL) location.assign(returnURL);});
  setInterval(refresh,5000);
  refresh();
})();
