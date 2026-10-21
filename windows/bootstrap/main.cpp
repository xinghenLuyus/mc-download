// SPDX-License-Identifier: MIT
// Native, statically linked launcher; the application remains a normal Flutter bundle.
#include <windows.h>
#include <shellapi.h>
#include <bcrypt.h>
// FDI defines the legacy HUGE keyword as an empty macro. Keep it local to
// this header: otherwise UCRT's later `extern double HUGE;` loses its name.
#pragma push_macro("HUGE")
#undef HUGE
#include <fdi.h>
#pragma pop_macro("HUGE")
#include <fcntl.h>
#include <io.h>
#include <sys/stat.h>
#include <share.h>
#include <cstdint>
#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>
#include "config.h"

namespace fs = std::filesystem;
namespace {
class Handle {
 public:
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~Handle() { if (value_ != INVALID_HANDLE_VALUE && value_) CloseHandle(value_); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  HANDLE get() const { return value_; }
 private:
  HANDLE value_;
};
void Require(bool ok, const char* message) {
  if (!ok) throw std::runtime_error(message);
}
std::wstring Wide(const std::string& text) {
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  Require(length > 0, "Invalid UTF-8 in runtime manifest.");
  std::wstring result(length, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), result.data(), length);
  return result;
}
fs::path Executable() {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  Require(length > 0 && length < buffer.size(), "Cannot locate launcher.");
  return fs::path(std::wstring(buffer.data(), length));
}
struct Resource { const BYTE* data; DWORD size; };
Resource Load(int id) {
  const HRSRC resource = FindResourceW(nullptr, MAKEINTRESOURCEW(id), RT_RCDATA);
  Require(resource != nullptr, "Missing embedded runtime.");
  const HGLOBAL memory = LoadResource(nullptr, resource);
  Require(memory != nullptr, "Cannot load embedded runtime.");
  return {static_cast<const BYTE*>(LockResource(memory)), SizeofResource(nullptr, resource)};
}
std::string Digest(Resource cab, Resource manifest) {
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  Require(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM, nullptr, 0) >= 0,
      "Cannot initialize SHA-256.");
  BCRYPT_HASH_HANDLE hash = nullptr;
  BYTE digest[32]{};
  const bool ok = BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0) >= 0 &&
      BCryptHashData(hash, const_cast<BYTE*>(cab.data), cab.size, 0) >= 0 &&
      BCryptHashData(hash, const_cast<BYTE*>(manifest.data), manifest.size, 0) >= 0 &&
      BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  BCryptCloseAlgorithmProvider(algorithm, 0);
  Require(ok, "Cannot verify embedded runtime.");
  std::string result;
  const char* hex = "0123456789abcdef";
  for (BYTE byte : digest) { result += hex[byte >> 4]; result += hex[byte & 15]; }
  return result;
}
struct Entry { fs::path path; uint64_t size; };
std::vector<Entry> Manifest(Resource resource) {
  std::istringstream input(std::string(reinterpret_cast<const char*>(resource.data), resource.size));
  std::vector<Entry> entries;
  std::string line;
  while (std::getline(input, line)) {
    const auto separator = line.find('\t');
    Require(separator != std::string::npos, "Invalid runtime manifest.");
    fs::path relative(Wide(line.substr(separator + 1)));
    Require(!relative.empty() && !relative.is_absolute() && !relative.has_root_name(),
        "Invalid runtime file path.");
    for (const auto& component : relative)
      Require(component != L".." && component != L"." && component.native().find(L':') == std::wstring::npos,
          "Invalid runtime file path.");
    entries.push_back({relative, std::stoull(line.substr(0, separator))});
  }
  Require(!entries.empty(), "Empty embedded runtime.");
  return entries;
}
bool Complete(const fs::path& directory, const std::vector<Entry>& entries, bool marker = true) {
  if (marker) {
    std::ifstream input(directory / L".complete");
    std::string id;
    std::getline(input, id);
    if (id != MCD_PAYLOAD_ID) return false;
  }
  for (const auto& entry : entries) {
    std::error_code error;
    if (!fs::is_regular_file(directory / entry.path, error) ||
        fs::file_size(directory / entry.path, error) != entry.size || error) return false;
  }
  return true;
}
HANDLE Lock(const fs::path& directory) {
  const ULONGLONG start = GetTickCount64();
  while (true) {
    HANDLE lock = CreateFileW((directory / L".extract.lock").c_str(), GENERIC_READ | GENERIC_WRITE,
        0, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (lock != INVALID_HANDLE_VALUE) return lock;
    const DWORD error = GetLastError();
    Require((error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION) &&
        GetTickCount64() - start < 120000, "Cannot lock runtime cache. Check folder permissions or try again.");
    Sleep(100);
  }
}
HANDLE Lease(const fs::path& directory, bool exclusive = false) {
  return CreateFileW((directory / L".in-use").c_str(), GENERIC_READ | GENERIC_WRITE,
      exclusive ? 0 : FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
}
void* DIAMONDAPI Allocate(ULONG bytes) { return std::malloc(bytes); }
void DIAMONDAPI Free(void* memory) { std::free(memory); }
int OpenFile(const fs::path& path, int flags, int sharing) {
  int file = -1;
  return _wsopen_s(&file, path.c_str(), flags | _O_BINARY, sharing,
      _S_IREAD | _S_IWRITE) == 0 ? file : -1;
}
fs::path cabinet_path;
INT_PTR DIAMONDAPI Open(char*, int flags, int) {
  return OpenFile(cabinet_path, flags, _SH_DENYNO);
}
UINT DIAMONDAPI Read(INT_PTR file, void* buffer, UINT bytes) { return static_cast<UINT>(_read(static_cast<int>(file), buffer, bytes)); }
UINT DIAMONDAPI Write(INT_PTR file, void* buffer, UINT bytes) { return static_cast<UINT>(_write(static_cast<int>(file), buffer, bytes)); }
int DIAMONDAPI Close(INT_PTR file) { return _close(static_cast<int>(file)); }
long DIAMONDAPI Seek(INT_PTR file, long offset, int origin) { return _lseek(static_cast<int>(file), offset, origin); }
struct Extraction { fs::path directory; const std::vector<Entry>& entries; };
INT_PTR DIAMONDAPI Notify(FDINOTIFICATIONTYPE type, PFDINOTIFICATION notification) {
  try {
    if (type == fdintNEXT_CABINET) return -1; // Only self-contained cabinets are supported.
    if (type == fdintCLOSE_FILE_INFO) return Close(notification->hf) == 0;
    if (type != fdintCOPY_FILE) return 0;
    const std::string name(notification->psz1);
    Require(!name.empty() && name.size() <= 8 &&
        name.find_first_not_of("0123456789") == std::string::npos, "Invalid cabinet entry.");
    auto& context = *static_cast<Extraction*>(notification->pv);
    const size_t index = std::stoul(name);
    Require(index < context.entries.size(), "Invalid cabinet entry index.");
    const auto target = context.directory / context.entries[index].path;
    fs::create_directories(target.parent_path());
    int file = OpenFile(target, _O_WRONLY | _O_CREAT | _O_EXCL, _SH_DENYRW);
    if (file == 0) { const int duplicate = _dup(file); _close(file); file = duplicate; }
    return file == -1 ? -1 : static_cast<INT_PTR>(file);
  } catch (...) { return -1; }
}
void Extract(const fs::path& stage, Resource resource, const std::vector<Entry>& entries) {
  const auto cabinet = stage / L"payload.cab";
  {
    std::ofstream output(cabinet, std::ios::binary);
    output.write(reinterpret_cast<const char*>(resource.data), resource.size);
    Require(output.good(), "Cannot write runtime. Check free disk space and folder permissions.");
  }
  ERF error{};
  HFDI fdi = FDICreate(Allocate, Free, Open, Read, Write, Close, Seek, cpuUNKNOWN, &error);
  Require(fdi != nullptr, "Cannot initialize cabinet extraction.");
  Extraction context{stage, entries};
  cabinet_path = cabinet;
  char name[] = "payload.cab", directory[] = "";
  const BOOL ok = FDICopy(fdi, name, directory, 0, Notify, nullptr, &context);
  FDIDestroy(fdi);
  Require(ok != FALSE, "Runtime extraction failed. Check free disk space and folder permissions.");
  fs::remove(cabinet);
  Require(Complete(stage, entries, false), "Extracted runtime is incomplete.");
  std::ofstream marker(stage / L".complete");
  marker << MCD_PAYLOAD_ID;
  Require(marker.good(), "Cannot finish runtime extraction.");
}
std::wstring Quote(const std::wstring& argument) {
  std::wstring result = L"\"";
  size_t slashes = 0;
  for (wchar_t character : argument) {
    if (character == L'\\') { ++slashes; continue; }
    result.append(character == L'"' ? slashes * 2 + 1 : slashes, L'\\');
    slashes = 0;
    result += character;
  }
  result.append(slashes * 2, L'\\');
  return result + L'"';
}
void Clean(const fs::path& cache, const fs::path& current) {
  // A shared lease is inherited by the Flutter process, including if this
  // launcher is terminated. Never remove a version used by another process.
  for (const auto& item : fs::directory_iterator(cache)) {
    const auto name = item.path().filename().u8string();
    if (item.path() == current || !item.is_directory() || name.size() != 64 ||
        name.find_first_not_of("0123456789abcdef") != std::string::npos) continue;
    bool unused;
    { Handle lease(Lease(item.path(), true)); unused = lease.get() != INVALID_HANDLE_VALUE; }
    if (unused) { std::error_code ignored; fs::remove_all(item.path(), ignored); }
  }
}
}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  try {
    const fs::path home = Executable().parent_path() / L".mcdownload";
    const fs::path cache = home / L"runtime";
    const fs::path runtime = cache / MCD_PAYLOAD_ID;
    const auto cab = Load(101), manifest = Load(102);
    const auto entries = Manifest(manifest);
    fs::create_directories(cache);
    HANDLE lease;
    {
      Handle lock(Lock(cache));
      if (!Complete(runtime, entries)) {
        Require(Digest(cab, manifest) == MCD_PAYLOAD_ID, "Embedded runtime checksum mismatch. Download the application again.");
        // No other extraction can be active while this lock is held.
        for (const auto& item : fs::directory_iterator(cache)) {
          const auto name = item.path().filename().u8string();
          if (name.find(std::string(MCD_PAYLOAD_ID) + ".partial-") == 0) fs::remove_all(item.path());
        }
        const auto stage = cache / (std::string(MCD_PAYLOAD_ID) + ".partial-" + std::to_string(GetCurrentProcessId()));
        fs::create_directories(stage);
        try {
          Extract(stage, cab, entries);
          if (fs::exists(runtime)) {
            { Handle replacement(Lease(runtime, true));
              Require(replacement.get() != INVALID_HANDLE_VALUE, "Runtime needs repair. Close other MC Download windows and retry."); }
            fs::remove_all(runtime);
          }
          fs::rename(stage, runtime);
        } catch (...) { std::error_code ignored; fs::remove_all(stage, ignored); throw; }
      }
      lease = Lease(runtime);
      Require(lease != INVALID_HANDLE_VALUE, "Cannot open runtime cache.");
    }
    Handle runtime_lease(lease);
    Require(SetHandleInformation(lease, HANDLE_FLAG_INHERIT, HANDLE_FLAG_INHERIT) != FALSE,
        "Cannot protect active runtime.");
    Require(SetEnvironmentVariableW(L"MCD_PORTABLE_DATA", home.c_str()) != FALSE,
        "Cannot configure portable data directory.");
    const auto application = runtime / L"mc_download.exe";
    std::wstring command = Quote(application.native());
    int count = 0;
    LPWSTR* arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    Require(arguments != nullptr, "Cannot read command-line arguments.");
    for (int i = 1; i < count; ++i) command += L" " + Quote(arguments[i]);
    LocalFree(arguments);
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    Require(CreateProcessW(application.c_str(), command.data(), nullptr, nullptr,
        TRUE, 0, nullptr, runtime.c_str(), &startup, &process) != FALSE,
        "Cannot start MC Download. Try deleting .mcdownload/runtime and launch again.");
    Handle child(process.hProcess), thread(process.hThread);
    // Once the new child has started, discard unused older runtimes immediately.
    // Keep the exit-time pass for versions still in use during this first pass.
    try { Handle lock(Lock(cache)); Clean(cache, runtime); } catch (...) { /* cleanup is optional */ }
    WaitForSingleObject(child.get(), INFINITE);
    DWORD code = EXIT_FAILURE;
    GetExitCodeProcess(child.get(), &code);
    try { Handle lock(Lock(cache)); Clean(cache, runtime); } catch (...) { /* cleanup is optional */ }
    return static_cast<int>(code);
  } catch (const std::exception& error) {
    std::wstring detail;
    try { detail = Wide(error.what()); } catch (...) { detail = L"File system error."; }
    const std::wstring text = L"MC Download 无法启动。\n\n" + detail +
        L"\n\n请将程序放在可写目录。必要时删除 .mcdownload/runtime 后重试；设置和游戏文件无需删除。";
    MessageBoxW(nullptr, text.c_str(), L"MC Download", MB_OK | MB_ICONERROR);
    return EXIT_FAILURE;
  }
}
