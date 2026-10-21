#include "winhttp_proxy.h"

DWORD McdProxyConfig(WINHTTP_CURRENT_USER_IE_PROXY_CONFIG* config) {
  return WinHttpGetIEProxyConfigForCurrentUser(config) ? ERROR_SUCCESS : GetLastError();
}

DWORD McdProxyOpen(LPCWSTR agent, HINTERNET* session) {
  *session = WinHttpOpen(agent, WINHTTP_ACCESS_TYPE_NO_PROXY,
      WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!*session) return GetLastError();
  if (!WinHttpSetTimeouts(*session, 5000, 5000, 5000, 5000)) {
    const DWORD error = GetLastError();
    WinHttpCloseHandle(*session);
    *session = nullptr;
    return error;
  }
  return ERROR_SUCCESS;
}

DWORD McdProxyResolve(HINTERNET session, LPCWSTR url,
    WINHTTP_AUTOPROXY_OPTIONS* options, WINHTTP_PROXY_INFO* result) {
  return WinHttpGetProxyForUrl(session, url, options, result) ? ERROR_SUCCESS : GetLastError();
}

void McdProxyClose(HINTERNET session) {
  if (session) WinHttpCloseHandle(session);
}
