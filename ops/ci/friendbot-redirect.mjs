// CI only. Loaded into our own processes with NODE_OPTIONS=--import=<this file>.
// His code calls https://friendbot.stellar.org directly (F28); this sends those calls
// to the local network's friendbot instead. Does nothing unless LOCAL_FRIENDBOT_URL is set.
const target = process.env.LOCAL_FRIENDBOT_URL;
if (target) {
  const realFetch = globalThis.fetch;
  globalThis.fetch = (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (/^https:\/\/friendbot\.stellar\.org\/?(\?|$)/.test(url)) {
      return realFetch(target + new URL(url).search, init);
    }
    return realFetch(input, init);
  };
}