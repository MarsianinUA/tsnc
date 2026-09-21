package link

import "core:os"
import "core:strconv"
import "core:strings"
import win32 "core:sys/windows"

// windows_library_dirs finds the x64 library directories lld-link needs: the Windows SDK's um
// (kernel32.lib) and ucrt (libucrt.lib), and MSVC's (libcmt.lib, libvcruntime.lib). Odin, Rust and
// Zig find them the same way. On failure detail is in the temp allocator, like the directories.
@(private)
windows_library_dirs :: proc() -> (dirs: [3]string, err: Link_Error) {
	// --- Windows SDK: the root from the registry, then the newest version with both libraries.
	root, root_found := kits_root()
	if !root_found {
		return {}, {.Windows_SDK_Missing, `HKLM\` + KITS_KEY + `\` + KITS_VALUE}
	}
	sdk_lib := join(root, "Lib")
	// An unreadable directory has no entries, and the check below reports it.
	entries, _ := os.read_all_directory_by_path(sdk_lib, context.temp_allocator)
	newest: u64
	for entry in entries {
		version, is_version := sdk_version(entry.name)
		if !is_version || version <= newest {
			continue
		}
		um := join(entry.fullpath, "um", "x64")
		ucrt := join(entry.fullpath, "ucrt", "x64")
		if os.is_file(join(um, "kernel32.lib")) && os.is_file(join(ucrt, "libucrt.lib")) {
			newest = version
			dirs[0], dirs[1] = um, ucrt
		}
	}
	if dirs[0] == "" {
		return {}, {.Windows_SDK_Missing, sdk_lib}
	}

	// --- MSVC: the newest Visual Studio or Build Tools with the C++ x64 tools, then its default
	// toolset. vswhere ships with the Visual Studio installer since 2017, always at this path.
	vswhere := join(
		os.get_env("ProgramFiles(x86)", context.temp_allocator),
		"Microsoft Visual Studio",
		"Installer",
		"vswhere.exe",
	)
	vswhere_command := []string {
		vswhere,
		"-latest",
		"-products",
		"*",
		"-requires",
		"Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
		"-property",
		"installationPath",
		"-utf8",
		"-nologo",
	}
	state, stdout, _, run_err := os.process_exec(
		{command = vswhere_command},
		context.temp_allocator,
	)
	installation := strings.trim_space(string(stdout))
	if run_err != nil || state.exit_code != 0 || installation == "" {
		return {}, {.MSVC_Missing, vswhere}
	}
	version_file := join(
		installation,
		"VC",
		"Auxiliary",
		"Build",
		"Microsoft.VCToolsVersion.default.txt",
	)
	toolset, read_err := os.read_entire_file(version_file, context.temp_allocator)
	if read_err != nil {
		return {}, {.MSVC_Missing, version_file}
	}
	dirs[2] = join(
		installation,
		"VC",
		"Tools",
		"MSVC",
		strings.trim_space(string(toolset)),
		"lib",
		"x64",
	)
	if !os.is_file(join(dirs[2], "libcmt.lib")) {
		return {}, {.MSVC_Missing, dirs[2]}
	}
	return dirs, {}
}

@(private)
KITS_KEY :: `SOFTWARE\Microsoft\Windows Kits\Installed Roots`
@(private)
KITS_VALUE :: "KitsRoot10"

// kits_root opens the 32-bit view of the registry, because that is where the installer writes the
// Windows 10 SDK root.
@(private)
kits_root :: proc() -> (root: string, found: bool) {
	key: win32.HKEY
	status := win32.RegOpenKeyExW(
		win32.HKEY_LOCAL_MACHINE,
		win32.L(KITS_KEY),
		0,
		win32.KEY_QUERY_VALUE | win32.KEY_WOW64_32KEY,
		&key,
	)
	if status != 0 {
		return
	}
	defer win32.RegCloseKey(key)

	// A root longer than the buffer counts as missing.
	units: [1024]u16
	size := win32.DWORD(size_of(units))
	status = win32.RegGetValueW(
		key,
		nil,
		win32.L(KITS_VALUE),
		win32.RRF_RT_REG_SZ,
		nil,
		raw_data(units[:]),
		&size,
	)
	if status != 0 {
		return
	}
	root, _ = win32.utf16_to_utf8(units[:size / size_of(u16)], context.temp_allocator)
	return root, root != ""
}

// sdk_version turns a directory name such as 10.0.26100.0 into a number that orders versions. Each
// of the four parts fits 16 bits, as in every Windows file version.
@(private)
sdk_version :: proc(name: string) -> (version: u64, ok: bool) {
	parts := strings.split(name, ".", context.temp_allocator)
	if len(parts) != 4 {
		return
	}
	for part in parts {
		value, is_number := strconv.parse_uint(part, 10)
		if !is_number || value > 0xFFFF {
			return 0, false
		}
		version = version << 16 | u64(value)
	}
	return version, true
}
