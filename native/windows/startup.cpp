// The loader only changes the browser's documented CEF startup callback.
// DllMain performs no file I/O, process creation, waits, or LoadLibrary calls.
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <windows.h>
#include <winver.h>
#include <stdint.h>
#include <string>
#include <vector>
#include "cef91.h"

static wchar_t module_path[32768];
static CefInitialize original_initialize;
static BeforeCommandLine original_before;
static std::wstring generation;
static std::wstring client_path;
static unsigned short debug_port;
static bool flags_applied;
static LONG initialize_entered;

// CEF bridge arguments carry transferred references, not borrowed pointers.
// Pin a reference across the original bridge call before using its C wrapper.
struct ReleaseCef {
    CefBase* base = NULL;
    ~ReleaseCef() { if (base) base->release(base); }
    ReleaseCef() = default;
    ReleaseCef(const ReleaseCef&) = delete;
    ReleaseCef& operator=(const ReleaseCef&) = delete;
};

static std::wstring Parent(const std::wstring& path) {
    size_t slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"" : path.substr(0, slash);
}
static std::wstring StateDirectory() {
    wchar_t path[32768];
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", path, 32768);
    return length && length < 32768 ? std::wstring(path, length) + L"\\NCMGapless\\startup" : L"";
}
static std::string ReadSmallFile(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return "";
    DWORD size = GetFileSize(file, NULL), count = 0;
    std::string text;
    if (size > 0 && size < 65536) {
        text.resize(size);
        if (!ReadFile(file, &text[0], size, &count, NULL) || count != size) text.clear();
    }
    CloseHandle(file);
    return text;
}
static std::wstring FromUtf8(const std::string& bytes) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(), (int)bytes.size(), NULL, 0);
    if (!count) return L"";
    std::wstring text(count, L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes.data(), (int)bytes.size(), &text[0], count);
    return text;
}
static std::string ToUtf8(const std::wstring& text) {
    int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), (int)text.size(), NULL, 0, NULL, NULL);
    if (!count) return "";
    std::string bytes(count, '\0');
    WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text.data(), (int)text.size(), &bytes[0], count, NULL, NULL);
    return bytes;
}
static bool SamePath(const std::wstring& left, const std::wstring& right) {
    return CompareStringOrdinal(left.c_str(), -1, right.c_str(), -1, TRUE) == CSTR_EQUAL;
}
static std::wstring EnabledGeneration() {
    const std::wstring directory = StateDirectory();
    if (directory.empty()) return L"";
    std::wstring text = FromUtf8(ReadSmallFile(directory + L"\\enabled.txt"));
    if (text.size() < 40 || text.substr(0, 6) != L"NCMG1\n") return L"";
    const size_t end = text.find(L'\n', 6);
    if (end != 38) return L"";
    std::wstring token = text.substr(6, 32);
    for (wchar_t ch : token) if (!((ch >= L'0' && ch <= L'9') || (ch >= L'a' && ch <= L'f'))) return L"";
    std::wstring target = text.substr(39);
    if (!target.empty() && target.back() == L'\n') target.pop_back();
    return SamePath(target, client_path) ? token : L"";
}
static bool SupportedClient() {
    // Match the C ABI, independently of the application's release number.
    // Only call this API after the CEF 91 version gate below (newer CEF changed it).
    const auto hash = (const char* (*)(int))GetProcAddress(GetModuleHandleW(L"libcef.dll"), "cef_api_hash");
    if (!hash) return false;
    const char* value = hash(0);
    return value && strcmp(value, "135912956b05b8d66775a091c5f7f17ae26eb09c") == 0;
}
static unsigned short AvailablePort() {
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data)) return 0;
    unsigned short port = 0;
    for (int attempt = 0; attempt < 4 && !port; ++attempt) {
        SOCKET socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (socket == INVALID_SOCKET) break;
        sockaddr_in address = {};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (!bind(socket, (sockaddr*)&address, sizeof(address))) {
            int size = sizeof(address);
            if (!getsockname(socket, (sockaddr*)&address, &size)) {
                const auto candidate = ntohs(address.sin_port);
                if (candidate >= 1024 && candidate < 65535) port = candidate;
            }
        }
        closesocket(socket);
    }
    WSACleanup();
    return port;
}
static void Append(CefCommandLine* command, const wchar_t* name, const wchar_t* value) {
    CefString key = { const_cast<wchar_t*>(name), wcslen(name), NULL };
    CefString text = { const_cast<wchar_t*>(value), wcslen(value), NULL };
    command->append_switch_with_value(command, &key, &text);
}
static void Before(CefApp* self, const CefString* type, CefCommandLine* command) {
    const bool reference_valid = command && command->base.size >= sizeof(CefBase) && command->base.add_ref && command->base.release;
    ReleaseCef command_hold;
    if (reference_valid) {
        if (original_before) command->base.add_ref(&command->base);
        command_hold.base = &command->base; // With no original callback, adopt the incoming reference.
    }
    if (original_before) original_before(self, type, command);
    if (!reference_valid || (type && type->length) || command->base.size < 168 ||
        !command->is_valid || !command->is_valid(command) || !command->is_read_only ||
        command->is_read_only(command) || !command->append_switch_with_value) return;
    try {
        if (EnabledGeneration() != generation) return;
        CefString name = { const_cast<wchar_t*>(L"remote-debugging-port"), 21, NULL };
        if (!command->has_switch) return;
        // Reuse an explicit debugging port instead of silently replacing it.
        if (command->has_switch(command, &name)) {
            const auto release = (void (*)(CefString*))GetProcAddress(GetModuleHandleW(L"libcef.dll"), "cef_string_userfree_utf16_free");
            if (!command->get_switch_value || !release) return;
            CefString* value = command->get_switch_value(command, &name);
            unsigned long port = 0;
            bool valid = value && value->text && value->length > 0 && value->length <= 5;
            if (valid) for (size_t index = 0; index < value->length; ++index) {
                const wchar_t digit = value->text[index];
                if (digit < L'0' || digit > L'9') { valid = false; break; }
                port = port * 10 + digit - L'0';
            }
            if (value) release(value);
            if (!valid || port < 1024 || port >= 65535) return;
            debug_port = (unsigned short)port;
        } else { debug_port = AvailablePort(); }
        if (!debug_port) return;
        wchar_t port[8]; swprintf_s(port, L"%hu", debug_port);
        Append(command, L"remote-debugging-address", L"127.0.0.1");
        Append(command, L"remote-debugging-port", port);
        flags_applied = true;
    } catch (...) { /* A failed optional loader must leave official startup intact. */ }
}
static uint64_t StartedFileTime() {
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes(GetCurrentProcess(), &created, &exited, &kernel, &user)) return 0;
    return ((uint64_t)created.dwHighDateTime << 32) | created.dwLowDateTime;
}
static void Record(const wchar_t* stage) {
    const std::wstring path = StateDirectory() + L"\\native.txt";
    const std::wstring temporary = path + L"." + std::to_wstring(GetCurrentProcessId()) + L".tmp";
    const std::wstring body = L"NCMG1\n" + std::to_wstring(GetCurrentProcessId()) + L"\n" +
        std::to_wstring(StartedFileTime()) + L"\n" + std::to_wstring(debug_port) + L"\n" +
        generation + L"\n" + stage + L"\n" + client_path + L"\n";
    const std::string bytes = ToUtf8(body);
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    const bool success = WriteFile(file, bytes.data(), (DWORD)bytes.size(), &written, NULL) && written == bytes.size();
    CloseHandle(file);
    if (success) MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
    DeleteFileW(temporary.c_str());
}
static void StartHelper() {
    if (EnabledGeneration() != generation) return;
    wchar_t system[32768];
    UINT length = GetSystemDirectoryW(system, 32768);
    if (!length || length >= 32768) return;
    const std::wstring executable = std::wstring(system) + L"\\WindowsPowerShell\\v1.0\\powershell.exe";
    std::wstring runtime = Parent(module_path) + L"\\ncm-gapless";
    const std::string active = ReadSmallFile(runtime + L"\\active.txt");
    if (!active.empty()) {
        if (active.size() != 64) return;
        for (char ch : active) if (!((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f'))) return;
        runtime += L"\\versions\\" + FromUtf8(active);
    }
    const std::wstring script = runtime + L"\\tools\\AutoAttach-NcmGapless.ps1";
    std::wstring arguments = L"\"" + executable + L"\" -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" +
        script + L"\" -Port " + std::to_wstring(debug_port) + L" -ClientProcessId " + std::to_wstring(GetCurrentProcessId()) +
        L" -StartedFileTime " + std::to_wstring(StartedFileTime()) + L" -Token " + generation;
    STARTUPINFOW startup = {}; startup.cb = sizeof(startup); startup.dwFlags = STARTF_USESHOWWINDOW; startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process = {};
    if (CreateProcessW(executable.c_str(), &arguments[0], NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process)) {
        CloseHandle(process.hThread); CloseHandle(process.hProcess); Record(L"helper-started");
    } else { Record(L"helper-start-failed"); }
}
static int Initialize(const void* args, const void* settings, CefApp* app, void* sandbox) {
    if (InterlockedCompareExchange(&initialize_entered, 1, 0) != 0) return original_initialize(args, settings, app, sandbox);
    bool changed = false;
    ReleaseCef app_hold;
    try {
        wchar_t executable[32768];
        DWORD length = GetModuleFileNameW(NULL, executable, 32768);
        if (length && length < 32768) client_path.assign(executable, length);
        const auto version = (int (*)(int))GetProcAddress(GetModuleHandleW(L"libcef.dll"), "cef_version_info");
        generation = EnabledGeneration();
        if (version && version(0) == 91 && version(6) == 4472 && SupportedClient() &&
            app && app->base.size >= 48 && app->base.add_ref && app->base.release && !generation.empty() &&
            SamePath(Parent(client_path), Parent(module_path))) {
            original_before = app->before_command_line;
            app->base.add_ref(&app->base);
            app_hold.base = &app->base;
            app->before_command_line = Before;
            changed = true;
        }
    } catch (...) { }
    // Calling the original outside our exception handlers preserves its behavior.
    const int result = original_initialize(args, settings, app, sandbox);
    if (changed && app->before_command_line == Before) app->before_command_line = original_before;
    if (result && flags_applied) { try { StartHelper(); } catch (...) { } }
    return result;
}
static bool InstallImportHook() {
    // Both modules are already mapped by the Windows loader. No module is loaded here.
    const HMODULE image = GetModuleHandleW(L"cloudmusic.dll");
    if (!image) return false;
    auto base = (unsigned char*)image;
    auto dos = (IMAGE_DOS_HEADER*)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return false;
    auto nt = (IMAGE_NT_HEADERS64*)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->FileHeader.Machine != IMAGE_FILE_MACHINE_AMD64) return false;
    const auto directory = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (!directory.VirtualAddress || directory.VirtualAddress >= nt->OptionalHeader.SizeOfImage) return false;
    for (auto import = (IMAGE_IMPORT_DESCRIPTOR*)(base + directory.VirtualAddress); import->Name; ++import) {
        if (_stricmp((char*)base + import->Name, "libcef.dll") || !import->OriginalFirstThunk) continue;
        auto names = (IMAGE_THUNK_DATA64*)(base + import->OriginalFirstThunk);
        auto addresses = (IMAGE_THUNK_DATA64*)(base + import->FirstThunk);
        for (; names->u1.AddressOfData; ++names, ++addresses) {
            if (IMAGE_SNAP_BY_ORDINAL64(names->u1.Ordinal)) continue;
            auto name = (IMAGE_IMPORT_BY_NAME*)(base + names->u1.AddressOfData);
            if (strcmp((char*)name->Name, "cef_initialize")) continue;
            DWORD previous = 0, ignored = 0;
            if (!VirtualProtect(&addresses->u1.Function, sizeof(void*), PAGE_READWRITE, &previous)) return false;
            original_initialize = (CefInitialize)addresses->u1.Function;
            InterlockedExchangePointer((void* volatile*)&addresses->u1.Function, (void*)&Initialize);
            VirtualProtect(&addresses->u1.Function, sizeof(void*), previous, &ignored);
            return true;
        }
    }
    return false;
}
BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        const DWORD length = GetModuleFileNameW(instance, module_path, 32768);
        if (!length || length >= 32768) return TRUE;
        wchar_t executable[32768];
        const DWORD size = GetModuleFileNameW(NULL, executable, 32768);
        if (!size || size >= 32768) return TRUE;
        const wchar_t* name = wcsrchr(executable, L'\\');
        if (!name || _wcsicmp(name + 1, L"cloudmusic.exe")) return TRUE;
        InstallImportHook();
    }
    return TRUE;
}
