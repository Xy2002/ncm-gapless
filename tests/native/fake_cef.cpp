#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <string>
#include <vector>
#include <stdio.h>
#include "../../native/windows/cef91.h"
static std::vector<std::pair<std::wstring, std::wstring>> switches;
static int original_switches;
static int command_references;
static int ownership_errors;
static void AddCommand(CefBase*) { if (command_references <= 0) ownership_errors++; command_references++; }
static int ReleaseCommand(CefBase*) { command_references--; if (command_references < 0) ownership_errors++; return command_references == 0; }
static bool Mode(const wchar_t* text) { return wcsstr(GetCommandLineW(), text) != NULL; }
static int Valid(CefCommandLine*) { if (command_references <= 0) { ownership_errors++; return 0; } return 1; }
static int ReadOnly(CefCommandLine*) { return Mode(L"--readonly") ? 1 : 0; }
static int HasSwitch(CefCommandLine*, const CefString* name) {
    for (const auto& item : switches) if (item.first == std::wstring(name->text, name->length)) return 1;
    return 0;
}
static CefString* SwitchValue(CefCommandLine*, const CefString* name) {
    for (const auto& item : switches) if (item.first == std::wstring(name->text, name->length)) {
        CefString* value = new CefString();
        value->length = item.second.size(); value->text = new wchar_t[value->length + 1]; value->destructor = NULL;
        wcscpy_s(value->text, value->length + 1, item.second.c_str()); return value;
    }
    return NULL;
}
extern "C" __declspec(dllexport) void cef_string_userfree_utf16_free(CefString* value) { if (value) { delete[] value->text; delete value; } }
static void Append(CefCommandLine*, const CefString* name, const CefString* value) {
    std::wstring key(name->text, name->length), text(value->text, value->length);
    if (key == L"official-original") original_switches++;
    switches.push_back(std::make_pair(key, text));
}
static void Cancel() {
    wchar_t path[32768]; GetEnvironmentVariableW(L"LOCALAPPDATA", path, 32768);
    std::wstring flag = std::wstring(path) + L"\\NCMGapless\\startup\\enabled.txt";
    DeleteFileW(flag.c_str());
}
extern "C" __declspec(dllexport) int cef_version_info(int entry) {
    const int entries[] = {91, 2, 3, 0, 91, 0, 4472, 169};
    return entry == 0 && Mode(L"--unverified-cef") ? 92 : (entry >= 0 && entry < 8 ? entries[entry] : 0);
}
extern "C" __declspec(dllexport) const char* cef_api_hash(int) {
    return Mode(L"--mismatched-api") ? "different-abi" : "135912956b05b8d66775a091c5f7f17ae26eb09c";
}
extern "C" __declspec(dllexport) int cef_initialize(const void*, const void*, CefApp* app, void*) {
    switches.clear(); original_switches = 0; command_references = 1; ownership_errors = 0;
    CefCommandLine command = {};
    command.base.size = Mode(L"--small-command") ? 40 : sizeof(command);
    command.base.add_ref = AddCommand; command.base.release = ReleaseCommand;
    command.is_valid = Valid; command.is_read_only = ReadOnly;
    command.has_switch = HasSwitch; command.get_switch_value = SwitchValue; command.append_switch_with_value = Append;
    if (Mode(L"--existing-port")) switches.push_back(std::make_pair(L"remote-debugging-port", L"49321"));
    CefString type = { const_cast<wchar_t*>(L"renderer"), 8, NULL };
    if (app && app->before_command_line) app->before_command_line(app, Mode(L"--renderer-process") ? &type : NULL, &command);
    else ReleaseCommand(&command.base);
    if (Mode(L"--cancel-after-before")) Cancel();
    if (app) app->base.release(&app->base); // cef_initialize consumes the incoming app wrapper reference.
    bool loopback = false, port = false;
    for (const auto& item : switches) {
        if (item.first == L"remote-debugging-address" && item.second == L"127.0.0.1") loopback = true;
        if (item.first == L"remote-debugging-port" && _wtoi(item.second.c_str()) > 0) port = true;
    }
    printf("{\"originalSwitches\":%d,\"loopback\":%s,\"port\":%s,\"commandReferences\":%d,\"ownershipErrors\":%d}\n", original_switches, loopback ? "true" : "false", port ? "true" : "false", command_references, ownership_errors);
    return Mode(L"--init-failed") ? 0 : 1;
}
