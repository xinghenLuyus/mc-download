#pragma once
#include <windows.h>
#include <winhttp.h>

#ifdef MCD_PROXY_BUILD
#define MCD_PROXY_API extern "C" __declspec(dllexport)
#else
#define MCD_PROXY_API extern "C" __declspec(dllimport)
#endif

// Return the error as data before Dart/VM transitions can change thread state.
MCD_PROXY_API DWORD McdProxyConfig(WINHTTP_CURRENT_USER_IE_PROXY_CONFIG* config);
MCD_PROXY_API DWORD McdProxyOpen(LPCWSTR agent, HINTERNET* session);
MCD_PROXY_API DWORD McdProxyResolve(HINTERNET session, LPCWSTR url,
    WINHTTP_AUTOPROXY_OPTIONS* options, WINHTTP_PROXY_INFO* result);
MCD_PROXY_API void McdProxyClose(HINTERNET session);
