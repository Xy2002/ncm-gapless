#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
int main() {
    HMODULE client = LoadLibraryW(L"cloudmusic.dll");
    if (!client) { printf("loader-error=%lu\n", GetLastError()); return 1; }
    auto run = (int (*)())GetProcAddress(client, "FixtureRun");
    if (!run || run()) return 2;
    HMODULE proxy = GetModuleHandleW(L"MSIMG32.dll");
    HMODULE drawing = GetModuleHandleW(L"ncm_gapless_msimg32.dll");
    const char* names[] = {"vSetDdrawflag", "AlphaBlend", "DllInitialize", "GradientFill", "TransparentBlt"};
    int forwarded = 0;
    for (const char* name : names) if (GetProcAddress(proxy, name) == GetProcAddress(drawing, name) && GetProcAddress(proxy, name)) forwarded++;
    printf("{\"forwardedExports\":%d}\n", forwarded);
    Sleep(1000);
    return forwarded == 5 ? 0 : 3;
}
