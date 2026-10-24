(() => {
  const api = globalThis.browser || globalThis.chrome;
  function time(seconds) {const m=Math.ceil(seconds/60);return m>=60?`${Math.floor(m/60)} h ${m%60} min`:`${m} min`;}
  async function refresh() {
    const status=document.getElementById('status');
    try {
      const data=await api.runtime.sendMessage({type:'status'});
      status.textContent=data.enforcementError || (!data.configured?'Setup needed in the Mac app':!data.connected?'Service unavailable — restricted sites paused':data.coverage!=='complete'?'Connected · some protection needs setup':'Connected');
      const list=document.getElementById('rules');list.replaceChildren();
      for(const rule of data.rules || []) {
        const row=document.createElement('div');row.className='service-row';
        const name=document.createElement('span');name.textContent=rule.name || rule.serviceId;
        const balance=document.createElement('span');balance.textContent=rule.reason==='unavailable'?'Paused':rule.blocked?'Limit reached':`${time(rule.remainingSeconds)} left`;
        row.append(name,balance);list.append(row);
      }
    } catch {status.textContent='Browser protection needs attention. Open Kids Quota.';}
  }
  document.getElementById('refresh').addEventListener('click',refresh);
  refresh();
})();
