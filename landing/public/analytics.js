  (function(){
    const GA_ID = 'G-M65PNVW5TE';
    const CONSENT_KEY = 'darkbloom_ga_consent';
    const COOKIE_MAX_AGE = 60 * 60 * 24 * 365;
    const ATTRIBUTION_PARAMS = new Set(['_gl','dclid','fbclid','gbraid','gclid','li_fat_id','mc_cid','mc_eid','msclkid','srsltid','ttclid','wbraid']);
    const UTM_PARAMS = new Set(['utm_source','utm_medium','utm_campaign','utm_term','utm_content','utm_id','utm_source_platform','utm_creative_format','utm_marketing_tactic']);

    function cookieDomain(){
      const host = window.location.hostname;
      return host === 'darkbloom.dev' || host.endsWith('.darkbloom.dev') ? '; domain=.darkbloom.dev' : '';
    }

    function getCookieConsent(){
      const prefix = CONSENT_KEY + '=';
      const cookie = document.cookie.split(';').map(part => part.trim()).find(part => part.startsWith(prefix));
      const value = cookie ? decodeURIComponent(cookie.slice(prefix.length)) : '';
      return value === 'granted' || value === 'denied' ? value : 'unset';
    }

    function getConsent(){
      try {
        const stored = window.localStorage.getItem(CONSENT_KEY);
        if (stored === 'granted' || stored === 'denied') return stored;
      } catch (e) {}
      return getCookieConsent();
    }

    function setConsent(value){
      try { window.localStorage.setItem(CONSENT_KEY, value); } catch (e) {}
      const secure = window.location.protocol === 'https:' ? '; secure' : '';
      document.cookie = CONSENT_KEY + '=' + encodeURIComponent(value) + '; path=/; max-age=' + COOKIE_MAX_AGE + '; samesite=lax' + secure + cookieDomain();
    }

    function allowedParam(name){
      return UTM_PARAMS.has(name) || ATTRIBUTION_PARAMS.has(name);
    }

    function sanitizeLocation(raw){
      try {
        const url = new URL(raw);
        const params = new URLSearchParams();
        for (const [name, value] of url.searchParams) {
          if (allowedParam(name)) params.append(name, value);
        }
        url.search = params.toString();
        url.hash = '';
        return url.toString();
      } catch (e) {
        return window.location.origin + window.location.pathname;
      }
    }

    function sanitizeReferrer(raw){
      if (!raw) return undefined;
      try {
        const url = new URL(raw);
        url.search = '';
        url.hash = '';
        return url.toString();
      } catch (e) {
        return undefined;
      }
    }

    function initAnalytics(){
      if (window.__darkbloomGaInitialized || getConsent() !== 'granted') return;
      window.__darkbloomGaInitialized = true;
      window.dataLayer = window.dataLayer || [];
      window.gtag = window.gtag || function(){ window.dataLayer.push(arguments); };
      const script = document.createElement('script');
      script.async = true;
      script.src = 'https://www.googletagmanager.com/gtag/js?id=' + encodeURIComponent(GA_ID);
      document.head.appendChild(script);
      window.gtag('js', new Date());
      window.gtag('config', GA_ID, { send_page_view: false });
      window.gtag('event', 'page_view', {
        page_location: sanitizeLocation(window.location.href),
        page_referrer: sanitizeReferrer(document.referrer),
        page_title: document.title,
        send_to: GA_ID
      });
    }

    // Analytics is auto-allowed by default (privacy-filtered: page URLs are
    // sanitized and no PII is sent). No consent prompt is shown; a visitor's
    // prior explicit "denied" choice is still respected.
    if (getConsent() === 'unset') setConsent('granted');
    initAnalytics();
  })();
