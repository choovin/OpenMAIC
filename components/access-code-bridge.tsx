'use client';

import { useEffect } from 'react';

/**
 * Cross-site embedding bridge for the ACCESS_CODE gate.
 *
 * When OpenMAIC is embedded in a cross-site <iframe>, the SameSite=Lax
 * `openmaic_access` cookie is never delivered, so the normal cookie-based auth
 * fails. Instead the parent passes the access code to the iframe — either via a
 * `?access_code=` query param on the iframe `src`, or via `postMessage` — and
 * we attach it as an `x-access-code` header on every same-origin `/api` request.
 *
 * A custom header (not a cookie) sidesteps the SameSite restriction entirely, so
 * this works over both HTTP and HTTPS with no cookie/`SameSite` changes.
 *
 * When there is no access code (direct, non-embedded use), the fetch wrapper is
 * a transparent pass-through — no header is added and behaviour is unchanged.
 */

let accessCode: string | null = null;
let patched = false;

function readCodeFromUrl(): void {
  if (typeof window === 'undefined' || accessCode) return;
  const code = new URLSearchParams(window.location.search).get('access_code');
  if (code) accessCode = code;
}

function installFetchPatch(): void {
  if (patched || typeof window === 'undefined') return;
  patched = true;

  const origFetch = window.fetch.bind(window);
  window.fetch = (input: RequestInfo | URL, init?: RequestInit) => {
    if (accessCode) {
      const urlStr =
        typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
      const isSameOriginApi =
        urlStr.startsWith('/api') || urlStr.startsWith(window.location.origin + '/api');
      if (isSameOriginApi) {
        const headers = new Headers(
          init?.headers ?? (input instanceof Request ? input.headers : undefined),
        );
        headers.set('x-access-code', accessCode);
        init = { ...init, headers };
      }
    }
    return origFetch(input as RequestInfo | URL, init);
  };
}

// Run as early as the client bundle evaluates, so the header is in place before
// AccessCodeGuard's `/api/access-code/status` fetch (and any other API call) fires.
readCodeFromUrl();
installFetchPatch();

export function AccessCodeBridge() {
  // Belt-and-braces: also run during render (before effects), and accept a code
  // pushed by the parent after load via postMessage.
  readCodeFromUrl();
  installFetchPatch();

  useEffect(() => {
    const onMessage = (event: MessageEvent) => {
      const data = event.data as { type?: string; code?: string } | null;
      if (data && data.type === 'openmaic-access-code' && typeof data.code === 'string') {
        accessCode = data.code;
      }
    };
    window.addEventListener('message', onMessage);
    return () => window.removeEventListener('message', onMessage);
  }, []);

  return null;
}
