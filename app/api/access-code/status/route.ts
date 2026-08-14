import { cookies } from 'next/headers';
import { apiSuccess } from '@/lib/server/api-response';
import { verifyAccessToken } from '@/lib/server/access-token';

export async function GET(request: Request) {
  const accessCode = process.env.ACCESS_CODE;
  const enabled = !!accessCode;

  let authenticated = false;
  if (enabled) {
    // Header auth (cross-site iframe embedding) takes precedence over the cookie,
    // since the SameSite=Lax cookie is not delivered inside a cross-site iframe.
    const headerCode = request.headers.get('x-access-code');
    if (headerCode && headerCode.length === accessCode.length) {
      let mismatch = 0;
      for (let i = 0; i < headerCode.length; i++) {
        mismatch |= headerCode.charCodeAt(i) ^ accessCode.charCodeAt(i);
      }
      authenticated = mismatch === 0;
    }
    if (!authenticated) {
      const cookieStore = await cookies();
      const token = cookieStore.get('openmaic_access')?.value;
      authenticated = !!token && verifyAccessToken(token, accessCode);
    }
  }

  return apiSuccess({ enabled, authenticated });
}
