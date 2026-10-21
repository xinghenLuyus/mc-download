#include "winhttp_proxy.h"
#include <cstdio>

int main() {
  WINHTTP_AUTOPROXY_OPTIONS options{};
  options.dwFlags = WINHTTP_AUTOPROXY_AUTO_DETECT;
  options.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DNS_A;
  WINHTTP_PROXY_INFO result{};
  // A deterministic WinHTTP failure without PAC, network, or registry changes.
  const DWORD error = McdProxyResolve(nullptr, L"https://example.invalid/", &options, &result);
  SetLastError(ERROR_SUCCESS); // Emulate error-clobbering VM/library work.
  if (error == ERROR_SUCCESS) {
    std::fprintf(stderr, "WinHTTP failure lost its error code.\n");
    return 1;
  }
  HINTERNET session = nullptr;
  const DWORD opened = McdProxyOpen(L"MC-Download-test", &session);
  if (opened != ERROR_SUCCESS || !session) {
    std::fprintf(stderr, "Cannot open WinHTTP session: %lu\n", opened);
    return 1;
  }
  McdProxyClose(session);
  std::puts("WinHTTP native error capture and session checks passed.");
  return 0;
}
