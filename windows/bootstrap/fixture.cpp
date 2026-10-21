// CI fixture for exercising the real native launcher without opening Flutter UI.
#include <windows.h>
#include <shellapi.h>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>
namespace fs = std::filesystem;
int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  int count = 0;
  LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!arguments) return 90;
  fs::path report;
  DWORD hold = 0;
  int code = 0;
  for (int i = 1; i + 1 < count; ++i) {
    const std::wstring argument(arguments[i]);
    if (argument == L"--report") report = arguments[i + 1];
    if (argument == L"--hold-ms") hold = std::stoul(arguments[i + 1]);
    if (argument == L"--exit-code") code = std::stoi(arguments[i + 1]);
  }
  if (report.empty()) { LocalFree(arguments); return 91; }
  std::vector<wchar_t> path(32768), data(32768);
  GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  const DWORD length = GetEnvironmentVariableW(L"MCD_PORTABLE_DATA", data.data(), static_cast<DWORD>(data.size()));
  if (length == 0 || length >= data.size()) { LocalFree(arguments); return 92; }
  std::ofstream output(report, std::ios::binary);
  output << fs::path(data.data()).u8string() << '\n'
         << fs::current_path().u8string() << '\n'
         << fs::path(path.data()).u8string() << '\n';
  for (int i = 1; i < count; ++i) output << fs::path(arguments[i]).u8string() << '\n';
  output.close();
  LocalFree(arguments);
  if (!output.good()) return 93;
  Sleep(hold);
  return code;
}
